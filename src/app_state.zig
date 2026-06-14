/// Global application state shared between GUI components.
const std = @import("std");
const advanced = @import("advanced_packet");
const raw = @import("raw_file");
const raw_file_reader = @import("raw_file_reader");
const scan_event = @import("scan_event");
const trailer_events = @import("trailer_events");
const profile = @import("profile_packet");
const scan_decoder = @import("scan_decoder");
const file_state = @import("file_state");
const view_state = @import("view_state");

// Re-exports for backwards compatibility (Opportunity 1: decomposition).
// Callers can migrate to importing file_state / view_state directly.
pub const ScanInfo = file_state.ScanInfo;
pub const ZoomState = view_state.ZoomState;
pub const ViewMode = view_state.ViewMode;

/// Chromatogram data extracted from scan indices (no packet decode needed).
/// Contains all scans; filtering by MS level happens at render time.
pub const Chromatogram = struct {
    rt: []f64, // retention time in minutes
    intensity: []f64, // TIC or base peak intensity
    ms_level: []u8, // 1=MS1, 2=MS2, etc.
    num_points: usize,

    pub fn deinit(self: Chromatogram, allocator: std.mem.Allocator) void {
        allocator.free(self.rt);
        allocator.free(self.intensity);
        allocator.free(self.ms_level);
    }
};

// ScanInfo is now defined in file_state.zig and re-exported above.
// Keeping this comment for greppability during migration.

/// Full error surface for AppState public operations.
pub const AppStateError = file_state.FileStateError || error{
    NoFileOpen,
    OffsetBeyondFile,
} || std.mem.Allocator.Error || raw.RawResolveError || advanced.PacketError || profile.ProfileError;

/// Result of a zero-allocation bulk scan load, including decoded array bounds.
pub const BulkLoadResult = struct {
    num_points: usize,
    mz_min: f64,
    mz_max: f64,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // File-level metadata (raw file, scan list, trailers, instrument id).
    // Extracted into FileState during Opportunity 1 decomposition.
    file: file_state.FileState,

    // Current spectrum
    current_spectrum: ?advanced.Spectrum,
    current_scan_index: usize, // index into scans array

    // View state (zoom, pan, filters, view mode).
    // Extracted into ViewState during Opportunity 1 decomposition.
    view: view_state.ViewState,

    // Label-parse temporary buffers (resolution widths + noise packets).
    // These are NOT spectrum decode buffers; they are only used when
    // parsing peak metadata (resolution, noise, baseline) in loadScan.
    label_widths: ?[]f32,
    label_noise: ?[]advanced.NoiseInfoPacket,

    // Filtered index mapping for virtual list view (null = no filter)
    filtered_indices: ?[]usize,

    // Chromatograms (computed at file open)
    tic_chromatogram: ?Chromatogram,
    bpc_chromatogram: ?Chromatogram,
    chromatogram_ms_level_filter: ?u8,

    // Scan decoder — owns the decode pipeline and spectrum cache.
    // Extracted from the four loadScan* methods (C1 refactor). Keeps
    // packet-header read, decode dispatch, and SIMD min/max in one place.
    decoder: scan_decoder.ScanDecoder,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AppState {
        return .{
            .allocator = allocator,
            .io = io,
            .file = file_state.FileState.init(allocator),
            .current_spectrum = null,
            .current_scan_index = 0,
            .view = view_state.ViewState.init(),
            .label_widths = null,
            .label_noise = null,
            .filtered_indices = null,
            .tic_chromatogram = null,
            .bpc_chromatogram = null,
            .chromatogram_ms_level_filter = null,
            .decoder = scan_decoder.ScanDecoder.init(allocator),
        };
    }

    pub fn deinit(self: *AppState) void {
        if (self.label_widths) |buf| {
            self.allocator.free(buf);
            self.label_widths = null;
        }
        if (self.label_noise) |buf| {
            self.allocator.free(buf);
            self.label_noise = null;
        }
        if (self.filtered_indices) |fi| {
            self.allocator.free(fi);
            self.filtered_indices = null;
        }
        if (self.tic_chromatogram) |*c| {
            c.deinit(self.allocator);
            self.tic_chromatogram = null;
        }
        if (self.bpc_chromatogram) |*c| {
            c.deinit(self.allocator);
            self.bpc_chromatogram = null;
        }
        // Free current_spectrum only if it's not owned by the cache
        if (self.current_spectrum) |*spec| {
            if (!self.decoder.is_cached(spec.*)) spec.deinit(self.allocator);
        }
        // Free all cached spectra via decoder
        self.decoder.free_cache();
        // Delegate file-level cleanup to FileState
        self.file.deinit();
    }

    pub fn open_file(self: *AppState, path: []const u8) AppStateError!void {
        // Close existing
        self.deinit();
        self.* = init(self.allocator, self.io);

        // Delegate file open to FileState (mmap, scan table, trailers, instrument id)
        self.file.open(self.io, path) catch |err| {
            return switch (err) {
                error.FileTooLarge => error.FileTooLarge,
                error.Truncated => error.Truncated,
                error.InvalidRawFile => error.InvalidRawFile,
                error.UnsupportedFileRevision => error.UnsupportedFileRevision,
                error.InvalidRawFileInfo => error.InvalidRawFileInfo,
                error.NoMsController => error.NoMsController,
                error.InvalidControllerOffset => error.InvalidControllerOffset,
                error.InvalidRunHeader => error.InvalidRunHeader,
                error.TooManyScans => error.TooManyScans,
                error.InvalidStringLength => error.InvalidStringLength,
                error.OffsetOverflow => error.OffsetOverflow,
                error.ScanOutOfRange => error.ScanOutOfRange,
                error.ScanIndexMismatch => error.ScanIndexMismatch,
                error.OutOfMemory => error.OutOfMemory,
            };
        };

        if (self.file.creation_time) |ct| {
            std.log.info("RAW CreationDate: {s}", .{ct});
        }

        // Configure scan decoder with RawFile state
        const rf = self.file.raw_file.?;
        self.decoder.configure(
            rf.mm,
            rf.packet_pos,
            rf.file_size,
            self.file.trailer_events,
        );

        // Default to MS1 filter for cleaner initial view
        self.view.filter_ms_level = 1;

        // NOTE: Chromatograms are computed on-demand to keep
        // file open fast and responsive. For benchmark mode, call
        // computeChromatograms() after openFile.
    }

    /// Read individual scan trailers to populate filter strings.
    /// For rev < 65 files: reads per-scan trailer records by byte offset.
    /// For rev >= 65 files: uses TrailerScanEvents lookup by event index.
    /// Ground truth: Thermo MassSpecDevice.cs:2228 uses TrailerScanEvents.GetEvent(trailerOffset).
    pub fn read_all_scan_trailers(self: *AppState) AppStateError!void {
        if (self.file.raw_file == null) return error.NoFileOpen;
        const rf = self.file.raw_file.?;
        const mm = rf.mm;
        const rev = self.file.file_revision();
        const usage = raw.trailer_usage(rev);

        for (self.file.scans) |*scan| {
            if (usage == .event_index) {
                // Modern files: trailer_offset is an index into TrailerScanEvents.
                // Thermo uses TrailerScanEvents.GetEvent(trailerOffset) for scan events
                // and GetTrailerExtraValues(scanNumber) for trailer extra data.
                if (self.file.trailer_events) |*te| {
                    if (te.get_event(@intCast(scan.trailer_offset))) |evt| {
                        // Update MS level from ScanEvent info
                        if (evt.info.ms_order > 0 and scan.ms_level == 0) {
                            scan.ms_level = @intCast(evt.info.ms_order);
                        }
                    }
                }
            } else {
                // Legacy files: trailer_offset is a byte offset into the file
                const trailer = trailer_events.read_scan_trailer(self.allocator, mm, scan.trailer_offset) catch |err| {
                    std.log.warn("Failed to read scan trailer for scan {d}: {s}", .{ scan.scan_number, @errorName(err) });
                    continue;
                };

                // Free existing filter string if any
                if (scan.filter_string) |fs| {
                    self.allocator.free(fs);
                    scan.filter_string = null;
                }

                // Take ownership of the newly parsed filter string
                scan.filter_string = trailer.filter_string;

                // Update ms_level and charge_state from trailer if not already set
                if (trailer.ms_level > 0 and scan.ms_level == 0) {
                    scan.ms_level = trailer.ms_level;
                }
                if (trailer.charge_state > 0 and scan.charge_state == 0) {
                    scan.charge_state = trailer.charge_state;
                }
                if (trailer.precursor_mz > 0 and scan.precursor_mz == 0) {
                    scan.precursor_mz = trailer.precursor_mz;
                }
            }
        }
    }

    /// Return true if the given spectrum's memory is owned by the cache.
    fn isSpectrumCached(self: *AppState, spectrum: advanced.Spectrum) bool {
        return self.decoder.is_cached(spectrum);
    }

    /// Preload the first N scans into the cache.
    pub fn preload_cache(self: *AppState) void {
        const n = @min(scan_decoder.SPECTRUM_CACHE_SIZE, self.file.scans.len);
        for (0..n) |i| {
            self.load_scan(i) catch continue;
        }
    }

    pub fn load_scan(self: *AppState, scan_index: usize) AppStateError!void {
        if (scan_index >= self.file.scans.len) return error.ScanOutOfRange;
        if (self.file.raw_file == null) return error.NoFileOpen;
        // TrailerScanEvents are parsed at file open. MS level and precursor
        // metadata are already authoritative in self.file.scans[scan_index].

        const scan = self.file.scans[scan_index];

        // Check packet type — we support FT centroid and FT profile packets
        const packet_type = scan.packet_type & 0xFFFF;
        if (packet_type != raw.PACKET_TYPE_FT_CENTROID and
            packet_type != raw.PACKET_TYPE_FT_PROFILE and
            packet_type != raw.PACKET_TYPE_LINEAR_TRAP_CENTROID and
            packet_type != raw.PACKET_TYPE_STANDARD_ACCURACY and
            packet_type != raw.PACKET_TYPE_LOW_RES_SPECTRUM and
            packet_type != raw.PACKET_TYPE_HIGH_RES_SPECTRUM)
        {
            // Profile or unsupported packet type — create empty spectrum
            if (self.current_spectrum) |*spec| {
                if (!self.isSpectrumCached(spec.*)) spec.deinit(self.allocator);
                self.current_spectrum = null;
            }
            self.current_scan_index = scan_index;
            self.view.zoom = .{
                .mz_min = 0,
                .mz_max = 1,
                .inten_min = 0,
                .inten_max = 1,
            };
            return;
        }

        // Check cache first (ScanDecoder manages the LRU cache)
        if (self.decoder.get_cached(scan_index)) |cached| {
            if (self.current_spectrum) |*spec| {
                if (!self.isSpectrumCached(spec.*)) spec.deinit(self.allocator);
            }
            self.current_spectrum = cached; // shallow copy
            self.current_scan_index = scan_index;
            self.view.zoom = .{
                .mz_min = cached.mz_min,
                .mz_max = cached.mz_max,
                .inten_min = 0,
                .inten_max = cached.intensity_max,
            };
            self.file.scans[scan_index].peak_count = cached.point_count();
            return;
        }

        // Free old spectrum (only if not cached)
        if (self.current_spectrum) |*spec| {
            if (!self.isSpectrumCached(spec.*)) spec.deinit(self.allocator);
            self.current_spectrum = null;
        }

        // Decode into pool buffers via ScanDecoder.
        const result = try self.decoder.decode(
            scan_index,
            &.{ .packet_type = scan.packet_type, .data_offset = scan.data_offset },
        );
        const num_points = result.num_points;
        const mz_min = result.mz_min;
        const mz_max = result.mz_max;
        const intensity_max = result.intensity_max;

        // Work directly with pool buffers (valid until next decode or steal).
        const mz = result.mz;
        const intensity = result.intensity;
        const features_opt = result.features_opt;

        // ------------------------------------------------------------------
        // Label Peak Data Parsing (resolution, noise, baseline)
        // ------------------------------------------------------------------
        // Only available from centroid packets; needs parse_peak_metadata flag.
        const packet_offset = std.math.add(u64, self.file.raw_file.?.packet_pos, scan.data_offset) catch return error.OffsetOverflow;
        const packet_offset_usz = std.math.cast(usize, packet_offset) orelse return error.OffsetOverflow;
        const header_end = std.math.add(usize, packet_offset_usz, 32) catch return error.OffsetOverflow;
        const header_bytes = self.file.raw_file.?.mm.memory[packet_offset_usz..header_end];
        const h = try advanced.read_header(header_bytes, 0);
        const packet_size = try advanced.packet_size_from_header(h);
        const remaining = std.math.sub(u64, self.file.raw_file.?.file_size, packet_offset) catch return error.OffsetOverflow;
        const actual_size: usize = std.math.cast(usize, @min(packet_size, remaining)) orelse return error.OffsetOverflow;
        if (actual_size == 0) return error.Truncated;
        const packet_end = std.math.add(usize, packet_offset_usz, actual_size) catch return error.OffsetOverflow;
        const packet_slice = self.file.raw_file.?.mm.memory[packet_offset_usz..packet_end];

        const packet_needs_features = h.num_centroid_words > 0;
        const has_label_data = self.view.parse_peak_metadata and packet_needs_features and num_points > 0 and
            (h.num_expansion_words > 0 or h.num_noise_info_words > 0);

        if (has_label_data) {
            if (h.num_expansion_words > 0) {
                const max_widths = std.math.sub(usize, @as(usize, h.num_expansion_words), 1) catch return error.OffsetOverflow;
                if (self.label_widths == null or self.label_widths.?.len < max_widths) {
                    if (self.label_widths) |old| self.allocator.free(old);
                    self.label_widths = self.allocator.alloc(f32, max_widths) catch null;
                }
                if (self.label_widths) |wb| {
                    const n = advanced.read_resolution_widths(packet_slice, 0, wb) catch 0;
                    if (n > 0) {
                        if (features_opt) |fb| {
                            const limit = @min(n, num_points);
                            for (0..limit) |pi| {
                                fb[pi].resolution = wb[pi];
                            }
                        }
                    }
                }
            }

            if (h.num_noise_info_words > 0) {
                const noise_bytes = std.math.mul(u32, h.num_noise_info_words, 4) catch return error.OffsetOverflow;
                const max_noise = noise_bytes / @sizeOf(advanced.NoiseInfoPacket);
                if (self.label_noise == null or self.label_noise.?.len < max_noise) {
                    if (self.label_noise) |old| self.allocator.free(old);
                    self.label_noise = self.allocator.alloc(advanced.NoiseInfoPacket, max_noise) catch null;
                }
                if (self.label_noise) |nb| {
                    const n = advanced.read_noise_info_packets(packet_slice, 0, nb) catch 0;
                    if (n > 0) {
                        if (features_opt) |fb| {
                            advanced.interpolate_noise_baseline(
                                mz,
                                intensity,
                                fb,
                                nb,
                            );
                        }
                    }
                }
            }
        }

        // Steal pool buffers into cache (infallible, zero allocations).
        self.decoder.cache_spectrum_steal(
            scan_index,
            num_points,
            mz_min,
            mz_max,
            intensity_max,
            features_opt != null,
        );

        // Point current_spectrum at the newly cached entry.
        self.current_spectrum = self.decoder.get_cached(scan_index).?;
        self.current_scan_index = scan_index;
        self.file.scans[scan_index].peak_count = num_points;
        const zm_min = if (scan.low_mass > 0 and scan.low_mass < mz_min) scan.low_mass else mz_min;
        const zm_max = if (scan.high_mass > zm_min) scan.high_mass else mz_max;
        self.view.zoom = .{
            .mz_min = zm_min,
            .mz_max = zm_max,
            .inten_min = 0,
            .inten_max = intensity_max,
        };
    }

    /// Find next/previous scan index respecting the current filter.
    pub fn find_next_filtered_scan(self: *AppState, direction: i32) ?usize {
        if (self.filtered_indices) |fi| {
            // Find current position in filtered list
            var current_pos: ?usize = null;
            for (fi, 0..) |idx, i| {
                if (idx == self.current_scan_index) {
                    current_pos = i;
                    break;
                }
            }
            const pos = current_pos orelse return null;
            const new_pos = if (direction > 0)
                pos + 1
            else if (pos > 0)
                pos - 1
            else
                return null;
            if (new_pos >= fi.len) return null;
            return fi[new_pos];
        } else {
            // No filter active
            if (direction > 0) {
                if (self.current_scan_index + 1 < self.file.scans.len)
                    return self.current_scan_index + 1;
            } else {
                if (self.current_scan_index > 0)
                    return self.current_scan_index - 1;
            }
            return null;
        }
    }

    pub fn go_to_previous_scan(self: *AppState) AppStateError!void {
        if (self.find_next_filtered_scan(-1)) |idx| {
            try self.load_scan(idx);
        }
    }

    pub fn go_to_next_scan(self: *AppState) AppStateError!void {
        if (self.find_next_filtered_scan(1)) |idx| {
            try self.load_scan(idx);
        }
    }

    pub fn go_to_first_scan(self: *AppState) AppStateError!void {
        if (self.filtered_indices) |fi| {
            if (fi.len > 0) try self.load_scan(fi[0]);
        } else if (self.file.scans.len > 0) {
            try self.load_scan(0);
        }
    }

    pub fn go_to_last_scan(self: *AppState) AppStateError!void {
        if (self.filtered_indices) |fi| {
            if (fi.len > 0) try self.load_scan(fi[fi.len - 1]);
        } else if (self.file.scans.len > 0) {
            try self.load_scan(self.file.scans.len - 1);
        }
    }

    pub fn has_file_open(self: AppState) bool {
        return self.file.raw_file != null;
    }

    pub fn has_spectrum(self: AppState) bool {
        return self.current_spectrum != null;
    }

    /// Returns cached spectrum data. WARNING: The returned slices are
    /// invalidated by a subsequent loadScan() that triggers LRU eviction.
    /// Do not hold across loadScan() calls. Copy if needed.
    pub fn get_current_spectrum(self: AppState) ?advanced.Spectrum {
        return self.current_spectrum;
    }

    /// Load scan using an arena allocator — all allocations are freed when arena is destroyed.
    /// This is ~10x faster than per-scan alloc/free for bulk iteration (B5).
    pub fn load_scan_arena(self: *AppState, scan_index: usize, arena: *std.heap.ArenaAllocator) AppStateError!usize {
        if (scan_index >= self.file.scans.len) return error.ScanOutOfRange;
        if (self.file.raw_file == null) return error.NoFileOpen;

        const scan = self.file.scans[scan_index];
        const result = try self.decoder.decode(
            scan_index,
            &.{ .packet_type = scan.packet_type, .data_offset = scan.data_offset },
        );
        const num_points = result.num_points;

        // Copy from pool into arena-allocated arrays (arena owns the copies on reset)
        const mz = arena.allocator().alloc(f64, num_points) catch return error.OutOfMemory;
        const intensity = arena.allocator().alloc(f32, num_points) catch return error.OutOfMemory;
        @memcpy(mz, result.mz);
        @memcpy(intensity, result.intensity);

        return num_points;
    }

    /// Zero-allocation bulk scan loader for benchmarks.
    /// Reuses grow-only buffers; no allocator calls, no copies.
    /// Returns the point count and the actual decoded m/z bounds.
    pub fn load_scan_bulk(self: *AppState, scan_index: usize) AppStateError!BulkLoadResult {
        if (scan_index >= self.file.scans.len) return error.ScanOutOfRange;
        if (self.file.raw_file == null) return error.NoFileOpen;

        const scan = self.file.scans[scan_index];

        // Prefetch next scan's data (overlaps memory fetch with decode)
        if (scan_index + 1 < self.file.scans.len) {
            const next_scan = self.file.scans[scan_index + 1];
            const next_offset = std.math.add(u64, self.file.raw_file.?.packet_pos, next_scan.data_offset) catch return error.OffsetOverflow;
            if (next_offset < self.file.raw_file.?.file_size) {
                const next_offset_usz = std.math.cast(usize, next_offset) orelse return error.OffsetOverflow;
                @prefetch(self.file.raw_file.?.mm.memory.ptr + next_offset_usz, .{ .rw = .read, .cache = .data, .locality = 3 });
            }
        }

        const result = try self.decoder.decode(
            scan_index,
            &.{ .packet_type = scan.packet_type, .data_offset = scan.data_offset },
        );
        self.file.scans[scan_index].peak_count = result.num_points;
        return .{
            .num_points = result.num_points,
            .mz_min = result.mz_min,
            .mz_max = result.mz_max,
        };
    }

    /// Load scan data with raw frequencies preserved (for profile packets).
    /// Identical to load_scan_bulk but also populates reuse_freq with raw frequencies.
    pub fn load_scan_bulk_with_freq(self: *AppState, scan_index: usize) AppStateError!BulkLoadResult {
        if (scan_index >= self.file.scans.len) return error.ScanOutOfRange;
        if (self.file.raw_file == null) return error.NoFileOpen;

        const scan = self.file.scans[scan_index];
        const result = try self.decoder.decode(
            scan_index,
            &.{ .packet_type = scan.packet_type, .data_offset = scan.data_offset },
        );
        self.file.scans[scan_index].peak_count = result.num_points;
        _ = self.decoder.freq_buffer(); // freq available in decoder pool if profile
        return .{
            .num_points = result.num_points,
            .mz_min = result.mz_min,
            .mz_max = result.mz_max,
        };
    }

    pub fn set_ms_level_filter(self: *AppState, level: ?u8) void {
        self.view.filter_ms_level = level;
    }

    /// Compute TIC and BPC chromatograms from scan indices (no packet decode).
    pub fn compute_chromatograms(self: *AppState) void {
        if (self.file.scans.len == 0) return;

        // Free old chromatograms
        if (self.tic_chromatogram) |*c| {
            c.deinit(self.allocator);
            self.tic_chromatogram = null;
        }
        if (self.bpc_chromatogram) |*c| {
            c.deinit(self.allocator);
            self.bpc_chromatogram = null;
        }

        const n = self.file.scans.len;
        const allocator = self.allocator;

        // TIC: rt + tic + ms_level
        const tic_rt = allocator.alloc(f64, n) catch return;
        errdefer allocator.free(tic_rt);
        const tic_intensity = allocator.alloc(f64, n) catch return;
        errdefer allocator.free(tic_intensity);
        const tic_ms_level = allocator.alloc(u8, n) catch return;
        errdefer allocator.free(tic_ms_level);
        for (self.file.scans, 0..) |scan, i| {
            tic_rt[i] = scan.rt;
            tic_intensity[i] = scan.tic;
            tic_ms_level[i] = scan.ms_level;
        }
        self.tic_chromatogram = .{
            .rt = tic_rt,
            .intensity = tic_intensity,
            .ms_level = tic_ms_level,
            .num_points = n,
        };

        // BPC: rt + base_peak_intensity + ms_level
        const bpc_rt = allocator.alloc(f64, n) catch return;
        errdefer allocator.free(bpc_rt);
        const bpc_intensity = allocator.alloc(f64, n) catch return;
        errdefer allocator.free(bpc_intensity);
        const bpc_ms_level = allocator.alloc(u8, n) catch return;
        errdefer allocator.free(bpc_ms_level);
        for (self.file.scans, 0..) |scan, i| {
            bpc_rt[i] = scan.rt;
            bpc_intensity[i] = scan.base_peak_intensity;
            bpc_ms_level[i] = scan.ms_level;
        }
        self.bpc_chromatogram = .{
            .rt = bpc_rt,
            .intensity = bpc_intensity,
            .ms_level = bpc_ms_level,
            .num_points = n,
        };
    }

    pub fn set_chromatogram_ms_level_filter(self: *AppState, level: ?u8) void {
        self.chromatogram_ms_level_filter = level;
    }
};
