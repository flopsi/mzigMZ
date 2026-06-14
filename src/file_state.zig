/// FileState — owns all file-level metadata for an open .raw file.
///
/// Extracted from AppState (Opportunity 1). Before this module, file metadata
/// (RawFile, ScanInfo[], TrailerScanEvents, instrument identity) was mixed with
/// GUI state (zoom, pan, view mode) in a single 800-line struct.
///
/// FileState is a deep module: small interface (~8 methods) hiding complex
/// parsing logic (mmap, controller resolution, scan table parsing, trailer
/// events, instrument ID extraction).
const std = @import("std");
const raw = @import("raw_file");
const raw_file_reader = @import("raw_file_reader");
const trailer_events = @import("trailer_events");
const trailer_extra = @import("trailer_extra");
const scan_event = @import("scan_event");

/// Per-scan metadata extracted from the scan index (zero-copy into mmap).
/// This struct was originally part of AppState; moved here during
/// Opportunity 1 (AppState decomposition) so FileState can own it.
pub const ScanInfo = struct {
    scan_number: i32,
    packet_type: u32,
    number_packets: i32,
    data_size: u32,
    data_offset: u64,
    trailer_offset: i32,
    ms_level: u8,
    charge_state: i32,
    precursor_mz: f64,
    filter_string: ?[]u8,
    rt: f64,
    tic: f64,
    base_peak_mz: f64,
    base_peak_intensity: f64,
    low_mass: f64,
    high_mass: f64,
    scan_event_index: usize,
    collision_energy: f64,
    isolation_width: f64,
    peak_count: usize,
    cycle_number: i32,
    master_scan_number: i32,
    monoisotopic_mz: f64,
};

pub const FileStateError = error{
    FileTooLarge,
    Truncated,
    InvalidRawFile,
    UnsupportedFileRevision,
    InvalidRawFileInfo,
    NoMsController,
    InvalidControllerOffset,
    InvalidRunHeader,
    TooManyScans,
    InvalidStringLength,
    OffsetOverflow,
    ScanOutOfRange,
    ScanIndexMismatch,
    OutOfMemory,
};

pub const FileState = struct {
    allocator: std.mem.Allocator,

    file_path: ?[]u8,
    raw_file: ?raw_file_reader.RawFile,
    scans: []ScanInfo,

    trailer_events: ?trailer_events.TrailerScanEvents,
    trailer_extra: ?trailer_extra.TrailerExtra,

    instrument_model: ?[]u8,
    instrument_serial: ?[]u8,
    software_version: ?[]u8,
    creation_time: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) FileState {
        return .{
            .allocator = allocator,
            .file_path = null,
            .raw_file = null,
            .scans = &.{},
            .trailer_events = null,
            .trailer_extra = null,
            .instrument_model = null,
            .instrument_serial = null,
            .software_version = null,
            .creation_time = null,
        };
    }

    pub fn deinit(self: *FileState) void {
        if (self.trailer_events) |*te| {
            te.deinit(self.allocator);
            self.trailer_events = null;
        }
        if (self.trailer_extra) |*te| {
            te.deinit(self.allocator);
            self.trailer_extra = null;
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
        for (self.scans) |scan| {
            if (scan.filter_string) |fs| self.allocator.free(fs);
        }
        if (self.raw_file) |*rf| {
            rf.deinit();
            self.raw_file = null;
        }
        self.allocator.free(self.file_path orelse &[_]u8{});
        self.allocator.free(self.scans);
    }

    pub fn is_open(self: FileState) bool {
        return self.raw_file != null;
    }

    pub fn scan_count(self: FileState) usize {
        return self.scans.len;
    }

    pub fn file_revision(self: FileState) u16 {
        return if (self.raw_file) |rf| rf.file_revision else 0;
    }

    pub fn memory(self: FileState) ?[]const u8 {
        return if (self.raw_file) |rf| rf.memory() else null;
    }

    pub fn packet_pos(self: FileState) u64 {
        return if (self.raw_file) |rf| rf.packet_pos else 0;
    }

    pub fn file_size(self: FileState) u64 {
        return if (self.raw_file) |rf| rf.file_size else 0;
    }

    pub fn scan_at(self: FileState, index: usize) ?*ScanInfo {
        if (index >= self.scans.len) return null;
        return &self.scans[index];
    }

    pub fn open(self: *FileState, io: std.Io, path: []const u8) FileStateError!void {
        self.deinit();
        self.* = init(self.allocator);

        var rf = raw_file_reader.RawFile.open(self.allocator, io, path) catch |err| {
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
                error.OutOfMemory => return error.OutOfMemory,
            };
        };

        const path_copy = self.allocator.dupe(u8, path) catch {
            rf.deinit();
            return error.OutOfMemory;
        };
        self.file_path = path_copy;

        self.creation_time = rf.creation_time_iso;
        rf.creation_time_iso = null;
        self.instrument_model = rf.instrument_model;
        rf.instrument_model = null;
        self.instrument_serial = rf.instrument_serial;
        rf.instrument_serial = null;
        self.software_version = rf.software_version;
        rf.software_version = null;

        try self.buildScanList(&rf);
        self.raw_file = rf;
        try self.parse_trailer_scan_events();
        try self.parse_trailer_extra_table();
    }

    fn buildScanList(self: *FileState, rf: *raw_file_reader.RawFile) FileStateError!void {
        const rev = rf.file_revision;
        const num_scans = rf.num_scans;
        const scan_index_size = raw.scan_index_size(rev);
        const mm_mem = rf.memory();
        const scan_table_buf = mm_mem[rf.scan_table_start..][0..rf.scan_table_size];

        const scans = self.allocator.alloc(ScanInfo, num_scans) catch return error.OutOfMemory;
        errdefer self.allocator.free(scans);

        var scan_idx: usize = 0;
        while (scan_idx < num_scans) : (scan_idx += 1) {
            const entry_offset = std.math.mul(usize, scan_idx, scan_index_size) catch return error.OffsetOverflow;
            const entry = raw.parse_scan_index(scan_table_buf, entry_offset, rev) catch |err| switch (err) {
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
                .ms_level = 0,
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
                .cycle_number = entry.cycle_number,
                .master_scan_number = 0,
                .monoisotopic_mz = 0,
            };
        }

        self.scans = scans;
    }

    fn parse_trailer_scan_events(self: *FileState) FileStateError!void {
        const rf = &self.raw_file.?;
        const mm = rf.mm;
        const controller_offset = rf.controller_offset;
        const num_scans = rf.num_scans;
        const rev = rf.file_revision;

        const trailer_read_offset = std.math.add(u64, controller_offset, @as(u64, raw.RUN_HEADER_TRAILER_SCAN_EVENTS_POS)) catch {
            std.log.warn("Trailer read offset overflows, using heuristic MS levels", .{});
            self.applyHeuristicMsLevels();
            return;
        };
        const trailer_pos_i64 = raw.readI64Mm(mm.memory, trailer_read_offset) catch |err| {
            std.log.warn("Failed to read trailer position: {s}, using heuristic MS levels", .{@errorName(err)});
            self.applyHeuristicMsLevels();
            return;
        };
        const trailer_pos: u64 = std.math.cast(u64, trailer_pos_i64) orelse {
            std.log.warn("Invalid trailer position {}, using heuristic MS levels", .{trailer_pos_i64});
            self.applyHeuristicMsLevels();
            return;
        };
        if (trailer_pos == 0) {
            std.log.warn("Invalid trailer position 0, using heuristic MS levels", .{});
            self.applyHeuristicMsLevels();
            return;
        }

        const trailers = trailer_events.parse_trailer_scan_events(
            self.allocator,
            mm,
            trailer_pos,
            num_scans,
            rev,
        ) catch |err| {
            std.log.warn("Failed to parse trailer events: {s}, using heuristic MS levels", .{@errorName(err)});
            self.applyHeuristicMsLevels();
            return;
        };

        self.trailer_events = trailers;

        for (self.scans, 0..) |*scan, i| {
            if (self.trailer_events.?.get_event(i)) |evt| {
                scan.ms_level = std.math.cast(u8, evt.info.ms_order) orelse
                    if (scan.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
                scan.scan_event_index = self.trailer_events.?.scan_to_unique[i];
                if (scan.ms_level >= 2 and evt.reactions.len > 0) {
                    const rxn = evt.reactions[0];
                    scan.precursor_mz = rxn.precursor_mass;
                    scan.isolation_width = rxn.isolation_width;
                    scan.collision_energy = rxn.collision_energy;
                }

                // Build Thermo-style filter string from the scan event. This is
                // required by downstream mzML consumers (OpenMS, pyteomics, etc.)
                // and is the only source for modern (rev >= 65) RAW files.
                if (scan.filter_string == null) {
                    if (scan_event.build_filter_string(evt.*, self.allocator)) |maybe_fs| {
                        scan.filter_string = maybe_fs;
                    } else |err| {
                        std.log.warn("Failed to build filter string for scan {d}: {s}", .{ scan.scan_number, @errorName(err) });
                    }
                }
            } else {
                scan.ms_level = if (scan.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
            }
        }
    }

    fn applyHeuristicMsLevels(self: *FileState) void {
        for (self.scans) |*scan| {
            scan.ms_level = if (scan.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
        }
    }

    fn parse_trailer_extra_table(self: *FileState) FileStateError!void {
        const rf = &self.raw_file.?;
        if (rf.trailer_extra_pos == 0 or rf.num_trailer_extra == 0) {
            return;
        }

        const table = trailer_extra.parse_trailer_extra(
            self.allocator,
            rf.mm,
            rf.controller_offset,
            rf.trailer_extra_pos,
            rf.num_trailer_extra,
            rf.file_revision,
        ) catch |err| {
            std.log.warn("Failed to parse trailer extra table: {s}", .{@errorName(err)});
            return;
        };

        self.trailer_extra = table;

        for (self.scans, 0..) |*scan, i| {
            if (table.get_i32(rf.mm.memory, i, "Master Scan Number:")) |master| {
                scan.master_scan_number = master;
            } else if (table.get_i32(rf.mm.memory, i, "Master Scan Number")) |master| {
                scan.master_scan_number = master;
            }
            if (table.get_f64(rf.mm.memory, i, "Monoisotopic M/Z:")) |mz| {
                scan.monoisotopic_mz = mz;
            } else if (table.get_f64(rf.mm.memory, i, "Monoisotopic M/Z")) |mz| {
                scan.monoisotopic_mz = mz;
            }
        }
    }
};

test "FileState init/deinit is idempotent" {
    var fs = FileState.init(std.testing.allocator);
    defer fs.deinit();
    try std.testing.expect(!fs.is_open());
    try std.testing.expectEqual(@as(usize, 0), fs.scan_count());
}
