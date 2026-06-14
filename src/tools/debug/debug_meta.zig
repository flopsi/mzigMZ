const std = @import("std");
const app = @import("app_state");
const cli = @import("cli_args");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try cli.get_args(allocator);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len < 2) {
        std.debug.print("Usage: debug_meta <raw-file>\n", .{});
        return;
    }

    const raw_path = args[1];

    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    try state.open_file(raw_path);

    std.debug.print("\n========================================\n", .{});
    std.debug.print("FILE: {s}\n", .{raw_path});
    std.debug.print("Total scans: {d}\n", .{state.file.scans.len});
    std.debug.print("========================================\n\n", .{});

    // Show scan pattern: first 150 scans with their event mapping
    std.debug.print("--- Scan Pattern (first 150 scans) ---\n", .{});
    std.debug.print("Scan | Event | MS Level | Precursor m/z | CE    | Mass Range\n", .{});
    std.debug.print("-----|-------|----------|---------------|-------|---------------------------\n", .{});

    var i: usize = 0;
    while (i < @min(150, state.file.scans.len)) : (i += 1) {
        const scan = state.file.scans[i];
        const event_idx = scan.scan_event_index;

        if (state.file.trailer_events) |te| {
            if (te.get_event(i)) |evt| {
                const ms_level = if (evt.reactions.len > 0 and evt.reactions[0].collision_energy > 0) @as(u8, 2) else @as(u8, 1);
                const precursor = if (evt.reactions.len > 0) evt.reactions[0].precursor_mass else 0.0;
                const ce = if (evt.reactions.len > 0) evt.reactions[0].collision_energy else 0.0;
                const mass_low = if (evt.mass_ranges.len > 0) evt.mass_ranges[0].low else 0.0;
                const mass_high = if (evt.mass_ranges.len > 0) evt.mass_ranges[0].high else 0.0;

                std.debug.print("{d:>4} | {d:>5} | MS{d}      | {d:>13.4} | {d:>5.1} | {d:.1}-{d:.1}\n", .{
                    i + 1, event_idx, ms_level, precursor, ce, mass_low, mass_high,
                });
            } else {
                std.debug.print("{d:>4} | {d:>5} | ?        | ?             | ?     | ?\n", .{ i + 1, event_idx });
            }
        }
    }

    // Count MS1 vs MS2 across all scans
    std.debug.print("\n--- MS Level Distribution (first 1000 scans) ---\n", .{});
    var ms1_count: usize = 0;
    var ms2_count: usize = 0;
    var unknown_count: usize = 0;
    i = 0;
    while (i < @min(1000, state.file.scans.len)) : (i += 1) {
        if (state.file.trailer_events) |te| {
            if (te.get_event(i)) |evt| {
                if (evt.reactions.len > 0 and evt.reactions[0].collision_energy > 0) {
                    ms2_count += 1;
                } else {
                    ms1_count += 1;
                }
            } else {
                unknown_count += 1;
            }
        }
    }
    std.debug.print("  MS1: {d}\n", .{ms1_count});
    std.debug.print("  MS2: {d}\n", .{ms2_count});
    std.debug.print("  Unknown: {d}\n", .{unknown_count});

    // Find the cycle pattern
    std.debug.print("\n--- Cycle Pattern Detection ---\n", .{});
    if (state.file.trailer_events) |te| {
        // Find first MS1 after scan 1
        var first_ms1_after_start: usize = 0;
        i = 1;
        while (i < @min(500, state.file.scans.len)) : (i += 1) {
            if (te.get_event(i)) |evt| {
                if (evt.reactions.len == 0 or evt.reactions[0].collision_energy == 0) {
                    first_ms1_after_start = i;
                    break;
                }
            }
        }
        std.debug.print("  First MS1 after scan 1: scan {d}\n", .{first_ms1_after_start + 1});
        std.debug.print("  MS2 scans between MS1s: {d}\n", .{first_ms1_after_start - 1});

        // Check if pattern repeats
        if (first_ms1_after_start > 1 and first_ms1_after_start < state.file.scans.len) {
            const cycle_len = first_ms1_after_start;
            var second_ms1: usize = 0;
            i = first_ms1_after_start + 1;
            while (i < @min(first_ms1_after_start + cycle_len + 10, state.file.scans.len)) : (i += 1) {
                if (te.get_event(i)) |evt| {
                    if (evt.reactions.len == 0 or evt.reactions[0].collision_energy == 0) {
                        second_ms1 = i;
                        break;
                    }
                }
            }
            if (second_ms1 > 0) {
                std.debug.print("  Second MS1: scan {d}\n", .{second_ms1 + 1});
                std.debug.print("  Cycle length: {d} scans\n", .{second_ms1 - first_ms1_after_start + 1});
            }
        }
    }

    // Show unique events summary
    if (state.file.trailer_events) |te| {
        std.debug.print("\n--- Unique Events Summary ({d} total) ---\n", .{te.unique_events.len});
        std.debug.print("Event | MS Level | Precursor     | CE    | Mass Range      | Calibrators\n", .{});
        std.debug.print("------|----------|---------------|-------|-----------------|-------------------\n", .{});
        i = 0;
        while (i < @min(20, te.unique_events.len)) : (i += 1) {
            const evt = te.unique_events[i];
            const ms_level = if (evt.reactions.len > 0 and evt.reactions[0].collision_energy > 0) @as(u8, 2) else @as(u8, 1);
            const precursor = if (evt.reactions.len > 0) evt.reactions[0].precursor_mass else 0.0;
            const ce = if (evt.reactions.len > 0) evt.reactions[0].collision_energy else 0.0;
            const mass_low = if (evt.mass_ranges.len > 0) evt.mass_ranges[0].low else 0.0;
            const mass_high = if (evt.mass_ranges.len > 0) evt.mass_ranges[0].high else 0.0;

            std.debug.print("{d:>5} | MS{d}      | {d:>13.4} | {d:>5.1} | {d:>7.1}-{d:>7.1} | {d} cals\n", .{
                i, ms_level, precursor, ce, mass_low, mass_high, evt.mass_calibrators.len,
            });
        }
    }

    std.debug.print("\n========================================\n", .{});
}
