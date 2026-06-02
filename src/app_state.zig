/// Global application state shared between GUI components.
const std = @import("std");
const advanced = @import("advanced_packet");
const raw = @import("raw_file");
const raw_file_reader = @import("raw_file_reader");
const scan_event = @import("scan_event");
const trailer_events = @import("trailer_events");
const profile = @import("profile_packet");

/// Convert Windows FILETIME (100ns intervals since 1601-01-01 UTC) to ISO 8601 string.
fn fileTimeToIso8601(allocator: std.mem.Allocator, filetime: u64) !?[]u8 {
    if (filetime == 0) return null;
    const windows_epoch_offset: i128 = 116444736000000000;
    const hundred_ns_per_sec: i128 = 10000000;
    const unix_ts = @divFloor(@as(i128, filetime) - windows_epoch_offset, hundred_ns_per_sec);
    if (unix_ts < 0) return null;

    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_ts) };
    const yd = es.getEpochDay();
    const year_day = yd.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

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

pub const ViewMode = enum {
    stick,
    line,
};

const SPECTRUM_CACHE_SIZE = 8;

const CachedSpectrum = struct {
    scan_index: usize,
    spectrum: advanced.Spectrum,
};

pub const ZoomState = struct {
    mz_min: f64,
    mz_max: f64,
    inten_min: f32,
    inten_max: f32,

    pub fn init(spectrum: *const advanced.Spectrum) ZoomState {
        return .{
            .mz_min = spectrum.mzMin(),
            .mz_max = spectrum.mzMax(),
            .inten_min = 0,
            .inten_max = spectrum.intensityMax(),
        };
    }

    pub fn reset(self: *ZoomState, spectrum: *const advanced.Spectrum) void {
        self.mz_min = spectrum.mzMin();
        self.mz_max = spectrum.mzMax();
        self.inten_min = 0;
        self.inten_max = spectrum.intensityMax();
    }

    pub fn mzSpan(self: ZoomState) f64 {
        const span = self.mz_max - self.mz_min;
        return if (span > 0) span else 1.0;
    }

    pub fn intenSpan(self: ZoomState) f32 {
        const span = self.inten_max - self.inten_min;
        return if (span > 0) span else 1.0;
    }

    pub fn zoomAround(self: *ZoomState, center_mz: f64, factor: f64) void {
        const span = self.mzSpan();
        const new_span = span * factor;
        const half = new_span / 2.0;
        self.mz_min = center_mz - half;
        self.mz_max = center_mz + half;
    }

    pub fn panBy(self: *ZoomState, delta_mz: f64) void {
        self.mz_min += delta_mz;
        self.mz_max += delta_mz;
    }
};

pub const ScanInfo = struct {
    scan_number: i32,
    packet_type: u32,
    number_packets: i32,
    data_size: u32,
    data_offset: u64,
    trailer_offset: i32,    // offset to scan trailer record
    ms_level: u8,           // 1=MS1, 2=MS2, etc. (0 = unknown)
    charge_state: i32,      // scan-level charge (0 = unknown)
    precursor_mz: f64,      // for MSn (0 = none)
    filter_string: ?[]u8,   // owned, null if not parsed
    // From scan index (for chromatograms, no packet decode needed)
    rt: f64,                // retention time in minutes
    tic: f64,               // total ion current
    base_peak_mz: f64,      // base peak m/z
    base_peak_intensity: f64, // base peak intensity
    low_mass: f64,          // scan low mass
    high_mass: f64,         // scan high mass
    // Scan event data (set after trailer scan events parsing)
    scan_event_index: usize, // index into unique scan events array (0 = unknown)
    collision_energy: f64,  // from reaction data (0 = none)
    isolation_width: f64,   // from reaction data (0 = none)
    // Peak count (populated when scan is first loaded, 0 = unknown)
    peak_count: usize,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // Current file
    file_path: ?[]const u8,
    raw_file: ?raw_file_reader.RawFile,

    // Scan list
    scans: []ScanInfo,

    // Current spectrum
    current_spectrum: ?advanced.Spectrum,
    current_scan_index: usize, // index into scans array

    // View state
    zoom: ZoomState,
    view_mode: ViewMode,
    show_peak_labels: bool,

    // Parse resolution widths + noise/baseline/SNR from label data
    parse_peak_metadata: bool,

    // Pan state
    is_panning: bool,
    pan_start_x: i32,
    pan_start_mz: f64,

    // Reusable decode buffers to eliminate alloc churn during bulk iteration
    reuse_mz: ?[]f64,
    reuse_intensity: ?[]f32,
    reuse_freq: ?[]f64,
    reuse_features: ?[]advanced.PeakFeatures,
    reuse_widths: ?[]f32,              // temp buffer for resolution widths
    reuse_noise: ?[]advanced.NoiseInfoPacket, // temp buffer for noise info packets

    // Spectrum cache for recently viewed scans (avoids re-decode on navigation)
    spectrum_cache: [SPECTRUM_CACHE_SIZE]?CachedSpectrum,
    spectrum_cache_next: usize,

    // MS level filter for scan list
    filter_ms_level: ?u8,

    // Filtered index mapping for virtual list view (null = no filter)
    filtered_indices: ?[]usize,

    // Chromatograms (computed at file open)
    tic_chromatogram: ?Chromatogram,
    bpc_chromatogram: ?Chromatogram,
    chromatogram_ms_level_filter: ?u8,

    // Trailer scan events (parsed at file open)
    trailer_events: ?trailer_events.TrailerScanEvents,

    // Instrument metadata (from file header)
    instrument_model: ?[]u8,
    instrument_serial: ?[]u8,
    software_version: ?[]u8,
    creation_time: ?[]u8, // ISO 8601 datetime from RAW file header FILETIME

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AppState {
        return .{
            .allocator = allocator,
            .io = io,
            .file_path = null,
            .raw_file = null,
            .scans = &.{},
            .current_spectrum = null,
            .current_scan_index = 0,
            .zoom = undefined,
            .view_mode = .stick,
            .show_peak_labels = false,
            .parse_peak_metadata = true,
            .is_panning = false,
            .pan_start_x = 0,
            .pan_start_mz = 0,
            .reuse_mz = null,
            .reuse_intensity = null,
            .reuse_freq = null,
            .reuse_features = null,
            .reuse_widths = null,
            .reuse_noise = null,
            .spectrum_cache = .{null} ** SPECTRUM_CACHE_SIZE,
            .spectrum_cache_next = 0,
            .filter_ms_level = null,
            .filtered_indices = null,
            .tic_chromatogram = null,
            .bpc_chromatogram = null,
            .chromatogram_ms_level_filter = null,
            .trailer_events = null,
            .instrument_model = null,
            .instrument_serial = null,
            .software_version = null,
            .creation_time = null,
        };
    }

    pub fn deinit(self: *AppState) void {
        if (self.reuse_mz) |buf| {
            self.allocator.free(buf);
            self.reuse_mz = null;
        }
        if (self.reuse_intensity) |buf| {
            self.allocator.free(buf);
            self.reuse_intensity = null;
        }
        if (self.reuse_freq) |buf| {
            self.allocator.free(buf);
            self.reuse_freq = null;
        }
        if (self.reuse_features) |buf| {
            self.allocator.free(buf);
            self.reuse_features = null;
        }
        if (self.reuse_widths) |buf| {
            self.allocator.free(buf);
            self.reuse_widths = null;
        }
        if (self.reuse_noise) |buf| {
            self.allocator.free(buf);
            self.reuse_noise = null;
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
        if (self.trailer_events) |*te| {
            te.deinit(self.allocator);
            self.trailer_events = null;
        }
        if (self.instrument_model) |s| {
            self.allocator.free(s);
            self.instrument_model = null;
        }
        if (self.instrument_serial) |s| {
            self.allocator.free(s);
            self.instrument_serial = null;
        }
        if (self.software_version) |s| {
            self.allocator.free(s);
            self.software_version = null;
        }
        if (self.creation_time) |s| {
            self.allocator.free(s);
            self.creation_time = null;
        }
        // Free filter strings in ScanInfo
        for (self.scans) |scan| {
            if (scan.filter_string) |fs| self.allocator.free(fs);
        }
        // Free current_spectrum only if it's not owned by the cache
        if (self.current_spectrum) |*spec| {
            if (!self.isSpectrumCached(spec.*)) spec.deinit(self.allocator);
        }
        // Free all cached spectra
        for (&self.spectrum_cache) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                entry.spectrum.deinit(self.allocator);
                entry_opt.* = null;
            }
        }
        if (self.raw_file) |*rf| {
            rf.deinit();
            self.raw_file = null;
        }
        self.allocator.free(self.file_path orelse &[_]u8{});
        self.allocator.free(self.scans);

    }

    pub fn openFile(self: *AppState, path: []const u8) !void {
        // Close existing
        self.deinit();
        self.* = init(self.allocator, self.io);

        // Open the .raw file. This does the signature check, mmap, controller
        // discovery, scan table parse, instrument id, and creation time in one
        // call. Owns the mmap and the allocated strings until deinit().
        var rf = raw_file_reader.RawFile.open(self.allocator, self.io, path) catch |err| {
            // Map the module-local errors back to the historical AppState errors
            // so GUI/clients don't have to know about the module split.
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
                error.InvalidScanNumber => error.ScanOutOfRange,
                error.ScanOutOfRange => error.ScanOutOfRange,
                error.ScanIndexMismatch => error.ScanIndexMismatch,
            };
        };

        const path_copy = self.allocator.dupe(u8, path) catch {
            rf.deinit();
            return error.OutOfMemory;
        };
        self.file_path = path_copy;

        if (rf.creation_time_iso) |ct| {
            std.log.info("RAW CreationDate: {s}", .{ct});
        }
        self.creation_time = rf.creation_time_iso;
        rf.creation_time_iso = null;
        self.instrument_model = rf.instrument_model;
        rf.instrument_model = null;
        self.instrument_serial = rf.instrument_serial;
        rf.instrument_serial = null;
        self.software_version = rf.software_version;
        rf.software_version = null;

        // Build scan list — parse directly from the mmap (zero copy).
        const file_revision = rf.file_revision;
        const num_scans = rf.num_scans;
        const scan_index_size = raw.scanIndexSize(file_revision);
        const mm_mem = rf.memory();
        const scan_table_buf = mm_mem[rf.scan_table_start..][0..rf.scan_table_size];

        const scans = self.allocator.alloc(ScanInfo, num_scans) catch {
            rf.deinit();
            self.allocator.free(path_copy);
            self.file_path = null;
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(scans);

        var scan_idx: usize = 0;
        while (scan_idx < num_scans) : (scan_idx += 1) {
            const entry = raw.parseScanIndex(scan_table_buf, scan_idx * scan_index_size, file_revision) catch |err| switch (err) {
                raw.RawResolveError.Truncated => break,
                else => return err,
            };
            scans[scan_idx] = .{
                .scan_number = entry.scan_number,
                .packet_type = entry.packet_type,
                .number_packets = entry.number_packets,
                .data_size = entry.data_size,
                .data_offset = entry.data_offset,
                .trailer_offset = entry.trailer_offset,
                .ms_level = 0, // Will be set from trailers or heuristic below
                .charge_state = 0,
                .precursor_mz = 0,
                .filter_string = null,
                .rt = entry.start_time,
                .tic = entry.tic,
                .base_peak_mz = entry.base_peak_mass,
                .base_peak_intensity = entry.base_peak_intensity,
                .low_mass = entry.low_mass,
                .high_mass = entry.high_mass,
                .scan_event_index = 0,
                .collision_energy = 0,
                .isolation_width = 0,
                .peak_count = 0,
            };
        }

        self.scans = scans;
        self.raw_file = rf;

        // Parse TrailerScanEvents to get authoritative MS level and precursor metadata.
        // trailer_offset in ScanIndexEntry is an INDEX into the scan_to_unique array.
        try self.parseScanTrailersAtOpen();

        // Default to MS1 filter for cleaner initial view
        self.filter_ms_level = 1;

        // Preload first 10 scans into cache for instant navigation
        self.preloadCache();

        // NOTE: Chromatograms are computed on-demand to keep
        // file open fast and responsive. For benchmark mode, call
        // computeChromatograms() after openFile.
    }

    /// Parse TrailerScanEvents at file open to get authoritative MS level and metadata.
    /// The trailer_offset field in ScanIndexEntry is an INDEX into scan_to_unique,
    /// NOT a file offset. The table lives at RunHeader.TrailerScanEventsPos.
    fn parseScanTrailersAtOpen(self: *AppState) !void {
        const rf = &self.raw_file.?;
        const mm = rf.mm;
        const controller_offset = rf.controller_offset;
        const num_scans = rf.num_scans;
        const file_revision = rf.file_revision;

        // Read trailer scan events position from run header
        const trailer_pos_i64 = raw.readI64Mm(mm.memory, controller_offset + raw.RUN_HEADER_TRAILER_SCAN_EVENTS_POS) catch |err| {
            std.log.warn("Failed to read trailer position: {s}, using heuristic MS levels", .{@errorName(err)});
            self.applyHeuristicMsLevels();
            return;
        };
        if (trailer_pos_i64 <= 0) {
            std.log.warn("Invalid trailer position {}, using heuristic MS levels", .{trailer_pos_i64});
            self.applyHeuristicMsLevels();
            return;
        }
        const trailer_pos: u64 = @intCast(trailer_pos_i64);

        // Parse the TrailerScanEvents table
        const trailers = trailer_events.parseTrailerScanEvents(
            self.allocator,
            mm,
            trailer_pos,
            num_scans,
            file_revision,
        ) catch |err| {
            std.log.warn("Failed to parse trailer events: {s}, using heuristic MS levels", .{@errorName(err)});
            self.applyHeuristicMsLevels();
            return;
        };

        self.trailer_events = trailers;

        // Apply authoritative MS levels and metadata from trailers
        for (self.scans, 0..) |*scan, i| {
            if (self.trailer_events.?.getEvent(i)) |evt| {
                // MS level: ms_order is 1-based (1=MS1, 2=MS2, 3=MS3...)
                scan.ms_level = @intCast(evt.info.ms_order);
                scan.scan_event_index = self.trailer_events.?.scan_to_unique[i];

                // Charge state from scan event info (if available)
                // Note: charge_state is not directly in ScanEventInfo in current struct.
                // It may be in the reactions or in a trailer label. For now, leave at 0.

                // Precursor metadata from first reaction (only for MS2+)
                if (scan.ms_level >= 2 and evt.reactions.len > 0) {
                    const rxn = evt.reactions[0];
                    scan.precursor_mz = rxn.precursor_mass;
                    scan.isolation_width = rxn.isolation_width;
                    scan.collision_energy = rxn.collision_energy;
                }

                // Mass calibrators (for profile decode in Phase 2)
                // evt.mass_calibrators is available here
            } else {
                // Fallback for this scan
                scan.ms_level = if (scan.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
            }
        }
    }

    /// Apply heuristic MS levels when trailer parsing fails.
    fn applyHeuristicMsLevels(self: *AppState) void {
        for (self.scans) |*scan| {
            scan.ms_level = if (scan.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
        }
    }

    /// Read individual scan trailers to populate filter strings.
    /// This is expensive (O(n) file reads) so it's not done at openFile time.
    /// Call this when filter strings are needed (e.g., golden validation).
    pub fn readAllScanTrailers(self: *AppState) !void {
        if (self.raw_file == null) return error.NoFileOpen;
        const mm = self.raw_file.?.mm;

        for (self.scans) |*scan| {
            const trailer = raw.readScanTrailer(self.allocator, mm, scan.trailer_offset) catch |err| {
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

    /// Return true if the given spectrum's memory is owned by the cache.
    fn isSpectrumCached(self: *AppState, spectrum: advanced.Spectrum) bool {
        for (self.spectrum_cache) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.spectrum.mz.ptr == spectrum.mz.ptr) return true;
            }
        }
        return false;
    }

    /// Deep-copy a spectrum into the cache (round-robin eviction).
    fn cacheSpectrum(self: *AppState, scan_index: usize, spectrum: advanced.Spectrum) !void {
        const slot = self.spectrum_cache_next;
        self.spectrum_cache_next = (self.spectrum_cache_next + 1) % SPECTRUM_CACHE_SIZE;

        // Evict old entry
        if (self.spectrum_cache[slot]) |*old| {
            old.spectrum.deinit(self.allocator);
        }

        const mz = try self.allocator.dupe(f64, spectrum.mz);
        const intensity = try self.allocator.dupe(f32, spectrum.intensity);
        const ranges = try self.allocator.dupe(advanced.MassRange, spectrum.ranges);
        const features: ?[]advanced.PeakFeatures = if (spectrum.features) |f|
            try self.allocator.dupe(advanced.PeakFeatures, f)
        else
            null;

        self.spectrum_cache[slot] = .{
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

    /// Preload the first N scans into the cache.
    pub fn preloadCache(self: *AppState) void {
        const n = @min(SPECTRUM_CACHE_SIZE, self.scans.len);
        for (0..n) |i| {
            self.loadScan(i) catch continue;
        }
    }

    pub fn loadScan(self: *AppState, scan_index: usize) !void {
        if (scan_index >= self.scans.len) return error.ScanOutOfRange;
        if (self.raw_file == null) return error.NoFileOpen;
        // TrailerScanEvents are parsed at file open. MS level and precursor
        // metadata are already authoritative in self.scans[scan_index].

        const mm = self.raw_file.?.mm;
        const packet_pos = self.raw_file.?.packet_pos;
        const file_size = self.raw_file.?.file_size;
        const scan = self.scans[scan_index];

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
            self.zoom = .{
                .mz_min = 0,
                .mz_max = 1,
                .inten_min = 0,
                .inten_max = 1,
            };
            return;
        }

        // Check cache first
        for (self.spectrum_cache) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.scan_index == scan_index) {
                    // Free old spectrum only if it's not cached
                    if (self.current_spectrum) |*spec| {
                        if (!self.isSpectrumCached(spec.*)) spec.deinit(self.allocator);
                    }
                    self.current_spectrum = entry.spectrum; // shallow copy
                    self.current_scan_index = scan_index;
                    self.zoom = .{
                        .mz_min = entry.spectrum.mz_min,
                        .mz_max = entry.spectrum.mz_max,
                        .inten_min = 0,
                        .inten_max = entry.spectrum.intensity_max,
                    };
                    self.scans[scan_index].peak_count = entry.spectrum.pointCount();
                    return;
                }
            }
        }

        // Free old spectrum (only if not cached)
        if (self.current_spectrum) |*spec| {
            if (!self.isSpectrumCached(spec.*)) spec.deinit(self.allocator);
            self.current_spectrum = null;
        }

        const packet_offset = packet_pos + scan.data_offset;
        if (packet_offset >= file_size) {
            return error.OffsetBeyondFile;
        }

        // Read packet header to compute exact size
        const header_size = 32;
        if (packet_offset + header_size > file_size) {
            return error.Truncated;
        }
        const header_bytes = mm.memory[packet_offset..packet_offset + header_size];
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

        const actual_size: usize = @intCast(@min(packet_size, file_size - packet_offset));
        if (actual_size == 0) {
            return error.Truncated;
        }

        const packet_slice = mm.memory[packet_offset..packet_offset + actual_size];

        // Determine packet type and whether to decode full profile or centroids
        const is_profile = packet_type == raw.PACKET_TYPE_FT_PROFILE;
        const has_centroid_data = h.num_centroid_words > 0;

        // For FT_PROFILE packets, decode embedded centroids when available;
        // fall back to full profile trace only when no centroids are present.
        const decode_profile = is_profile and !has_centroid_data;

        // features are only needed when decoding centroid data
        const needs_features = !decode_profile;

        // Estimate output size based on decode path
        const est_points: usize = if (decode_profile) blk: {
            // Profile packets can have multiple segments. The total output points
            // is the sum of all segments' num_expanded_words. Parse all segment
            // headers to compute the exact total. See UNSKILLED.md.
            const segment_data_start = 32 + @as(usize, h.num_segments) * 8;
            var seg_pos = segment_data_start;
            var total_expanded: usize = 0;
            var seg: u32 = 0;
            while (seg < h.num_segments) : (seg += 1) {
                if (packet_slice.len >= seg_pos + 24) {
                    const num_expanded = std.mem.readInt(u32, packet_slice[seg_pos + 20 ..][0..4], .little);
                    total_expanded += num_expanded;
                }
                seg_pos += 24; // each segment header is 24 bytes
            }

            break :blk @intCast(@max(64, total_expanded));
        } else blk: {
            const accurate = h.accurateMassCentroids();
            const entry_size: u64 = if (accurate) 12 else 8;
            break :blk @intCast(@max(64, h.num_centroid_words * 4 / entry_size));
        };

        // Grow reusable buffers if needed
        if (self.reuse_mz == null or self.reuse_mz.?.len < est_points) {
            if (self.reuse_mz) |old| self.allocator.free(old);
            self.reuse_mz = try self.allocator.alloc(f64, est_points);
        }
        if (self.reuse_intensity == null or self.reuse_intensity.?.len < est_points) {
            if (self.reuse_intensity) |old| self.allocator.free(old);
            self.reuse_intensity = try self.allocator.alloc(f32, est_points);
        }
        if (needs_features) {
            if (self.reuse_features == null or self.reuse_features.?.len < est_points) {
                if (self.reuse_features) |old| self.allocator.free(old);
                self.reuse_features = try self.allocator.alloc(advanced.PeakFeatures, est_points);
            }
        }

        const num_points = if (decode_profile) blk: {
            // Get calibrators from trailer event
            var calibrators: []const f64 = &[_]f64{};
            if (self.trailer_events) |te| {
                if (te.getEvent(scan_index)) |evt| {
                    calibrators = evt.mass_calibrators;
                }
            }

            // Determine UseFtProfileSubSegment from header
            const use_subsegment = (h.default_feature_word & 0x40) == 0
                and (h.default_feature_word & 0x80) != 0;

            break :blk try profile.decodeFtProfile(
                packet_slice,
                calibrators,
                self.reuse_mz.?,
                self.reuse_intensity.?,
                use_subsegment,
            );
        } else try advanced.decodeSimplifiedCentroidsIntoBuffers(
            packet_slice,
            0,
            self.reuse_mz.?,
            self.reuse_intensity.?,
            if (needs_features) self.reuse_features.? else null,
        );

        // ------------------------------------------------------------------
        // Label Peak Data Parsing (resolution, noise, baseline)
        // ------------------------------------------------------------------
        // Lazily parse resolution widths and noise info only when requested.
        const has_label_data = self.parse_peak_metadata and needs_features and num_points > 0 and
            (h.num_expansion_words > 0 or h.num_noise_info_words > 0);
        if (has_label_data) {
            // Parse resolution widths from expansion words
            if (h.num_expansion_words > 0) {
                const max_widths = h.num_expansion_words - 1;
                if (self.reuse_widths == null or self.reuse_widths.?.len < max_widths) {
                    if (self.reuse_widths) |old| self.allocator.free(old);
                    self.reuse_widths = self.allocator.alloc(f32, max_widths) catch null;
                }
                if (self.reuse_widths) |wb| {
                    const n = advanced.readResolutionWidths(packet_slice, 0, wb) catch 0;
                    // Apply resolution widths to features
                    if (n > 0) {
                        if (self.reuse_features) |fb| {
                            const limit = @min(n, num_points);
                            for (0..limit) |pi| {
                                fb[pi].resolution = wb[pi];
                            }
                        }
                    }
                }
            }

            // Parse noise info packets and interpolate
            if (h.num_noise_info_words > 0) {
                const max_noise = h.num_noise_info_words * 4 / @sizeOf(advanced.NoiseInfoPacket);
                if (self.reuse_noise == null or self.reuse_noise.?.len < max_noise) {
                    if (self.reuse_noise) |old| self.allocator.free(old);
                    self.reuse_noise = self.allocator.alloc(advanced.NoiseInfoPacket, max_noise) catch null;
                }
                if (self.reuse_noise) |nb| {
                    const n = advanced.readNoiseInfoPackets(packet_slice, 0, nb) catch 0;
                    if (n > 0) {
                        if (self.reuse_features) |fb| {
                            advanced.interpolateNoiseBaseline(
                                self.reuse_mz.?[0..num_points],
                                self.reuse_intensity.?[0..num_points],
                                fb[0..num_points],
                                nb[0..n],
                            );
                        }
                    }
                }
            }
        }

        // Copy exactly num_points into owned arrays for the Spectrum struct
        const mz = try self.allocator.alloc(f64, num_points);
        errdefer self.allocator.free(mz);
        const intensity = try self.allocator.alloc(f32, num_points);
        errdefer self.allocator.free(intensity);

        @memcpy(mz, self.reuse_mz.?[0..num_points]);
        @memcpy(intensity, self.reuse_intensity.?[0..num_points]);

        // Copy features into owned array (centroid data only)
        var features_opt: ?[]advanced.PeakFeatures = null;
        if (needs_features) {
            const f = try self.allocator.alloc(advanced.PeakFeatures, num_points);
            errdefer self.allocator.free(f);
            @memcpy(f, self.reuse_features.?[0..num_points]);
            features_opt = f;
        }

        // Compute min/max using SIMD where possible
        var mz_min: f64 = std.math.inf(f64);
        var mz_max: f64 = -std.math.inf(f64);
        var intensity_max: f32 = 0;

        if (num_points >= 4) {
            // SIMD reduction for mz min/max (process 4 f64 at a time)
            const Vec4f64 = @Vector(4, f64);
            var mz_min_vec: Vec4f64 = @splat(std.math.inf(f64));
            var mz_max_vec: Vec4f64 = @splat(-std.math.inf(f64));

            const simd_end = num_points - (num_points % 4);
            var i: usize = 0;
            while (i < simd_end) : (i += 4) {
                const v = Vec4f64{ mz[i], mz[i + 1], mz[i + 2], mz[i + 3] };
                mz_min_vec = @min(mz_min_vec, v);
                mz_max_vec = @max(mz_max_vec, v);
            }
            mz_min = @reduce(.Min, mz_min_vec);
            mz_max = @reduce(.Max, mz_max_vec);

            // Handle tail elements
            while (i < num_points) : (i += 1) {
                const m = mz[i];
                if (m < mz_min) mz_min = m;
                if (m > mz_max) mz_max = m;
            }

            // SIMD reduction for intensity max (process 8 f32 at a time)
            const Vec8f32 = @Vector(8, f32);
            var inten_max_vec: Vec8f32 = @splat(0.0);

            const simd_end_inten = num_points - (num_points % 8);
            i = 0;
            while (i < simd_end_inten) : (i += 8) {
                const v = Vec8f32{ intensity[i], intensity[i + 1], intensity[i + 2], intensity[i + 3],
                                   intensity[i + 4], intensity[i + 5], intensity[i + 6], intensity[i + 7] };
                inten_max_vec = @max(inten_max_vec, v);
            }
            intensity_max = @reduce(.Max, inten_max_vec);

            // Handle tail elements
            while (i < num_points) : (i += 1) {
                const inten = intensity[i];
                if (inten > intensity_max) intensity_max = inten;
            }
        } else {
            // Scalar fallback for small arrays
            for (mz, intensity) |m, inten| {
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

        const spectrum = advanced.Spectrum{
            .mz = mz,
            .intensity = intensity,
            .ranges = &[_]advanced.MassRange{},
            .features = features_opt,
            .mz_min = mz_min,
            .mz_max = mz_max,
            .intensity_max = intensity_max,
        };

        self.current_spectrum = spectrum;
        self.current_scan_index = scan_index;
        self.scans[scan_index].peak_count = num_points;
        // Use the scan's method mass range for default x-axis view
        const zm_min = if (scan.low_mass > 0 and scan.low_mass < mz_min) scan.low_mass else mz_min;
        const zm_max = if (scan.high_mass > zm_min) scan.high_mass else mz_max;
        self.zoom = .{
            .mz_min = zm_min,
            .mz_max = zm_max,
            .inten_min = 0,
            .inten_max = intensity_max,
        };

        // Cache the decoded spectrum for fast navigation back to this scan
        self.cacheSpectrum(scan_index, spectrum) catch {};
    }

    /// Find next/previous scan index respecting the current filter.
    pub fn findNextFilteredScan(self: *AppState, direction: i32) ?usize {
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
                if (self.current_scan_index + 1 < self.scans.len)
                    return self.current_scan_index + 1;
            } else {
                if (self.current_scan_index > 0)
                    return self.current_scan_index - 1;
            }
            return null;
        }
    }

    pub fn goToPreviousScan(self: *AppState) !void {
        if (self.findNextFilteredScan(-1)) |idx| {
            try self.loadScan(idx);
        }
    }

    pub fn goToNextScan(self: *AppState) !void {
        if (self.findNextFilteredScan(1)) |idx| {
            try self.loadScan(idx);
        }
    }

    pub fn goToFirstScan(self: *AppState) !void {
        if (self.filtered_indices) |fi| {
            if (fi.len > 0) try self.loadScan(fi[0]);
        } else if (self.scans.len > 0) {
            try self.loadScan(0);
        }
    }

    pub fn goToLastScan(self: *AppState) !void {
        if (self.filtered_indices) |fi| {
            if (fi.len > 0) try self.loadScan(fi[fi.len - 1]);
        } else if (self.scans.len > 0) {
            try self.loadScan(self.scans.len - 1);
        }
    }

    pub fn hasFileOpen(self: AppState) bool {
        return self.raw_file != null;
    }

    pub fn hasSpectrum(self: AppState) bool {
        return self.current_spectrum != null;
    }

    /// Load scan using an arena allocator — all allocations are freed when arena is destroyed.
    /// This is ~10x faster than per-scan alloc/free for bulk iteration (B5).
    pub fn loadScanArena(self: *AppState, scan_index: usize, arena: *std.heap.ArenaAllocator) !usize {
        if (scan_index >= self.scans.len) return error.ScanOutOfRange;
        if (self.raw_file == null) return error.NoFileOpen;

        const mm = self.raw_file.?.mm;
        const packet_pos = self.raw_file.?.packet_pos;
        const file_size = self.raw_file.?.file_size;
        const scan = self.scans[scan_index];

        const packet_offset = packet_pos + scan.data_offset;
        if (packet_offset >= file_size) {
            return error.OffsetBeyondFile;
        }

        const header_size = 32;
        if (packet_offset + header_size > file_size) {
            return error.Truncated;
        }
        const header_bytes = mm.memory[packet_offset..packet_offset + header_size];
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
        const actual_size: usize = @intCast(@min(packet_size, file_size - packet_offset));
        if (actual_size == 0) return error.Truncated;

        const packet_slice = mm.memory[packet_offset..packet_offset + actual_size];

        // Determine packet type and estimate output size
        const is_profile = scan.packet_type == raw.PACKET_TYPE_FT_PROFILE;
        const est_peaks: usize = if (is_profile) blk: {
            // Profile packets can have multiple segments. Sum all segments' num_expanded.
            // See UNSKILLED.md: "DO NOT silently ignore profile buffer sizing bug"
            const segment_data_start = 32 + @as(usize, h.num_segments) * 8;
            var seg_pos = segment_data_start;
            var total_expanded: usize = 0;
            var seg: u32 = 0;
            while (seg < h.num_segments) : (seg += 1) {
                if (packet_slice.len >= seg_pos + 24) {
                    const num_expanded = std.mem.readInt(u32, packet_slice[seg_pos + 20 ..][0..4], .little);
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

        // Allocate decode buffers from arena (fast bump allocation)
        const mz_buf = arena.allocator().alloc(f64, est_peaks) catch return error.OutOfMemory;
        const intensity_buf = arena.allocator().alloc(f32, est_peaks) catch return error.OutOfMemory;

        // For FT_PROFILE packets with embedded centroid data, decode centroids instead of profile
        const has_centroid_data = h.num_centroid_words > 0;
        const num_points = if (is_profile and !has_centroid_data) blk: {
            var calibrators: []const f64 = &[_]f64{};
            if (self.trailer_events) |te| {
                if (te.getEvent(scan_index)) |evt| {
                    calibrators = evt.mass_calibrators;
                }
            }
            const use_subsegment = (h.default_feature_word & 0x40) == 0
                and (h.default_feature_word & 0x80) != 0;
            break :blk try profile.decodeFtProfile(
                packet_slice, calibrators, mz_buf, intensity_buf, use_subsegment);
        } else advanced.decodeSimplifiedCentroidsIntoBuffers(
            packet_slice, 0, mz_buf, intensity_buf, null,
        ) catch |err| switch (err) {
            advanced.PacketError.OutOfMemory => return error.OutOfMemory,
            else => return error.Truncated,
        };

        // Allocate final arrays from arena
        const mz = arena.allocator().alloc(f64, num_points) catch return error.OutOfMemory;
        const intensity = arena.allocator().alloc(f32, num_points) catch return error.OutOfMemory;
        @memcpy(mz, mz_buf[0..num_points]);
        @memcpy(intensity, intensity_buf[0..num_points]);

        return num_points;
    }

    /// Zero-allocation bulk scan loader for benchmarks.
    /// Reuses grow-only buffers; no allocator calls, no copies. Returns point count.
    pub fn loadScanBulk(self: *AppState, scan_index: usize) !usize {
        if (scan_index >= self.scans.len) return error.ScanOutOfRange;
        if (self.raw_file == null) return error.NoFileOpen;

        const mm = self.raw_file.?.mm;
        const packet_pos = self.raw_file.?.packet_pos;
        const file_size = self.raw_file.?.file_size;
        const scan = self.scans[scan_index];

        const packet_offset = packet_pos + scan.data_offset;
        if (packet_offset >= file_size) {
            return error.OffsetBeyondFile;
        }

        const header_size = 32;
        if (packet_offset + header_size > file_size) {
            return error.Truncated;
        }
        const header_bytes = mm.memory[packet_offset..packet_offset + header_size];
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
        const actual_size: usize = @intCast(@min(packet_size, file_size - packet_offset));
        if (actual_size == 0) return error.Truncated;

        const packet_slice = mm.memory[packet_offset..packet_offset + actual_size];

        // Determine packet type and estimate output size
        const is_profile = scan.packet_type == raw.PACKET_TYPE_FT_PROFILE;
        const est_peaks: usize = if (is_profile) blk: {
            // Profile packets can have multiple segments. Sum all segments' num_expanded.
            // See UNSKILLED.md: "DO NOT silently ignore profile buffer sizing bug"
            const segment_data_start = 32 + @as(usize, h.num_segments) * 8;
            var seg_pos = segment_data_start;
            var total_expanded: usize = 0;
            var seg: u32 = 0;
            while (seg < h.num_segments) : (seg += 1) {
                if (packet_slice.len >= seg_pos + 24) {
                    const num_expanded = std.mem.readInt(u32, packet_slice[seg_pos + 20 ..][0..4], .little);
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

        // Grow reusable buffers if needed (amortized — rarely reallocates)
        if (self.reuse_mz == null or self.reuse_mz.?.len < est_peaks) {
            if (self.reuse_mz) |old| self.allocator.free(old);
            self.reuse_mz = self.allocator.alloc(f64, est_peaks) catch return error.OutOfMemory;
        }
        if (self.reuse_intensity == null or self.reuse_intensity.?.len < est_peaks) {
            if (self.reuse_intensity) |old| self.allocator.free(old);
            self.reuse_intensity = self.allocator.alloc(f32, est_peaks) catch return error.OutOfMemory;
        }

        // Prefetch next scan's data if available (overlaps memory fetch with decode)
        if (scan_index + 1 < self.scans.len) {
            const next_scan = self.scans[scan_index + 1];
            const next_offset = packet_pos + next_scan.data_offset;
            if (next_offset < file_size) {
                @prefetch(mm.memory.ptr + next_offset, .{ .rw = .read, .cache = .data, .locality = 3 });
            }
        }

        // For FT_PROFILE packets with embedded centroid data, decode centroids instead of profile
        const has_centroid_data = h.num_centroid_words > 0;
        const num_points = if (is_profile and !has_centroid_data) blk: {
            var calibrators: []const f64 = &[_]f64{};
            if (self.trailer_events) |te| {
                if (te.getEvent(scan_index)) |evt| {
                    calibrators = evt.mass_calibrators;
                }
            }
            const use_subsegment = (h.default_feature_word & 0x40) == 0
                and (h.default_feature_word & 0x80) != 0;
            break :blk try profile.decodeFtProfile(
                packet_slice, calibrators, self.reuse_mz.?, self.reuse_intensity.?, use_subsegment);
        } else advanced.decodeSimplifiedCentroidsIntoBuffers(
            packet_slice, 0, self.reuse_mz.?, self.reuse_intensity.?, null,
        ) catch |err| switch (err) {
            advanced.PacketError.OutOfMemory => return error.OutOfMemory,
            else => return error.Truncated,
        };

        self.scans[scan_index].peak_count = num_points;
        return num_points;
    }

    /// Load scan data with raw frequencies preserved (for profile packets).
    /// Identical to loadScanBulk but also populates reuse_freq with raw frequencies.
    pub fn loadScanBulkWithFreq(self: *AppState, scan_index: usize) !usize {
        if (scan_index >= self.scans.len) return error.ScanOutOfRange;
        if (self.raw_file == null) return error.NoFileOpen;

        const mm = self.raw_file.?.mm;
        const packet_pos = self.raw_file.?.packet_pos;
        const file_size = self.raw_file.?.file_size;
        const scan = self.scans[scan_index];

        const packet_offset = packet_pos + scan.data_offset;
        if (packet_offset >= file_size) {
            return error.OffsetBeyondFile;
        }

        const header_size = 32;
        if (packet_offset + header_size > file_size) {
            return error.Truncated;
        }
        const header_bytes = mm.memory[packet_offset..packet_offset + header_size];
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
        const actual_size: usize = @intCast(@min(packet_size, file_size - packet_offset));
        if (actual_size == 0) return error.Truncated;

        const packet_slice = mm.memory[packet_offset..packet_offset + actual_size];

        // Determine packet type and estimate output size
        const is_profile = scan.packet_type == raw.PACKET_TYPE_FT_PROFILE;
        const est_peaks: usize = if (is_profile) blk: {
            const segment_data_start = 32 + @as(usize, h.num_segments) * 8;
            var seg_pos = segment_data_start;
            var total_expanded: usize = 0;
            var seg: u32 = 0;
            while (seg < h.num_segments) : (seg += 1) {
                if (packet_slice.len >= seg_pos + 24) {
                    const num_expanded = std.mem.readInt(u32, packet_slice[seg_pos + 20 ..][0..4], .little);
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

        // Grow reusable buffers if needed
        if (self.reuse_mz == null or self.reuse_mz.?.len < est_peaks) {
            if (self.reuse_mz) |old| self.allocator.free(old);
            self.reuse_mz = self.allocator.alloc(f64, est_peaks) catch return error.OutOfMemory;
        }
        if (self.reuse_intensity == null or self.reuse_intensity.?.len < est_peaks) {
            if (self.reuse_intensity) |old| self.allocator.free(old);
            self.reuse_intensity = self.allocator.alloc(f32, est_peaks) catch return error.OutOfMemory;
        }
        if (self.reuse_freq == null or self.reuse_freq.?.len < est_peaks) {
            if (self.reuse_freq) |old| self.allocator.free(old);
            self.reuse_freq = self.allocator.alloc(f64, est_peaks) catch return error.OutOfMemory;
        }

        // For FT_PROFILE packets with embedded centroid data, decode centroids instead of profile
        const has_centroid_data = h.num_centroid_words > 0;
        const num_points = if (is_profile and !has_centroid_data) blk: {
            var calibrators: []const f64 = &[_]f64{};
            if (self.trailer_events) |te| {
                if (te.getEvent(scan_index)) |evt| {
                    calibrators = evt.mass_calibrators;
                }
            }
            const use_subsegment = (h.default_feature_word & 0x40) == 0
                and (h.default_feature_word & 0x80) != 0;
            break :blk try profile.decodeFtProfileWithFreq(
                packet_slice, calibrators, self.reuse_freq.?, self.reuse_mz.?, self.reuse_intensity.?, use_subsegment);
        } else advanced.decodeSimplifiedCentroidsIntoBuffers(
            packet_slice, 0, self.reuse_mz.?, self.reuse_intensity.?, null,
        ) catch |err| switch (err) {
            advanced.PacketError.OutOfMemory => return error.OutOfMemory,
            else => return error.Truncated,
        };

        self.scans[scan_index].peak_count = num_points;
        return num_points;
    }

    /// Parse first N scan trailers eagerly (for scan list display), rest on demand.
    /// With TrailerScanEvents parsed at file open, this is a no-op.
    pub fn parseScanTrailersLazily(self: *AppState) !void {
        _ = self;
    }

    /// Ensure scan trailer metadata is available (for navigation/loading).
    /// With TrailerScanEvents parsed at open, this is a no-op — all metadata
    /// is already populated. Kept for API compatibility.
    pub fn ensureScanTrailer(self: *AppState, scan_index: usize) void {
        _ = self;
        _ = scan_index;
    }

    pub fn setMsLevelFilter(self: *AppState, level: ?u8) void {
        self.filter_ms_level = level;
    }

    /// Compute TIC and BPC chromatograms from scan indices (no packet decode).
    pub fn computeChromatograms(self: *AppState) void {
        if (self.scans.len == 0) return;

        // Free old chromatograms
        if (self.tic_chromatogram) |*c| {
            c.deinit(self.allocator);
            self.tic_chromatogram = null;
        }
        if (self.bpc_chromatogram) |*c| {
            c.deinit(self.allocator);
            self.bpc_chromatogram = null;
        }

        const n = self.scans.len;
        const allocator = self.allocator;

        // TIC: rt + tic + ms_level
        const tic_rt = allocator.alloc(f64, n) catch return;
        errdefer allocator.free(tic_rt);
        const tic_intensity = allocator.alloc(f64, n) catch return;
        errdefer allocator.free(tic_intensity);
        const tic_ms_level = allocator.alloc(u8, n) catch return;
        errdefer allocator.free(tic_ms_level);
        for (self.scans, 0..) |scan, i| {
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
        for (self.scans, 0..) |scan, i| {
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

    pub fn setChromatogramMsLevelFilter(self: *AppState, level: ?u8) void {
        self.chromatogram_ms_level_filter = level;
    }
};

// Global singleton instance (thread-unsafe but Win32 is single-threaded anyway)
var g_state: ?*AppState = null;

pub fn setGlobalState(state: *AppState) void {
    g_state = state;
}

pub fn getGlobalState() ?*AppState {
    return g_state;
}
