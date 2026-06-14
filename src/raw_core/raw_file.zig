const std = @import("std");
const spec_scan_index = @import("spec/scan_index");
const spec_file_header = @import("spec/file_header");
const spec_run_header = @import("spec/run_header");
const spec_raw_info = @import("spec/raw_info");
const spec_scan_event_info = @import("spec/scan_event_info");
const spec_reaction = @import("spec/reaction");
const spec_ph = @import("spec/packet_header");

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
    /// Propagated from allocator failures (e.g. in scan_event / trailer_events).
    /// Per zig-quality, allocation failures should NOT be silently converted to
    /// data-format errors. Callers that need to handle OOM can switch on it.
    OutOfMemory,
};

pub const ScanIndexEntry = struct {
    /// Always 0 for rev < 65 files (offset 0 is DataOffset32Bit, not DataSize).
    /// For rev >= 65, this is the actual packet data size read from offset 0.
    data_size: u32,
    /// Interpret via trailerUsage(file_revision) — byte offset for rev < 65, event index for rev >= 65.
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
    /// Cycle number for rev >= 65 files; 0 for older revisions.
    cycle_number: i32,
};

/// How to interpret the trailer_offset field in ScanIndexEntry.
/// Ground truth from Thermo decompiled code (MassSpecDeviceWriter.cs:477,
/// MassSpecDevice.cs:2228): for rev >= 65, trailer_offset is an
/// auto-incrementing event index into the TrailerScanEvents table.
pub const TrailerUsage = enum { byte_offset, event_index };

/// Returns how trailer_offset should be interpreted for a given file revision.
pub fn trailer_usage(file_revision: u16) TrailerUsage {
    return if (file_revision >= 65) .event_index else .byte_offset;
}
pub const trailerUsage = trailer_usage; // DEPRECATED: use trailer_usage

// ---------------------------------------------------------------------------
// Re-exports from spec modules (backwards compatibility).
// New code should import spec modules directly.
// ---------------------------------------------------------------------------
pub const FILE_REV_OFFSET = spec_file_header.FILE_REV_OFFSET;
pub const FILE_HEADER_SIZE = spec_file_header.FILE_HEADER_SIZE;

pub const SEQ_ROW_INFO_SIZE = spec_file_header.SEQ_ROW_INFO_SIZE;
pub const AUTO_SAMPLER_CONFIG_SIZE = spec_file_header.AUTO_SAMPLER_CONFIG_SIZE;

pub const RAW_INFO_NUM_CONTROLLERS = spec_raw_info.CURRENT.num_controllers;
pub const RAW_INFO_CONTROLLER_TABLE_CURRENT = spec_raw_info.CURRENT.controller_table;
pub const RAW_INFO_CONTROLLER_SIZE_CURRENT = spec_raw_info.CURRENT.controller_size;
pub const RAW_INFO_CONTROLLER_TYPE = spec_raw_info.CURRENT.controller_type;
pub const RAW_INFO_CONTROLLER_OFFSET = spec_raw_info.CURRENT.controller_offset;

pub const RUN_HEADER_FIRST_SPECTRUM = spec_run_header.CURRENT.first_spectrum;
pub const RUN_HEADER_LAST_SPECTRUM = spec_run_header.CURRENT.last_spectrum;
pub const RUN_HEADER_SPECT_POS = spec_run_header.CURRENT.spect_pos;
pub const RUN_HEADER_PACKET_POS = spec_run_header.CURRENT.packet_pos;
pub const RUN_HEADER_NUM_STATUS_LOG = spec_run_header.CURRENT.num_status_log;
pub const RUN_HEADER_NUM_ERROR_LOG = spec_run_header.CURRENT.num_error_log;
pub const RUN_HEADER_NUM_TRAILER_SCAN_EVENTS = spec_run_header.CURRENT.num_trailer_scan_events;
pub const RUN_HEADER_TRAILER_SCAN_EVENTS_POS = spec_run_header.CURRENT.trailer_scan_events_pos;
pub const RUN_HEADER_NUM_TRAILER_EXTRA = spec_run_header.CURRENT.num_trailer_extra;
pub const RUN_HEADER_NUM_TUNE_DATA = spec_run_header.CURRENT.num_tune_data;
pub const RUN_HEADER_TRAILER_EXTRA_POS = spec_run_header.CURRENT.trailer_extra_pos;
pub const RUN_HEADER_STRUCT_SIZE = spec_run_header.CURRENT.struct_size;

// ScanEventInfoStruct sizes by file revision (from C# Marshal.SizeOf):
pub const SCAN_EVENT_INFO_SIZE = spec_scan_event_info.SIZE_CURRENT;
pub const SCAN_EVENT_INFO_SIZE_LEGACY = spec_scan_event_info.SIZE_LEGACY;

// MsReactionStruct sizes by file revision:
pub const REACTION_SIZE_CURRENT = spec_reaction.SIZE_CURRENT;
pub const REACTION_SIZE_REV65 = spec_reaction.SIZE_REV65;
pub const REACTION_SIZE_LEGACY = spec_reaction.SIZE_LEGACY;

pub const VIRTUAL_DEVICE_MS = spec_raw_info.VIRTUAL_DEVICE_MS;
pub const MAX_STRING_CHARS = spec_raw_info.MAX_STRING_CHARS;

// Spectrum packet types (from Thermo CommonData)
// SpectrumPacketType enum values from ThermoFisher.CommonCore.RawFileReader.
// NOTE: The FUNCTIONALITY_REPORT incorrectly inferred FtCentroid=15, FtProfile=16.
// The ACTUAL raw values in ScanIndexStruct.PacketType (verified from file data) are:
// - MS1 scans: packet_type = 21 (FT_PROFILE)
// - MS2 scans: packet_type = 20 (FT_CENTROID)
// These match the C# code which casts PacketType & 0xFFFF directly to SpectrumPacketType.
pub const PACKET_TYPE_PROFILE_SPECTRUM = @intFromEnum(spec_ph.PacketType.profile_spectrum);
pub const PACKET_TYPE_LOW_RES_SPECTRUM = @intFromEnum(spec_ph.PacketType.low_res_spectrum);
pub const PACKET_TYPE_HIGH_RES_SPECTRUM = @intFromEnum(spec_ph.PacketType.high_res_spectrum);
pub const PACKET_TYPE_PROFILE_INDEX = @intFromEnum(spec_ph.PacketType.profile_index);
pub const PACKET_TYPE_LINEAR_TRAP_PROFILE = @intFromEnum(spec_ph.PacketType.linear_trap_profile);
pub const PACKET_TYPE_STANDARD_ACCURACY = @intFromEnum(spec_ph.PacketType.standard_accuracy); // C# StandardAccuracyPacket
pub const PACKET_TYPE_FT_CENTROID = @intFromEnum(spec_ph.PacketType.ft_centroid);
pub const PACKET_TYPE_LINEAR_TRAP_CENTROID = @intFromEnum(spec_ph.PacketType.linear_trap_centroid); // C# LinearTrapCentroid
pub const PACKET_TYPE_FT_PROFILE = @intFromEnum(spec_ph.PacketType.ft_profile);
pub const PACKET_TYPE_HIGH_RES_COMPRESSED_PROFILE = @intFromEnum(spec_ph.PacketType.high_res_compressed_profile);
pub const PACKET_TYPE_LOW_RES_COMPRESSED_PROFILE = @intFromEnum(spec_ph.PacketType.low_res_compressed_profile);
pub const PACKET_TYPE_LOW_RES_SPECTRUM_TYPE = @intFromEnum(spec_ph.PacketType.low_res_spectrum_type);

/// Returns true for profile-mode packet types.
pub fn is_profile_packet_type(packet_type: u32) bool {
    return packet_type == PACKET_TYPE_PROFILE_SPECTRUM or
        packet_type == PACKET_TYPE_LINEAR_TRAP_PROFILE or
        packet_type == PACKET_TYPE_FT_PROFILE or
        packet_type == PACKET_TYPE_HIGH_RES_COMPRESSED_PROFILE or
        packet_type == PACKET_TYPE_LOW_RES_COMPRESSED_PROFILE;
}
pub const isProfilePacketType = is_profile_packet_type; // DEPRECATED: use is_profile_packet_type

/// Format a scan ID in ThermoRawFileParser-compatible form:
/// `controllerType=0 controllerNumber=1 scan=N`.
/// Every spectrum `id` and `<precursor spectrumRef="...">` must use this
/// exact format for downstream tool compatibility (OpenMS, MSFileReader, pyteomics).
pub const FormatScanIdError = std.mem.Allocator.Error;

pub fn format_scan_id(allocator: std.mem.Allocator, scan_number: i32) FormatScanIdError![]u8 {
    return std.fmt.allocPrint(allocator, "controllerType=0 controllerNumber=1 scan={d}", .{scan_number});
}
pub const formatScanId = format_scan_id; // DEPRECATED: use format_scan_id

pub fn scan_event_info_size(file_revision: u16) u64 {
    return spec_scan_event_info.struct_size(file_revision);
}
pub const scanEventInfoSize = scan_event_info_size; // DEPRECATED: use scan_event_info_size

/// Returns the size of a scan index entry (in bytes) for a given file revision.
pub fn scan_index_size(file_revision: u16) u64 {
    const layout = spec_scan_index.get_layout(file_revision);
    return @as(u64, layout.entry_size);
}
pub const scanIndexSize = scan_index_size; // DEPRECATED: use scan_index_size

pub fn reaction_size(file_revision: u16) u64 {
    return spec_reaction.struct_size(file_revision);
}
pub const reactionSize = reaction_size; // DEPRECATED: use reaction_size
/// This avoids syscalls when the entire scan index table has been batch-read.
pub fn parse_scan_index(bytes: []const u8, offset: usize, file_revision: u16) RawResolveError!ScanIndexEntry {
    const layout = spec_scan_index.get_layout(file_revision);
    const entry_size = std.math.cast(usize, layout.entry_size) orelse return RawResolveError.OffsetOverflow;
    const end = std.math.add(usize, entry_size, offset) catch return RawResolveError.OffsetOverflow;
    if (end > bytes.len) return RawResolveError.Truncated;

    const data_offset_i64 = if (layout.data_offset != 0)
        std.mem.readInt(i64, bytes[offset + layout.data_offset ..][0..8], .little)
    else
        std.mem.readInt(i64, bytes[offset + 0 ..][0..8], .little); // Legacy u32 at 0, but read as i64 for conversion

    // Special case for legacy: data_offset is u32 at 0
    const data_offset_val: u64 = if (layout.data_offset == 0)
        std.mem.readInt(u32, bytes[offset + 0 ..][0..4], .little)
    else
        @bitCast(data_offset_i64);

    if (layout.data_offset != 0 and data_offset_i64 < 0) return RawResolveError.InvalidRawFileInfo;

    // data_size: offset 0 is the DataOffset32Bit for rev < 65, but DataSize (u32) for rev >= 65.
    // Ground truth: Thermo ScanIndexStruct has DataSize at offset 0 (confirmed in decompiled ScanIndices.cs).
    return .{
        .data_size = if (file_revision >= 65)
            std.mem.readInt(u32, bytes[offset + 0 ..][0..4], .little)
        else
            0,
        .trailer_offset = std.mem.readInt(i32, bytes[offset + layout.trailer_offset ..][0..4], .little),
        .scan_type_index = std.mem.readInt(i32, bytes[offset + layout.scan_type_index ..][0..4], .little),
        .scan_number = std.mem.readInt(i32, bytes[offset + layout.scan_number ..][0..4], .little),
        .packet_type = std.mem.readInt(u32, bytes[offset + layout.packet_type ..][0..4], .little),
        .number_packets = std.mem.readInt(i32, bytes[offset + layout.number_packets ..][0..4], .little),
        .data_offset = data_offset_val,
        .start_time = if (layout.start_time == 0) 0 else @bitCast(std.mem.readInt(u64, bytes[offset + layout.start_time ..][0..8], .little)),
        .tic = if (layout.tic == 0) 0 else @bitCast(std.mem.readInt(u64, bytes[offset + layout.tic ..][0..8], .little)),
        .base_peak_intensity = if (layout.base_peak_intensity == 0) 0 else @bitCast(std.mem.readInt(u64, bytes[offset + layout.base_peak_intensity ..][0..8], .little)),
        .base_peak_mass = if (layout.base_peak_mass == 0) 0 else @bitCast(std.mem.readInt(u64, bytes[offset + layout.base_peak_mass ..][0..8], .little)),
        .low_mass = if (layout.low_mass == 0) 0 else @bitCast(std.mem.readInt(u64, bytes[offset + layout.low_mass ..][0..8], .little)),
        .high_mass = if (layout.high_mass == 0) 0 else @bitCast(std.mem.readInt(u64, bytes[offset + layout.high_mass ..][0..8], .little)),
        .cycle_number = if (layout.cycle_number == 0) 0 else std.mem.readInt(i32, bytes[offset + layout.cycle_number ..][0..4], .little),
    };
}
pub const parseScanIndex = parse_scan_index; // DEPRECATED: use parse_scan_index

pub const InstrumentId = struct {
    model: ?[]u8,
    serial: ?[]u8,
    software_version: ?[]u8,
};

pub inline fn readU16Mm(mm: []const u8, offset: u64) RawResolveError!u16 {
    const end = std.math.add(u64, offset, 2) catch return RawResolveError.OffsetOverflow;
    if (end > mm.len) return RawResolveError.Truncated;
    const usz_offset = std.math.cast(usize, offset) orelse return RawResolveError.OffsetOverflow;
    return std.mem.readInt(u16, mm[usz_offset..][0..2], .little);
}

pub inline fn readU32Mm(mm: []const u8, offset: u64) RawResolveError!u32 {
    const end = std.math.add(u64, offset, 4) catch return RawResolveError.OffsetOverflow;
    if (end > mm.len) return RawResolveError.Truncated;
    const usz_offset = std.math.cast(usize, offset) orelse return RawResolveError.OffsetOverflow;
    return std.mem.readInt(u32, mm[usz_offset..][0..4], .little);
}

pub inline fn readI32Mm(mm: []const u8, offset: u64) RawResolveError!i32 {
    return @bitCast(try readU32Mm(mm, offset));
}

pub inline fn readU64Mm(mm: []const u8, offset: u64) RawResolveError!u64 {
    const end = std.math.add(u64, offset, 8) catch return RawResolveError.OffsetOverflow;
    if (end > mm.len) return RawResolveError.Truncated;
    const usz_offset = std.math.cast(usize, offset) orelse return RawResolveError.OffsetOverflow;
    return std.mem.readInt(u64, mm[usz_offset..][0..8], .little);
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

// ---------------------------------------------------------------------------
// Byte-level writers (mirrors read helpers above).
// Callers must guarantee offset + size <= mm.len; serialize_scan_index_entry
// performs this check before calling these helpers.
// ---------------------------------------------------------------------------

pub inline fn writeU16Mm(mm: []u8, offset: u64, value: u16) void {
    // SAFETY: callers (e.g. serialize_scan_index_entry) guarantee offset + size <= mm.len, so offset fits usize.
    std.mem.writeInt(u16, mm[@intCast(offset)..][0..2], value, .little);
}

pub inline fn writeU32Mm(mm: []u8, offset: u64, value: u32) void {
    // SAFETY: callers guarantee offset + 4 <= mm.len, so offset fits usize.
    std.mem.writeInt(u32, mm[@intCast(offset)..][0..4], value, .little);
}

pub inline fn writeI32Mm(mm: []u8, offset: u64, value: i32) void {
    writeU32Mm(mm, offset, @bitCast(value));
}

pub inline fn writeU64Mm(mm: []u8, offset: u64, value: u64) void {
    // SAFETY: callers guarantee offset + 8 <= mm.len, so offset fits usize.
    std.mem.writeInt(u64, mm[@intCast(offset)..][0..8], value, .little);
}

pub inline fn writeI64Mm(mm: []u8, offset: u64, value: i64) void {
    writeU64Mm(mm, offset, @bitCast(value));
}

pub inline fn writeF64Mm(mm: []u8, offset: u64, value: f64) void {
    writeU64Mm(mm, offset, @bitCast(value));
}

/// Serialize a ScanIndexEntry back to bytes at `offset` in `mm`.
/// `size` is the struct size for this file revision (from scanIndexSize).
/// Unknown trailing bytes are zeroed.
pub fn serialize_scan_index_entry(mm: []u8, offset: usize, entry: ScanIndexEntry, size: u64, file_revision: u16) RawResolveError!void {
    const size_usz = std.math.cast(usize, size) orelse return RawResolveError.OffsetOverflow;
    const end = std.math.add(usize, offset, size_usz) catch return RawResolveError.OffsetOverflow;
    if (end > mm.len) return;
    const layout = spec_scan_index.get_layout(file_revision);

    // data_size: for rev >= 65 it's at offset 0 (ground truth: Thermo ScanIndices.cs).
    // For rev < 65, offset 0 is DataOffset32Bit — do not overwrite data_size there.
    // SAFETY: all `offset + field_offset` addresses are bounded by `end <= mm.len`.
    if (file_revision >= 65) writeU32Mm(mm, offset + 0, entry.data_size);
    writeI32Mm(mm, offset + layout.trailer_offset, entry.trailer_offset);
    writeI32Mm(mm, offset + layout.scan_type_index, entry.scan_type_index);
    writeI32Mm(mm, offset + layout.scan_number, entry.scan_number);
    writeU32Mm(mm, offset + layout.packet_type, entry.packet_type);
    writeI32Mm(mm, offset + layout.number_packets, entry.number_packets);

    if (layout.start_time != 0) writeF64Mm(mm, offset + layout.start_time, entry.start_time);
    if (layout.tic != 0) writeF64Mm(mm, offset + layout.tic, entry.tic);
    if (layout.base_peak_intensity != 0) writeF64Mm(mm, offset + layout.base_peak_intensity, entry.base_peak_intensity);
    if (layout.base_peak_mass != 0) writeF64Mm(mm, offset + layout.base_peak_mass, entry.base_peak_mass);
    if (layout.low_mass != 0) writeF64Mm(mm, offset + layout.low_mass, entry.low_mass);
    if (layout.high_mass != 0) writeF64Mm(mm, offset + layout.high_mass, entry.high_mass);
    if (layout.cycle_number != 0) writeI32Mm(mm, offset + layout.cycle_number, entry.cycle_number);

    const data_offset_i64 = std.math.cast(i64, entry.data_offset) orelse return RawResolveError.OffsetOverflow;
    writeI64Mm(mm, offset + layout.data_offset, data_offset_i64);

    // Zero trailing bytes if the entry size is larger than the fields we wrote.
    // Rev >= 65 has data_offset at 72 (ends at 80) and cycle_number at 80 (ends at 84),
    // leaving 4 trailing bytes (84..88) to zero. Rev 64 has no cycle_number and ends at 80.
    const cycle_end: u32 = if (layout.cycle_number != 0) layout.cycle_number + 4 else 0;
    const data_offset_end = layout.data_offset + 8;
    const last_field_end = @max(data_offset_end, cycle_end);
    const last_field_end_usz = std.math.cast(usize, last_field_end) orelse return RawResolveError.OffsetOverflow;
    if (size > last_field_end) {
        const zero_start = std.math.add(usize, offset, last_field_end_usz) catch return RawResolveError.OffsetOverflow;
        @memset(mm[zero_start..end], 0);
    }
}
pub const serializeScanIndexEntry = serialize_scan_index_entry; // DEPRECATED: use serialize_scan_index_entry

/// Returns an allocator-owned UTF-8 string. Caller must free.
pub const ScanEventInfo = struct {
    // offsets 0-11: 12 byte fields (tightly packed, no alignment needed)
    is_valid: u8, // 0
    is_custom: u8, // 1
    corona: u8, // 2
    detector: u8, // 3
    polarity: u8, // 4
    scan_data_type: u8, // 5
    ms_order: i8, // 6
    scan_type: u8, // 7
    source_fragmentation: u8, // 8
    turbo_scan: u8, // 9
    dependent_data: u8, // 10
    ionization_mode: u8, // 11

    // offset 12-15: padding to align next double to 8
    _pad1: [4]u8,

    // offset 16-23
    detector_value: f64, // 16

    // offset 24
    source_fragmentation_type: u8, // 24

    // offset 25-27: padding to align next int to 4
    _pad2: [3]u8,

    // offset 28-31
    scan_type_index: i32, // 28

    // offset 32
    wideband: u8, // 32

    // offset 33-35: padding to align next int enum to 4
    _pad3: [3]u8,

    // offset 36-39 (C# enum = int)
    accurate_mass_type: u32, // 36

    // offset 40-46: 7 byte fields (tightly packed)
    mass_analyzer_type: u8, // 40
    sector_scan: u8, // 41
    lock: u8, // 42
    free_region: u8, // 43
    ultra: u8, // 44
    enhanced: u8, // 45
    mpd_type: u8, // 46

    // offset 47: padding to align next double to 8
    _pad4: u8,

    // offset 48-55
    mpd_value: f64, // 48

    // offset 56
    ecd_type: u8, // 56

    // offset 57-63: padding to align next double to 8
    _pad5: [7]u8,

    // offset 64-71
    ecd_value: f64, // 64

    // offset 72-73: 2 byte fields
    photo_ionization: u8, // 72
    pqd_type: u8, // 73

    // offset 74-79: padding to align next double to 8
    _pad6: [6]u8,

    // offset 80-87
    pqd_value: f64, // 80

    // offset 88
    etd_type: u8, // 88

    // offset 89-95: padding to align next double to 8
    _pad7: [7]u8,

    // offset 96-103
    etd_value: f64, // 96

    // offset 104
    hcd_type: u8, // 104

    // offset 105-111: padding to align next double to 8
    _pad8: [7]u8,

    // offset 112-119
    hcd_value: f64, // 112

    // offset 120-130: 11 byte fields (tightly packed)
    supplemental_activation: u8, // 120
    multi_state_activation: u8, // 121
    compensation_voltage: u8, // 122
    compensation_voltage_type: u8, // 123
    multiplex: u8, // 124
    param_a: u8, // 125
    param_b: u8, // 126
    param_f: u8, // 127
    sps_multi_notch: u8, // 128
    param_r: u8, // 129
    param_v: u8, // 130

    // offset 131-135: padding to round total to multiple of 8
    _pad9: [5]u8,

    /// Parse from byte slice at given offset.
    /// `size` is the actual struct size for this file revision (24/32/40/80/136).
    pub fn read(bytes: []const u8, offset: usize, size: u64) RawResolveError!ScanEventInfo {
        const size_usz = std.math.cast(usize, size) orelse return RawResolveError.OffsetOverflow;
        const end = std.math.add(usize, offset, size_usz) catch return RawResolveError.OffsetOverflow;
        if (end > bytes.len) return RawResolveError.Truncated;
        var info = std.mem.zeroes(ScanEventInfo);

        const sei = spec_scan_event_info;

        // Offsets 0-23: present in all versions (legacy = 24 bytes)
        if (size >= sei.SIZE_LEGACY) {
            info.is_valid = bytes[offset + sei.is_valid];
            info.is_custom = bytes[offset + sei.is_custom];
            info.corona = bytes[offset + sei.corona];
            info.detector = bytes[offset + sei.detector];
            info.polarity = bytes[offset + sei.polarity];
            info.scan_data_type = bytes[offset + sei.scan_data_type];
            info.ms_order = std.math.cast(i8, bytes[offset + sei.ms_order]) orelse return RawResolveError.InvalidRawFileInfo;
            info.scan_type = bytes[offset + sei.scan_type];
            info.source_fragmentation = bytes[offset + sei.source_fragmentation];
            info.turbo_scan = bytes[offset + sei.turbo_scan];
            info.dependent_data = bytes[offset + sei.dependent_data];
            info.ionization_mode = bytes[offset + sei.ionization_mode];
            info._pad1 = bytes[offset + sei.ionization_mode + 1 ..][0..4].*;
            info.detector_value = @bitCast(std.mem.readInt(u64, bytes[offset + sei.detector_value ..][0..8], .little));
        }

        // Offsets 24-31: rev >= 31 (Struct3 = 32 bytes)
        if (size >= sei.SIZE_REV31) {
            info.source_fragmentation_type = bytes[offset + sei.source_fragmentation_type];
            info._pad2 = bytes[offset + sei.source_fragmentation_type + 1 ..][0..3].*;
            info.scan_type_index = std.mem.readInt(i32, bytes[offset + sei.scan_type_index ..][0..4], .little);
        }

        // Offsets 32-39: rev >= 48 (Struct50/51 = 40 bytes)
        if (size >= sei.SIZE_REV48) {
            info.wideband = bytes[offset + sei.wideband];
            info._pad3 = bytes[offset + sei.wideband + 1 ..][0..3].*;
            info.accurate_mass_type = std.mem.readInt(u32, bytes[offset + sei.accurate_mass_type ..][0..4], .little);
        }

        // Offsets 40-79: rev 54-61 (Struct54 = 80 bytes)
        if (size >= sei.SIZE_REV54) {
            info.mass_analyzer_type = bytes[offset + sei.mass_analyzer_type];
            info.sector_scan = bytes[offset + sei.sector_scan];
            info.lock = bytes[offset + sei.lock];
            info.free_region = bytes[offset + sei.free_region];
            info.ultra = bytes[offset + sei.ultra];
            info.enhanced = bytes[offset + sei.enhanced];
            info.mpd_type = bytes[offset + sei.mpd_type];
            info._pad4 = bytes[offset + sei.mpd_type + 1];
            info.mpd_value = @bitCast(std.mem.readInt(u64, bytes[offset + sei.mpd_value ..][0..8], .little));
            info.ecd_type = bytes[offset + sei.ecd_type];
            info._pad5 = bytes[offset + sei.ecd_type + 1 ..][0..7].*;
            info.ecd_value = @bitCast(std.mem.readInt(u64, bytes[offset + sei.ecd_value ..][0..8], .little));
            info.photo_ionization = bytes[offset + sei.photo_ionization];
            info.pqd_type = bytes[offset + sei.pqd_type];
            info._pad6 = bytes[offset + sei.pqd_type + 1 ..][0..6].*;
        }

        // Offsets 80-119: rev >= 62 (Struct62 = 120 bytes)
        if (size >= sei.SIZE_REV62) {
            info.pqd_value = @bitCast(std.mem.readInt(u64, bytes[offset + sei.pqd_value ..][0..8], .little));
            info.etd_type = bytes[offset + sei.etd_type];
            info._pad7 = bytes[offset + sei.etd_type + 1 ..][0..7].*;
            info.etd_value = @bitCast(std.mem.readInt(u64, bytes[offset + sei.etd_value ..][0..8], .little));
            info.hcd_type = bytes[offset + sei.hcd_type];
            info._pad8 = bytes[offset + sei.hcd_type + 1 ..][0..7].*;
            info.hcd_value = @bitCast(std.mem.readInt(u64, bytes[offset + sei.hcd_value ..][0..8], .little));
        }

        // Offsets 120-123: rev >= 63 (Struct63 = 128 bytes)
        if (size >= sei.SIZE_REV63) {
            info.supplemental_activation = bytes[offset + sei.supplemental_activation];
            info.multi_state_activation = bytes[offset + sei.multi_state_activation];
            info.compensation_voltage = bytes[offset + sei.compensation_voltage];
            info.compensation_voltage_type = bytes[offset + sei.compensation_voltage_type];
        }

        // Offsets 124-135: rev >= 65 (full 136 bytes)
        if (size >= sei.SIZE_CURRENT) {
            info.multiplex = bytes[offset + sei.multiplex];
            info.param_a = bytes[offset + sei.param_a];
            info.param_b = bytes[offset + sei.param_b];
            info.param_f = bytes[offset + sei.param_f];
            info.sps_multi_notch = bytes[offset + sei.sps_multi_notch];
            info.param_r = bytes[offset + sei.param_r];
            info.param_v = bytes[offset + sei.param_v];
            info._pad9 = bytes[offset + sei.param_v + 1 ..][0..5].*;
        }

        return info;
    }
};

/// Reaction struct (56 bytes, file rev >= 66)
/// C#: Marshal.SizeOf(typeof(MsReactionStruct)) = 56
pub const Reaction = struct {
    precursor_mass: f64, // offset 0
    isolation_width: f64, // offset 8
    collision_energy: f64, // offset 16
    collision_energy_valid: u32, // offset 24 (C# bool marshals as 4 bytes)
    range_is_valid: u32, // offset 28
    first_precursor_mass: f64, // offset 32
    last_precursor_mass: f64, // offset 40
    isolation_width_offset: f64, // offset 48

    /// Parse from byte slice at given offset.
    /// `size` is the revision-specific Reaction struct size (24/32/48/56).
    pub fn read(bytes: []const u8, offset: usize, size: u64) RawResolveError!Reaction {
        const size_usz = std.math.cast(usize, size) orelse return RawResolveError.OffsetOverflow;
        const end = std.math.add(usize, offset, size_usz) catch return RawResolveError.OffsetOverflow;
        if (end > bytes.len) return RawResolveError.Truncated;
        const sr = spec_reaction;

        var rxn: Reaction = .{
            .precursor_mass = @bitCast(std.mem.readInt(u64, bytes[offset + sr.precursor_mass ..][0..8], .little)),
            .isolation_width = @bitCast(std.mem.readInt(u64, bytes[offset + sr.isolation_width ..][0..8], .little)),
            .collision_energy = @bitCast(std.mem.readInt(u64, bytes[offset + sr.collision_energy ..][0..8], .little)),
            .collision_energy_valid = 1,
            .range_is_valid = 0,
            .first_precursor_mass = 0.0,
            .last_precursor_mass = 0.0,
            .isolation_width_offset = 0.0,
        };

        if (size >= 32) {
            rxn.collision_energy_valid = std.mem.readInt(u32, bytes[offset + sr.collision_energy_valid ..][0..4], .little);
            rxn.range_is_valid = std.mem.readInt(u32, bytes[offset + sr.range_is_valid ..][0..4], .little);
        }
        if (size >= 48) {
            rxn.first_precursor_mass = @bitCast(std.mem.readInt(u64, bytes[offset + sr.first_precursor_mass ..][0..8], .little));
            rxn.last_precursor_mass = @bitCast(std.mem.readInt(u64, bytes[offset + sr.last_precursor_mass ..][0..8], .little));
        }
        if (size >= 56) {
            rxn.isolation_width_offset = @bitCast(std.mem.readInt(u64, bytes[offset + sr.isolation_width_offset ..][0..8], .little));
        }

        return rxn;
    }
};

/// ScanEventMassRange struct (16 bytes: f64 low + f64 high)
pub const ScanEventMassRange = struct {
    low: f64,
    high: f64,
};

// ============================================================================
// Unit tests
// ============================================================================

test "scanIndexSize returns expected values by revision" {
    try std.testing.expectEqual(@as(u64, 80), scan_index_size(64));
    try std.testing.expectEqual(@as(u64, 88), scan_index_size(65));
    try std.testing.expectEqual(@as(u64, 88), scan_index_size(66));
}

test "scanEventInfoSize returns expected values by revision" {
    // Verified by Marshal.SizeOf on ThermoFisher.CommonCore.RawFileReader.dll
    try std.testing.expectEqual(@as(u64, 24), scan_event_info_size(30)); // < 31
    try std.testing.expectEqual(@as(u64, 32), scan_event_info_size(31)); // 31-47
    try std.testing.expectEqual(@as(u64, 32), scan_event_info_size(47)); // 31-47
    try std.testing.expectEqual(@as(u64, 40), scan_event_info_size(48)); // 48-50
    try std.testing.expectEqual(@as(u64, 40), scan_event_info_size(50)); // 48-50
    try std.testing.expectEqual(@as(u64, 40), scan_event_info_size(51)); // 51-53
    try std.testing.expectEqual(@as(u64, 40), scan_event_info_size(53)); // 51-53
    try std.testing.expectEqual(@as(u64, 80), scan_event_info_size(54)); // 54-61
    try std.testing.expectEqual(@as(u64, 80), scan_event_info_size(61)); // 54-61
    try std.testing.expectEqual(@as(u64, 120), scan_event_info_size(62)); // 62
    try std.testing.expectEqual(@as(u64, 128), scan_event_info_size(63)); // 63-64
    try std.testing.expectEqual(@as(u64, 128), scan_event_info_size(64)); // 63-64
    try std.testing.expectEqual(@as(u64, 136), scan_event_info_size(65)); // >= 65
    try std.testing.expectEqual(@as(u64, 136), scan_event_info_size(66)); // >= 65
}

test "reactionSize returns expected values by revision" {
    try std.testing.expectEqual(@as(u64, 24), reaction_size(30));
    try std.testing.expectEqual(@as(u64, 32), reaction_size(31));
    try std.testing.expectEqual(@as(u64, 32), reaction_size(64));
    try std.testing.expectEqual(@as(u64, 48), reaction_size(65));
    try std.testing.expectEqual(@as(u64, 56), reaction_size(66));
}

test "parse_scan_index and serialize_scan_index_entry round-trip rev 66" {
    var buf: [88]u8 = undefined;
    @memset(&buf, 0);

    const entry = ScanIndexEntry{
        .data_size = 1234, // rev >= 65 stores DataSize at offset 0 (ground truth: Thermo ScanIndices.cs)
        .trailer_offset = 100,
        .scan_type_index = 1,
        .scan_number = 42,
        .packet_type = 20,
        .number_packets = 1,
        .data_offset = 98765,
        .start_time = 12.34,
        .tic = 56789.0,
        .base_peak_intensity = 1000.5,
        .base_peak_mass = 500.25,
        .low_mass = 100.0,
        .high_mass = 1000.0,
        .cycle_number = 7,
    };

    try serialize_scan_index_entry(&buf, 0, entry, 88, 66);
    const parsed = try parse_scan_index(&buf, 0, 66);

    // data_size IS stored in rev >= 65 scan index binary layout at offset 0
    try std.testing.expectEqual(entry.data_size, parsed.data_size);
    try std.testing.expectEqual(entry.scan_number, parsed.scan_number);
    try std.testing.expectEqual(entry.packet_type, parsed.packet_type);
    try std.testing.expectEqual(entry.data_offset, parsed.data_offset);
    try std.testing.expectEqual(entry.cycle_number, parsed.cycle_number);
}

test "serialize_scan_index_entry rejects data_offset that overflows i64" {
    var buf: [88]u8 = undefined;
    @memset(&buf, 0);
    var entry: ScanIndexEntry = std.mem.zeroes(ScanIndexEntry);
    entry.data_offset = std.math.maxInt(i64) + 1;
    try std.testing.expectError(RawResolveError.OffsetOverflow, serialize_scan_index_entry(&buf, 0, entry, 88, 66));
}

test "readU32Mm and writeU32Mm round-trip" {
    var buf: [4]u8 = undefined;
    writeU32Mm(&buf, 0, 0xDEADBEEF);
    const val = try readU32Mm(&buf, 0);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), val);
}

test "readF64Mm and writeF64Mm round-trip" {
    var buf: [8]u8 = undefined;
    writeF64Mm(&buf, 0, 3.1415926535);
    const val = try readF64Mm(&buf, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 3.1415926535), val, 1e-10);
}
