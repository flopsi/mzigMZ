/// Structural layout of ScanEventInfoStruct.
/// Field offsets are bytes from the start of the struct.
/// These offsets are FIXED across all revisions; smaller revisions simply
/// truncate the struct at an earlier point.
///
/// Sources (runtime Marshal.SizeOf from ThermoFisher.CommonCore.RawFileReader.dll):
/// - rev < 31:  ScanEventInfoStruct2  = 24 bytes
/// - rev 31-47: ScanEventInfoStruct3  = 32 bytes
/// - rev 48-50: ScanEventInfoStruct50 = 40 bytes
/// - rev 51-53: ScanEventInfoStruct51 = 40 bytes
/// - rev 54-61: ScanEventInfoStruct54 = 80 bytes
/// - rev 62:    ScanEventInfoStruct62 = 120 bytes
/// - rev 63-64: ScanEventInfoStruct63 = 128 bytes
/// - rev >= 65: ScanEventInfoStruct   = 136 bytes

// --- Offsets 0-23: present in all versions ---
pub const is_valid: u32 = 0;
pub const is_custom: u32 = 1;
pub const corona: u32 = 2;
pub const detector: u32 = 3;
pub const polarity: u32 = 4;
pub const scan_data_type: u32 = 5;
pub const ms_order: u32 = 6;
pub const scan_type: u32 = 7;
pub const source_fragmentation: u32 = 8;
pub const turbo_scan: u32 = 9;
pub const dependent_data: u32 = 10;
pub const ionization_mode: u32 = 11;

// Padding: offsets 12-15 (4 bytes, aligns detector_value to 8)
pub const detector_value: u32 = 16;

// --- Offsets 24-31: rev >= 31 ---
pub const source_fragmentation_type: u32 = 24;
// Padding: offsets 25-27 (3 bytes, aligns scan_type_index to 4)
pub const scan_type_index: u32 = 28;

// --- Offsets 32-39: rev >= 48 ---
pub const wideband: u32 = 32;
// Padding: offsets 33-35 (3 bytes, aligns accurate_mass_type to 4)
pub const accurate_mass_type: u32 = 36;

// --- Offsets 40-79: rev >= 54 ---
pub const mass_analyzer_type: u32 = 40;
pub const sector_scan: u32 = 41;
pub const lock: u32 = 42;
pub const free_region: u32 = 43;
pub const ultra: u32 = 44;
pub const enhanced: u32 = 45;
pub const mpd_type: u32 = 46;
// Padding: offset 47 (1 byte, aligns mpd_value to 8)
pub const mpd_value: u32 = 48;
pub const ecd_type: u32 = 56;
// Padding: offsets 57-63 (7 bytes, aligns ecd_value to 8)
pub const ecd_value: u32 = 64;
pub const photo_ionization: u32 = 72;
pub const pqd_type: u32 = 73;
// Padding: offsets 74-79 (6 bytes, aligns pqd_value to 8)

// --- Offsets 80-135: rev >= 65 ---
pub const pqd_value: u32 = 80;
pub const etd_type: u32 = 88;
// Padding: offsets 89-95 (7 bytes, aligns etd_value to 8)
pub const etd_value: u32 = 96;
pub const hcd_type: u32 = 104;
// Padding: offsets 105-111 (7 bytes, aligns hcd_value to 8)
pub const hcd_value: u32 = 112;
pub const supplemental_activation: u32 = 120;
pub const multi_state_activation: u32 = 121;
pub const compensation_voltage: u32 = 122;
pub const compensation_voltage_type: u32 = 123;
pub const multiplex: u32 = 124;
pub const param_a: u32 = 125;
pub const param_b: u32 = 126;
pub const param_f: u32 = 127;
pub const sps_multi_notch: u32 = 128;
pub const param_r: u32 = 129;
pub const param_v: u32 = 130;
// Padding: offsets 131-135 (5 bytes, rounds total to multiple of 8)

// --- Struct sizes by revision ---
pub const SIZE_LEGACY: u64 = 24; // rev < 31
pub const SIZE_REV31: u64 = 32; // rev 31-47
pub const SIZE_REV48: u64 = 40; // rev 48-50
pub const SIZE_REV51: u64 = 40; // rev 51-53
pub const SIZE_REV54: u64 = 80; // rev 54-61
pub const SIZE_REV62: u64 = 120; // rev 62
pub const SIZE_REV63: u64 = 128; // rev 63-64
pub const SIZE_CURRENT: u64 = 136; // rev >= 65

/// Returns the ScanEventInfo struct size for a given file revision.
pub fn struct_size(revision: u16) u64 {
    if (revision >= 65) return SIZE_CURRENT;
    if (revision >= 63) return SIZE_REV63;
    if (revision >= 62) return SIZE_REV62;
    if (revision >= 54) return SIZE_REV54;
    if (revision >= 51) return SIZE_REV51;
    if (revision >= 48) return SIZE_REV48;
    if (revision >= 31) return SIZE_REV31;
    return SIZE_LEGACY;
}

// ============================================================================
// Enum value tables — Thermo-defined codes for ScanEventInfo fields.
// These are the canonical string labels for each integer code in the binary
// struct. Verified from decompiled ThermoFisher.CommonCore.RawFileReader.
// ============================================================================

/// Polarity codes (field offset 4).
pub const Polarity = enum(u8) {
    negative = 0,
    positive = 1,
    _,
    pub fn label(p: Polarity) []const u8 {
        return switch (p) {
            .negative => "-",
            .positive => "+",
            _ => "?",
        };
    }
};

/// Scan data type codes (field offset 5).
pub const ScanDataType = enum(u8) {
    centroid = 0,
    profile = 1,
    _,
    pub fn label(dt: ScanDataType) []const u8 {
        return switch (dt) {
            .centroid => "c",
            .profile => "p",
            _ => "?",
        };
    }
};

/// Scan type codes (field offset 7).
pub const ScanType = enum(u8) {
    full = 0,
    zoom = 1,
    sim = 2,
    srm = 3,
    crm = 4,
    _,
    pub fn label(st: ScanType) []const u8 {
        return switch (st) {
            .full => "Full",
            .zoom => "Zoom",
            .sim => "SIM",
            .srm => "SRM",
            .crm => "CRM",
            _ => "?",
        };
    }
};

/// Ionization mode codes (field offset 11).
pub const IonizationMode = enum(u8) {
    ei = 0,
    ci = 1,
    fab = 2,
    esi = 3,
    apci = 4,
    nsi = 5,
    tsp = 6,
    fd = 7,
    maldi = 8,
    gd = 9,
    any = 10,
    psi = 11,
    cnsi = 12,
    im1 = 13,
    im2 = 14,
    _,
    pub fn label(im: IonizationMode) []const u8 {
        return switch (im) {
            .ei => "EI",
            .ci => "CI",
            .fab => "FAB",
            .esi => "ESI",
            .apci => "APCI",
            .nsi => "NSI",
            .tsp => "TSP",
            .fd => "FD",
            .maldi => "MALDI",
            .gd => "GD",
            .any => "",
            .psi => "PSI",
            .cnsi => "cNSI",
            .im1 => "IM1",
            .im2 => "IM2",
            _ => "?",
        };
    }
};

/// Mass analyzer type codes (field offset 40, rev >= 54).
pub const MassAnalyzerType = enum(u8) {
    ion_trap = 0,
    triple_quad = 1,
    single_quad = 2,
    tof = 3,
    orbitrap = 4,
    sector = 5,
    astral = 7,
    _,
    pub fn label(mat: MassAnalyzerType) []const u8 {
        return switch (mat) {
            .ion_trap => "ITMS",
            .triple_quad => "TQMS",
            .single_quad => "SQMS",
            .tof => "TOFMS",
            .orbitrap => "FTMS",
            .sector => "Sector",
            .astral => "ASTMS",
            _ => "",
        };
    }
};

test "structSize returns expected values by revision" {
    const std = @import("std");
    // Sizes verified by Marshal.SizeOf on ThermoFisher.CommonCore.RawFileReader.dll
    try std.testing.expectEqual(@as(u64, 24), struct_size(30)); // < 31
    try std.testing.expectEqual(@as(u64, 32), struct_size(31)); // 31-47
    try std.testing.expectEqual(@as(u64, 40), struct_size(48)); // 48-50
    try std.testing.expectEqual(@as(u64, 40), struct_size(50)); // 48-50
    try std.testing.expectEqual(@as(u64, 40), struct_size(51)); // 51-53
    try std.testing.expectEqual(@as(u64, 40), struct_size(53)); // 51-53
    try std.testing.expectEqual(@as(u64, 80), struct_size(54)); // 54-61
    try std.testing.expectEqual(@as(u64, 80), struct_size(61)); // 54-61
    try std.testing.expectEqual(@as(u64, 120), struct_size(62)); // 62
    try std.testing.expectEqual(@as(u64, 128), struct_size(63)); // 63-64
    try std.testing.expectEqual(@as(u64, 128), struct_size(64)); // 63-64
    try std.testing.expectEqual(@as(u64, 136), struct_size(65)); // >= 65
    try std.testing.expectEqual(@as(u64, 136), struct_size(100)); // >= 65
}

test "field offsets are monotonic within each block" {
    const std = @import("std");
    // Block 0-23
    try std.testing.expect(is_valid < is_custom);
    try std.testing.expect(ionization_mode < detector_value);

    // Block 24-31
    try std.testing.expect(source_fragmentation_type < scan_type_index);

    // Block 32-39
    try std.testing.expect(wideband < accurate_mass_type);

    // Block 40-79
    try std.testing.expect(mass_analyzer_type < mpd_value);
    try std.testing.expect(mpd_value < ecd_type);
    try std.testing.expect(ecd_type < ecd_value);
    try std.testing.expect(ecd_value < photo_ionization);

    // Block 80-135
    try std.testing.expect(pqd_value < etd_type);
    try std.testing.expect(etd_type < etd_value);
    try std.testing.expect(etd_value < hcd_type);
    try std.testing.expect(hcd_type < hcd_value);
    try std.testing.expect(hcd_value < supplemental_activation);
}
