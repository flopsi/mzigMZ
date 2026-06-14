const std = @import("std");

/// Structural layout of a Scan Index entry in the .raw file.
/// Offsets are bytes from the start of the entry.
/// A field offset of 0 means "not present in this revision" UNLESS
/// the field is actually at byte offset 0. For data_size: rev >= 65
/// stores it at offset 0; rev < 65 does not (offset 0 is DataOffset32Bit).
/// Ground truth verified against Thermo decompiled ScanIndices.cs.
pub const Layout = struct {
    data_size: u32,
    trailer_offset: u32,
    scan_type_index: u32,
    scan_number: u32,
    packet_type: u32,
    number_packets: u32,
    data_offset: u32,

    // Extended fields (rev >= 65)
    start_time: u32,
    tic: u32,
    base_peak_intensity: u32,
    base_peak_mass: u32,
    low_mass: u32,
    high_mass: u32,
    cycle_number: u32,

    entry_size: u64,
};

/// Returns the structured layout for a given file revision.
pub fn get_layout(revision: u16) Layout {
    if (revision >= 65) {
        return .{
            .data_size = 0, // offset 0 = DataSize (u32) for rev >= 65 (Thermo ScanIndices.cs:ReadScanIndexStruct)
            .trailer_offset = 4,
            .scan_type_index = 8,
            .scan_number = 12,
            .packet_type = 16,
            .number_packets = 20,
            .data_offset = 72,
            .start_time = 24,
            .tic = 32,
            .base_peak_intensity = 40,
            .base_peak_mass = 48,
            .low_mass = 56,
            .high_mass = 64,
            .cycle_number = 80,
            .entry_size = 88,
        };
    }
    if (revision >= 64) {
        return .{
            .data_size = 0, // absent for rev 64 (offset 0 is DataOffset32Bit)
            .trailer_offset = 4,
            .scan_type_index = 8,
            .scan_number = 12,
            .packet_type = 16,
            .number_packets = 20,
            .data_offset = 72,
            .start_time = 0,
            .tic = 0,
            .base_peak_intensity = 0,
            .base_peak_mass = 0,
            .low_mass = 0,
            .high_mass = 0,
            .cycle_number = 0,
            .entry_size = 80,
        };
    }
    // Legacy (< 64)
    return .{
        .data_size = 0, // absent for rev < 64 (offset 0 is DataOffset32Bit)
        .trailer_offset = 4,
        .scan_type_index = 8,
        .scan_number = 12,
        .packet_type = 16,
        .number_packets = 20,
        .data_offset = 0, // data_offset is at 0 in legacy
        .start_time = 0,
        .tic = 0,
        .base_peak_intensity = 0,
        .base_peak_mass = 0,
        .low_mass = 0,
        .high_mass = 0,
        .cycle_number = 0,
        .entry_size = 72,
    };
}
