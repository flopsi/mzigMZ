const std = @import("std");
const app = @import("app_state");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");
const json = @import("../output/json.zig");
const csv = @import("../output/csv.zig");

pub const DumpScanError = app.AppStateError || error{
    OutputFailed,
    WriteFailed,
    InvalidScanNumber,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.DumpScanArgs) DumpScanError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    const scan_number_i32 = std.math.cast(i32, cmd.scan) orelse return error.InvalidScanNumber;
    const scan_index = scanIndexForNumber(state.file.scans, scan_number_i32) orelse return error.InvalidScanNumber;
    try state.load_scan(scan_index);
    const scan = state.file.scans[scan_index];

    const spec = state.get_current_spectrum();
    const mz: []const f64 = if (spec) |s| s.mz else &[_]f64{};
    const intensity: []const f32 = if (spec) |s| s.intensity else &[_]f32{};

    switch (cmd.format) {
        .json => {
            const Precursor = struct {
                isolation_mz: f64,
                charge: i32,
                intensity: f64,
            };
            const Peaks = struct {
                mz: []const f64,
                intensity: []const f32,
            };
            const Output = struct {
                scan_number: i32,
                ms_level: u8,
                rt_in_minutes: f64,
                filter_string: ?[]const u8,
                analyzer: []const u8,
                source: []const u8,
                precursor: ?Precursor,
                peaks: Peaks,
            };
            const output: Output = .{
                .scan_number = scan.scan_number,
                .ms_level = scan.ms_level,
                .rt_in_minutes = scan.rt,
                .filter_string = if (scan.filter_string) |fs| @as([]const u8, fs) else null,
                .analyzer = detectAnalyzer(scan.filter_string),
                .source = detectSource(scan.filter_string),
                .precursor = if (scan.ms_level >= 2) .{
                    .isolation_mz = scan.precursor_mz,
                    .charge = scan.charge_state,
                    .intensity = 0,
                } else null,
                .peaks = .{
                    .mz = mz,
                    .intensity = intensity,
                },
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
            for (mz, 0..) |m, i| {
                const inten = intensity[i];
                var sn_buf: [32]u8 = undefined;
                var mz_buf: [64]u8 = undefined;
                var int_buf: [64]u8 = undefined;
                const sn_str = std.fmt.bufPrint(&sn_buf, "{}", .{scan.scan_number}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const mz_str = std.fmt.bufPrint(&mz_buf, "{}", .{m}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                const int_str = std.fmt.bufPrint(&int_buf, "{}", .{inten}) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutputFailed,
                };
                try cw.writeRow(&[_][]const u8{ sn_str, mz_str, int_str });
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

fn detectAnalyzer(filter: ?[]const u8) []const u8 {
    const f = filter orelse return "unknown";
    if (std.mem.indexOf(u8, f, "ASTMS") != null) return "astral";
    if (std.mem.indexOf(u8, f, "FTMS") != null) return "orbitrap";
    if (std.mem.indexOf(u8, f, "ITMS") != null) return "ion_trap";
    if (std.mem.indexOf(u8, f, "TQMS") != null) return "triple_quad";
    return "unknown";
}

fn detectSource(filter: ?[]const u8) []const u8 {
    const f = filter orelse return "unknown";
    if (std.mem.indexOf(u8, f, "NSI") != null) return "NSI";
    if (std.mem.indexOf(u8, f, "ESI") != null) return "ESI";
    if (std.mem.indexOf(u8, f, "APCI") != null) return "APCI";
    if (std.mem.indexOf(u8, f, "MALDI") != null) return "MALDI";
    return "unknown";
}
