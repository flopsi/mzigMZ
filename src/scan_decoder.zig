/// Scan decoder for Thermo RAW files. Owns the decode pipeline for a single scan.
/// The pipeline: read packet header → compute size → estimate peaks → dispatch
/// (centroid or profile) → SIMD min/max reduction → post-process into destination.
///
/// Before this module existed, the decode pipeline was copy-pasted into four methods
/// on AppState (loadScan, loadScanArena, loadScanBulk, loadScanBulkWithFreq). The
/// duplication meant a bug in label-parse or min/max required four fixes, and the
/// packet-header read was tested four different ways. Extracting it here gives a
/// single point of truth for the hot path.
///
/// Two adapters sit on top:
/// - AppState.loadScan* delegates to ScanDecoder and handles post-processing
///   (ownership, caching, label parse) in thin adapter methods.
/// - bench.zig calls AppState.loadScan* directly, so the adapter methods are
///   also the observable API.
const std = @import("std");
const advanced = @import("advanced_packet");
const raw = @import("raw_file");
const profile = @import("profile_packet");
const trailer_events = @import("trailer_events");

pub const SPECTRUM_CACHE_SIZE = 8;

const CachedSpectrum = struct {
    scan_index: usize,
    spectrum: advanced.Spectrum,
};

/// Destination for the decoded scan data. Each variant encodes ownership:
/// - `.owned`: caller manages lifetime (AppState.loadScan)
/// - `.arena`: lifetime managed by arena (AppState.loadScanArena)
/// - `.reuse_buffers`: caller reuses grow-only buffers (AppState.loadScanBulk)
/// - `.reuse_with_freq`: also populates freq output (AppState.loadScanBulkWithFreq)
pub const Destination = enum {
    /// Decode into freshly allocated arrays owned by the caller.
    /// The result.mz and result.intensity are owned; result.features_opt if non-null.
    owned,
    /// Decode into arena-allocated arrays. The arena owns everything.
    /// Caller must provide arena_allocator so decoder allocates directly.
    arena,
    /// Decode into reusable grow-only buffers (reuse_mz, reuse_intensity).
    /// The caller may hold the buffers across calls; they grow but never shrink.
    reuse_buffers,
    /// Like reuse_buffers but also populates reuse_freq with raw frequencies
    /// (for profile calibration). Caller must provide a freq buffer.
    reuse_with_freq,
};

/// Result of a successful decode. The caller decides what to do with the arrays
/// based on which Destination variant was used. For .owned and .arena, the caller
/// is responsible for calling deinit on the arrays if decode failed after allocation.
/// For .reuse_buffers and .reuse_with_freq, no ownership is transferred.
pub const DecodeResult = struct {
    num_points: usize,
    /// mz values. For .owned: caller owns. For .arena: arena owns. For .reuse_*: borrow.
    mz: []f64,
    /// Intensity values. Same ownership as mz.
    intensity: []f32,
    /// Per-peak features (centroid only, null for profile). Same ownership as mz.
    features_opt: ?[]advanced.PeakFeatures,
    /// Computed bounds from SIMD reduction
    mz_min: f64,
    mz_max: f64,
    intensity_max: f32,
};

/// Internal intermediate result used between decode and post-process.
const DecodeIntermediate = struct {
    num_points: usize,
    mz: []f64,
    intensity: []f32,
    features_opt: ?[]advanced.PeakFeatures,
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

    // Reusable decode buffers (amortized allocation across bulk iteration).
    // These are the same buffers AppState manages separately; ScanDecoder
    // borrows them so AppState retains control of allocation/lifetime.
    reuse_mz: ?[]f64,
    reuse_intensity: ?[]f32,
    reuse_freq: ?[]f64,
    reuse_features: ?[]advanced.PeakFeatures,
    reuse_widths: ?[]f32,
    reuse_noise: ?[]advanced.NoiseInfoPacket,

    // Spectrum cache for recently viewed scans (avoids re-decode on navigation).
    // ScanDecoder manages its own cache; AppState holds it via the decoder field.
    cache: [SPECTRUM_CACHE_SIZE]?CachedSpectrum,
    cache_next: usize,

    pub fn init(allocator: std.mem.Allocator) ScanDecoder {
        return .{
            .allocator = allocator,
            .mm = undefined,
            .packet_pos = 0,
            .file_size = 0,
            .trailer_events = null,
            .reuse_mz = null,
            .reuse_intensity = null,
            .reuse_freq = null,
            .reuse_features = null,
            .reuse_widths = null,
            .reuse_noise = null,
            .cache = .{null} ** SPECTRUM_CACHE_SIZE,
            .cache_next = 0,
        };
    }

    /// Configure with the open RawFile. Called once at AppState.openFile time.
    pub fn configure(self: *ScanDecoder, mm: std.Io.File.MemoryMap, packet_pos: u64, file_size: u64, trailers: ?trailer_events.TrailerScanEvents) void {
        self.mm = mm;
        self.packet_pos = packet_pos;
        self.file_size = file_size;
        self.trailer_events = trailers;
    }

    /// Configure reuse buffers. Called by AppState after its own buffer
    /// allocation so we borrow from AppState's allocation state.
    pub fn setReuseBuffers(
        self: *ScanDecoder,
        mz: ?[]f64,
        intensity: ?[]f32,
        freq: ?[]f64,
        features: ?[]advanced.PeakFeatures,
        widths: ?[]f32,
        noise: ?[]advanced.NoiseInfoPacket,
    ) void {
        self.reuse_mz = mz;
        self.reuse_intensity = intensity;
        self.reuse_freq = freq;
        self.reuse_features = features;
        self.reuse_widths = widths;
        self.reuse_noise = noise;
    }

    /// Check if a scan is in the cache and return the cached spectrum (shallow borrow).
    /// Returns null if not cached.
    pub fn getCached(self: ScanDecoder, scan_index: usize) ?advanced.Spectrum {
        for (self.cache) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.scan_index == scan_index) {
                    return entry.spectrum;
                }
            }
        }
        return null;
    }

    /// Cache a decoded spectrum (deep copy into the round-robin slot).
    pub fn cacheSpectrum(self: *ScanDecoder, scan_index: usize, spectrum: advanced.Spectrum) !void {
        const slot = self.cache_next;
        self.cache_next = (self.cache_next + 1) % SPECTRUM_CACHE_SIZE;

        // Evict old entry
        if (self.cache[slot]) |*old| {
            old.spectrum.deinit(self.allocator);
        }

        const mz = try self.allocator.dupe(f64, spectrum.mz);
        const intensity = try self.allocator.dupe(f32, spectrum.intensity);
        const ranges = try self.allocator.dupe(advanced.MassRange, spectrum.ranges);
        const features: ?[]advanced.PeakFeatures = if (spectrum.features) |f|
            try self.allocator.dupe(advanced.PeakFeatures, f)
        else
            null;

        self.cache[slot] = .{
            .scan_index = scan_index,
            .spectrum = .{
                .mz = mz,
                .intensity = intensity,
                .ranges = ranges,
                .features = features,
                .mz_min = spectrum.mz_min,
                .mz_max = spectrum.mz_max,
                .intensity_max = spectrum.intensity_max,
            },
        };
    }

    /// Free all cached spectra. Call at shutdown.
    pub fn freeCache(self: *ScanDecoder) void {
        for (&self.cache) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                entry.spectrum.deinit(self.allocator);
                entry_opt.* = null;
            }
        }
    }

    /// Check if a given spectrum's memory is owned by the cache (pointer identity).
    pub fn isCached(self: ScanDecoder, spectrum: advanced.Spectrum) bool {
        for (self.cache) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.spectrum.mz.ptr == spectrum.mz.ptr) return true;
            }
        }
        return false;
    }

    /// Decode a scan into the given destination. Returns the intermediate result
    /// (arrays + computed bounds). The caller applies post-processing (ownership,
    /// cache, label parse) based on the destination variant.
    ///
    /// scan_index: index into the scan table
    /// scan: the ScanInfo entry (packet_type, data_offset)
    /// destination: where the decoded data should go (owned/arena/reuse/reuse+freq)
    ///
    /// Returns error on file-level issues (truncated, range). Does not return
    /// errors for unsupported packet types — those produce num_points=0.
    pub fn decode(
        self: *ScanDecoder,
        scan_index: usize,
        scan: *const struct {
            packet_type: u32,
            data_offset: u64,
        },
        destination: Destination,
    ) !DecodeIntermediate {
        const packet_offset = self.packet_pos + scan.data_offset;
        if (packet_offset >= self.file_size) return error.OffsetBeyondFile;

        const header_size: usize = 32;
        if (packet_offset + header_size > self.file_size) return error.Truncated;

        const header_bytes = self.mm.memory[packet_offset..packet_offset + header_size];
        const h = advanced.PacketHeader{
            .num_segments = std.mem.readInt(u32, header_bytes[0..4], .little),
            .num_profile_words = std.mem.readInt(u32, header_bytes[4..8], .little),
            .num_centroid_words = std.mem.readInt(u32, header_bytes[8..12], .little),
            .default_feature_word = std.mem.readInt(u32, header_bytes[12..16], .little),
            .num_non_default_feature_words = std.mem.readInt(u32, header_bytes[16..20], .little),
            .num_expansion_words = std.mem.readInt(u32, header_bytes[20..24], .little),
            .num_noise_info_words = std.mem.readInt(u32, header_bytes[24..28], .little),
            .num_debug_info_words = std.mem.readInt(u32, header_bytes[28..32], .little),
        };
        const packet_size = advanced.packetSizeFromHeader(h);
        const actual_size: usize = @intCast(@min(packet_size, self.file_size - packet_offset));
        if (actual_size == 0) return error.Truncated;

        const packet_slice = self.mm.memory[packet_offset..packet_offset + actual_size];

        // Determine packet type and whether to decode full profile or centroids
        const packet_type = scan.packet_type & 0xFFFF;
        const is_profile = packet_type == raw.PACKET_TYPE_FT_PROFILE;
        const has_centroid_data = h.num_centroid_words > 0;
        const decode_profile = is_profile and !has_centroid_data;
        const needs_features = !decode_profile;

        // Estimate peak count for buffer allocation
        const est_points: usize = if (decode_profile) blk: {
            // Profile packets: sum all segments' num_expanded_words.
            // See UNSKILLED.md: "DO NOT silently ignore profile buffer sizing bug"
            const segment_data_start = 32 + @as(usize, h.num_segments) * 8;
            var seg_pos = segment_data_start;
            var total_expanded: usize = 0;
            var seg: u32 = 0;
            while (seg < h.num_segments) : (seg += 1) {
                if (packet_slice.len >= seg_pos + 24) {
                    const num_expanded = std.mem.readInt(u32, packet_slice[seg_pos + 20..][0..4], .little);
                    total_expanded += num_expanded;
                }
                seg_pos += 24;
            }
            break :blk @intCast(@max(64, total_expanded));
        } else blk: {
            const accurate = h.accurateMassCentroids();
            const entry_size: u64 = if (accurate) 12 else 8;
            break :blk @intCast(@max(64, h.num_centroid_words * 4 / entry_size));
        };

        // Allocate decode buffers based on destination
        const buf_result = try self.allocateBuffers(destination, est_points, needs_features);
        const mz_buf = buf_result[0];
        const inten_buf = buf_result[1];
        const feat_buf = buf_result[2];
        const freq_buf = buf_result[3];

        // Dispatch to the correct decoder
        const num_points = if (decode_profile) blk: {
            var calibrators: []const f64 = &[_]f64{};
            if (self.trailer_events) |te| {
                if (te.getEvent(scan_index)) |evt| {
                    calibrators = evt.mass_calibrators;
                }
            }
            const use_subsegment = (h.default_feature_word & 0x40) == 0
                and (h.default_feature_word & 0x80) != 0;

            if (destination == .reuse_with_freq and freq_buf != null) {
                break :blk try profile.decodeFtProfileWithFreq(
                    packet_slice, calibrators, freq_buf.?, mz_buf, inten_buf, use_subsegment);
            } else {
                break :blk try profile.decodeFtProfile(
                    packet_slice, calibrators, mz_buf, inten_buf, use_subsegment);
            }
        } else try advanced.decodeSimplifiedCentroidsIntoBuffers(
            packet_slice, 0, mz_buf, inten_buf, feat_buf,
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

            // SIMD reduction for intensity max (8 at a time)
            const Vec8f32 = @Vector(8, f32);
            var inten_max_vec: Vec8f32 = @splat(0.0);

            const simd_end_inten = num_points - (num_points % 8);
            i = 0;
            while (i < simd_end_inten) : (i += 8) {
                const v = Vec8f32{
                    inten_buf[i], inten_buf[i + 1], inten_buf[i + 2], inten_buf[i + 3],
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

        return .{
            .num_points = num_points,
            .mz = mz_buf[0..num_points],
            .intensity = inten_buf[0..num_points],
            .features_opt = if (needs_features) feat_buf else null,
            .mz_min = mz_min,
            .mz_max = mz_max,
            .intensity_max = intensity_max,
        };
    }

    /// Allocate decode buffers based on destination variant.
    /// Returns (mz, intensity, features, freq). Only the buffers needed for the
    /// given destination are populated; others are null.
    fn allocateBuffers(
        self: *ScanDecoder,
        destination: Destination,
        est_points: usize,
        needs_features: bool,
    ) !struct { []f64, []f32, ?[]advanced.PeakFeatures, ?[]f64 } {
        switch (destination) {
            .owned, .arena => {
                const mz = try self.allocator.alloc(f64, est_points);
                errdefer self.allocator.free(mz);
                const inten = try self.allocator.alloc(f32, est_points);
                errdefer self.allocator.free(inten);
                var feat: ?[]advanced.PeakFeatures = null;
                if (needs_features) {
                    feat = try self.allocator.alloc(advanced.PeakFeatures, est_points);
                    errdefer self.allocator.free(feat.?);
                }
                return .{ mz, inten, feat, null };
            },
            .reuse_buffers => {
                if (self.reuse_mz == null or self.reuse_mz.?.len < est_points) {
                    if (self.reuse_mz) |old| self.allocator.free(old);
                    self.reuse_mz = try self.allocator.alloc(f64, est_points);
                }
                if (self.reuse_intensity == null or self.reuse_intensity.?.len < est_points) {
                    if (self.reuse_intensity) |old| self.allocator.free(old);
                    self.reuse_intensity = try self.allocator.alloc(f32, est_points);
                }
                return .{ self.reuse_mz.?, self.reuse_intensity.?, null, null };
            },
            .reuse_with_freq => {
                if (self.reuse_mz == null or self.reuse_mz.?.len < est_points) {
                    if (self.reuse_mz) |old| self.allocator.free(old);
                    self.reuse_mz = try self.allocator.alloc(f64, est_points);
                }
                if (self.reuse_intensity == null or self.reuse_intensity.?.len < est_points) {
                    if (self.reuse_intensity) |old| self.allocator.free(old);
                    self.reuse_intensity = try self.allocator.alloc(f32, est_points);
                }
                if (self.reuse_freq == null or self.reuse_freq.?.len < est_points) {
                    if (self.reuse_freq) |old| self.allocator.free(old);
                    self.reuse_freq = try self.allocator.alloc(f64, est_points);
                }
                return .{ self.reuse_mz.?, self.reuse_intensity.?, null, self.reuse_freq.? };
            },
        }
    }
};