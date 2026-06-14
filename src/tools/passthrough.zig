/// Passthrough writer (no verification). Writes re-encoded copy for Spectronaut testing.
const std = @import("std");
const app_state = @import("app_state");
const writer = @import("raw_file_writer");
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
        std.debug.print("Usage: passthrough <input.raw> <output.raw>\n", .{});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = args[2];

    var state = app_state.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(input_path);

    std.debug.print("Source: {s} ({d} scans, {d} bytes)\n", .{
        input_path, state.file.raw_file.?.num_scans, state.file.raw_file.?.file_size,
    });

    const start = std.Io.Clock.now(.boot, io);
    try writer.passthrough(allocator, io, &state.file.raw_file.?, state.file.trailer_events, output_path);
    const ms = start.untilNow(io, .boot).toMilliseconds();
    std.debug.print("Done in {d} ms → {s}\n", .{ ms, output_path });
}
