const std = @import("std");
const app = @import("app_state");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");
const json = @import("../output/json.zig");
const csv = @import("../output/csv.zig");

pub const DumpScansError = app.AppStateError || error{
    OutputFailed,
    WriteFailed,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.DumpScansArgs) DumpScansError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    switch (cmd.format) {
        .json => {
            const Summary = struct {
                scan_number: i32,
                ms_level: u8,
                rt: f64,
                filter_string: ?[]const u8,
                tic: f64,
                base_peak_mz: f64,
                base_peak_intensity: f64,
            };
            var summaries: std.ArrayList(Summary) = .empty;
            defer summaries.deinit(allocator);
            for (state.file.scans) |scan| {
                if (!scanInRange(scan.scan_number, cmd.range_start, cmd.range_end)) continue;
                try summaries.append(allocator, .{
                    .scan_number = scan.scan_number,
                    .ms_level = scan.ms_level,
                    .rt = scan.rt,
                    .filter_string = if (scan.filter_string) |fs| @as([]const u8, fs) else null,
                    .tic = scan.tic,
                    .base_peak_mz = scan.base_peak_mz,
                    .base_peak_intensity = scan.base_peak_intensity,
                });
            }
            var buf: std.Io.Writer.Allocating = .init(allocator);
            defer buf.deinit();
            try json.write(summaries.items, &buf.writer, false);
            try buf.writer.writeByte('\n');
            var out = sink.OutputSink.init_stdout(io, allocator);
            defer out.deinit();
            out.write(buf.written()) catch return error.OutputFailed;
        },
        .csv => {
            var cw = csv.CsvWriter.init(allocator);
            defer cw.deinit();
            try cw.writeRow(&[_][]const u8{ "scan_number", "ms_level", "rt", "filter_string", "tic", "base_peak_mz", "base_peak_intensity" });
            for (state.file.scans) |scan| {
                if (!scanInRange(scan.scan_number, cmd.range_start, cmd.range_end)) continue;
                var sn_buf: [32]u8 = undefined;
                var ms_buf: [8]u8 = undefined;
                var rt_buf: [64]u8 = undefined;
                var tic_buf: [64]u8 = undefined;
                var bpm_buf: [64]u8 = undefined;
                var bpi_buf: [64]u8 = undefined;
                const sn_str = std.fmt.bufPrint(&sn_buf, "{}", .{scan.scan_number}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const ms_str = std.fmt.bufPrint(&ms_buf, "{}", .{scan.ms_level}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const rt_str = std.fmt.bufPrint(&rt_buf, "{}", .{scan.rt}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const tic_str = std.fmt.bufPrint(&tic_buf, "{}", .{scan.tic}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const bpm_str = std.fmt.bufPrint(&bpm_buf, "{}", .{scan.base_peak_mz}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const bpi_str = std.fmt.bufPrint(&bpi_buf, "{}", .{scan.base_peak_intensity}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                try cw.writeRow(&[_][]const u8{
                    sn_str,
                    ms_str,
                    rt_str,
                    if (scan.filter_string) |fs| @as([]const u8, fs) else "",
                    tic_str,
                    bpm_str,
                    bpi_str,
                });
            }
            var out = sink.OutputSink.init_stdout(io, allocator);
            defer out.deinit();
            out.write(cw.bytes()) catch return error.OutputFailed;
        },
    }
}

fn scanInRange(scan_number: i32, start: ?usize, end: ?usize) bool {
    if (start) |s| {
        const s_i32 = std.math.cast(i32, s) orelse return false;
        if (scan_number < s_i32) return false;
    }
    if (end) |e| {
        const e_i32 = std.math.cast(i32, e) orelse return false;
        if (scan_number > e_i32) return false;
    }
    return true;
}
