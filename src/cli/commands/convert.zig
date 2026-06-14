const std = @import("std");
const app = @import("app_state");
const streaming = @import("streaming_convert");
const mzml_writer = @import("mzml_writer");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");

pub const ConvertError = app.AppStateError || streaming.StreamingConvertError || std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error || std.Io.Dir.AccessError || error{ BatchFailed, OutputFailed };

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.ConvertArgs) ConvertError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    const options = mzml_writer.MzmlWriterOptions{
        .compression = .none,
        .precision = .f64,
        .use_indexed_mzml = false,
    };

    const source_name = std.fs.path.basename(cmd.input_path);

    try streaming.convert_raw_to_mzml_streaming(
        io,
        allocator,
        &state,
        cmd.output_path,
        source_name,
        null,
        options,
    );

    var out = sink.OutputSink.init_stdout(io, allocator);
    defer out.deinit();
    out.write("OK\n") catch return error.OutputFailed;
}

pub fn run_batch(io: std.Io, allocator: std.mem.Allocator, cmd: args.ConvertBatchArgs) ConvertError!void {
    const cwd = std.Io.Dir.cwd();
    const input_dir = try cwd.openDir(io, cmd.input_dir, .{ .iterate = true });
    defer input_dir.close(io);

    var iter = input_dir.iterate();

    var any_failed = false;
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".raw")) continue;

        const input_path = try std.fs.path.join(allocator, &[_][]const u8{ cmd.input_dir, entry.name });
        defer allocator.free(input_path);

        const base = entry.name[0 .. entry.name.len - 4];
        const output_name = try std.mem.concat(allocator, u8, &[_][]const u8{ base, ".mzML" });
        defer allocator.free(output_name);
        const output_path = try std.fs.path.join(allocator, &[_][]const u8{ cmd.output_dir, output_name });
        defer allocator.free(output_path);

        if (cmd.skip_existing) {
            if (cwd.access(io, output_path, .{})) {
                std.log.info("Skipping existing {s}", .{output_path});
                continue;
            } else |_| {}
        }

        run(io, allocator, .{ .input_path = input_path, .output_path = output_path }) catch |err| {
            std.log.err("FAILED {s}: {s}", .{ input_path, @errorName(err) });
            any_failed = true;
            if (cmd.fail_fast) return err;
            continue;
        };
        std.log.info("OK {s}", .{output_path});
    }

    if (any_failed) return error.BatchFailed;
}
