//! Cycle navigation — groups scans into DIA cycles (MS1 + n×MS2 sharing the
//! same `scan_event_index`).
//!
//! The AppState's `ScanInfo` array has `scan_event_index: usize` set by
//! `parseTrailerScanEvents` for rev ≥ 65 files. All scans sharing the same
//! `scan_event_index` are part of the same DIA cycle. The MS1 (ms_level == 1)
//! is the parent; the MS2s (ms_level >= 2) are children.
//!
//! This module provides pure helpers: given a scan index, find the parent
//! MS1, find prev/next cycle, find prev/next MS2 within a cycle. No state.

const std = @import("std");
const AppState = @import("app_state").AppState;
const ScanInfo = @import("file_state").ScanInfo;

/// Find the MS1 (parent) of the DIA cycle that the given scan index belongs to.
/// Returns the index of the MS1, or null if no MS1 exists in the cycle.
pub fn parent_ms1_index(state: *AppState, scan_index: usize) ?usize {
    if (scan_index >= state.file.scans.len) return null;
    const cycle_id = state.file.scans[scan_index].scan_event_index;

    // Search backward for the MS1 with this cycle_id (most efficient, since
    // scans are stored in acquisition order and MS1 always precedes its MS2s).
    var i: usize = scan_index;
    while (true) {
        const s = state.file.scans[i];
        if (s.scan_event_index != cycle_id) return null; // crossed a cycle boundary
        if (s.ms_level == 1) return i;
        if (i == 0) return null;
        i -= 1;
    }
}

/// Find the next MS2 in the same cycle AFTER the given scan index.
/// Returns null if scan_index is already the last MS2 of the cycle, or if the
/// scan is itself an MS1.
pub fn next_ms2_in_cycle(state: *AppState, scan_index: usize) ?usize {
    if (scan_index >= state.file.scans.len) return null;
    const cycle_id = state.file.scans[scan_index].scan_event_index;
    var i: usize = scan_index + 1;
    while (i < state.file.scans.len) {
        const s = state.file.scans[i];
        if (s.scan_event_index != cycle_id) return null; // crossed to next cycle
        if (s.ms_level >= 2) return i;
        i += 1;
    }
    return null;
}

/// Find the previous MS2 in the same cycle BEFORE the given scan index.
/// Returns null if no previous MS2 in the cycle exists.
pub fn prev_ms2_in_cycle(state: *AppState, scan_index: usize) ?usize {
    if (scan_index == 0) return null;
    if (scan_index >= state.file.scans.len) return null;
    const cycle_id = state.file.scans[scan_index].scan_event_index;
    var i: usize = scan_index;
    while (i > 0) {
        i -= 1;
        const s = state.file.scans[i];
        if (s.scan_event_index != cycle_id) return null; // crossed to previous cycle
        if (s.ms_level >= 2) return i;
    }
    return null;
}

/// Find the parent MS1 of the next DIA cycle (i.e. the first MS1 whose cycle_id
/// is greater than the current cycle's cycle_id).
/// Returns null if no next cycle exists.
pub fn next_cycle_ms1(state: *AppState, scan_index: usize) ?usize {
    if (scan_index >= state.file.scans.len) return null;
    const cur_cycle_id = state.file.scans[scan_index].scan_event_index;
    var i: usize = scan_index + 1;
    while (i < state.file.scans.len) {
        const s = state.file.scans[i];
        if (s.scan_event_index > cur_cycle_id and s.ms_level == 1) return i;
        i += 1;
    }
    return null;
}

/// Find the parent MS1 of the previous DIA cycle.
pub fn prev_cycle_ms1(state: *AppState, scan_index: usize) ?usize {
    if (scan_index == 0) return null;
    if (scan_index >= state.file.scans.len) return null;
    const cur_cycle_id = state.file.scans[scan_index].scan_event_index;
    var i: usize = scan_index;
    while (i > 0) {
        i -= 1;
        const s = state.file.scans[i];
        if (s.scan_event_index < cur_cycle_id and s.ms_level == 1) return i;
    }
    return null;
}

/// Count the number of MS2 scans in the same cycle as the given scan index.
pub fn ms2_count_in_cycle(state: *AppState, scan_index: usize) usize {
    if (scan_index >= state.file.scans.len) return 0;
    const cycle_id = state.file.scans[scan_index].scan_event_index;
    var count: usize = 0;
    for (state.file.scans) |s| {
        if (s.scan_event_index == cycle_id and s.ms_level >= 2) count += 1;
    }
    return count;
}

/// Check whether the given scan index is the start (MS1) of a DIA cycle.
pub fn is_cycle_parent(state: *AppState, scan_index: usize) bool {
    if (scan_index >= state.file.scans.len) return false;
    const s = state.file.scans[scan_index];
    return s.ms_level == 1;
}

const std2 = std; // for tests below

test "parentMs1Index finds the MS1 of the same cycle" {
    const allocator = std.testing.allocator;
    var state = AppState.init(allocator, std.testing.allocator);
    defer state.deinit();

    // Construct 5 scans: MS1(cycle=0), MS2(cycle=0), MS2(cycle=0), MS1(cycle=1), MS2(cycle=1)
    state.file.scans = try allocator.alloc(ScanInfo, 5);
    defer allocator.free(state.file.scans);
    state.file.scans[0] = .{ .scan_number = 1, .scan_event_index = 0, .ms_level = 1, .rt = 0.0, .tic = 100.0, .base_peak_mz = 0, .base_peak_intensity = 0, .low_mass = 0, .high_mass = 0, .packet_type = 0, .number_packets = 0, .data_size = 0, .data_offset = 0, .trailer_offset = 0, .charge_state = 0, .precursor_mz = 0, .filter_string = null, .collision_energy = 0, .isolation_width = 0, .peak_count = 0, .cycle_number = 0 };
    state.file.scans[1] = .{ .scan_number = 2, .scan_event_index = 0, .ms_level = 2, .rt = 0.1, .tic = 50.0, .base_peak_mz = 0, .base_peak_intensity = 0, .low_mass = 0, .high_mass = 0, .packet_type = 0, .number_packets = 0, .data_size = 0, .data_offset = 0, .trailer_offset = 0, .charge_state = 2, .precursor_mz = 500.0, .filter_string = null, .collision_energy = 30, .isolation_width = 1, .peak_count = 0, .cycle_number = 0 };
    state.file.scans[2] = .{ .scan_number = 3, .scan_event_index = 0, .ms_level = 2, .rt = 0.2, .tic = 60.0, .base_peak_mz = 0, .base_peak_intensity = 0, .low_mass = 0, .high_mass = 0, .packet_type = 0, .number_packets = 0, .data_size = 0, .data_offset = 0, .trailer_offset = 0, .charge_state = 2, .precursor_mz = 600.0, .filter_string = null, .collision_energy = 30, .isolation_width = 1, .peak_count = 0, .cycle_number = 0 };
    state.file.scans[3] = .{ .scan_number = 4, .scan_event_index = 1, .ms_level = 1, .rt = 0.3, .tic = 200.0, .base_peak_mz = 0, .base_peak_intensity = 0, .low_mass = 0, .high_mass = 0, .packet_type = 0, .number_packets = 0, .data_size = 0, .data_offset = 0, .trailer_offset = 0, .charge_state = 0, .precursor_mz = 0, .filter_string = null, .collision_energy = 0, .isolation_width = 0, .peak_count = 0, .cycle_number = 0 };
    state.file.scans[4] = .{ .scan_number = 5, .scan_event_index = 1, .ms_level = 2, .rt = 0.4, .tic = 80.0, .base_peak_mz = 0, .base_peak_intensity = 0, .low_mass = 0, .high_mass = 0, .packet_type = 0, .number_packets = 0, .data_size = 0, .data_offset = 0, .trailer_offset = 0, .charge_state = 2, .precursor_mz = 700.0, .filter_string = null, .collision_energy = 30, .isolation_width = 1, .peak_count = 0, .cycle_number = 0 };

    try std.testing.expectEqual(@as(usize, 0), parent_ms1_index(&state, 0).?);
    try std.testing.expectEqual(@as(usize, 0), parent_ms1_index(&state, 1).?);
    try std.testing.expectEqual(@as(usize, 0), parent_ms1_index(&state, 2).?);
    try std.testing.expectEqual(@as(usize, 3), parent_ms1_index(&state, 3).?);
    try std.testing.expectEqual(@as(usize, 3), parent_ms1_index(&state, 4).?);

    try std.testing.expectEqual(@as(usize, 2), next_ms2_in_cycle(&state, 1).?);
    try std.testing.expectEqual(@as(?usize, null), next_ms2_in_cycle(&state, 2));
    try std.testing.expectEqual(@as(?usize, null), next_ms2_in_cycle(&state, 4));

    try std.testing.expectEqual(@as(usize, 1), prev_ms2_in_cycle(&state, 2).?);
    try std.testing.expectEqual(@as(?usize, null), prev_ms2_in_cycle(&state, 1));

    try std.testing.expectEqual(@as(usize, 3), next_cycle_ms1(&state, 0).?);
    try std.testing.expectEqual(@as(?usize, null), next_cycle_ms1(&state, 3));
    try std.testing.expectEqual(@as(usize, 0), prev_cycle_ms1(&state, 3).?);
    try std.testing.expectEqual(@as(?usize, null), prev_cycle_ms1(&state, 0));

    try std.testing.expectEqual(@as(usize, 2), ms2_count_in_cycle(&state, 0));
    try std.testing.expectEqual(@as(usize, 1), ms2_count_in_cycle(&state, 3));

    try std.testing.expect(is_cycle_parent(&state, 0));
    try std.testing.expect(!is_cycle_parent(&state, 1));
    try std.testing.expect(is_cycle_parent(&state, 3));
}
