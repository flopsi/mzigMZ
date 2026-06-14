/// Structural layout of the RawInfo / controller table region.
/// Offsets are bytes from the start of the RawInfo struct (after sequence row + auto sampler).
///
/// Verified from decompiled ThermoFisher.CommonCore.RawFileReader.
pub const Layout = struct {
    num_controllers: u32,
    controller_table: u32,
    controller_size: u32,
    controller_type: u32,
    controller_offset: u32,
    /// Total size of the RawInfo / controller table region.
    /// Verified from decompiled ThermoFisher.CommonCore.RawFileReader (RawInfo struct ~1024 bytes).
    struct_size: u64,
};

/// Current layout for file rev >= 65.
pub const CURRENT = Layout{
    .num_controllers = 28,
    .controller_table = 816,
    .controller_size = 16,
    .controller_type = 0,
    .controller_offset = 8,
    .struct_size = 1024,
};

/// Virtual device type constant for MS controller.
pub const VIRTUAL_DEVICE_MS: i32 = 0;

/// Maximum string length for wide-string reads (safety bound).
pub const MAX_STRING_CHARS: u32 = 1_000_000;

test "raw info layout offsets are non-zero" {
    const std = @import("std");
    try std.testing.expect(CURRENT.num_controllers > 0);
    try std.testing.expect(CURRENT.controller_table > CURRENT.num_controllers);
    try std.testing.expect(CURRENT.controller_size > 0);
    try std.testing.expect(CURRENT.struct_size > CURRENT.controller_table);
}
