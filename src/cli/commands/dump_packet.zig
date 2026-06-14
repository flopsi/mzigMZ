const std = @import("std");
const app = @import("app_state");
const args = @import("../args.zig");
const sink = @import("../output/sink.zig");
const json = @import("../output/json.zig");
const csv = @import("../output/csv.zig");

pub const DumpPacketError = app.AppStateError || error{
    OutputFailed,
    WriteFailed,
    InvalidScanNumber,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, cmd: args.DumpPacketArgs) DumpPacketError!void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(cmd.input_path);

    const scan_number_i32 = std.math.cast(i32, cmd.scan) orelse return error.InvalidScanNumber;
    const scan_index = scanIndexForNumber(state.file.scans, scan_number_i32) orelse return error.InvalidScanNumber;
    const scan = state.file.scans[scan_index];

    switch (cmd.format) {
        .json => {
            const Packet = struct {
                scan_number: i32,
                packet_type: u32,
                data_offset: u64,
                data_size: u32,
                number_packets: i32,
            };
            const output = Packet{
                .scan_number = scan.scan_number,
                .packet_type = scan.packet_type,
                .data_offset = scan.data_offset,
                .data_size = scan.data_size,
                .number_packets = scan.number_packets,
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
            try cw.writeRow(&[_][]const u8{ "scan_number", "packet_type", "data_offset", "data_size", "number_packets" });
            var sn_buf: [32]u8 = undefined;
            var pt_buf: [32]u8 = undefined;
            var off_buf: [32]u8 = undefined;
            var ds_buf: [32]u8 = undefined;
            var np_buf: [32]u8 = undefined;
            const sn_str = std.fmt.bufPrint(&sn_buf, "{}", .{scan.scan_number}) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutputFailed,
            };
            const pt_str = std.fmt.bufPrint(&pt_buf, "{}", .{scan.packet_type}) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutputFailed,
            };
            const off_str = std.fmt.bufPrint(&off_buf, "{}", .{scan.data_offset}) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutputFailed,
            };
            const ds_str = std.fmt.bufPrint(&ds_buf, "{}", .{scan.data_size}) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutputFailed,
            };
            const np_str = std.fmt.bufPrint(&np_buf, "{}", .{scan.number_packets}) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutputFailed,
            };
            try cw.writeRow(&[_][]const u8{ sn_str, pt_str, off_str, ds_str, np_str });
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
