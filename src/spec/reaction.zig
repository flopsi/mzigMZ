/// Structural layout of the MsReactionStruct.
/// Offsets are bytes from the start of the struct.
///
/// Sizes by file revision (verified from decompiled ThermoFisher.CommonCore.RawFileReader):
/// - rev < 31:  MsReactionStruct1 = 24 bytes
/// - rev 31-64: MsReactionStruct2 = 32 bytes
/// - rev 65:    MsReactionStruct3 = 48 bytes
/// - rev >= 66: MsReactionStruct  = 56 bytes
pub const precursor_mass: u32 = 0;
pub const isolation_width: u32 = 8;
pub const collision_energy: u32 = 16;
pub const collision_energy_valid: u32 = 24; // C# bool marshals as 4 bytes
pub const range_is_valid: u32 = 28;
pub const first_precursor_mass: u32 = 32;
pub const last_precursor_mass: u32 = 40;
pub const isolation_width_offset: u32 = 48;

pub const SIZE_LEGACY: u64 = 24; // rev < 31
pub const SIZE_REV31: u64 = 32; // rev 31-64
pub const SIZE_REV65: u64 = 48; // rev 65
pub const SIZE_CURRENT: u64 = 56; // rev >= 66

/// Returns the Reaction struct size for a given file revision.
pub fn struct_size(revision: u16) u64 {
    if (revision >= 66) return SIZE_CURRENT;
    if (revision >= 65) return SIZE_REV65;
    if (revision >= 31) return SIZE_REV31;
    return SIZE_LEGACY;
}

test "structSize returns expected values by revision" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 24), struct_size(30));
    try std.testing.expectEqual(@as(u64, 32), struct_size(31));
    try std.testing.expectEqual(@as(u64, 32), struct_size(64));
    try std.testing.expectEqual(@as(u64, 48), struct_size(65));
    try std.testing.expectEqual(@as(u64, 56), struct_size(66));
    try std.testing.expectEqual(@as(u64, 56), struct_size(100));
}

test "field offsets are monotonic" {
    const std = @import("std");
    try std.testing.expect(precursor_mass < isolation_width);
    try std.testing.expect(isolation_width < collision_energy);
    try std.testing.expect(collision_energy < collision_energy_valid);
    try std.testing.expect(collision_energy_valid < range_is_valid);
    try std.testing.expect(range_is_valid < first_precursor_mass);
    try std.testing.expect(first_precursor_mass < last_precursor_mass);
    try std.testing.expect(last_precursor_mass < isolation_width_offset);
}
