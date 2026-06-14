const std = @import("std");
const app = @import("app_state");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");
const json = @import("../output/json.zig");
const csv = @import("../output/csv.zig");

pub const DumpCalibrationError = app.AppStateError || error{
    OutputFailed,
    WriteFailed,
    InvalidScanNumber,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.DumpCalibrationArgs) DumpCalibrationError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    const scan_index = if (cmd.scan) |sn|
        scanIndexForNumber(state.file.scans, std.math.cast(i32, sn) orelse return error.InvalidScanNumber) orelse return error.InvalidScanNumber
    else
        0;
    const scan = state.file.scans[scan_index];

    const calibrators: []const f64 = if (state.file.trailer_events) |*te|
        if (te.get_event(scan.scan_event_index)) |evt| evt.mass_calibrators else &[_]f64{}
    else
        &[_]f64{};

    switch (cmd.format) {
        .json => {
            const Calibration = struct {
                scan_number: i32,
                scan_event_index: usize,
                mass_calibrators: []const f64,
            };
            const output = Calibration{
                .scan_number = scan.scan_number,
                .scan_event_index = scan.scan_event_index,
                .mass_calibrators = calibrators,
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
            try cw.writeRow(&[_][]const u8{ "scan_number", "scan_event_index", "index", "mass_calibrator" });
            for (calibrators, 0..) |cal, i| {
                var sn_buf: [32]u8 = undefined;
                var sei_buf: [32]u8 = undefined;
                var idx_buf: [32]u8 = undefined;
                var cal_buf: [64]u8 = undefined;
                const sn_str = std.fmt.bufPrint(&sn_buf, "{}", .{scan.scan_number}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const sei_str = std.fmt.bufPrint(&sei_buf, "{}", .{scan.scan_event_index}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const idx_str = std.fmt.bufPrint(&idx_buf, "{}", .{i}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const cal_str = std.fmt.bufPrint(&cal_buf, "{}", .{cal}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                try cw.writeRow(&[_][]const u8{ sn_str, sei_str, idx_str, cal_str });
            }
            var out = sink.OutputSink.init_stdout(io, allocator);
            defer out.deinit();
            out.write(cw.bytes()) catch return error.OutputFailed;
        },
    }
}

fn scanIndexForNumber(scans: []const app.ScanInfo, scan_number: i32) ?usize {
    for (scans, 0..) |scan, i| {
        if (scan.scan_number == scan_number) return i;
    }
    return null;
}
