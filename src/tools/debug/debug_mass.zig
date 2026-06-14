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

    if (args.len < 3) {
        std.debug.print("Usage: debug_mass <raw-file> <scan-number>\n", .{});
        return;
    }

    const raw_path = args[1];
    const scan_arg = args[2];
    const scan_num = try std.fmt.parseInt(usize, scan_arg, 10);

    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    try state.open_file(raw_path);

    if (scan_num >= state.file.scans.len) {
        std.debug.print("Scan {} out of range ({} scans)\n", .{ scan_num, state.file.scans.len });
        return;
    }

    try state.load_scan(scan_num);

    const spec = state.current_spectrum.?;
    std.debug.print("Scan {}: {} points\n", .{ scan_num + 1, spec.point_count() });
    std.debug.print("  First mass: {d:.4}\n", .{spec.mz[0]});
    std.debug.print("  Last mass:  {d:.4}\n", .{spec.mz[spec.point_count() - 1]});

    // Find actual max intensity
    var max_inten: f32 = 0;
    for (spec.intensity) |inten| {
        if (inten > max_inten) max_inten = inten;
    }
    std.debug.print("  Actual max intensity: {d:.2}\n", .{max_inten});

    // Print calibrators
    const event = state.file.trailer_events.?.get_event(scan_num).?;
    std.debug.print("  Calibrators ({} values):\n", .{event.mass_calibrators.len});
    for (event.mass_calibrators, 0..) |c, i| {
        std.debug.print("    [{d}] = {e:.15}\n", .{ i, c });
    }
}
