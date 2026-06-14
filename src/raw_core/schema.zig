/// Schema detection for .raw files.
///
/// Per ADR-0002, the fast-path passthrough validates the file against a
/// known schema by inspecting the first 10-20 scans. If the layout matches
/// a known schema (file revision, scan index size, packet header layout),
/// bulk-copy passthrough is safe. Otherwise, fall back to the generic
/// decode+encode slow path.
const std = @import("std");
const raw_mod = @import("raw_file");
const advanced = @import("advanced_packet");

/// Captures the layout of a known-schema .raw file.
/// When a file matches this schema, the fast-path passthrough is safe.
pub const FileSchema = struct {
    file_revision: u16,
    scan_index_size: u64,
    packet_pos: u64,
    /// End of the packet region. For rev 65/66 this is the start of the
    /// trailer scan events table (if present) or the end of the file.
    packet_region_end: u64,
    num_scans: usize,
};

pub const SchemaError = error{
    Truncated,
    OffsetOverflow,
    InvalidScanIndex,
    InvalidPacketHeader,
    UnsupportedFileRevision,
};

/// Number of scans to validate during schema detection.
const VALIDATION_SCAN_COUNT: usize = 20;

/// Validate a .raw file's layout against a known schema. Inspects the
/// first 10-20 scans to confirm the scan index and packet headers parse
/// cleanly. Returns null if the file does not match a known schema.
///
/// Caller must ensure `mm` is a valid mmap of the entire .raw file and
/// that `scan_table_start`, `scan_table_size`, `packet_pos`, and
/// `num_scans` were extracted from the RunHeader (e.g. via RawFile.open).
pub fn detect_schema(
    mm: []const u8,
    file_revision: u16,
    scan_table_start: u64,
    scan_table_size: u64,
    scan_index_size: u64,
    packet_pos: u64,
    num_scans: usize,
    trailer_pos: u64, // 0 = no trailer
) SchemaError!?FileSchema {
    // Only rev 65 and 66 are known schemas.
    if (file_revision < 65 or file_revision > 66) return null;

    // Sanity checks on layout.
    const scan_table_end = std.math.add(u64, scan_table_start, scan_table_size) catch return error.OffsetOverflow;
    if (scan_table_end > mm.len) return error.Truncated;
    const packet_header_end = std.math.add(u64, packet_pos, 32) catch return error.OffsetOverflow;
    if (packet_header_end > mm.len) return error.Truncated;

    // Packet region end: trailer events table if present, else end of file.
    // The packet region can be anywhere relative to the scan table — only the
    // data_offset values (relative to packet_pos) determine where each scan's
    // packet lives.
    const packet_region_end: u64 = if (trailer_pos > packet_pos) trailer_pos else mm.len;
    if (packet_region_end > mm.len) return error.Truncated;

    // Validate the first 10-20 scans: scan index entry parses AND packet header at
    // (packet_pos + data_offset) parses cleanly.
    const scan_count_to_check = @min(VALIDATION_SCAN_COUNT, num_scans);
    for (0..scan_count_to_check) |i| {
        const entry_offset = std.math.add(u64, scan_table_start, std.math.mul(u64, @as(u64, i), scan_index_size) catch return error.OffsetOverflow) catch return error.OffsetOverflow;
        // Parse scan index entry
        const entry = raw_mod.parse_scan_index(mm, entry_offset, file_revision) catch {
            return null;
        };
        // Parse packet header at this scan's actual packet offset
        const pkt_offset = std.math.add(u64, packet_pos, entry.data_offset) catch return error.OffsetOverflow;
        const pkt_header_end = std.math.add(u64, pkt_offset, 32) catch return error.OffsetOverflow;
        if (pkt_header_end > mm.len) return null;
        _ = advanced.read_header(mm, pkt_offset) catch {
            return null;
        };
        // Mixed profile+centroid packets are valid for advanced LT/FT detectors
        // (see AdvancedPacketBase summary in the Thermo reference). The fast path
        // copies profile packets verbatim, so embedded centroid data is preserved.
    }

    return FileSchema{
        .file_revision = file_revision,
        .scan_index_size = scan_index_size,
        .packet_pos = packet_pos,
        .packet_region_end = packet_region_end,
        .num_scans = num_scans,
    };
}

test "detectSchema returns Truncated for empty input" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(error.Truncated, detect_schema(
        empty,
        66,
        0,
        0,
        88,
        0,
        0,
        0,
    ));
}

test "detectSchema returns null for unsupported file revision" {
    const empty: []const u8 = &[_]u8{};
    if (detect_schema(empty, 64, 0, 0, 80, 0, 0, 0)) |detected| {
        try std.testing.expect(detected == null);
    } else |_| {}
}

test "detectSchema returns OffsetOverflow for extreme scan table size" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(error.OffsetOverflow, detect_schema(
        empty,
        66,
        std.math.maxInt(u64),
        1,
        88,
        0,
        1,
        0,
    ));
}

test "detectSchema returns null when scan index parse fails" {
    // Buffer with 2 scans: first scan is valid, second scan's data_offset
    // points past the buffer so packet header check fails.
    var buf: [2000]u8 = undefined;
    @memset(&buf, 0);
    // File revision at offset 36
    std.mem.writeInt(u16, buf[36..][0..2], 66, .little);
    // Scan table at 1356: two entries
    const scan_table_start: u64 = 1356;
    // First scan: data_offset = 0 (valid, packet at 148)
    std.mem.writeInt(i64, buf[scan_table_start + 72 ..][0..8], 0, .little);
    // Second scan: data_offset = 2000 (invalid, packet past buffer)
    std.mem.writeInt(i64, buf[scan_table_start + 88 + 72 ..][0..8], 2000, .little);
    // Valid packet header at packet_pos (148)
    const packet_pos: u64 = 148;
    std.mem.writeInt(u32, buf[packet_pos..][0..4], 1, .little); // num_segments
    std.mem.writeInt(u32, buf[packet_pos + 8 ..][0..4], 4, .little); // num_centroid_words
    std.mem.writeInt(u32, buf[packet_pos + 12 ..][0..4], 0x40, .little); // default_feature_word
    const result = try detect_schema(&buf, 66, scan_table_start, 176, 88, packet_pos, 2, 0);
    try std.testing.expect(result == null);
}

test "detectSchema accepts rev 66 with clean layout" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0);
    // File revision at offset 36
    std.mem.writeInt(u16, buf[36..][0..2], 66, .little);
    // Scan table at 1356: one entry with data_offset = 0, data_size = 100
    const scan_table_start: u64 = 1356;
    std.mem.writeInt(u32, buf[scan_table_start..][0..4], 100, .little); // data_size
    std.mem.writeInt(i64, buf[scan_table_start + 80 ..][0..8], 0, .little); // data_offset
    // Packet header at packet_pos (148): valid single-segment centroid header
    const packet_pos: u64 = 148;
    std.mem.writeInt(u32, buf[packet_pos..][0..4], 1, .little); // num_segments
    std.mem.writeInt(u32, buf[packet_pos + 8 ..][0..4], 4, .little); // num_centroid_words
    std.mem.writeInt(u32, buf[packet_pos + 12 ..][0..4], 0x40, .little); // default_feature_word

    const result = try detect_schema(&buf, 66, scan_table_start, 88, 88, packet_pos, 1, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 66), result.?.file_revision);
    try std.testing.expectEqual(@as(u64, 88), result.?.scan_index_size);
}

test "detectSchema accepts profile packet with embedded centroids" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0);
    // File revision at offset 36
    std.mem.writeInt(u16, buf[36..][0..2], 66, .little);
    // Scan table at 1356: one entry with data_offset = 0, data_size = 100
    const scan_table_start: u64 = 1356;
    std.mem.writeInt(u32, buf[scan_table_start..][0..4], 100, .little); // data_size
    std.mem.writeInt(i64, buf[scan_table_start + 80 ..][0..8], 0, .little); // data_offset
    // Packet header at packet_pos (148): profile packet WITH embedded centroids.
    // Advanced LT/FT detectors may store both; fast path copies profile verbatim.
    const packet_pos: u64 = 148;
    std.mem.writeInt(u32, buf[packet_pos..][0..4], 1, .little); // num_segments
    std.mem.writeInt(u32, buf[packet_pos + 4 ..][0..4], 100, .little); // num_profile_words > 0
    std.mem.writeInt(u32, buf[packet_pos + 8 ..][0..4], 4, .little); // num_centroid_words > 0
    std.mem.writeInt(u32, buf[packet_pos + 12 ..][0..4], 0x40, .little); // default_feature_word

    const result = try detect_schema(&buf, 66, scan_table_start, 88, 88, packet_pos, 1, 0);
    try std.testing.expect(result != null); // Should be accepted
}
