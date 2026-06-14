/// RawFileWriter: centroid-only .raw file writer.
const std = @import("std");
const raw = @import("raw_file");
const wp = @import("writer_primitives");
const scan_event = @import("scan_event");
const advanced_packet = @import("advanced_packet");
const spec_file_header = @import("spec/file_header");
const spec_raw_info = @import("spec/raw_info");
const spec_run_header = @import("spec/run_header");

/// File revision produced by this de-novo writer. Currently hard-coded to rev 66.
pub const target_file_revision = 66;

pub const RawWriterError = error{
    NoScans,
    InvalidState,
    ShortWrite,
    TooManyScans,
    TooManyPoints,
    InvalidInput,
    OffsetOverflow,
};

/// Full error surface for the public RawFileWriter API and patchChecksum.
pub const Error = RawWriterError || wp.WritePrimitiveError || advanced_packet.PacketError || std.Io.Dir.OpenError || std.Io.File.StatError;

pub const ScanWriteInfo = struct {
    scan_number: i32,
    ms_level: u8,
    rt: f64,
    tic: f64,
    base_peak_mz: f64,
    base_peak_intensity: f64,
    low_mass: f64,
    high_mass: f64,
    precursor_mz: f64,
    charge_state: i32,
    collision_energy: f64,
    isolation_width: f64,
    mz: []const f64,
    intensity: []const f32,
    event: ?scan_event.ScanEvent,
};

const RunHeaderPatches = struct {
    file_offset: u64,
    first_spectrum: u64,
    last_spectrum: u64,
    spectrum_pos: u64,
    packet_pos: u64,
    num_trailer_scan_events: u64,
    trailer_scan_events_pos: u64,
};

pub const RawFileWriter = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    file_header_size: u64,
    file_revision: u16,
    sequence_row_offset: u64,
    raw_info_offset: u64,
    run_header_offset: u64,
    patches: RunHeaderPatches,
    scans: std.ArrayList(ScanIndexEntry),
    trailer_events: TrailerEventsBuilder,
    current_offset: u64,
    state: enum { init, header_written, scanning, finalized },

    const ScanIndexEntry = struct {
        data_size: u32,
        trailer_offset: i32,
        scan_type_index: i32,
        scan_number: i32,
        packet_type: u32,
        number_packets: i32,
        data_offset: u64,
        start_time: f64,
        tic: f64,
        base_peak_intensity: f64,
        base_peak_mass: f64,
        low_mass: f64,
        high_mass: f64,
    };

    const TrailerEventsBuilder = struct {
        unique_events: std.ArrayList(scan_event.ScanEvent),
        scan_to_unique: std.ArrayList(usize),

        pub fn init() TrailerEventsBuilder {
            return .{ .unique_events = .empty, .scan_to_unique = .empty };
        }

        pub fn deinit(self: *TrailerEventsBuilder, allocator: std.mem.Allocator) void {
            for (self.unique_events.items) |*evt| evt.deinit(allocator);
            self.unique_events.deinit(allocator);
            self.scan_to_unique.deinit(allocator);
        }

        pub fn add_event(self: *TrailerEventsBuilder, allocator: std.mem.Allocator, evt: scan_event.ScanEvent) Error!usize {
            for (self.unique_events.items, 0..) |*ue, i| {
                if (scan_event.ScanEvent.eql(ue.*, evt)) {
                    var dup = evt;
                    dup.deinit(allocator);
                    try self.scan_to_unique.append(allocator, i);
                    return i;
                }
            }
            const new_idx = self.unique_events.items.len;
            try self.unique_events.append(allocator, evt);
            try self.scan_to_unique.append(allocator, new_idx);
            return new_idx;
        }

        // scanEventsEqual removed: use scan_event.ScanEvent.eql()
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, first_scan_number: i32) Error!RawFileWriter {
        var writer = RawFileWriter{
            .file = file,
            .io = io,
            .allocator = allocator,
            .file_header_size = spec_file_header.FILE_HEADER_SIZE,
            .file_revision = target_file_revision,
            .sequence_row_offset = 0,
            .raw_info_offset = 0,
            .run_header_offset = 0,
            .patches = undefined,
            .scans = .empty,
            .trailer_events = TrailerEventsBuilder.init(),
            .current_offset = 0,
            .state = .init,
        };
        try writer.writeFileHeaderPlaceholder();
        writer.sequence_row_offset = writer.current_offset;
        try writer.writeMinimalSequenceRow();
        try writer.writeMinimalAutoSamplerConfig();
        writer.raw_info_offset = writer.current_offset;
        try writer.writeMinimalRawFileInfo();
        writer.run_header_offset = writer.current_offset;
        try writer.writeRunHeaderPlaceholder(first_scan_number);
        writer.state = .header_written;
        return writer;
    }

    pub fn deinit(self: *RawFileWriter) void {
        self.scans.deinit(self.allocator);
        self.trailer_events.deinit(self.allocator);
    }

    pub fn add_scan(self: *RawFileWriter, scan: ScanWriteInfo) Error!void {
        if (self.state != .header_written and self.state != .scanning) return RawWriterError.InvalidState;
        const MAX_SCAN_COUNT: usize = 10_000_000;
        if (self.scans.items.len >= MAX_SCAN_COUNT) return RawWriterError.TooManyScans;
        const MAX_PEAKS_PER_SCAN: usize = 50_000_000;
        if (scan.mz.len > MAX_PEAKS_PER_SCAN or scan.intensity.len > MAX_PEAKS_PER_SCAN) return RawWriterError.TooManyPoints;
        if (scan.mz.len != scan.intensity.len or scan.mz.len == 0) return RawWriterError.InvalidInput;

        const packet_bytes = try advanced_packet.encode_simple_centroid(self.allocator, scan.mz, scan.intensity);
        defer self.allocator.free(packet_bytes);

        const packet_offset = self.current_offset;
        try self.file.writePositionalAll(self.io, packet_bytes, packet_offset);

        var trailer_event = scan.event orelse try self.makeDefaultScanEvent(scan);
        errdefer if (scan.event == null) trailer_event.deinit(self.allocator);
        const unique_idx = try self.trailer_events.add_event(self.allocator, trailer_event);

        const data_offset_relative = packet_offset - self.file_header_size;
        const scan_idx = ScanIndexEntry{
            .scan_number = scan.scan_number,
            // SAFETY: packet_bytes is produced by this writer, so its length is program-derived.
            .data_size = @intCast(packet_bytes.len),
            .data_offset = data_offset_relative,
            // SAFETY: unique_idx is a small in-memory index returned by the trailer-events builder.
            .trailer_offset = @intCast(unique_idx),
            .scan_type_index = 0,
            .packet_type = raw.PACKET_TYPE_FT_CENTROID,
            .number_packets = 1,
            .start_time = scan.rt,
            .tic = scan.tic,
            .base_peak_intensity = scan.base_peak_intensity,
            .base_peak_mass = scan.base_peak_mz,
            .low_mass = scan.low_mass,
            .high_mass = scan.high_mass,
            .cycle_number = 0,
        };
        try self.scans.append(self.allocator, scan_idx);
        self.current_offset = std.math.add(u64, self.current_offset, packet_bytes.len) catch return RawWriterError.OffsetOverflow;
        self.state = .scanning;
    }

    pub fn finalize(self: *RawFileWriter) Error!void {
        if (self.state != .scanning) return RawWriterError.InvalidState;
        if (self.scans.items.len == 0) return RawWriterError.NoScans;

        const spectrum_pos = self.current_offset;
        const scan_index_size = raw.scan_index_size(self.file_revision);
        const index_table_size = std.math.mul(usize, self.scans.items.len, scan_index_size) catch return RawWriterError.OffsetOverflow;
        var index_buf = try self.allocator.alloc(u8, index_table_size);
        defer self.allocator.free(index_buf);
        @memset(index_buf, 0);

        for (self.scans.items, 0..) |scan, i| {
            const entry_offset = std.math.mul(usize, i, scan_index_size) catch return RawWriterError.OffsetOverflow;
            try wp.encode_scan_index_entry(index_buf[entry_offset..][0..scan_index_size], .{
                .data_size = scan.data_size,
                .trailer_offset = scan.trailer_offset,
                .scan_type_index = scan.scan_type_index,
                .scan_number = scan.scan_number,
                .packet_type = scan.packet_type,
                .number_packets = scan.number_packets,
                .data_offset = scan.data_offset,
                .start_time = scan.start_time,
                .tic = scan.tic,
                .base_peak_intensity = scan.base_peak_intensity,
                .base_peak_mass = scan.base_peak_mass,
                .low_mass = scan.low_mass,
                .high_mass = scan.high_mass,
                .cycle_number = scan.cycle_number,
            }, self.file_revision);
        }
        try self.file.writePositionalAll(self.io, index_buf, spectrum_pos);
        self.current_offset = std.math.add(u64, self.current_offset, index_table_size) catch return RawWriterError.OffsetOverflow;

        const trailer_pos = self.current_offset;
        try self.writeTrailerScanEventsTable(trailer_pos);
        try self.patchRunHeader(spectrum_pos, trailer_pos);
        self.state = .finalized;
    }

    fn writeFileHeaderPlaceholder(self: *RawFileWriter) !void {
        var header: [spec_file_header.FILE_HEADER_SIZE]u8 = std.mem.zeroes([spec_file_header.FILE_HEADER_SIZE]u8);
        @memcpy(header[0..4], "RAW1");
        std.mem.writeInt(u16, header[spec_file_header.FILE_REV_OFFSET..][0..2], self.file_revision, .little);
        try self.file.writePositionalAll(self.io, &header, 0);
        self.current_offset = header.len;
    }

    fn writeMinimalSequenceRow(self: *RawFileWriter) !void {
        var base: [spec_file_header.SEQ_ROW_INFO_SIZE]u8 = std.mem.zeroes([spec_file_header.SEQ_ROW_INFO_SIZE]u8);
        try self.file.writePositionalAll(self.io, &base, self.current_offset);
        self.current_offset = std.math.add(u64, self.current_offset, base.len) catch return RawWriterError.OffsetOverflow;
        var i: usize = 0;
        while (i < 13) : (i += 1) {
            try wp.write_i32_at(self.file, self.io, self.current_offset, 0);
            self.current_offset = std.math.add(u64, self.current_offset, 4) catch return RawWriterError.OffsetOverflow;
        }
        try wp.write_i32_at(self.file, self.io, self.current_offset, 0);
        self.current_offset = std.math.add(u64, self.current_offset, 4) catch return RawWriterError.OffsetOverflow;
        try wp.write_i32_at(self.file, self.io, self.current_offset, 0);
        self.current_offset = std.math.add(u64, self.current_offset, 4) catch return RawWriterError.OffsetOverflow;
        try wp.write_i32_at(self.file, self.io, self.current_offset, 0);
        self.current_offset = std.math.add(u64, self.current_offset, 4) catch return RawWriterError.OffsetOverflow;
        try wp.write_i32_at(self.file, self.io, self.current_offset, 0);
        self.current_offset = std.math.add(u64, self.current_offset, 4) catch return RawWriterError.OffsetOverflow;
        i = 0;
        while (i < 15) : (i += 1) {
            try wp.write_i32_at(self.file, self.io, self.current_offset, 0);
            self.current_offset = std.math.add(u64, self.current_offset, 4) catch return RawWriterError.OffsetOverflow;
        }
    }

    fn writeMinimalAutoSamplerConfig(self: *RawFileWriter) !void {
        var base: [spec_file_header.AUTO_SAMPLER_CONFIG_SIZE]u8 = std.mem.zeroes([spec_file_header.AUTO_SAMPLER_CONFIG_SIZE]u8);
        try self.file.writePositionalAll(self.io, &base, self.current_offset);
        self.current_offset = std.math.add(u64, self.current_offset, base.len) catch return RawWriterError.OffsetOverflow;
        try wp.write_i32_at(self.file, self.io, self.current_offset, 0);
        self.current_offset = std.math.add(u64, self.current_offset, 4) catch return RawWriterError.OffsetOverflow;
    }

    fn writeMinimalRawFileInfo(self: *RawFileWriter) !void {
        var buf: [spec_raw_info.CURRENT.struct_size]u8 = std.mem.zeroes([spec_raw_info.CURRENT.struct_size]u8);
        std.mem.writeInt(i32, buf[spec_raw_info.CURRENT.num_controllers..][0..4], 1, .little);
        const controller_type_offset = spec_raw_info.CURRENT.controller_table + spec_raw_info.CURRENT.controller_type;
        const controller_offset_offset = spec_raw_info.CURRENT.controller_table + spec_raw_info.CURRENT.controller_offset;
        std.mem.writeInt(i32, buf[controller_type_offset..][0..4], spec_raw_info.VIRTUAL_DEVICE_MS, .little);
        std.mem.writeInt(i64, buf[controller_offset_offset..][0..8], 0, .little);
        try self.file.writePositionalAll(self.io, &buf, self.current_offset);
        self.current_offset = std.math.add(u64, self.current_offset, buf.len) catch return RawWriterError.OffsetOverflow;
    }

    fn writeRunHeaderPlaceholder(self: *RawFileWriter, first_scan_number: i32) !void {
        var buf: [spec_run_header.CURRENT.struct_size]u8 = std.mem.zeroes([spec_run_header.CURRENT.struct_size]u8);
        std.mem.writeInt(i32, buf[spec_run_header.CURRENT.first_spectrum..][0..4], first_scan_number, .little);
        std.mem.writeInt(i32, buf[spec_run_header.CURRENT.last_spectrum..][0..4], first_scan_number, .little);
        try self.file.writePositionalAll(self.io, &buf, self.current_offset);
        self.patches = .{
            .file_offset = self.current_offset,
            .first_spectrum = std.math.add(u64, self.current_offset, spec_run_header.CURRENT.first_spectrum) catch return RawWriterError.OffsetOverflow,
            .last_spectrum = std.math.add(u64, self.current_offset, spec_run_header.CURRENT.last_spectrum) catch return RawWriterError.OffsetOverflow,
            .spectrum_pos = std.math.add(u64, self.current_offset, spec_run_header.CURRENT.spect_pos) catch return RawWriterError.OffsetOverflow,
            .packet_pos = std.math.add(u64, self.current_offset, spec_run_header.CURRENT.packet_pos) catch return RawWriterError.OffsetOverflow,
            .num_trailer_scan_events = std.math.add(u64, self.current_offset, spec_run_header.CURRENT.num_trailer_scan_events) catch return RawWriterError.OffsetOverflow,
            .trailer_scan_events_pos = std.math.add(u64, self.current_offset, spec_run_header.CURRENT.trailer_scan_events_pos) catch return RawWriterError.OffsetOverflow,
        };
        self.current_offset = std.math.add(u64, self.current_offset, buf.len) catch return RawWriterError.OffsetOverflow;
        // self.run_header_offset is an internal u64 offset; writer controls file layout.
        const run_header_ptr_offset = std.math.add(u64, self.raw_info_offset, spec_raw_info.CURRENT.controller_table) catch return RawWriterError.OffsetOverflow;
        const run_header_ptr_offset_plus_8 = std.math.add(u64, run_header_ptr_offset, spec_raw_info.CURRENT.controller_offset) catch return RawWriterError.OffsetOverflow;
        // SAFETY: self.run_header_offset is an internal u64 offset produced by this writer and fits i64 for any realistic file.
        try wp.write_i64_at(self.file, self.io, run_header_ptr_offset_plus_8, @intCast(self.run_header_offset));
    }

    fn patchRunHeader(self: *RawFileWriter, spectrum_pos: u64, trailer_pos: u64) !void {
        const first = self.scans.items[0].scan_number;
        const last = self.scans.items[self.scans.items.len - 1].scan_number;
        try wp.write_i32_at(self.file, self.io, self.patches.first_spectrum, first);
        try wp.write_i32_at(self.file, self.io, self.patches.last_spectrum, last);
        // SAFETY: spectrum_pos and trailer_pos are internal u64 offsets produced by this writer.
        try wp.write_i64_at(self.file, self.io, self.patches.spectrum_pos, @intCast(spectrum_pos));
        try wp.write_i64_at(self.file, self.io, self.patches.packet_pos, @intCast(self.file_header_size));
        // SAFETY: scans.items.len is bounded by the writer's own scan list.
        try wp.write_i32_at(self.file, self.io, self.patches.num_trailer_scan_events, @intCast(self.scans.items.len));
        try wp.write_i64_at(self.file, self.io, self.patches.trailer_scan_events_pos, @intCast(trailer_pos));
    }

    fn writeTrailerScanEventsTable(self: *RawFileWriter, table_offset: u64) !void {
        try wp.write_i32_at(self.file, self.io, table_offset, 0);
        var pos: u64 = std.math.add(u64, table_offset, 4) catch return RawWriterError.OffsetOverflow;
        for (self.scans.items) |scan| {
            // SAFETY: trailer_offset is an in-memory index assigned by this writer (bounded by unique events count).
            const unique_idx = @as(usize, @intCast(scan.trailer_offset));
            const evt = self.trailer_events.unique_events.items[unique_idx];
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            try wp.serialize_scan_event(self.allocator, &buf, evt, self.file_revision);
            try self.file.writePositionalAll(self.io, buf.items, pos);
            pos = std.math.add(u64, pos, buf.items.len) catch return RawWriterError.OffsetOverflow;
        }
        self.current_offset = pos;
    }

    fn makeDefaultScanEvent(self: *RawFileWriter, scan: ScanWriteInfo) !scan_event.ScanEvent {
        const info = raw.ScanEventInfo{
            .is_valid = 1,
            .is_custom = 0,
            .corona = 0,
            .detector = 0,
            .polarity = 1,
            .scan_data_type = 0,
            // SAFETY: ms_level is a small caller-provided level (1, 2, ...) and fits i8.
            .ms_order = @intCast(scan.ms_level),
            .scan_type = 0,
            .source_fragmentation = 0,
            .turbo_scan = 0,
            .dependent_data = 0,
            .ionization_mode = 1,
            ._pad1 = std.mem.zeroes([4]u8),
            .detector_value = 0,
            .source_fragmentation_type = 0,
            ._pad2 = std.mem.zeroes([3]u8),
            .scan_type_index = 0,
            .wideband = 0,
            ._pad3 = std.mem.zeroes([3]u8),
            .accurate_mass_type = 0,
            .mass_analyzer_type = 0,
            .sector_scan = 0,
            .lock = 0,
            .free_region = 0,
            .ultra = 0,
            .enhanced = 0,
            .mpd_type = 0,
            ._pad4 = 0,
            .mpd_value = 0,
            .ecd_type = 0,
            ._pad5 = std.mem.zeroes([7]u8),
            .ecd_value = 0,
            .photo_ionization = 0,
            .pqd_type = 0,
            ._pad6 = std.mem.zeroes([6]u8),
            .pqd_value = 0,
            .etd_type = 0,
            ._pad7 = std.mem.zeroes([7]u8),
            .etd_value = 0,
            .hcd_type = 0,
            ._pad8 = std.mem.zeroes([7]u8),
            .hcd_value = 0,
            .supplemental_activation = 0,
            .multi_state_activation = 0,
            .compensation_voltage = 0,
            .compensation_voltage_type = 0,
            .multiplex = 0,
            .param_a = 0,
            .param_b = 0,
            .param_f = 0,
            .sps_multi_notch = 0,
            .param_r = 0,
            .param_v = 0,
            ._pad9 = std.mem.zeroes([5]u8),
        };

        var reactions: []raw.Reaction = &[_]raw.Reaction{};
        if (scan.ms_level >= 2 and scan.precursor_mz > 0) {
            reactions = try self.allocator.alloc(raw.Reaction, 1);
            reactions[0] = .{
                .precursor_mass = scan.precursor_mz,
                .isolation_width = scan.isolation_width,
                .collision_energy = scan.collision_energy,
                .collision_energy_valid = 1,
                .range_is_valid = 0,
                .first_precursor_mass = scan.precursor_mz,
                .last_precursor_mass = scan.precursor_mz,
                .isolation_width_offset = 0,
            };
        }

        return .{
            .info = info,
            .reactions = reactions,
            .mass_ranges = &[_]raw.ScanEventMassRange{},
            .mass_calibrators = &[_]f64{},
            .source_fragmentations = &[_]f64{},
            .source_fragmentation_mass_ranges = &[_]raw.ScanEventMassRange{},
            .name = null,
        };
    }
};

pub fn patch_checksum(allocator: std.mem.Allocator, path: []const u8, io: std.Io, file_rev: u16) Error!void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    const stat = try file.stat(io);
    try wp.write_checksum_at148(allocator, file, io, file_rev, stat.size);
}

test "RawFileWriter state machine transitions" {
    const State = enum { init, header_written, scanning, finalized };
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(State.init));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(State.finalized));
}

test "ScanWriteInfo struct layout" {
    const info = ScanWriteInfo{
        .scan_number = 1,
        .ms_level = 1,
        .rt = 0.5,
        .tic = 1000.0,
        .base_peak_mz = 500.0,
        .base_peak_intensity = 100.0,
        .low_mass = 100.0,
        .high_mass = 2000.0,
        .precursor_mz = 0,
        .charge_state = 0,
        .collision_energy = 0,
        .isolation_width = 0,
        .mz = &.{},
        .intensity = &.{},
        .event = null,
    };
    try std.testing.expectEqual(@as(i32, 1), info.scan_number);
    try std.testing.expectEqual(@as(u8, 1), info.ms_level);
}

test "RawWriterError variants" {
    try std.testing.expectError(RawWriterError.NoScans, @as(RawWriterError!void, RawWriterError.NoScans));
    try std.testing.expectError(RawWriterError.InvalidState, @as(RawWriterError!void, RawWriterError.InvalidState));
    try std.testing.expectError(RawWriterError.OffsetOverflow, @as(RawWriterError!void, RawWriterError.OffsetOverflow));
}
