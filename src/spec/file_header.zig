/// Structural layout of the Thermo RAW file header region.
/// Offsets are absolute bytes from the start of the file.
///
/// Sources:
/// - FILE_REV_OFFSET: offset 36 in all known revisions
/// - FILE_HEADER_SIZE: 1356 bytes (end of header, start of sequence row)
/// - Creation time: Windows FILETIME at offsets 40-47
pub const FILE_REV_OFFSET: u64 = 36;
pub const FILE_HEADER_SIZE: u64 = 1356;

/// Windows FILETIME stores creation time as two u32 halves.
/// Low dword at offset 40, high dword at offset 44.
pub const CREATION_TIME_LOW_OFFSET: u64 = 40;
pub const CREATION_TIME_HIGH_OFFSET: u64 = 44;

/// Sequence row info struct size (precedes the string table).
pub const SEQ_ROW_INFO_SIZE: u64 = 64;

/// Auto-sampler config struct size (rev >= 36).
pub const AUTO_SAMPLER_CONFIG_SIZE: u64 = 24;

test "file header constants are non-zero" {
    const std = @import("std");
    try std.testing.expect(FILE_REV_OFFSET > 0);
    try std.testing.expect(FILE_HEADER_SIZE > FILE_REV_OFFSET);
    try std.testing.expect(CREATION_TIME_LOW_OFFSET < CREATION_TIME_HIGH_OFFSET);
}
