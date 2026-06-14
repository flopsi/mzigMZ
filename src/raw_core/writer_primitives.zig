/// Binary write primitives for Thermo RAW files.
const std = @import("std");
const raw = @import("raw_file");
const checksum = @import("checksum");
const scan_event = @import("scan_event");
const spec_scan_index = @import("spec/scan_index");
const spec_scan_event_info = @import("spec/scan_event_info");
const spec_reaction = @import("spec/reaction");

pub const WritePrimitiveError = std.Io.File.WritePositionalError || std.mem.Allocator.Error || error{ InvalidUtf8, OffsetOverflow } || checksum.ChecksumError;

pub fn write_u16_at(file: std.Io.File, io: std.Io, offset: u64, value: u16) WritePrimitiveError!void {
    const b = [2]u8{ @truncate(value), @truncate(value >> 8) };
    try pwrite_exact(file, io, &b, offset);
}

pub fn write_u32_at(file: std.Io.File, io: std.Io, offset: u64, value: u32) WritePrimitiveError!void {
    const b = [4]u8{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
    try pwrite_exact(file, io, &b, offset);
}

pub fn write_i32_at(file: std.Io.File, io: std.Io, offset: u64, value: i32) WritePrimitiveError!void {
    try write_u32_at(file, io, offset, @bitCast(value));
}

pub fn write_u64_at(file: std.Io.File, io: std.Io, offset: u64, value: u64) WritePrimitiveError!void {
    const b = [8]u8{
        @truncate(value),       @truncate(value >> 8),  @truncate(value >> 16), @truncate(value >> 24),
        @truncate(value >> 32), @truncate(value >> 40), @truncate(value >> 48), @truncate(value >> 56),
    };
    try pwrite_exact(file, io, &b, offset);
}

pub fn write_i64_at(file: std.Io.File, io: std.Io, offset: u64, value: i64) WritePrimitiveError!void {
    try write_u64_at(file, io, offset, @bitCast(value));
}

pub fn write_f32_at(file: std.Io.File, io: std.Io, offset: u64, value: f32) WritePrimitiveError!void {
    try write_u32_at(file, io, offset, @bitCast(value));
}

pub fn write_f64_at(file: std.Io.File, io: std.Io, offset: u64, value: f64) WritePrimitiveError!void {
    try write_u64_at(file, io, offset, @bitCast(value));
}

pub fn pwrite_exact(file: std.Io.File, io: std.Io, buf: []const u8, offset: u64) WritePrimitiveError!void {
    try file.writePositionalAll(io, buf, offset);
}

pub fn write_wide_string_at(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, offset: u64, utf8: []const u8) WritePrimitiveError!u64 {
    const wide_string_data_offset: u32 = 4;
    if (utf8.len == 0) {
        try write_i32_at(file, io, offset, 0);
        return wide_string_data_offset;
    }
    const wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, utf8);
    defer allocator.free(wide);
    // SAFETY: wide.len is bounded by the caller-provided utf8 string length; callers pass short labels.
    try write_i32_at(file, io, offset, @intCast(wide.len));
    const wide_bytes = std.mem.sliceAsBytes(wide);
    try pwrite_exact(file, io, wide_bytes, offset + wide_string_data_offset);
    return wide_string_data_offset + wide_bytes.len;
}

pub fn write_scan_index_entry(file: std.Io.File, io: std.Io, offset: u64, entry: raw.ScanIndexEntry, file_revision: u16) WritePrimitiveError!void {
    const layout = spec_scan_index.get_layout(file_revision);
    if (layout.data_size != 0) try write_u32_at(file, io, offset + layout.data_size, entry.data_size);
    try write_i32_at(file, io, offset + layout.trailer_offset, entry.trailer_offset);
    try write_i32_at(file, io, offset + layout.scan_type_index, entry.scan_type_index);
    try write_i32_at(file, io, offset + layout.scan_number, entry.scan_number);
    try write_u32_at(file, io, offset + layout.packet_type, entry.packet_type);
    try write_i32_at(file, io, offset + layout.number_packets, entry.number_packets);
    const data_offset_i64 = std.math.cast(i64, entry.data_offset) orelse return WritePrimitiveError.OffsetOverflow;
    try write_i64_at(file, io, offset + layout.data_offset, data_offset_i64);
    if (layout.start_time != 0) try write_f64_at(file, io, offset + layout.start_time, entry.start_time);
    if (layout.tic != 0) try write_f64_at(file, io, offset + layout.tic, entry.tic);
    if (layout.base_peak_intensity != 0) try write_f64_at(file, io, offset + layout.base_peak_intensity, entry.base_peak_intensity);
    if (layout.base_peak_mass != 0) try write_f64_at(file, io, offset + layout.base_peak_mass, entry.base_peak_mass);
    if (layout.low_mass != 0) try write_f64_at(file, io, offset + layout.low_mass, entry.low_mass);
    if (layout.high_mass != 0) try write_f64_at(file, io, offset + layout.high_mass, entry.high_mass);
    if (layout.cycle_number != 0) try write_i32_at(file, io, offset + layout.cycle_number, entry.cycle_number);
}

pub fn write_scan_event_info(file: std.Io.File, io: std.Io, offset: u64, info: raw.ScanEventInfo, file_revision: u16) WritePrimitiveError!void {
    const info_size = raw.scan_event_info_size(file_revision);
    var buf: [136]u8 = std.mem.zeroes([136]u8);
    encode_scan_event_info(buf[0..info_size], info);
    try pwrite_exact(file, io, buf[0..info_size], offset);
}

pub fn write_reaction(file: std.Io.File, io: std.Io, offset: u64, rxn: raw.Reaction) WritePrimitiveError!void {
    try write_f64_at(file, io, offset + spec_reaction.precursor_mass, rxn.precursor_mass);
    try write_f64_at(file, io, offset + spec_reaction.isolation_width, rxn.isolation_width);
    try write_f64_at(file, io, offset + spec_reaction.collision_energy, rxn.collision_energy);
    try write_u32_at(file, io, offset + spec_reaction.collision_energy_valid, rxn.collision_energy_valid);
    try write_u32_at(file, io, offset + spec_reaction.range_is_valid, rxn.range_is_valid);
    try write_f64_at(file, io, offset + spec_reaction.first_precursor_mass, rxn.first_precursor_mass);
    try write_f64_at(file, io, offset + spec_reaction.last_precursor_mass, rxn.last_precursor_mass);
    try write_f64_at(file, io, offset + spec_reaction.isolation_width_offset, rxn.isolation_width_offset);
}

pub fn write_mass_range(file: std.Io.File, io: std.Io, offset: u64, range: raw.ScanEventMassRange) WritePrimitiveError!void {
    const mass_range_low: u32 = 0;
    const mass_range_high: u32 = 8;
    try write_f64_at(file, io, offset + mass_range_low, range.low);
    try write_f64_at(file, io, offset + mass_range_high, range.high);
}

// ============================================================================
// ArrayList-sink variants — same byte layout, append to growable buffer.
// Used by scan_event_writer.zig for trailer serialization.
// ============================================================================

pub fn append_u16(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) WritePrimitiveError!void {
    const b = [2]u8{ @truncate(value), @truncate(value >> 8) };
    try buf.appendSlice(allocator, &b);
}

pub fn append_u32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) WritePrimitiveError!void {
    const b = [4]u8{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
    try buf.appendSlice(allocator, &b);
}

pub fn append_i32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) WritePrimitiveError!void {
    try append_u32(buf, allocator, @bitCast(value));
}

pub fn append_u64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) WritePrimitiveError!void {
    const b = [8]u8{
        @truncate(value),       @truncate(value >> 8),  @truncate(value >> 16), @truncate(value >> 24),
        @truncate(value >> 32), @truncate(value >> 40), @truncate(value >> 48), @truncate(value >> 56),
    };
    try buf.appendSlice(allocator, &b);
}

/// Encode ScanEventInfo into a buffer whose length is the runtime struct size for
/// the target file revision (24–136 bytes). Writes only the fields that fit.
pub fn encode_scan_event_info(buf: []u8, info: raw.ScanEventInfo) void {
    @memset(buf, 0);
    buf[spec_scan_event_info.is_valid] = info.is_valid;
    buf[spec_scan_event_info.is_custom] = info.is_custom;
    buf[spec_scan_event_info.corona] = info.corona;
    buf[spec_scan_event_info.detector] = info.detector;
    buf[spec_scan_event_info.polarity] = info.polarity;
    buf[spec_scan_event_info.scan_data_type] = info.scan_data_type;
    buf[spec_scan_event_info.ms_order] = @bitCast(info.ms_order);
    buf[spec_scan_event_info.scan_type] = info.scan_type;
    buf[spec_scan_event_info.source_fragmentation] = info.source_fragmentation;
    buf[spec_scan_event_info.turbo_scan] = info.turbo_scan;
    buf[spec_scan_event_info.dependent_data] = info.dependent_data;
    buf[spec_scan_event_info.ionization_mode] = info.ionization_mode;
    std.mem.writeInt(u64, buf[spec_scan_event_info.detector_value..][0..8], @bitCast(info.detector_value), .little);

    if (buf.len >= spec_scan_event_info.SIZE_REV31) {
        buf[spec_scan_event_info.source_fragmentation_type] = info.source_fragmentation_type;
        std.mem.writeInt(i32, buf[spec_scan_event_info.scan_type_index..][0..4], info.scan_type_index, .little);
    }
    if (buf.len >= spec_scan_event_info.SIZE_REV48) {
        buf[spec_scan_event_info.wideband] = info.wideband;
        std.mem.writeInt(u32, buf[spec_scan_event_info.accurate_mass_type..][0..4], info.accurate_mass_type, .little);
    }
    if (buf.len >= spec_scan_event_info.SIZE_REV54) {
        buf[spec_scan_event_info.mass_analyzer_type] = info.mass_analyzer_type;
        buf[spec_scan_event_info.sector_scan] = info.sector_scan;
        buf[spec_scan_event_info.lock] = info.lock;
        buf[spec_scan_event_info.free_region] = info.free_region;
        buf[spec_scan_event_info.ultra] = info.ultra;
        buf[spec_scan_event_info.enhanced] = info.enhanced;
        buf[spec_scan_event_info.mpd_type] = info.mpd_type;
        std.mem.writeInt(u64, buf[spec_scan_event_info.mpd_value..][0..8], @bitCast(info.mpd_value), .little);
        buf[spec_scan_event_info.ecd_type] = info.ecd_type;
        std.mem.writeInt(u64, buf[spec_scan_event_info.ecd_value..][0..8], @bitCast(info.ecd_value), .little);
        buf[spec_scan_event_info.photo_ionization] = info.photo_ionization;
        buf[spec_scan_event_info.pqd_type] = info.pqd_type;
    }
    if (buf.len >= spec_scan_event_info.SIZE_REV62) {
        std.mem.writeInt(u64, buf[spec_scan_event_info.pqd_value..][0..8], @bitCast(info.pqd_value), .little);
        buf[spec_scan_event_info.etd_type] = info.etd_type;
        std.mem.writeInt(u64, buf[spec_scan_event_info.etd_value..][0..8], @bitCast(info.etd_value), .little);
        buf[spec_scan_event_info.hcd_type] = info.hcd_type;
        std.mem.writeInt(u64, buf[spec_scan_event_info.hcd_value..][0..8], @bitCast(info.hcd_value), .little);
    }
    if (buf.len >= spec_scan_event_info.SIZE_REV63) {
        buf[spec_scan_event_info.supplemental_activation] = info.supplemental_activation;
        buf[spec_scan_event_info.multi_state_activation] = info.multi_state_activation;
        buf[spec_scan_event_info.compensation_voltage] = info.compensation_voltage;
        buf[spec_scan_event_info.compensation_voltage_type] = info.compensation_voltage_type;
        buf[spec_scan_event_info.multiplex] = info.multiplex;
        buf[spec_scan_event_info.param_a] = info.param_a;
        buf[spec_scan_event_info.param_b] = info.param_b;
        buf[spec_scan_event_info.param_f] = info.param_f;
    }
    if (buf.len >= spec_scan_event_info.SIZE_CURRENT) {
        buf[spec_scan_event_info.sps_multi_notch] = info.sps_multi_notch;
        buf[spec_scan_event_info.param_r] = info.param_r;
        buf[spec_scan_event_info.param_v] = info.param_v;
    }
}

pub fn append_reaction(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, rxn: raw.Reaction) WritePrimitiveError!void {
    try append_u64(buf, allocator, @bitCast(rxn.precursor_mass));
    try append_u64(buf, allocator, @bitCast(rxn.isolation_width));
    try append_u64(buf, allocator, @bitCast(rxn.collision_energy));
    try append_u32(buf, allocator, rxn.collision_energy_valid);
    try append_u32(buf, allocator, rxn.range_is_valid);
    try append_u64(buf, allocator, @bitCast(rxn.first_precursor_mass));
    try append_u64(buf, allocator, @bitCast(rxn.last_precursor_mass));
    try append_u64(buf, allocator, @bitCast(rxn.isolation_width_offset));
}

pub fn append_mass_range(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, range: raw.ScanEventMassRange) WritePrimitiveError!void {
    try append_u64(buf, allocator, @bitCast(range.low));
    try append_u64(buf, allocator, @bitCast(range.high));
}

pub fn append_wide_string(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, utf8: []const u8) WritePrimitiveError!void {
    if (utf8.len == 0) {
        try append_i32(buf, allocator, 0);
        return;
    }
    const wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, utf8);
    defer allocator.free(wide);
    // SAFETY: wide.len is bounded by the caller-provided utf8 string length; callers pass short labels.
    try append_i32(buf, allocator, @intCast(wide.len));
    for (wide) |wc| {
        try append_u16(buf, allocator, wc);
    }
}

/// Encode a ScanIndexEntry into a buffer (for batch write).
/// Uses the runtime layout for the supplied file revision.
pub fn encode_scan_index_entry(buf: []u8, entry: raw.ScanIndexEntry, file_revision: u16) WritePrimitiveError!void {
    const layout = spec_scan_index.get_layout(file_revision);
    if (layout.data_size != 0) std.mem.writeInt(u32, buf[layout.data_size..][0..4], entry.data_size, .little);
    std.mem.writeInt(i32, buf[layout.trailer_offset..][0..4], entry.trailer_offset, .little);
    std.mem.writeInt(i32, buf[layout.scan_type_index..][0..4], entry.scan_type_index, .little);
    std.mem.writeInt(i32, buf[layout.scan_number..][0..4], entry.scan_number, .little);
    std.mem.writeInt(u32, buf[layout.packet_type..][0..4], entry.packet_type, .little);
    std.mem.writeInt(i32, buf[layout.number_packets..][0..4], entry.number_packets, .little);
    const data_offset_i64 = std.math.cast(i64, entry.data_offset) orelse return WritePrimitiveError.OffsetOverflow;
    std.mem.writeInt(i64, buf[layout.data_offset..][0..8], data_offset_i64, .little);
    if (layout.start_time != 0) std.mem.writeInt(u64, buf[layout.start_time..][0..8], @bitCast(entry.start_time), .little);
    if (layout.tic != 0) std.mem.writeInt(u64, buf[layout.tic..][0..8], @bitCast(entry.tic), .little);
    if (layout.base_peak_intensity != 0) std.mem.writeInt(u64, buf[layout.base_peak_intensity..][0..8], @bitCast(entry.base_peak_intensity), .little);
    if (layout.base_peak_mass != 0) std.mem.writeInt(u64, buf[layout.base_peak_mass..][0..8], @bitCast(entry.base_peak_mass), .little);
    if (layout.low_mass != 0) std.mem.writeInt(u64, buf[layout.low_mass..][0..8], @bitCast(entry.low_mass), .little);
    if (layout.high_mass != 0) std.mem.writeInt(u64, buf[layout.high_mass..][0..8], @bitCast(entry.high_mass), .little);
    if (layout.cycle_number != 0) std.mem.writeInt(i32, buf[layout.cycle_number..][0..4], entry.cycle_number, .little);
}

/// Write Adler32 checksum at file offset 148 (standard Thermo position).
/// Used by passthrough and de-novo writer finalization.
pub fn write_checksum_at148(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, file_rev: u16, file_length: u64) WritePrimitiveError!void {
    const cs = try checksum.compute_raw_checksum(allocator, file, io, file_rev, 1356, file_length);
    try write_u32_at(file, io, 148, cs);
}

/// Serialize a complete ScanEvent into an ArrayList (trailer format).
/// Delegates to the append* primitives above.
pub fn serialize_scan_event(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    event: scan_event.ScanEvent,
    file_revision: u16,
) WritePrimitiveError!void {
    const info_size = raw.scan_event_info_size(file_revision);

    const info_start = buf.items.len;
    try buf.appendNTimes(allocator, 0, info_size);
    encode_scan_event_info(buf.items[info_start..][0..info_size], event.info);

    const reaction_size = raw.reaction_size(file_revision);
    // SAFETY: event.reactions.len is an in-memory slice length controlled by callers (program-derived).
    try append_i32(buf, allocator, @intCast(event.reactions.len));
    for (event.reactions) |rxn| {
        try append_u64(buf, allocator, @bitCast(rxn.precursor_mass));
        try append_u64(buf, allocator, @bitCast(rxn.isolation_width));
        try append_u64(buf, allocator, @bitCast(rxn.collision_energy));
        if (reaction_size >= 32) {
            try append_u32(buf, allocator, rxn.collision_energy_valid);
            try append_u32(buf, allocator, rxn.range_is_valid);
        }
        if (reaction_size >= 48) {
            try append_u64(buf, allocator, @bitCast(rxn.first_precursor_mass));
            try append_u64(buf, allocator, @bitCast(rxn.last_precursor_mass));
        }
        if (reaction_size >= 56) {
            try append_u64(buf, allocator, @bitCast(rxn.isolation_width_offset));
        }
    }

    // SAFETY: event.mass_ranges.len is an in-memory slice length controlled by callers (program-derived).
    try append_i32(buf, allocator, @intCast(event.mass_ranges.len));
    for (event.mass_ranges) |range| {
        try append_u64(buf, allocator, @bitCast(range.low));
        try append_u64(buf, allocator, @bitCast(range.high));
    }

    // SAFETY: event.mass_calibrators.len is an in-memory slice length controlled by callers (program-derived).
    try append_i32(buf, allocator, @intCast(event.mass_calibrators.len));
    for (event.mass_calibrators) |cal| {
        try append_u64(buf, allocator, @bitCast(cal));
    }

    // SAFETY: event.source_fragmentations.len is an in-memory slice length controlled by callers (program-derived).
    try append_i32(buf, allocator, @intCast(event.source_fragmentations.len));
    for (event.source_fragmentations) |sf| {
        try append_u64(buf, allocator, @bitCast(sf));
    }

    // SAFETY: event.source_fragmentation_mass_ranges.len is an in-memory slice length controlled by callers (program-derived).
    try append_i32(buf, allocator, @intCast(event.source_fragmentation_mass_ranges.len));
    for (event.source_fragmentation_mass_ranges) |range| {
        try append_u64(buf, allocator, @bitCast(range.low));
        try append_u64(buf, allocator, @bitCast(range.high));
    }

    if (file_revision >= 65) {
        if (event.name) |name| {
            const wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, name);
            defer allocator.free(wide);
            // SAFETY: wide.len is bounded by the caller-provided event name length; names are short labels.
            try append_i32(buf, allocator, @intCast(wide.len));
            for (wide) |wc| {
                try append_u16(buf, allocator, wc);
            }
        } else {
            try append_i32(buf, allocator, 0);
        }
    }
}

/// Compute the serialized size of a ScanEvent in bytes.
pub fn serialized_scan_event_size(event: scan_event.ScanEvent, file_revision: u16) usize {
    var size: usize = raw.scan_event_info_size(file_revision);
    size += 4 + event.reactions.len * raw.reaction_size(file_revision);
    size += 4 + event.mass_ranges.len * 16;
    size += 4 + event.mass_calibrators.len * 8;
    size += 4 + event.source_fragmentations.len * 8;
    size += 4 + event.source_fragmentation_mass_ranges.len * 16;
    if (file_revision >= 65) {
        size += 4;
        if (event.name) |name| {
            size += name.len * 2;
        }
    }
    return size;
}

test "writeU32At byte encoding" {
    const value: u32 = 0xDEADBEEF;
    const b = [4]u8{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
    try std.testing.expectEqual(@as(u8, 0xEF), b[0]);
    try std.testing.expectEqual(@as(u8, 0xBE), b[1]);
    try std.testing.expectEqual(@as(u8, 0xAD), b[2]);
    try std.testing.expectEqual(@as(u8, 0xDE), b[3]);
}

test "writeF64At byte encoding" {
    const value: f64 = 1.0;
    const raw_bits = @as(u64, @bitCast(value));
    const b = [8]u8{
        @truncate(raw_bits),       @truncate(raw_bits >> 8),  @truncate(raw_bits >> 16), @truncate(raw_bits >> 24),
        @truncate(raw_bits >> 32), @truncate(raw_bits >> 40), @truncate(raw_bits >> 48), @truncate(raw_bits >> 56),
    };
    const decoded = std.mem.readInt(u64, &b, .little);
    const decoded_f64: f64 = @bitCast(decoded);
    try std.testing.expectEqual(value, decoded_f64);
}

test "encode_scan_index_entry rejects data_offset that overflows i64" {
    var buf: [88]u8 = undefined;
    @memset(&buf, 0);
    var entry: raw.ScanIndexEntry = std.mem.zeroes(raw.ScanIndexEntry);
    entry.data_offset = std.math.maxInt(i64) + 1;
    try std.testing.expectError(WritePrimitiveError.OffsetOverflow, encode_scan_index_entry(&buf, entry, 66));
}

test "encode_scan_event_info does not write out of bounds for rev 54-61 buffers" {
    // SIZE_REV54 is exactly 80 bytes; pqd_value lives at offset 80 and therefore
    // must only be written for SIZE_REV62 and larger. This test would panic in
    // Debug/ReleaseSafe if the bug were reintroduced.
    var buf: [spec_scan_event_info.SIZE_REV54]u8 = undefined;
    const info = std.mem.zeroes(raw.ScanEventInfo);
    encode_scan_event_info(&buf, info);
}

test "encode_scan_event_info does not write out of bounds for all revision tiers" {
    // Exercise the writer with buffers sized for each of the 8 revision tiers.
    // A panic in Debug/ReleaseSafe indicates an out-of-bounds write.
    const info = std.mem.zeroes(raw.ScanEventInfo);
    const tiers = [_]struct { rev: u16, size: u64 }{
        .{ .rev = 30, .size = spec_scan_event_info.SIZE_LEGACY },
        .{ .rev = 31, .size = spec_scan_event_info.SIZE_REV31 },
        .{ .rev = 48, .size = spec_scan_event_info.SIZE_REV48 },
        .{ .rev = 51, .size = spec_scan_event_info.SIZE_REV51 },
        .{ .rev = 54, .size = spec_scan_event_info.SIZE_REV54 },
        .{ .rev = 62, .size = spec_scan_event_info.SIZE_REV62 },
        .{ .rev = 63, .size = spec_scan_event_info.SIZE_REV63 },
        .{ .rev = 65, .size = spec_scan_event_info.SIZE_CURRENT },
    };
    inline for (tiers) |tier| {
        var buf: [tier.size]u8 = undefined;
        encode_scan_event_info(&buf, info);
        try std.testing.expectEqual(tier.size, raw.scan_event_info_size(tier.rev));
    }
}
