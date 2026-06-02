/// Global application state shared between GUI components.
const std = @import("std");
const advanced = @import("advanced_packet");
const raw = @import("raw_file");
const raw_file_reader = @import("raw_file_reader");
const scan_event = @import("scan_event");
const trailer_events = @import("trailer_events");
const profile = @import("profile_packet");
const scan_decoder = @import("scan_decoder");

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

pub const ViewMode = enum {
    stick,
    line,
};

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

    // Scan decoder — owns the decode pipeline and spectrum cache.
    // Extracted from the four loadScan* methods (C1 refactor). Keeps
    // packet-header read, decode dispatch, and SIMD min/max in one place.
    decoder: scan_decoder.ScanDecoder,

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
            .decoder = scan_decoder.ScanDecoder.init(allocator),
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
            if (!self.decoder.isCached(spec.*)) spec.deinit(self.allocator);
        }
        // Free all cached spectra via decoder
        self.decoder.freeCache();
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

        // Configure scan decoder with RawFile state
        self.decoder.configure(
            rf.mm,
            rf.packet_pos,
            rf.file_size,
            self.trailer_events,
        );
        self.decoder.setReuseBuffers(
            self.reuse_mz,
            self.reuse_intensity,
            self.reuse_freq,
            self.reuse_features,
            self.reuse_widths,
            self.reuse_noise,
        );

        // Parse TrailerScanEvents to get authoritative MS level and precursor metadata.
        // trailer_offset in ScanIndexEntry is an INDEX into the scan_to_unique array.
        try self.parseScanTrailersAtOpen();

        // Re-configure decoder with the trailer events now that they are parsed.
        self.decoder.configure(
            rf.mm,
            rf.packet_pos,
            rf.file_size,
            self.trailer_events,
        );

        // Default to MS1 filter for cleaner initial view
        self.filter_ms_level = 1;

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
            const trailer = trailer_events.readScanTrailer(self.allocator, mm, scan.trailer_offset) catch |err| {
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
        return self.decoder.isCached(spectrum);
    }

    /// Deep-copy a spectrum into the cache (round-robin eviction).
    fn cacheSpectrum(self: *AppState, scan_index: usize, spectrum: advanced.Spectrum) !void {
        try self.decoder.cacheSpectrum(scan_index, spectrum);
    }

    /// Preload the first N scans into the cache.
    pub fn preloadCache(self: *AppState) void {
        const n = @min(scan_decoder.SPECTRUM_CACHE_SIZE, self.scans.len);
        for (0..n) |i| {
            self.loadScan(i) catch continue;
        }
    }

    pub fn loadScan(self: *AppState, scan_index: usize) !void {
        if (scan_index >= self.scans.len) return error.ScanOutOfRange;
        if (self.raw_file == null) return error.NoFileOpen;
        // TrailerScanEvents are parsed at file open. MS level and precursor
        // metadata are already authoritative in self.scans[scan_index].

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

        // Check cache first (ScanDecoder manages the LRU cache)
        if (self.decoder.getCached(scan_index)) |cached| {
            if (self.current_spectrum) |*spec| {
                if (!self.isSpectrumCached(spec.*)) spec.deinit(self.allocator);
            }
            self.current_spectrum = cached; // shallow copy
            self.current_scan_index = scan_index;
            self.zoom = .{
                .mz_min = cached.mz_min,
                .mz_max = cached.mz_max,
                .inten_min = 0,
                .inten_max = cached.intensity_max,
            };
            self.scans[scan_index].peak_count = cached.pointCount();
            return;
        }

        // Free old spectrum (only if not cached)
        if (self.current_spectrum) |*spec| {
            if (!self.isSpectrumCached(spec.*)) spec.deinit(self.allocator);
            self.current_spectrum = null;
        }

        // Decode into owned buffers via ScanDecoder
        const result = try self.decoder.decode(
            scan_index,
            &.{ .packet_type = scan.packet_type, .data_offset = scan.data_offset },
            .owned,
        );
        const num_points = result.num_points;

        // Copy into owned arrays for the Spectrum struct
        const mz = try self.allocator.alloc(f64, num_points);
        errdefer self.allocator.free(mz);
        const intensity = try self.allocator.alloc(f32, num_points);
        errdefer self.allocator.free(intensity);
        @memcpy(mz, result.mz);
        @memcpy(intensity, result.intensity);

        // Copy features if present (centroid data)
        var features_opt: ?[]advanced.PeakFeatures = null;
        if (result.features_opt) |feat| {
            const f = try self.allocator.alloc(advanced.PeakFeatures, num_points);
            errdefer self.allocator.free(f);
            @memcpy(f, feat);
            features_opt = f;
        }

        const mz_min = result.mz_min;
        const mz_max = result.mz_max;
        const intensity_max = result.intensity_max;

        // ------------------------------------------------------------------
        // Label Peak Data Parsing (resolution, noise, baseline)
        // ------------------------------------------------------------------
        // Only available from centroid packets; needs parse_peak_metadata flag.
        // We need the packet header (h) to know if expansion/noise words exist.
        // Re-decode the packet header — this is just 32 bytes, cheap.
        const packet_offset = self.raw_file.?.packet_pos + scan.data_offset;
        const header_bytes = self.raw_file.?.mm.memory[packet_offset..packet_offset + 32];
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
        const actual_size: usize = @intCast(@min(packet_size, self.raw_file.?.file_size - packet_offset));
        if (actual_size == 0) return error.Truncated;
        const packet_slice = self.raw_file.?.mm.memory[packet_offset..packet_offset + actual_size];

        const needs_features = h.num_centroid_words > 0;
        const has_label_data = self.parse_peak_metadata and needs_features and num_points > 0 and
            (h.num_expansion_words > 0 or h.num_noise_info_words > 0);

        if (has_label_data) {
            // Reuse the result's mz/intensity slices as source for label parse
            if (h.num_expansion_words > 0) {
                const max_widths = h.num_expansion_words - 1;
                if (self.reuse_widths == null or self.reuse_widths.?.len < max_widths) {
                    if (self.reuse_widths) |old| self.allocator.free(old);
                    self.reuse_widths = self.allocator.alloc(f32, max_widths) catch null;
                }
                if (self.reuse_widths) |wb| {
                    const n = advanced.readResolutionWidths(packet_slice, 0, wb) catch 0;
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
                const max_noise = h.num_noise_info_words * 4 / @sizeOf(advanced.NoiseInfoPacket);
                if (self.reuse_noise == null or self.reuse_noise.?.len < max_noise) {
                    if (self.reuse_noise) |old| self.allocator.free(old);
                    self.reuse_noise = self.allocator.alloc(advanced.NoiseInfoPacket, max_noise) catch null;
                }
                if (self.reuse_noise) |nb| {
                    const n = advanced.readNoiseInfoPackets(packet_slice, 0, nb) catch 0;
                    if (n > 0) {
                        if (features_opt) |fb| {
                            advanced.interpolateNoiseBaseline(
                                mz, intensity, fb, nb,
                            );
                        }
                    }
                }
            }
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

        const scan = self.scans[scan_index];
        const result = try self.decoder.decode(
            scan_index,
            &.{ .packet_type = scan.packet_type, .data_offset = scan.data_offset },
            .owned,
        );
        const num_points = result.num_points;

        // Copy into arena-allocated arrays (arena owns the copies on reset)
        const mz = arena.allocator().alloc(f64, num_points) catch return error.OutOfMemory;
        const intensity = arena.allocator().alloc(f32, num_points) catch return error.OutOfMemory;
        @memcpy(mz, result.mz);
        @memcpy(intensity, result.intensity);

        return num_points;
    }

    /// Zero-allocation bulk scan loader for benchmarks.
    /// Reuses grow-only buffers; no allocator calls, no copies. Returns point count.
    pub fn loadScanBulk(self: *AppState, scan_index: usize) !usize {
        if (scan_index >= self.scans.len) return error.ScanOutOfRange;
        if (self.raw_file == null) return error.NoFileOpen;

        const scan = self.scans[scan_index];

        // Prefetch next scan's data (overlaps memory fetch with decode)
        if (scan_index + 1 < self.scans.len) {
            const next_scan = self.scans[scan_index + 1];
            const next_offset = self.raw_file.?.packet_pos + next_scan.data_offset;
            if (next_offset < self.raw_file.?.file_size) {
                @prefetch(self.raw_file.?.mm.memory.ptr + next_offset, .{ .rw = .read, .cache = .data, .locality = 3 });
            }
        }

        const result = try self.decoder.decode(
            scan_index,
            &.{ .packet_type = scan.packet_type, .data_offset = scan.data_offset },
            .reuse_buffers,
        );
        self.scans[scan_index].peak_count = result.num_points;
        return result.num_points;
    }

    /// Load scan data with raw frequencies preserved (for profile packets).
    /// Identical to loadScanBulk but also populates reuse_freq with raw frequencies.
    pub fn loadScanBulkWithFreq(self: *AppState, scan_index: usize) !usize {
        if (scan_index >= self.scans.len) return error.ScanOutOfRange;
        if (self.raw_file == null) return error.NoFileOpen;

        const scan = self.scans[scan_index];
        const result = try self.decoder.decode(
            scan_index,
            &.{ .packet_type = scan.packet_type, .data_offset = scan.data_offset },
            .reuse_with_freq,
        );
        self.scans[scan_index].peak_count = result.num_points;
        return result.num_points;
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
