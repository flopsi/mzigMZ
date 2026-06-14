/// Trailer Extra table parser for Thermo RAW files.
///
/// Trailer Extra is a separate generic-data table from TrailerScanEvents.
/// It stores per-scan fields such as "Master Scan Number:" and "Monoisotopic M/Z:".
/// The table has two parts:
///   1. Data descriptors (after the scan-event segments, before the scan indices).
///   2. Fixed-size per-scan records at RunHeader.TrailerExtraPos.
const std = @import("std");
const raw = @import("raw_file");
const scan_event = @import("scan_event");
const unicode = @import("unicode_utils");

pub const TrailerExtraError = raw.RawResolveError || error{OutOfMemory};

/// One field descriptor in the Trailer Extra table.
pub const DataDescriptor = struct {
    label: []u8, // allocator-owned UTF-8
    data_type: i32,
    field_offset: u32,
    size: u32,
};

/// Parsed Trailer Extra metadata and record layout.
pub const TrailerExtra = struct {
    descriptors: []DataDescriptor,
    data_offset: u64,
    record_size: u32,
    num_records: u32,

    pub fn deinit(self: *TrailerExtra, allocator: std.mem.Allocator) void {
        for (self.descriptors) |*d| {
            allocator.free(d.label);
        }
        allocator.free(self.descriptors);
    }

    /// Look up a descriptor by label (case-sensitive, including optional trailing colon).
    fn findDescriptor(self: TrailerExtra, label: []const u8) ?*const DataDescriptor {
        for (self.descriptors) |*d| {
            if (std.mem.eql(u8, d.label, label)) return d;
            // Also match the colon-less form if the file omits it.
            if (std.mem.endsWith(u8, d.label, ":")) {
                if (std.mem.eql(u8, d.label[0 .. d.label.len - 1], label)) return d;
            }
        }
        return null;
    }

    /// Read an i32 (Long) field for the given scan index and label.
    pub fn get_i32(self: TrailerExtra, mm: []const u8, scan_index: usize, label: []const u8) ?i32 {
        const desc = self.findDescriptor(label) orelse return null;
        if (desc.data_type != 8) return null; // DataTypes.Long
        if (scan_index >= self.num_records) return null;
        const record_offset = self.data_offset + scan_index * self.record_size + desc.field_offset;
        if (record_offset + desc.size > mm.len) return null;
        const off = std.math.cast(usize, record_offset) orelse return null;
        return std.mem.readInt(i32, mm[off..][0..4], .little);
    }

    /// Read an f64 (Double) field for the given scan index and label.
    pub fn get_f64(self: TrailerExtra, mm: []const u8, scan_index: usize, label: []const u8) ?f64 {
        const desc = self.findDescriptor(label) orelse return null;
        if (desc.data_type != 11) return null; // DataTypes.Double
        if (scan_index >= self.num_records) return null;
        const record_offset = self.data_offset + scan_index * self.record_size + desc.field_offset;
        if (record_offset + desc.size > mm.len) return null;
        const off = std.math.cast(usize, record_offset) orelse return null;
        return @bitCast(std.mem.readInt(u64, mm[off..][0..8], .little));
    }
};

/// Parse the Trailer Extra descriptors and return a lookup structure.
///
/// Parameters:
///   - allocator: memory allocator
///   - mm: memory-mapped file
///   - controller_offset: absolute offset of the MS controller (from RawFile.controller_offset)
///   - trailer_extra_pos: absolute offset of the per-scan records (RunHeader.TrailerExtraPos)
///   - num_trailer_extra: number of per-scan records (RunHeader.NumTrailerExtra)
///   - file_revision: RAW file revision
pub fn parse_trailer_extra(
    allocator: std.mem.Allocator,
    mm: std.Io.File.MemoryMap,
    controller_offset: u64,
    trailer_extra_pos: u64,
    num_trailer_extra: u32,
    file_revision: u16,
) TrailerExtraError!TrailerExtra {
    if (trailer_extra_pos == 0 or num_trailer_extra == 0) {
        return TrailerExtra{
            .descriptors = &.{},
            .data_offset = trailer_extra_pos,
            .record_size = 0,
            .num_records = 0,
        };
    }

    // The descriptors live after the RunHeader + InstrumentId block + scan-event segments.
    const descriptor_offset = try findDescriptorOffset(mm.memory, controller_offset, file_revision);

    var pos: usize = std.math.cast(usize, descriptor_offset) orelse return raw.RawResolveError.OffsetOverflow;

    if (pos + 4 > mm.memory.len) return raw.RawResolveError.Truncated;
    const num_descriptors = std.mem.readInt(i32, mm.memory[pos..][0..4], .little);
    pos += 4;
    if (num_descriptors < 0 or num_descriptors > 1000) return raw.RawResolveError.InvalidRawFileInfo;
    const n: usize = std.math.cast(usize, num_descriptors) orelse return raw.RawResolveError.InvalidRawFileInfo;

    var descriptors = try allocator.alloc(DataDescriptor, n);
    errdefer {
        for (descriptors) |*d| allocator.free(d.label);
        allocator.free(descriptors);
    }

    var record_size: u32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (pos + 8 > mm.memory.len) return raw.RawResolveError.Truncated;
        const data_type = std.mem.readInt(i32, mm.memory[pos..][0..4], .little);
        const length_or_precision = std.mem.readInt(u32, mm.memory[pos + 4 ..][0..4], .little);
        pos += 8;

        const label = try readWideStringAlloc(allocator, mm.memory, &pos);
        errdefer allocator.free(label);

        const size = dataTypeSize(data_type, length_or_precision);
        descriptors[i] = .{
            .label = label,
            .data_type = data_type,
            .field_offset = record_size,
            .size = size,
        };
        record_size += size;
    }

    return TrailerExtra{
        .descriptors = descriptors,
        .data_offset = trailer_extra_pos,
        .record_size = record_size,
        .num_records = num_trailer_extra,
    };
}

/// Locate the offset of the Trailer Extra data descriptors by skipping the
/// instrument-id block, status/error logs, and the scan-event segments that precede it.
fn findDescriptorOffset(mm: []const u8, controller_offset: u64, file_revision: u16) raw.RawResolveError!u64 {
    var pos: u64 = controller_offset + raw.RUN_HEADER_STRUCT_SIZE;

    // Skip InstIdInfoStruct (IsValid + AbsorbanceUnit).
    if (pos + 8 > mm.len) return raw.RawResolveError.Truncated;
    pos += 8;

    // Skip channel labels.
    if (pos + 4 > mm.len) return raw.RawResolveError.Truncated;
    const pos_usz = std.math.cast(usize, pos) orelse return raw.RawResolveError.OffsetOverflow;
    const channel_count = std.mem.readInt(i32, mm[pos_usz..][0..4], .little);
    pos += 4;
    if (channel_count < 0 or channel_count > 256) return raw.RawResolveError.InvalidStringLength;
    var n: i32 = 0;
    while (n < channel_count) : (n += 1) {
        try skipWideString(mm, &pos);
    }

    // Skip Name, Model, SerialNumber, SoftwareVersion, HardwareVersion.
    try skipWideString(mm, &pos);
    try skipWideString(mm, &pos);
    try skipWideString(mm, &pos);
    try skipWideString(mm, &pos);
    try skipWideString(mm, &pos);

    // Skip Flags (rev >= 32).
    if (file_revision >= 32) {
        try skipWideString(mm, &pos);
    }

    // Skip AxisLabelX and AxisLabelY (rev >= 37).
    if (file_revision >= 37) {
        try skipWideString(mm, &pos);
        try skipWideString(mm, &pos);
    }

    // Skip StatusLog (descriptors + fixed-size records).
    const num_status_log = raw.readI32Mm(mm, controller_offset + raw.RUN_HEADER_NUM_STATUS_LOG) catch 0;
    const status_log_record_size = try skipGenericLogDescriptors(mm, &pos);
    if (num_status_log > 0) {
        const num_status_log_u64 = std.math.cast(u64, num_status_log) orelse return raw.RawResolveError.InvalidRawFileInfo;
        const records_bytes = std.math.mul(u64, num_status_log_u64, 4 + status_log_record_size) catch return raw.RawResolveError.OffsetOverflow;
        if (pos + records_bytes > mm.len) return raw.RawResolveError.Truncated;
        pos += records_bytes;
    }

    // Skip ErrorLog.
    const num_error_log = raw.readI32Mm(mm, controller_offset + raw.RUN_HEADER_NUM_ERROR_LOG) catch 0;
    if (pos + 4 > mm.len) return raw.RawResolveError.Truncated;
    pos += 4; // ignored leading count
    if (num_error_log > 0) {
        var e: i32 = 0;
        while (e < num_error_log) : (e += 1) {
            if (pos + 4 > mm.len) return raw.RawResolveError.Truncated;
            pos += 4; // float retention time
            try skipWideString(mm, &pos);
        }
    }

    // Now at the scan-event segments. Skip them to reach the descriptors.
    if (pos + 4 > mm.len) return raw.RawResolveError.Truncated;
    const segments_pos_usz = std.math.cast(usize, pos) orelse return raw.RawResolveError.OffsetOverflow;
    const num_segments = std.mem.readInt(i32, mm[segments_pos_usz..][0..4], .little);
    pos += 4;
    if (num_segments < 0 or num_segments > 1000) return raw.RawResolveError.InvalidRawFileInfo;

    var seg_i: i32 = 0;
    while (seg_i < num_segments) : (seg_i += 1) {
        if (pos + 4 > mm.len) return raw.RawResolveError.Truncated;
        const events_pos_usz = std.math.cast(usize, pos) orelse return raw.RawResolveError.OffsetOverflow;
        const num_events = std.mem.readInt(i32, mm[events_pos_usz..][0..4], .little);
        pos += 4;
        if (num_events < 0 or num_events > 100000) return raw.RawResolveError.InvalidRawFileInfo;

        var evt_i: i32 = 0;
        while (evt_i < num_events) : (evt_i += 1) {
            const skipped = try scan_event.skip_scan_event(mm, pos, file_revision);
            pos = std.math.add(u64, pos, skipped) catch return raw.RawResolveError.OffsetOverflow;
        }
    }

    return pos;
}

/// Skip a generic descriptor table (StatusLog / ErrorLog / TrailerExtra header).
/// Returns the total data size implied by the descriptors (sum of item sizes).
fn skipGenericLogDescriptors(mm: []const u8, pos: *u64) raw.RawResolveError!u64 {
    if (pos.* + 4 > mm.len) return raw.RawResolveError.Truncated;
    const descriptors_pos_usz = std.math.cast(usize, pos.*) orelse return raw.RawResolveError.OffsetOverflow;
    const num_descriptors = std.mem.readInt(i32, mm[descriptors_pos_usz..][0..4], .little);
    pos.* += 4;
    if (num_descriptors < 0 or num_descriptors > 1000) return raw.RawResolveError.InvalidRawFileInfo;
    var total_data_size: u64 = 0;
    var i: i32 = 0;
    while (i < num_descriptors) : (i += 1) {
        if (pos.* + 8 > mm.len) return raw.RawResolveError.Truncated;
        const item_pos_usz = std.math.cast(usize, pos.*) orelse return raw.RawResolveError.OffsetOverflow;
        const data_type = std.mem.readInt(i32, mm[item_pos_usz..][0..4], .little);
        const length_or_precision = std.mem.readInt(u32, mm[item_pos_usz + 4 ..][0..4], .little);
        pos.* += 8;
        try skipWideString(mm, pos);
        const size = dataTypeSize(data_type, length_or_precision);
        total_data_size = std.math.add(u64, total_data_size, size) catch return raw.RawResolveError.OffsetOverflow;
    }
    return total_data_size;
}

/// Read a length-prefixed UTF-16LE string and convert it to an allocator-owned UTF-8 slice.
fn readWideStringAlloc(allocator: std.mem.Allocator, mm: []const u8, pos: *usize) (raw.RawResolveError || error{OutOfMemory})![]u8 {
    if (pos.* + 4 > mm.len) return raw.RawResolveError.Truncated;
    const len = std.mem.readInt(i32, mm[pos.*..][0..4], .little);
    pos.* += 4;
    if (len < 0 or len > raw.MAX_STRING_CHARS) return raw.RawResolveError.InvalidStringLength;
    const n: usize = std.math.cast(usize, len) orelse return raw.RawResolveError.InvalidStringLength;
    if (n == 0) return allocator.dupe(u8, "");
    if (pos.* + n * 2 > mm.len) return raw.RawResolveError.Truncated;
    const wide_slice = mm[pos.* .. pos.* + n * 2];
    pos.* += n * 2;
    return unicode.utf16_le_to_utf8_alloc(allocator, wide_slice, n) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return raw.RawResolveError.InvalidStringLength,
    };
}

/// Skip a length-prefixed UTF-16LE string without allocating.
fn skipWideString(mm: []const u8, pos: *u64) raw.RawResolveError!void {
    if (pos.* + 4 > mm.len) return raw.RawResolveError.Truncated;
    const skip_pos_usz = std.math.cast(usize, pos.*) orelse return raw.RawResolveError.OffsetOverflow;
    const len = std.mem.readInt(i32, mm[skip_pos_usz..][0..4], .little);
    pos.* += 4;
    if (len < 0 or len > raw.MAX_STRING_CHARS) return raw.RawResolveError.InvalidStringLength;
    const len_u64 = std.math.cast(u64, len) orelse return raw.RawResolveError.InvalidStringLength;
    const bytes = std.math.mul(u64, len_u64, 2) catch return raw.RawResolveError.OffsetOverflow;
    pos.* = std.math.add(u64, pos.*, bytes) catch return raw.RawResolveError.OffsetOverflow;
}

/// Size in bytes of one value of a Thermo DataTypes enum value.
fn dataTypeSize(data_type: i32, length_or_precision: u32) u32 {
    return switch (data_type) {
        1...5 => 1, // Char, TrueFalse, YesNo, OnOff, UnsignedChar
        6, 7 => 2, // Short, UnsignedShort
        8, 9 => 4, // Long, UnsignedLong
        10 => 4, // Float
        11 => 8, // Double
        12 => length_or_precision, // CharString
        13 => length_or_precision * 2, // WideCharString
        else => 0,
    };
}
