/// Structural layout of the InstIdInfoStruct.
/// This struct immediately follows the RunHeader at controller_offset + run_header_size.
///
/// C# layout: IsValid (u32) + AbsorbanceUnit (u32) = 8 bytes total.
pub const INST_ID_INFO_SIZE: u64 = 8;

/// Offset of IsValid field within InstIdInfoStruct.
pub const IS_VALID_OFFSET: u64 = 0;

/// Offset of AbsorbanceUnit field within InstIdInfoStruct.
pub const ABSORBANCE_UNIT_OFFSET: u64 = 4;

test "instrument id info size is 8 bytes" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 8), INST_ID_INFO_SIZE);
}
