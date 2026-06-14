const std = @import("std");
const app = @import("app_state");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");
const json = @import("../output/json.zig");
const csv = @import("../output/csv.zig");

pub const DumpMetadataError = app.AppStateError || error{
    OutputFailed,
    WriteFailed,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.DumpMetadataArgs) DumpMetadataError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    switch (cmd.format) {
        .json => {
            const Metadata = struct {
                file_path: ?[]const u8,
                scan_count: usize,
                file_revision: u16,
                creation_time: ?[]const u8,
                instrument_model: ?[]const u8,
                instrument_serial: ?[]const u8,
                software_version: ?[]const u8,
            };
            const output = Metadata{
                .file_path = if (state.file.file_path) |p| @as([]const u8, p) else null,
                .scan_count = state.file.scans.len,
                .file_revision = state.file.file_revision(),
                .creation_time = if (state.file.creation_time) |p| @as([]const u8, p) else null,
                .instrument_model = if (state.file.instrument_model) |p| @as([]const u8, p) else null,
                .instrument_serial = if (state.file.instrument_serial) |p| @as([]const u8, p) else null,
                .software_version = if (state.file.software_version) |p| @as([]const u8, p) else null,
            };
            var buf: std.Io.Writer.Allocating = .init(allocator);
            defer buf.deinit();
            try json.write(output, &buf.writer, false);
            try buf.writer.writeByte('\n');
            var out = sink.OutputSink.init_stdout(io, allocator);
            defer out.deinit();
            out.write(buf.written()) catch return error.OutputFailed;
        },
        .csv => {
            var cw = csv.CsvWriter.init(allocator);
            defer cw.deinit();
            try cw.writeRow(&[_][]const u8{ "file_path", "scan_count", "file_revision", "creation_time", "instrument_model", "instrument_serial", "software_version" });
            var rev_buf: [16]u8 = undefined;
            var count_buf: [32]u8 = undefined;
            const rev_str = std.fmt.bufPrint(&rev_buf, "{}", .{state.file.file_revision()}) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutputFailed,
            };
            const count_str = std.fmt.bufPrint(&count_buf, "{}", .{state.file.scans.len}) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutputFailed,
            };
            try cw.writeRow(&[_][]const u8{
                state.file.file_path orelse "",
                count_str,
                rev_str,
                state.file.creation_time orelse "",
                state.file.instrument_model orelse "",
                state.file.instrument_serial orelse "",
                state.file.software_version orelse "",
            });
            var out = sink.OutputSink.init_stdout(io, allocator);
            defer out.deinit();
            out.write(cw.bytes()) catch return error.OutputFailed;
        },
    }
}
