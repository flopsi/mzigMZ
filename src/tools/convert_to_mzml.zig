/// Convert a .raw file to mzML.
/// Usage: convert-to-mzml <input.raw> <output.mzML>
const std = @import("std");
const app = @import("app_state");
const streaming = @import("streaming_convert");
const mzml_writer = @import("mzml_writer");
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
        std.debug.print("Usage: convert-to-mzml <input.raw> <output.mzML>\n", .{});
        return;
    }

    const input_path = args[1];
    const output_path = args[2];

    // Infer source file name from path
    const source_name = std.fs.path.basename(input_path);

    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    std.debug.print("Opening {s}...\n", .{input_path});
    try state.open_file(input_path);

    std.debug.print("File: {d} scans, rev {d}\n", .{ state.file.scans.len, state.file.file_revision() });

    const options = mzml_writer.MzmlWriterOptions{
        .compression = .none,
        .precision = .f64,
        .use_indexed_mzml = false,
    };

    std.debug.print("Converting to {s}...\n", .{output_path});
    try streaming.convert_raw_to_mzml_streaming(
        io,
        allocator,
        &state,
        output_path,
        source_name,
        null,
        options,
    );

    std.debug.print("Done.\n", .{});
}
