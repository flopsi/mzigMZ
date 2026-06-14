/// Scan decoder for Thermo RAW files. Owns the decode pipeline for a single scan.
///
/// Before this module existed, the decode pipeline was copy-pasted into four methods
/// on AppState (loadScan, loadScanArena, loadScanBulk, loadScanBulkWithFreq). The
/// duplication meant a bug in label-parse or min/max required four fixes.
///
/// C1 refactor (completed): extracted decode pipeline into ScanDecoder.
/// C2 refactor (this file): replaced scattered reuse buffers with SpectrumPool.
///   - All decode targets write into the pool (grow-only, amortized allocation).
///   - Callers copy from pool into owned memory, or borrow directly for bulk mode.
///   - No more Destination enum, no more allocateBuffers() switch.
const std = @import("std");
const advanced = @import("advanced_packet");
const raw = @import("raw_file");
const profile = @import("profile_packet");
const trailer_events = @import("trailer_events");
const spec_packet_header = @import("spec/packet_header");
const spectrum_pool = @import("spectrum_pool");

pub const SPECTRUM_CACHE_SIZE = 8;

/// Estimate the number of centroid peaks from the centroid word count.
/// Uses floor division because `num_centroid_words * 4` includes the segment
/// count words as well as the peak entries, so it is not always an exact
/// multiple of the peak entry size.
fn estimateCentroidPeakCount(num_centroid_words: u32, accurate_mass: bool) error{OffsetOverflow}!u64 {
    const entry_size: u64 = if (accurate_mass) 12 else 8;
    const centroid_bytes = std.math.mul(u64, @as(u64, num_centroid_words), 4) catch return error.OffsetOverflow;
    return centroid_bytes / entry_size;
}

pub const DecodeError = error{OffsetBeyondFile} || advanced.PacketError || profile.ProfileError;

/// Reference to a scan's packet metadata. Passed to `ScanDecoder.decode`.
pub const ScanRef = struct {
    packet_type: u32,
    data_offset: u64,
};

const CachedSpectrum = struct {
    scan_index: usize,
    spectrum: advanced.Spectrum,
    mz_cap: usize,
    intensity_cap: usize,
    features_cap: usize,
    freq: ?[]f64,
    freq_cap: usize,
};

/// Decoded spectrum data. Slices point into SpectrumPool internal buffers.
/// WARNING: Invalid after the next decode() or decodeBulk() call — the pool
/// may reallocate or overwrite. If you need to keep the data across calls,
/// copy the slices (e.g. allocator.dupe).
pub const DecodeResult = struct {
    num_points: usize,
    mz: []f64,
    intensity: []f32,
    features_opt: ?[]advanced.PeakFeatures,
    freq: ?[]f64,
    mz_min: f64,
    mz_max: f64,
    intensity_max: f32,
};

pub const ScanDecoder = struct {
    allocator: std.mem.Allocator,
    mm: std.Io.File.MemoryMap,
    packet_pos: u64,
    file_size: u64,
    trailer_events: ?trailer_events.TrailerScanEvents,

    // Grow-only buffer pool — all decode targets write here.
    pool: spectrum_pool.SpectrumPool,

    // Spectrum cache for recently viewed scans (avoids re-decode on navigation).
    cache: [SPECTRUM_CACHE_SIZE]?CachedSpectrum,
    cache_next: usize,

    pub fn init(allocator: std.mem.Allocator) ScanDecoder {
        return .{
            .allocator = allocator,
            .mm = undefined,
            .packet_pos = 0,
            .file_size = 0,
            .trailer_events = null,
            .pool = spectrum_pool.SpectrumPool.init(allocator),
            .cache = .{null} ** SPECTRUM_CACHE_SIZE,
            .cache_next = 0,
        };
    }

    pub fn deinit(self: *ScanDecoder) void {
        self.free_cache();
        self.pool.deinit();
    }

    /// Configure with the open RawFile. Called once at AppState.openFile time.
    pub fn configure(self: *ScanDecoder, mm: std.Io.File.MemoryMap, packet_pos: u64, file_size: u64, trailers: ?trailer_events.TrailerScanEvents) void {
        self.mm = mm;
        self.packet_pos = packet_pos;
        self.file_size = file_size;
        self.trailer_events = trailers;
    }

    /// Check if a scan is in the cache and return the cached spectrum (shallow borrow).
    pub fn get_cached(self: ScanDecoder, scan_index: usize) ?advanced.Spectrum {
        for (self.cache) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.scan_index == scan_index) {
                    return entry.spectrum;
                }
            }
        }
        return null;
    }
    pub const getCached = get_cached; // DEPRECATED: use get_cached

    /// Cache a decoded spectrum by stealing the pool buffers (infallible).
    /// The pool is reset to empty; the next decode() will reallocate.
    pub fn cache_spectrum_steal(self: *ScanDecoder, scan_index: usize, num_points: usize, mz_min: f64, mz_max: f64, intensity_max: f32, has_features: bool) void {
        const slot = self.cache_next;
        self.cache_next = (self.cache_next + 1) % SPECTRUM_CACHE_SIZE;

        if (self.cache[slot]) |*old| {
            self.allocator.free(old.spectrum.mz.ptr[0..old.mz_cap]);
            self.allocator.free(old.spectrum.intensity.ptr[0..old.intensity_cap]);
            if (old.features_cap > 0) {
                self.allocator.free(old.spectrum.features.?.ptr[0..old.features_cap]);
            }
            if (old.freq_cap > 0) {
                if (old.freq) |f| self.allocator.free(f.ptr[0..old.freq_cap]);
            }
        }

        const stolen = self.pool.shrink_and_steal(num_points, has_features);

        self.cache[slot] = .{
            .scan_index = scan_index,
            .spectrum = .{
                .mz = stolen.mz,
                .intensity = stolen.intensity,
                .features = stolen.features,
                .mz_min = mz_min,
                .mz_max = mz_max,
                .intensity_max = intensity_max,
            },
            .mz_cap = stolen.mz_cap,
            .intensity_cap = stolen.intensity_cap,
            .features_cap = stolen.features_cap,
            .freq = stolen.freq,
            .freq_cap = stolen.freq_cap,
        };
    }
    pub const cacheSpectrumSteal = cache_spectrum_steal; // DEPRECATED: use cache_spectrum_steal

    pub fn free_cache(self: *ScanDecoder) void {
        for (&self.cache) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                self.allocator.free(entry.spectrum.mz.ptr[0..entry.mz_cap]);
                self.allocator.free(entry.spectrum.intensity.ptr[0..entry.intensity_cap]);
                if (entry.features_cap > 0) {
                    self.allocator.free(entry.spectrum.features.?.ptr[0..entry.features_cap]);
                }
                if (entry.freq_cap > 0) {
                    if (entry.freq) |f| self.allocator.free(f.ptr[0..entry.freq_cap]);
                }
                entry_opt.* = null;
            }
        }
    }
    pub const freeCache = free_cache; // DEPRECATED: use free_cache

    pub fn is_cached(self: ScanDecoder, spectrum: advanced.Spectrum) bool {
        for (self.cache) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.spectrum.mz.ptr == spectrum.mz.ptr) return true;
            }
        }
        return false;
    }
    pub const isCached = is_cached; // DEPRECATED: use is_cached

    /// Return the raw frequency buffer from the last profile decode.
    /// Null if the last decode was not a profile packet with freq enabled.
    pub fn freq_buffer(self: ScanDecoder) ?[]f64 {
        if (self.pool.freq.items.len == 0) return null;
        return self.pool.freq.items;
    }
    pub const freqBuffer = freq_buffer; // DEPRECATED: use freq_buffer

    /// Return the intensity buffer from the last decode.
    pub fn intensity_buffer(self: ScanDecoder) []f32 {
        return self.pool.intensity.items;
    }
    pub const intensityBuffer = intensity_buffer; // DEPRECATED: use intensity_buffer

    /// Return the m/z buffer from the last decode.
    pub fn mz_buffer(self: ScanDecoder) []f64 {
        return self.pool.mz.items;
    }
    pub const mzBuffer = mz_buffer; // DEPRECATED: use mz_buffer

    /// Decode a scan. All decoded data is written into the internal pool.
    /// The returned DecodeResult borrows from the pool; the borrow is valid
    /// until the next decode() call.
    pub fn decode(
        self: *ScanDecoder,
        scan_index: usize,
        scan: *const ScanRef,
    ) DecodeError!DecodeResult {
        const packet_offset = std.math.add(u64, self.packet_pos, scan.data_offset) catch return error.OffsetOverflow;
        if (packet_offset >= self.file_size) return error.OffsetBeyondFile;

        const header_size: usize = spec_packet_header.CURRENT.header_size;
        const packet_header_end = std.math.add(u64, packet_offset, header_size) catch return error.OffsetOverflow;
        if (packet_header_end > self.file_size) return error.Truncated;

        const packet_offset_usz = std.math.cast(usize, packet_offset) orelse return error.OffsetOverflow;
        const packet_header_end_usz = std.math.cast(usize, packet_header_end) orelse return error.OffsetOverflow;
        const header_bytes = self.mm.memory[packet_offset_usz..packet_header_end_usz];
        const h = try advanced.read_header(header_bytes, 0);
        const packet_size = try advanced.packet_size_from_header(h);
        const bounded_size = @min(packet_size, self.file_size - packet_offset);
        const actual_size = std.math.cast(usize, bounded_size) orelse return error.OffsetOverflow;
        if (actual_size == 0) return error.Truncated;

        const packet_end_usz = std.math.cast(usize, std.math.add(u64, packet_offset, actual_size) catch return error.OffsetOverflow) orelse return error.OffsetOverflow;
        const packet_slice = self.mm.memory[packet_offset_usz..packet_end_usz];

        const packet_type = scan.packet_type & 0xFFFF;
        const is_profile = packet_type == raw.PACKET_TYPE_FT_PROFILE;
        const has_profile_data = h.num_profile_words > 0;
        const decode_profile = is_profile and has_profile_data;
        const needs_features = !decode_profile;

        // Estimate peak count for buffer sizing
        const est_points: usize = if (decode_profile) blk: {
            const segment_bytes = std.math.mul(usize, @as(usize, h.num_segments), 8) catch return error.OffsetOverflow;
            const segment_data_start = std.math.add(usize, 32, segment_bytes) catch return error.OffsetOverflow;
            var seg_pos = segment_data_start;
            var total_expanded: usize = 0;
            var seg: u32 = 0;
            while (seg < h.num_segments) : (seg += 1) {
                const segment_struct_end = std.math.add(usize, seg_pos, 24) catch return error.OffsetOverflow;
                if (packet_slice.len >= segment_struct_end) {
                    const num_expanded = std.mem.readInt(u32, packet_slice[seg_pos + 20 ..][0..4], .little);
                    total_expanded = std.math.add(usize, total_expanded, num_expanded) catch return error.OffsetOverflow;
                }
                seg_pos = std.math.add(usize, seg_pos, 24) catch return error.OffsetOverflow;
            }
            break :blk std.math.cast(usize, @max(64, total_expanded)) orelse return error.OffsetOverflow;
        } else blk: {
            const est_count = try estimateCentroidPeakCount(h.num_centroid_words, h.accurate_mass_centroids());
            break :blk std.math.cast(usize, @max(64, est_count)) orelse return error.OffsetOverflow;
        };

        // Ensure pool buffers are large enough
        try self.pool.ensure(est_points, needs_features, decode_profile);

        const mz_buf = self.pool.mz.items;
        const inten_buf = self.pool.intensity.items;
        const feat_buf = if (needs_features) self.pool.features.items else null;
        // Dispatch to the correct decoder
        const num_points = if (decode_profile) blk: {
            var calibrators: []const f64 = &[_]f64{};
            if (self.trailer_events) |te| {
                if (te.get_event(scan_index)) |evt| {
                    calibrators = evt.mass_calibrators;
                }
            }
            const use_subsegment = (h.default_feature_word & 0x40) == 0 and (h.default_feature_word & 0x80) != 0;

            if (self.pool.freq.items.len >= est_points) {
                break :blk try profile.decode_ft_profile_with_freq(packet_slice, calibrators, self.pool.freq.items, mz_buf, inten_buf, use_subsegment);
            } else {
                break :blk try profile.decode_ft_profile(packet_slice, calibrators, mz_buf, inten_buf, use_subsegment);
            }
        } else try advanced.decode_simplified_centroids_into_buffers(
            packet_slice,
            0,
            mz_buf,
            inten_buf,
            feat_buf,
            self.allocator,
        );

        // Compute min/max using SIMD where possible
        var mz_min: f64 = std.math.inf(f64);
        var mz_max: f64 = -std.math.inf(f64);
        var intensity_max: f32 = 0;

        if (num_points >= 4) {
            const Vec4f64 = @Vector(4, f64);
            var mz_min_vec: Vec4f64 = @splat(std.math.inf(f64));
            var mz_max_vec: Vec4f64 = @splat(-std.math.inf(f64));

            const simd_end = num_points - (num_points % 4);
            var i: usize = 0;
            while (i < simd_end) : (i += 4) {
                const v = Vec4f64{ mz_buf[i], mz_buf[i + 1], mz_buf[i + 2], mz_buf[i + 3] };
                mz_min_vec = @min(mz_min_vec, v);
                mz_max_vec = @max(mz_max_vec, v);
            }
            mz_min = @reduce(.Min, mz_min_vec);
            mz_max = @reduce(.Max, mz_max_vec);

            while (i < num_points) : (i += 1) {
                const m = mz_buf[i];
                if (m < mz_min) mz_min = m;
                if (m > mz_max) mz_max = m;
            }

            const Vec8f32 = @Vector(8, f32);
            var inten_max_vec: Vec8f32 = @splat(0.0);

            const simd_end_inten = num_points - (num_points % 8);
            i = 0;
            while (i < simd_end_inten) : (i += 8) {
                const v = Vec8f32{
                    inten_buf[i],     inten_buf[i + 1], inten_buf[i + 2], inten_buf[i + 3],
                    inten_buf[i + 4], inten_buf[i + 5], inten_buf[i + 6], inten_buf[i + 7],
                };
                inten_max_vec = @max(inten_max_vec, v);
            }
            intensity_max = @reduce(.Max, inten_max_vec);

            while (i < num_points) : (i += 1) {
                const inten = inten_buf[i];
                if (inten > intensity_max) intensity_max = inten;
            }
        } else {
            for (mz_buf[0..num_points], inten_buf[0..num_points]) |m, inten| {
                if (m < mz_min) mz_min = m;
                if (m > mz_max) mz_max = m;
                if (inten > intensity_max) intensity_max = inten;
            }
        }

        if (num_points == 0) {
            mz_min = 0;
            mz_max = 1;
            intensity_max = 1;
        }

        const has_freq = decode_profile and self.pool.freq.items.len >= num_points;

        return .{
            .num_points = num_points,
            .mz = mz_buf[0..num_points],
            .intensity = inten_buf[0..num_points],
            .features_opt = if (needs_features) feat_buf else null,
            .freq = if (has_freq) self.pool.freq.items[0..num_points] else null,
            .mz_min = mz_min,
            .mz_max = mz_max,
            .intensity_max = intensity_max,
        };
    }
};

test "decode returns OffsetBeyondFile for packet offset past file end" {
    var decoder = ScanDecoder.init(std.testing.allocator);
    defer decoder.deinit();
    decoder.configure(undefined, 0, 0, null);
    const scan: ScanRef = .{ .packet_type = raw.PACKET_TYPE_FT_CENTROID, .data_offset = 1 };
    try std.testing.expectError(error.OffsetBeyondFile, decoder.decode(0, &scan));
}

test "decode returns OffsetOverflow for extreme packet offset" {
    var decoder = ScanDecoder.init(std.testing.allocator);
    defer decoder.deinit();
    decoder.configure(undefined, std.math.maxInt(u64), 0, null);
    const scan: ScanRef = .{ .packet_type = raw.PACKET_TYPE_FT_CENTROID, .data_offset = 1 };
    try std.testing.expectError(error.OffsetOverflow, decoder.decode(0, &scan));
}

test "centroid peak count estimate uses floor division for non-exact section size" {
    // 381 centroid words * 4 = 1524 bytes. With an 8-byte standard-mass entry,
    // 1524 / 8 = 190 remainder 4. The old divExact path returned OffsetOverflow;
    // floor division must yield 190.
    const est_standard = try estimateCentroidPeakCount(381, false);
    try std.testing.expectEqual(@as(u64, 190), est_standard);

    // 381 centroid words * 4 = 1524 bytes. With a 12-byte accurate-mass entry,
    // 1524 / 12 = 127 exactly.
    const est_accurate = try estimateCentroidPeakCount(381, true);
    try std.testing.expectEqual(@as(u64, 127), est_accurate);
}
