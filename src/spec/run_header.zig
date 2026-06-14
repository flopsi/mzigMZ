/// Structural layout of the RunHeader struct.
/// Offsets are bytes from the start of the RunHeader (i.e., from controller_offset).
///
/// Verified from decompiled ThermoFisher.CommonCore.RawFileReader:
/// RunHeaderStruct5 (rev 64-65) and RunHeaderStruct (rev >= 66) both marshal to 7576 bytes.
pub const Layout = struct {
    first_spectrum: u32,
    last_spectrum: u32,
    num_status_log: u32,
    num_error_log: u32,
    spect_pos: u32,
    packet_pos: u32,
    num_trailer_scan_events: u32,
    trailer_scan_events_pos: u32,
    num_trailer_extra: u32,
    num_tune_data: u32,
    trailer_extra_pos: u32,
    struct_size: u64,
};

/// Current layout for file rev >= 64.
/// All offsets are stable across rev 64, 65, and 66.
pub const CURRENT = Layout{
    .first_spectrum = 8,
    .last_spectrum = 12,
    .num_status_log = 16,
    .num_error_log = 20,
    .spect_pos = 7408,
    .packet_pos = 7416,
    .num_trailer_scan_events = 7376,
    .trailer_scan_events_pos = 7448,
    .num_trailer_extra = 7380,
    .num_tune_data = 7384,
    .trailer_extra_pos = 7456,
    .struct_size = 7576,
};

/// Returns the struct size for a given file revision.
/// Currently only one size is known (7576 bytes for rev >= 64).
pub fn struct_size(revision: u16) u64 {
    // All known revisions use the same RunHeader struct size.
    // Parameter reserved for future revision-specific sizes.
    _ = revision;
    return CURRENT.struct_size;
}

test "run header layout offsets are monotonic" {
    const std = @import("std");
    try std.testing.expect(CURRENT.first_spectrum < CURRENT.last_spectrum);
    try std.testing.expect(CURRENT.last_spectrum < CURRENT.spect_pos);
    try std.testing.expect(CURRENT.packet_pos < CURRENT.trailer_scan_events_pos);
    try std.testing.expect(CURRENT.struct_size > CURRENT.trailer_scan_events_pos);
}

test "structSize returns constant for all revisions" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 7576), struct_size(64));
    try std.testing.expectEqual(@as(u64, 7576), struct_size(65));
    try std.testing.expectEqual(@as(u64, 7576), struct_size(66));
    try std.testing.expectEqual(@as(u64, 7576), struct_size(100));
}
