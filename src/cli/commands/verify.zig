const std = @import("std");
const app = @import("app_state");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");

pub const VerifyError = app.AppStateError || error{
    OutputFailed,
    NoScans,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.VerifyArgs) VerifyError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    if (state.file.scans.len == 0) return error.NoScans;

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "OK: {d} scans, rev {d}\n", .{
        state.file.scans.len,
        state.file.file_revision(),
    }) catch |err| switch (err) {
        error.NoSpaceLeft => return error.OutputFailed,
    };

    var out = sink.OutputSink.init_stdout(io, allocator);
    defer out.deinit();
    out.write(msg) catch return error.OutputFailed;
}
