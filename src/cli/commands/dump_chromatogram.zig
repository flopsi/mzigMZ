const std = @import("std");
const app = @import("app_state");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");
const json = @import("../output/json.zig");
const csv = @import("../output/csv.zig");

pub const DumpChromatogramError = app.AppStateError || error{
    OutputFailed,
    WriteFailed,
    InvalidChromatogramType,
    UnsupportedChromatogramType,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.DumpChromatogramArgs) DumpChromatogramError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    const is_tic = std.mem.eql(u8, cmd.chrom_type, "tic");
    const is_bpc = std.mem.eql(u8, cmd.chrom_type, "bpc");
    const is_xic = std.mem.eql(u8, cmd.chrom_type, "xic");
    if (is_xic) return error.UnsupportedChromatogramType;
    if (!is_tic and !is_bpc) return error.InvalidChromatogramType;

    state.compute_chromatograms();
    const chrom_opt = if (is_tic) state.tic_chromatogram else state.bpc_chromatogram;
    const times: []const f64 = if (chrom_opt) |c| c.rt else &[_]f64{};
    const intensities: []const f64 = if (chrom_opt) |c| c.intensity else &[_]f64{};

    switch (cmd.format) {
        .json => {
            const Output = struct {
                type: []const u8,
                times: []const f64,
                intensities: []const f64,
            };
            const output = Output{
                .type = cmd.chrom_type,
                .times = times,
                .intensities = intensities,
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
            try cw.writeRow(&[_][]const u8{ "time", "intensity" });
            for (times, 0..) |t, i| {
                const inten = intensities[i];
                var t_buf: [64]u8 = undefined;
                var i_buf: [64]u8 = undefined;
                const t_str = std.fmt.bufPrint(&t_buf, "{}", .{t}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const i_str = std.fmt.bufPrint(&i_buf, "{}", .{inten}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                try cw.writeRow(&[_][]const u8{ t_str, i_str });
            }
            var out = sink.OutputSink.init_stdout(io, allocator);
            defer out.deinit();
            out.write(cw.bytes()) catch return error.OutputFailed;
        },
    }
}
