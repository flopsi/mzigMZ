/// Verification harness for .raw passthrough writer.
/// Usage: zig build verify-passthrough -- <input.raw> <output.raw>
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
        std.debug.print("Usage: verify_passthrough <input.raw> <output.raw>\n", .{});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = args[2];

    // Open source file
    var state = app_state.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(input_path);

    std.debug.print("Source: {s} ({d} scans, {d} bytes)\n", .{
        input_path,
        state.file.raw_file.?.num_scans,
        state.file.raw_file.?.file_size,
    });

    // Write passthrough copy
    const start_write = std.Io.Clock.now(.boot, io);
    try writer.passthrough(allocator, io, &state.file.raw_file.?, state.file.trailer_events, output_path);
    const write_ms = start_write.untilNow(io, .boot).toMilliseconds();
    std.debug.print("Wrote passthrough in {d} ms\n", .{write_ms});

    // Verify
    const start_verify = std.Io.Clock.now(.boot, io);
    const mismatches = try writer.verify_passthrough(allocator, io, input_path, output_path);
    const verify_ms = start_verify.untilNow(io, .boot).toMilliseconds();

    if (mismatches == 0) {
        std.debug.print("✓ PASSED — zero mismatches in {d} ms\n", .{verify_ms});
    } else {
        std.debug.print("✗ FAILED — {d} mismatches in {d} ms\n", .{ mismatches, verify_ms });
        std.process.exit(1);
    }
}
