const std = @import("std");

pub const RawResolveError = error{
    Truncated,
    InvalidStringLength,
    InvalidRawFileInfo,
    UnsupportedFileRevision,
    NoMsController,
    InvalidControllerOffset,
    InvalidRunHeader,
    ScanOutOfRange,
    ScanIndexMismatch,
    OffsetOverflow,
};

pub const ScanIndexEntry = struct {
    data_size: u32,
    trailer_offset: i32,
    scan_type_index: i32,
    scan_number: i32,
    packet_type: u32,
    number_packets: i32,
    data_offset: u64,
    // Extended fields for chromatograms (rev >= 65)
    start_time: f64,
    tic: f64,
    base_peak_intensity: f64,
    base_peak_mass: f64,
    low_mass: f64,
    high_mass: f64,
};

pub const ResolvedScan = struct {
    file_revision: u16,
    raw_file_info_offset: u64,
    ms_controller_index: usize,
    controller_offset: u64,
    first_spectrum: i32,
    last_spectrum: i32,
    spectrum_pos: u64,
    packet_pos: u64,
    scan_index_pos: u64,
    scan_index: ScanIndexEntry,
    absolute_packet_offset: u64,
};

pub const FILE_REV_OFFSET: u64 = 36;
pub const FILE_HEADER_SIZE: u64 = 1356;

pub const SEQ_ROW_INFO_SIZE: u64 = 64;
pub const AUTO_SAMPLER_CONFIG_SIZE: u64 = 24;

pub const RAW_INFO_NUM_CONTROLLERS: u64 = 28;
pub const RAW_INFO_CONTROLLER_TABLE_CURRENT: u64 = 816;
pub const RAW_INFO_CONTROLLER_SIZE_CURRENT: u64 = 16;
pub const RAW_INFO_CONTROLLER_TYPE: u64 = 0;
pub const RAW_INFO_CONTROLLER_OFFSET: u64 = 8;

pub const RUN_HEADER_FIRST_SPECTRUM: u64 = 8;
pub const RUN_HEADER_LAST_SPECTRUM: u64 = 12;
pub const RUN_HEADER_SPECT_POS: u64 = 7408;
pub const RUN_HEADER_PACKET_POS: u64 = 7416;
pub const RUN_HEADER_NUM_TRAILER_SCAN_EVENTS: u64 = 7376;
pub const RUN_HEADER_TRAILER_SCAN_EVENTS_POS: u64 = 7448;
/// Size of RunHeaderStruct on disk for file rev >= 64 (C# Marshal.SizeOf).
/// Verified from decompiled ThermoFisher.CommonCore.RawFileReader:
/// RunHeaderStruct5 (rev 64-65) and RunHeaderStruct (rev >= 66) both marshal to 7576 bytes.
pub const RUN_HEADER_STRUCT_SIZE: u64 = 7576;

pub const SCAN_INDEX_SIZE_CURRENT: u64 = 88; // file rev >= 65
pub const SCAN_INDEX_SIZE_REV64: u64 = 80;
pub const SCAN_INDEX_SIZE_LEGACY: u64 = 72;

// ScanEventInfoStruct sizes by file revision (from C# Marshal.SizeOf):
// rev < 50:  ScanEventInfoStruct2  = 24 bytes
// rev 50-53: ScanEventInfoStruct50 = 40 bytes
// rev 54-64: ScanEventInfoStruct54 = 80 bytes
// rev >= 65: ScanEventInfoStruct   = 136 bytes
pub const SCAN_EVENT_INFO_SIZE: u64 = 136; // file rev >= 65
pub const SCAN_EVENT_INFO_SIZE_REV64: u64 = 80;  // file rev 54-64
pub const SCAN_EVENT_INFO_SIZE_REV53: u64 = 40;  // file rev 50-53
pub const SCAN_EVENT_INFO_SIZE_LEGACY: u64 = 24; // file rev < 50

// MsReactionStruct sizes by file revision:
// rev < 65: MsReactionStruct1 = 24 bytes
// rev 65:   MsReactionStruct2 = 32 bytes
// rev 66+:  MsReactionStruct  = 56 bytes
pub const REACTION_SIZE_CURRENT: u64 = 56; // file rev >= 66
pub const REACTION_SIZE_REV65: u64 = 32;   // file rev 65
pub const REACTION_SIZE_LEGACY: u64 = 24;  // file rev < 65

pub const VIRTUAL_DEVICE_MS: i32 = 0;
pub const MAX_STRING_CHARS: u32 = 1_000_000;

// Spectrum packet types (from Thermo CommonData)
// SpectrumPacketType enum values from ThermoFisher.CommonCore.RawFileReader.
// NOTE: The FUNCTIONALITY_REPORT incorrectly inferred FtCentroid=15, FtProfile=16.
// The ACTUAL raw values in ScanIndexStruct.PacketType (verified from file data) are:
// - MS1 scans: packet_type = 21 (FT_PROFILE)
// - MS2 scans: packet_type = 20 (FT_CENTROID)
// These match the C# code which casts PacketType & 0xFFFF directly to SpectrumPacketType.
pub const PACKET_TYPE_PROFILE_SPECTRUM: u32 = 0;
pub const PACKET_TYPE_LOW_RES_SPECTRUM: u32 = 1;
pub const PACKET_TYPE_HIGH_RES_SPECTRUM: u32 = 2;
pub const PACKET_TYPE_PROFILE_INDEX: u32 = 3;
pub const PACKET_TYPE_LINEAR_TRAP_PROFILE: u32 = 4;
pub const PACKET_TYPE_STANDARD_ACCURACY: u32 = 5;      // C# StandardAccuracyPacket
pub const PACKET_TYPE_FT_CENTROID: u32 = 20;
pub const PACKET_TYPE_LINEAR_TRAP_CENTROID: u32 = 13;  // C# LinearTrapCentroid
pub const PACKET_TYPE_FT_PROFILE: u32 = 21;
pub const PACKET_TYPE_HIGH_RES_COMPRESSED_PROFILE: u32 = 22;
pub const PACKET_TYPE_LOW_RES_COMPRESSED_PROFILE: u32 = 23;
pub const PACKET_TYPE_LOW_RES_SPECTRUM_TYPE: u32 = 24;

pub fn resolveScan(file: std.Io.File, io: std.Io, scan_number: i32) RawResolveError!ResolvedScan {
    const file_revision = try readU16At(file, io, FILE_REV_OFFSET);
    if (file_revision < 65) {
        @branchHint(.unlikely);
        return RawResolveError.UnsupportedFileRevision;
    }

    var pos: u64 = FILE_HEADER_SIZE;
    try skipSequenceRow(file, io, &pos, file_revision);
    try skipAutoSamplerConfig(file, io, &pos, file_revision);

    const raw_info_offset = pos;
    const controller_count_i32 = try readI32At(file, io, raw_info_offset + RAW_INFO_NUM_CONTROLLERS);
    if (controller_count_i32 <= 0 or controller_count_i32 > 64) {
        @branchHint(.unlikely);
        return RawResolveError.InvalidRawFileInfo;
    }
    const controller_count: usize = @intCast(controller_count_i32);

    var ms_controller_index: ?usize = null;
    var controller_offset: u64 = 0;
    var i: usize = 0;
    while (i < controller_count) : (i += 1) {
        const entry_base = raw_info_offset + RAW_INFO_CONTROLLER_TABLE_CURRENT + @as(u64, @intCast(i)) * RAW_INFO_CONTROLLER_SIZE_CURRENT;
        const device_type = try readI32At(file, io, entry_base + RAW_INFO_CONTROLLER_TYPE);
        if (device_type == VIRTUAL_DEVICE_MS) {
            const off = try readI64At(file, io, entry_base + RAW_INFO_CONTROLLER_OFFSET);
            if (off <= 0) {
                @branchHint(.unlikely);
                return RawResolveError.InvalidControllerOffset;
            }
            ms_controller_index = i;
            controller_offset = @intCast(off);
            break;
        }
    }
    if (ms_controller_index == null) {
        @branchHint(.unlikely);
        return RawResolveError.NoMsController;
    }

    const first_spectrum = try readI32At(file, io, controller_offset + RUN_HEADER_FIRST_SPECTRUM);
    const last_spectrum = try readI32At(file, io, controller_offset + RUN_HEADER_LAST_SPECTRUM);
    if (first_spectrum <= 0 or last_spectrum < first_spectrum) {
        @branchHint(.unlikely);
        return RawResolveError.InvalidRunHeader;
    }
    if (scan_number < first_spectrum or scan_number > last_spectrum) {
        @branchHint(.unlikely);
        return RawResolveError.ScanOutOfRange;
    }

    const spectrum_pos_i64 = try readI64At(file, io, controller_offset + RUN_HEADER_SPECT_POS);
    const packet_pos_i64 = try readI64At(file, io, controller_offset + RUN_HEADER_PACKET_POS);
    if (spectrum_pos_i64 <= 0 or packet_pos_i64 <= 0) {
        @branchHint(.unlikely);
        return RawResolveError.InvalidRunHeader;
    }
    const spectrum_pos: u64 = @intCast(spectrum_pos_i64);
    const packet_pos: u64 = @intCast(packet_pos_i64);

    const scan_index_size = scanIndexSize(file_revision);
    const zero_based: u64 = @intCast(scan_number - first_spectrum);
    var scan_index_pos: u64 = std.math.add(u64, spectrum_pos, zero_based * scan_index_size) catch return RawResolveError.OffsetOverflow;
    var scan_index = try readScanIndex(file, io, scan_index_pos, file_revision);

    if (scan_index.scan_number != scan_number) {
        const num_scans: u64 = @intCast(last_spectrum - first_spectrum + 1);
        const scan_table_end_unclamped = std.math.add(u64, spectrum_pos, std.math.mul(u64, num_scans, scan_index_size) catch return RawResolveError.OffsetOverflow) catch return RawResolveError.OffsetOverflow;
        const file_len = (file.stat(io) catch return RawResolveError.Truncated).size;
        const scan_table_end = if (scan_table_end_unclamped < file_len) scan_table_end_unclamped else file_len;

        var next_scan_index_pos = spectrum_pos;
        var found: bool = false;
        while (next_scan_index_pos + scan_index_size <= scan_table_end) : (next_scan_index_pos += scan_index_size) {
            const candidate = readScanIndex(file, io, next_scan_index_pos, file_revision) catch |err| switch (err) {
                RawResolveError.Truncated => break,
                RawResolveError.InvalidRawFileInfo => continue,
                else => return err,
            };
            if (candidate.scan_number == scan_number) {
                scan_index = candidate;
                scan_index_pos = next_scan_index_pos;
                found = true;
                break;
            }
        }
        if (!found) return RawResolveError.ScanIndexMismatch;
    }

    const absolute_packet_offset = std.math.add(u64, packet_pos, scan_index.data_offset) catch return RawResolveError.OffsetOverflow;

    return .{
        .file_revision = file_revision,
        .raw_file_info_offset = raw_info_offset,
        .ms_controller_index = ms_controller_index.?,
        .controller_offset = controller_offset,
        .first_spectrum = first_spectrum,
        .last_spectrum = last_spectrum,
        .spectrum_pos = spectrum_pos,
        .packet_pos = packet_pos,
        .scan_index_pos = scan_index_pos,
        .scan_index = scan_index,
        .absolute_packet_offset = absolute_packet_offset,
    };
}

pub fn scanIndexSize(file_revision: u16) u64 {
    if (file_revision >= 65) return SCAN_INDEX_SIZE_CURRENT;
    if (file_revision >= 64) return SCAN_INDEX_SIZE_REV64;
    return SCAN_INDEX_SIZE_LEGACY;
}

pub fn scanEventInfoSize(file_revision: u16) u64 {
    if (file_revision >= 65) return SCAN_EVENT_INFO_SIZE;
    if (file_revision >= 54) return SCAN_EVENT_INFO_SIZE_REV64;
    if (file_revision >= 48) return SCAN_EVENT_INFO_SIZE_REV53;
    if (file_revision >= 31) return 32; // ScanEventInfoStruct3 (rev 31-47)
    return SCAN_EVENT_INFO_SIZE_LEGACY;
}

pub fn reactionSize(file_revision: u16) u64 {
    if (file_revision >= 66) return REACTION_SIZE_CURRENT;
    if (file_revision >= 65) return REACTION_SIZE_REV65;
    return REACTION_SIZE_LEGACY;
}

pub fn readScanIndex(file: std.Io.File, io: std.Io, offset: u64, file_revision: u16) RawResolveError!ScanIndexEntry {
    if (file_revision >= 65) {
        const data_offset_i64 = try readI64At(file, io, offset + 72);
        if (data_offset_i64 < 0) return RawResolveError.InvalidRawFileInfo;
        return .{
            .data_size = try readU32At(file, io, offset + 0),
            .trailer_offset = try readI32At(file, io, offset + 4),
            .scan_type_index = try readI32At(file, io, offset + 8),
            .scan_number = try readI32At(file, io, offset + 12),
            .packet_type = try readU32At(file, io, offset + 16),
            .number_packets = try readI32At(file, io, offset + 20),
            .data_offset = @bitCast(data_offset_i64),
            .start_time = try readF64At(file, io, offset + 24),
            .tic = try readF64At(file, io, offset + 32),
            .base_peak_intensity = try readF64At(file, io, offset + 40),
            .base_peak_mass = try readF64At(file, io, offset + 48),
            .low_mass = try readF64At(file, io, offset + 56),
            .high_mass = try readF64At(file, io, offset + 64),
        };
    }
    if (file_revision >= 64) {
        const data_offset_i64 = try readI64At(file, io, offset + 72);
        if (data_offset_i64 < 0) return RawResolveError.InvalidRawFileInfo;
        return .{
            .data_size = 0,
            .trailer_offset = try readI32At(file, io, offset + 4),
            .scan_type_index = try readI32At(file, io, offset + 8),
            .scan_number = try readI32At(file, io, offset + 12),
            .packet_type = try readU32At(file, io, offset + 16),
            .number_packets = try readI32At(file, io, offset + 20),
            .data_offset = @bitCast(data_offset_i64),
            .start_time = 0,
            .tic = 0,
            .base_peak_intensity = 0,
            .base_peak_mass = 0,
            .low_mass = 0,
            .high_mass = 0,
        };
    }
    return .{
        .data_size = 0,
        .trailer_offset = try readI32At(file, io, offset + 4),
        .scan_type_index = try readI32At(file, io, offset + 8),
        .scan_number = try readI32At(file, io, offset + 12),
        .packet_type = try readU32At(file, io, offset + 16),
        .number_packets = try readI32At(file, io, offset + 20),
        .data_offset = try readU32At(file, io, offset + 0),
        .start_time = 0,
        .tic = 0,
        .base_peak_intensity = 0,
        .base_peak_mass = 0,
        .low_mass = 0,
        .high_mass = 0,
    };
}

/// Parse a ScanIndexEntry from an in-memory buffer at the given offset.
/// This avoids syscalls when the entire scan index table has been batch-read.
pub fn parseScanIndex(bytes: []const u8, offset: usize, file_revision: u16) RawResolveError!ScanIndexEntry {
    if (offset + scanIndexSize(file_revision) > bytes.len) return RawResolveError.Truncated;
    if (file_revision >= 65) {
        const data_offset_i64 = std.mem.readInt(i64, bytes[offset + 72 ..][0..8], .little);
        if (data_offset_i64 < 0) return RawResolveError.InvalidRawFileInfo;
        return .{
            .data_size = std.mem.readInt(u32, bytes[offset + 0 ..][0..4], .little),
            .trailer_offset = std.mem.readInt(i32, bytes[offset + 4 ..][0..4], .little),
            .scan_type_index = std.mem.readInt(i32, bytes[offset + 8 ..][0..4], .little),
            .scan_number = std.mem.readInt(i32, bytes[offset + 12 ..][0..4], .little),
            .packet_type = std.mem.readInt(u32, bytes[offset + 16 ..][0..4], .little),
            .number_packets = std.mem.readInt(i32, bytes[offset + 20 ..][0..4], .little),
            .data_offset = @bitCast(data_offset_i64),
            .start_time = @bitCast(std.mem.readInt(u64, bytes[offset + 24 ..][0..8], .little)),
            .tic = @bitCast(std.mem.readInt(u64, bytes[offset + 32 ..][0..8], .little)),
            .base_peak_intensity = @bitCast(std.mem.readInt(u64, bytes[offset + 40 ..][0..8], .little)),
            .base_peak_mass = @bitCast(std.mem.readInt(u64, bytes[offset + 48 ..][0..8], .little)),
            .low_mass = @bitCast(std.mem.readInt(u64, bytes[offset + 56 ..][0..8], .little)),
            .high_mass = @bitCast(std.mem.readInt(u64, bytes[offset + 64 ..][0..8], .little)),
        };
    }
    if (file_revision >= 64) {
        const data_offset_i64 = std.mem.readInt(i64, bytes[offset + 72 ..][0..8], .little);
        if (data_offset_i64 < 0) return RawResolveError.InvalidRawFileInfo;
        return .{
            .data_size = 0,
            .trailer_offset = std.mem.readInt(i32, bytes[offset + 4 ..][0..4], .little),
            .scan_type_index = std.mem.readInt(i32, bytes[offset + 8 ..][0..4], .little),
            .scan_number = std.mem.readInt(i32, bytes[offset + 12 ..][0..4], .little),
            .packet_type = std.mem.readInt(u32, bytes[offset + 16 ..][0..4], .little),
            .number_packets = std.mem.readInt(i32, bytes[offset + 20 ..][0..4], .little),
            .data_offset = @bitCast(data_offset_i64),
            .start_time = 0,
            .tic = 0,
            .base_peak_intensity = 0,
            .base_peak_mass = 0,
            .low_mass = 0,
            .high_mass = 0,
        };
    }
    return .{
        .data_size = 0,
        .trailer_offset = std.mem.readInt(i32, bytes[offset + 4 ..][0..4], .little),
        .scan_type_index = std.mem.readInt(i32, bytes[offset + 8 ..][0..4], .little),
        .scan_number = std.mem.readInt(i32, bytes[offset + 12 ..][0..4], .little),
        .packet_type = std.mem.readInt(u32, bytes[offset + 16 ..][0..4], .little),
        .number_packets = std.mem.readInt(i32, bytes[offset + 20 ..][0..4], .little),
        .data_offset = std.mem.readInt(u32, bytes[offset + 0 ..][0..4], .little),
        .start_time = 0,
        .tic = 0,
        .base_peak_intensity = 0,
        .base_peak_mass = 0,
        .low_mass = 0,
        .high_mass = 0,
    };
}

pub fn skipSequenceRow(file: std.Io.File, io: std.Io, pos: *u64, file_revision: u16) RawResolveError!void {
    pos.* += SEQ_ROW_INFO_SIZE;

    // SequenceRow.Load:
    // CalLevel, SampleName, SampleId, Comment, 5 UserTexts, Inst, Method,
    // RawFileName, Path.
    var n: usize = 0;
    while (n < 13) : (n += 1) try skipWideString(file, io, pos);

    if (file_revision >= 25) {
        try skipWideString(file, io, pos); // Vial
        try skipWideString(file, io, pos); // CalibFile
    }
    if (file_revision >= 41) {
        try skipWideString(file, io, pos); // Barcode
        pos.* += 4; // BarcodeStatus int
    }
    if (file_revision >= 58) {
        n = 0;
        while (n < 15) : (n += 1) try skipWideString(file, io, pos);
    }
}

pub fn skipAutoSamplerConfig(file: std.Io.File, io: std.Io, pos: *u64, file_revision: u16) RawResolveError!void {
    if (file_revision >= 36) {
        pos.* += AUTO_SAMPLER_CONFIG_SIZE;
        try skipWideString(file, io, pos); // TrayName via ReadStringExt; same length + UTF-16 payload shape.
    }
}

pub fn skipWideString(file: std.Io.File, io: std.Io, pos: *u64) RawResolveError!void {
    const chars = try readU32At(file, io, pos.*);
    if (chars > MAX_STRING_CHARS) return RawResolveError.InvalidStringLength;
    pos.* += 4;
    const bytes = @as(u64, chars) * 2;
    pos.* = std.math.add(u64, pos.*, bytes) catch return RawResolveError.OffsetOverflow;
}

/// Read a wide string (UTF-16 LE) at the current position and advance pos.
/// Returns an allocator-owned UTF-8 string or null for empty strings.
/// Caller must free the returned string.
pub fn readWideStringAt(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, pos: *u64) RawResolveError!?[]u8 {
    const chars = try readU32At(file, io, pos.*);
    pos.* += 4;
    if (chars == 0) return null;
    if (chars > MAX_STRING_CHARS) return RawResolveError.InvalidStringLength;
    const bytes = @as(u64, chars) * 2;

    // Fast path: small strings (all instrument metadata, method names, etc.)
    const stack_chars = 256;
    if (chars <= stack_chars) {
        var stack_wide: [stack_chars]u16 = undefined;
        const wide_bytes = std.mem.sliceAsBytes(stack_wide[0..chars]);
        try preadExact(file, io, wide_bytes, pos.*);
        pos.* += bytes;

        // Worst-case BMP → UTF-8 is 3 bytes per char
        var stack_utf8: [stack_chars * 3]u8 = undefined;
        const utf8_len = std.unicode.utf16LeToUtf8(&stack_utf8, stack_wide[0..chars]) catch return RawResolveError.InvalidStringLength;

        const result = allocator.alloc(u8, utf8_len) catch return RawResolveError.Truncated;
        @memcpy(result, stack_utf8[0..utf8_len]);
        return result;
    }

    // Slow path: large strings (theoretical). Allocate u16 directly.
    const wide_u16 = allocator.alloc(u16, chars) catch return RawResolveError.Truncated;
    defer allocator.free(wide_u16);
    const wide_bytes = std.mem.sliceAsBytes(wide_u16);
    try preadExact(file, io, wide_bytes, pos.*);
    pos.* += bytes;
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide_u16) catch return RawResolveError.InvalidStringLength;
}

/// Read instrument metadata strings from the sequence row.
/// Returns the Inst (instrument model) and Method strings.
/// Advances pos past the entire sequence row.
pub fn readSequenceRowMetadata(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    pos: *u64,
    file_revision: u16,
) RawResolveError!struct { inst: ?[]u8, method: ?[]u8 } {
    pos.* += SEQ_ROW_INFO_SIZE;

    // Skip first 9 strings: CalLevel, SampleName, SampleId, Comment, 5 UserTexts
    var n: usize = 0;
    while (n < 9) : (n += 1) try skipWideString(file, io, pos);

    // Read Inst (10th string, index 9)
    const inst = try readWideStringAt(allocator, file, io, pos);

    // Read Method (11th string, index 10)
    const method = try readWideStringAt(allocator, file, io, pos);

    // Skip remaining strings in the first batch (RawFileName, Path = 2 strings)
    n = 0;
    while (n < 2) : (n += 1) try skipWideString(file, io, pos);

    if (file_revision >= 25) {
        try skipWideString(file, io, pos); // Vial
        try skipWideString(file, io, pos); // CalibFile
    }
    if (file_revision >= 41) {
        try skipWideString(file, io, pos); // Barcode
        pos.* += 4; // BarcodeStatus int
    }
    if (file_revision >= 58) {
        n = 0;
        while (n < 15) : (n += 1) try skipWideString(file, io, pos);
    }

    return .{ .inst = inst, .method = method };
}

pub const InstrumentId = struct {
    model: ?[]u8,
    serial: ?[]u8,
    software_version: ?[]u8,
};

/// Read instrument identity metadata from the MS controller data.
/// The InstrumentId structure lives immediately after the RunHeaderStruct
/// at `controller_offset + RUN_HEADER_STRUCT_SIZE`.
/// Returns Model, SerialNumber, and SoftwareVersion strings (allocator-owned, caller must free).
/// If the InstrumentId is not valid (IsValid == 0), returns null fields.
pub fn readInstrumentId(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    controller_offset: u64,
    file_revision: u16,
) RawResolveError!InstrumentId {
    if (file_revision < 45) {
        // InstrumentId not present in this format
        return InstrumentId{ .model = null, .serial = null, .software_version = null };
    }

    var pos = controller_offset + RUN_HEADER_STRUCT_SIZE;

    // Read InstIdInfoStruct (8 bytes: IsValid u32 + AbsorbanceUnit u32)
    var inst_id_buf: [8]u8 = undefined;
    try preadExact(file, io, &inst_id_buf, pos);
    pos += 8;
    const is_valid = std.mem.readInt(u32, inst_id_buf[0..4], .little);
    if (is_valid == 0) {
        // InstrumentId not populated; skip remaining fields anyway to keep
        // the API uniform, but return nulls.
    }

    // Read ChannelLabels array: count + strings
    var count_buf: [4]u8 = undefined;
    try preadExact(file, io, &count_buf, pos);
    pos += 4;
    const channel_count = std.mem.readInt(i32, &count_buf, .little);
    if (channel_count < 0 or channel_count > 256) return RawResolveError.InvalidStringLength;
    var n: i32 = 0;
    while (n < channel_count) : (n += 1) {
        try skipWideString(file, io, &pos);
    }

    // Name (we don't need it, but must skip)
    try skipWideString(file, io, &pos);

    // Model
    const model = try readWideStringAt(allocator, file, io, &pos);

    // SerialNumber
    const serial = try readWideStringAt(allocator, file, io, &pos);

    // SoftwareVersion
    const software_version = try readWideStringAt(allocator, file, io, &pos);

    // HardwareVersion (skip)
    try skipWideString(file, io, &pos);

    // Flags (rev >= 32)
    if (file_revision >= 32) {
        try skipWideString(file, io, &pos);
    }

    // AxisLabelX and AxisLabelY (rev >= 37)
    if (file_revision >= 37) {
        try skipWideString(file, io, &pos);
        try skipWideString(file, io, &pos);
    }

    return .{
        .model = model,
        .serial = serial,
        .software_version = software_version,
    };
}

pub fn readU16At(file: std.Io.File, io: std.Io, offset: u64) RawResolveError!u16 {
    var b: [2]u8 = undefined;
    try preadExact(file, io, b[0..], offset);
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

pub fn readU32At(file: std.Io.File, io: std.Io, offset: u64) RawResolveError!u32 {
    var b: [4]u8 = undefined;
    try preadExact(file, io, b[0..], offset);
    return @as(u32, b[0]) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);
}

pub fn readI32At(file: std.Io.File, io: std.Io, offset: u64) RawResolveError!i32 {
    return @bitCast(try readU32At(file, io, offset));
}

pub fn readU64At(file: std.Io.File, io: std.Io, offset: u64) RawResolveError!u64 {
    var b: [8]u8 = undefined;
    try preadExact(file, io, b[0..], offset);
    return @as(u64, b[0]) |
        (@as(u64, b[1]) << 8) |
        (@as(u64, b[2]) << 16) |
        (@as(u64, b[3]) << 24) |
        (@as(u64, b[4]) << 32) |
        (@as(u64, b[5]) << 40) |
        (@as(u64, b[6]) << 48) |
        (@as(u64, b[7]) << 56);
}

pub fn readI64At(file: std.Io.File, io: std.Io, offset: u64) RawResolveError!i64 {
    return @bitCast(try readU64At(file, io, offset));
}

pub fn readF32At(file: std.Io.File, io: std.Io, offset: u64) RawResolveError!f32 {
    return @bitCast(try readU32At(file, io, offset));
}

pub fn readF64At(file: std.Io.File, io: std.Io, offset: u64) RawResolveError!f64 {
    return @bitCast(try readU64At(file, io, offset));
}

// ------------------------------------------------------------------
// Memory-mapped variants — zero-syscall reads from mmap slice
// ------------------------------------------------------------------

pub inline fn readU16Mm(mm: []const u8, offset: u64) RawResolveError!u16 {
    if (offset + 2 > mm.len) return RawResolveError.Truncated;
    return std.mem.readInt(u16, mm[@intCast(offset)..][0..2], .little);
}

pub inline fn readU32Mm(mm: []const u8, offset: u64) RawResolveError!u32 {
    if (offset + 4 > mm.len) return RawResolveError.Truncated;
    return std.mem.readInt(u32, mm[@intCast(offset)..][0..4], .little);
}

pub inline fn readI32Mm(mm: []const u8, offset: u64) RawResolveError!i32 {
    return @bitCast(try readU32Mm(mm, offset));
}

pub inline fn readU64Mm(mm: []const u8, offset: u64) RawResolveError!u64 {
    if (offset + 8 > mm.len) return RawResolveError.Truncated;
    return std.mem.readInt(u64, mm[@intCast(offset)..][0..8], .little);
}

pub inline fn readI64Mm(mm: []const u8, offset: u64) RawResolveError!i64 {
    return @bitCast(try readU64Mm(mm, offset));
}

pub inline fn readF32Mm(mm: []const u8, offset: u64) RawResolveError!f32 {
    return @bitCast(try readU32Mm(mm, offset));
}

pub inline fn readF64Mm(mm: []const u8, offset: u64) RawResolveError!f64 {
    return @bitCast(try readU64Mm(mm, offset));
}

pub fn preadExact(file: std.Io.File, io: std.Io, buf: []u8, offset: u64) RawResolveError!void {
    const n = file.readPositionalAll(io, buf, offset) catch return RawResolveError.Truncated;
    if (n != buf.len) return RawResolveError.Truncated;
}

/// Read a wide string (UTF-16 LE) from the file at the given offset.
/// Returns an allocator-owned UTF-8 string. Caller must free.
pub fn readWideStringAlloc(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, offset: u64) RawResolveError![]u8 {
    var len_buf: [4]u8 = undefined;
    try preadExact(file, io, &len_buf, offset);
    const len = std.mem.readInt(i32, &len_buf, .little);
    if (len < 0 or len > MAX_STRING_CHARS) return RawResolveError.InvalidStringLength;
    if (len == 0) return allocator.dupe(u8, "");

    // Fast path: small strings on stack
    const stack_chars = 256;
    if (len <= stack_chars) {
        var stack_wide: [stack_chars]u16 = undefined;
        const wide_bytes = std.mem.sliceAsBytes(stack_wide[0..@intCast(len)]);
        try preadExact(file, io, wide_bytes, offset + 4);
        var stack_utf8: [stack_chars * 3]u8 = undefined;
        const utf8_len = std.unicode.utf16LeToUtf8(&stack_utf8, stack_wide[0..@intCast(len)]) catch return RawResolveError.InvalidStringLength;
        const result = allocator.alloc(u8, utf8_len) catch return RawResolveError.Truncated;
        @memcpy(result, stack_utf8[0..utf8_len]);
        return result;
    }

    // Slow path: large strings
    const wide_u16 = allocator.alloc(u16, @intCast(len)) catch return RawResolveError.Truncated;
    defer allocator.free(wide_u16);
    const wide_bytes = std.mem.sliceAsBytes(wide_u16);
    try preadExact(file, io, wide_bytes, offset + 4);
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide_u16) catch return RawResolveError.InvalidStringLength;
}

pub const ScanEventInfo = struct {
    // offsets 0-11: 12 byte fields (tightly packed, no alignment needed)
    is_valid: u8,                  // 0
    is_custom: u8,                 // 1
    corona: u8,                    // 2
    detector: u8,                  // 3
    polarity: u8,                  // 4
    scan_data_type: u8,            // 5
    ms_order: i8,                  // 6
    scan_type: u8,                 // 7
    source_fragmentation: u8,      // 8
    turbo_scan: u8,                // 9
    dependent_data: u8,            // 10
    ionization_mode: u8,           // 11

    // offset 12-15: padding to align next double to 8
    _pad1: [4]u8,

    // offset 16-23
    detector_value: f64,           // 16

    // offset 24
    source_fragmentation_type: u8, // 24

    // offset 25-27: padding to align next int to 4
    _pad2: [3]u8,

    // offset 28-31
    scan_type_index: i32,          // 28

    // offset 32
    wideband: u8,                  // 32

    // offset 33-35: padding to align next int enum to 4
    _pad3: [3]u8,

    // offset 36-39 (C# enum = int)
    accurate_mass_type: u32,       // 36

    // offset 40-46: 7 byte fields (tightly packed)
    mass_analyzer_type: u8,        // 40
    sector_scan: u8,               // 41
    lock: u8,                      // 42
    free_region: u8,               // 43
    ultra: u8,                     // 44
    enhanced: u8,                  // 45
    mpd_type: u8,                  // 46

    // offset 47: padding to align next double to 8
    _pad4: u8,

    // offset 48-55
    mpd_value: f64,                // 48

    // offset 56
    ecd_type: u8,                  // 56

    // offset 57-63: padding to align next double to 8
    _pad5: [7]u8,

    // offset 64-71
    ecd_value: f64,                // 64

    // offset 72-73: 2 byte fields
    photo_ionization: u8,          // 72
    pqd_type: u8,                  // 73

    // offset 74-79: padding to align next double to 8
    _pad6: [6]u8,

    // offset 80-87
    pqd_value: f64,                // 80

    // offset 88
    etd_type: u8,                  // 88

    // offset 89-95: padding to align next double to 8
    _pad7: [7]u8,

    // offset 96-103
    etd_value: f64,                // 96

    // offset 104
    hcd_type: u8,                  // 104

    // offset 105-111: padding to align next double to 8
    _pad8: [7]u8,

    // offset 112-119
    hcd_value: f64,                // 112

    // offset 120-130: 11 byte fields (tightly packed)
    supplemental_activation: u8,   // 120
    multi_state_activation: u8,    // 121
    compensation_voltage: u8,      // 122
    compensation_voltage_type: u8, // 123
    multiplex: u8,                 // 124
    param_a: u8,                   // 125
    param_b: u8,                   // 126
    param_f: u8,                   // 127
    sps_multi_notch: u8,           // 128
    param_r: u8,                   // 129
    param_v: u8,                   // 130

    // offset 131-135: padding to round total to multiple of 8
    _pad9: [5]u8,

    /// Parse from byte slice at given offset.
    /// `size` is the actual struct size for this file revision (24/32/40/80/136).
    pub fn read(bytes: []const u8, offset: usize, size: u64) RawResolveError!ScanEventInfo {
        if (offset + size > bytes.len) return RawResolveError.Truncated;
        var info = std.mem.zeroes(ScanEventInfo);

        // Offsets 0-23: present in all versions (legacy = 24 bytes)
        if (size >= 24) {
            info.is_valid = bytes[offset + 0];
            info.is_custom = bytes[offset + 1];
            info.corona = bytes[offset + 2];
            info.detector = bytes[offset + 3];
            info.polarity = bytes[offset + 4];
            info.scan_data_type = bytes[offset + 5];
            info.ms_order = @intCast(bytes[offset + 6]);
            info.scan_type = bytes[offset + 7];
            info.source_fragmentation = bytes[offset + 8];
            info.turbo_scan = bytes[offset + 9];
            info.dependent_data = bytes[offset + 10];
            info.ionization_mode = bytes[offset + 11];
            info._pad1 = bytes[offset + 12 ..][0..4].*;
            info.detector_value = @bitCast(std.mem.readInt(u64, bytes[offset + 16 ..][0..8], .little));
        }

        // Offsets 24-31: rev >= 31 (Struct3 = 32 bytes)
        if (size >= 32) {
            info.source_fragmentation_type = bytes[offset + 24];
            info._pad2 = bytes[offset + 25 ..][0..3].*;
            info.scan_type_index = std.mem.readInt(i32, bytes[offset + 28 ..][0..4], .little);
        }

        // Offsets 32-39: rev >= 48 (Struct50/51 = 40 bytes)
        if (size >= 40) {
            info.wideband = bytes[offset + 32];
            info._pad3 = bytes[offset + 33 ..][0..3].*;
            info.accurate_mass_type = std.mem.readInt(u32, bytes[offset + 36 ..][0..4], .little);
        }

        // Offsets 40-79: rev >= 54 (Struct54/62 = 80 bytes)
        if (size >= 80) {
            info.mass_analyzer_type = bytes[offset + 40];
            info.sector_scan = bytes[offset + 41];
            info.lock = bytes[offset + 42];
            info.free_region = bytes[offset + 43];
            info.ultra = bytes[offset + 44];
            info.enhanced = bytes[offset + 45];
            info.mpd_type = bytes[offset + 46];
            info._pad4 = bytes[offset + 47];
            info.mpd_value = @bitCast(std.mem.readInt(u64, bytes[offset + 48 ..][0..8], .little));
            info.ecd_type = bytes[offset + 56];
            info._pad5 = bytes[offset + 57 ..][0..7].*;
            info.ecd_value = @bitCast(std.mem.readInt(u64, bytes[offset + 64 ..][0..8], .little));
            info.photo_ionization = bytes[offset + 72];
            info.pqd_type = bytes[offset + 73];
            info._pad6 = bytes[offset + 74 ..][0..6].*;
        }

        // Offsets 80-135: rev >= 65 (full 136 bytes)
        if (size >= 136) {
            info.pqd_value = @bitCast(std.mem.readInt(u64, bytes[offset + 80 ..][0..8], .little));
            info.etd_type = bytes[offset + 88];
            info._pad7 = bytes[offset + 89 ..][0..7].*;
            info.etd_value = @bitCast(std.mem.readInt(u64, bytes[offset + 96 ..][0..8], .little));
            info.hcd_type = bytes[offset + 104];
            info._pad8 = bytes[offset + 105 ..][0..7].*;
            info.hcd_value = @bitCast(std.mem.readInt(u64, bytes[offset + 112 ..][0..8], .little));
            info.supplemental_activation = bytes[offset + 120];
            info.multi_state_activation = bytes[offset + 121];
            info.compensation_voltage = bytes[offset + 122];
            info.compensation_voltage_type = bytes[offset + 123];
            info.multiplex = bytes[offset + 124];
            info.param_a = bytes[offset + 125];
            info.param_b = bytes[offset + 126];
            info.param_f = bytes[offset + 127];
            info.sps_multi_notch = bytes[offset + 128];
            info.param_r = bytes[offset + 129];
            info.param_v = bytes[offset + 130];
            info._pad9 = bytes[offset + 131 ..][0..5].*;
        }

        return info;
    }
};

/// Reaction struct (56 bytes, file rev >= 66)
/// C#: Marshal.SizeOf(typeof(MsReactionStruct)) = 56

pub const Reaction = struct {
    precursor_mass: f64,         // offset 0
    isolation_width: f64,        // offset 8
    collision_energy: f64,       // offset 16
    collision_energy_valid: u32, // offset 24 (C# bool marshals as 4 bytes)
    range_is_valid: u32,         // offset 28
    first_precursor_mass: f64,   // offset 32
    last_precursor_mass: f64,    // offset 40
    isolation_width_offset: f64, // offset 48

    /// Parse from byte slice at given offset (rev >= 66).
    pub fn read(bytes: []const u8, offset: usize) RawResolveError!Reaction {
        if (offset + REACTION_SIZE_CURRENT > bytes.len) return RawResolveError.Truncated;
        return .{
            .precursor_mass = @bitCast(std.mem.readInt(u64, bytes[offset + 0 ..][0..8], .little)),
            .isolation_width = @bitCast(std.mem.readInt(u64, bytes[offset + 8 ..][0..8], .little)),
            .collision_energy = @bitCast(std.mem.readInt(u64, bytes[offset + 16 ..][0..8], .little)),
            .collision_energy_valid = std.mem.readInt(u32, bytes[offset + 24 ..][0..4], .little),
            .range_is_valid = std.mem.readInt(u32, bytes[offset + 28 ..][0..4], .little),
            .first_precursor_mass = @bitCast(std.mem.readInt(u64, bytes[offset + 32 ..][0..8], .little)),
            .last_precursor_mass = @bitCast(std.mem.readInt(u64, bytes[offset + 40 ..][0..8], .little)),
            .isolation_width_offset = @bitCast(std.mem.readInt(u64, bytes[offset + 48 ..][0..8], .little)),
        };
    }
};

/// MassRange struct (16 bytes: f64 low + f64 high)
pub const MassRange = struct {
    low: f64,
    high: f64,
};

