const std = @import("std");
const app = @import("app_state");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");
const json = @import("../output/json.zig");
const csv = @import("../output/csv.zig");

pub const DumpInstrumentError = app.AppStateError || error{
    OutputFailed,
    WriteFailed,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.DumpInstrumentArgs) DumpInstrumentError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    switch (cmd.format) {
        .json => {
            const Instrument = struct {
                model: ?[]const u8,
                serial_number: ?[]const u8,
                software_version: ?[]const u8,
            };
            const output = Instrument{
                .model = if (state.file.instrument_model) |p| @as([]const u8, p) else null,
                .serial_number = if (state.file.instrument_serial) |p| @as([]const u8, p) else null,
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
            try cw.writeRow(&[_][]const u8{ "model", "serial_number", "software_version" });
            try cw.writeRow(&[_][]const u8{
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
