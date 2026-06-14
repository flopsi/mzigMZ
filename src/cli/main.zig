const std = @import("std");
const cli_args = @import("cli_args");
const args = @import("args.zig");
const cli_lib = @import("lib.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const raw_args = try cli_args.get_args(allocator);
    defer {
        for (raw_args) |a| allocator.free(a);
        allocator.free(raw_args);
    }

    const cmd = args.parse(allocator, raw_args) catch |err| {
        std.log.err("Invalid arguments: {s}", .{@errorName(err)});
        std.debug.print("Usage: mzig <command> [args]\n", .{});
        return error.InvalidArguments;
    };

    switch (cmd) {
        .convert => |c| try cli_lib.convert.run(io, allocator, c),
        .convert_batch => |c| try cli_lib.convert.run_batch(io, allocator, c),
        .dump_scan => |c| try cli_lib.dump_scan.run(io, allocator, c),
        .dump_scans => |c| try cli_lib.dump_scans.run(io, allocator, c),
        .dump_chromatogram => |c| try cli_lib.dump_chromatogram.run(io, allocator, c),
        .dump_metadata => |c| try cli_lib.dump_metadata.run(io, allocator, c),
        .dump_calibration => |c| try cli_lib.dump_calibration.run(io, allocator, c),
        .dump_instrument => |c| try cli_lib.dump_instrument.run(io, allocator, c),
        .dump_packet => |c| try cli_lib.dump_packet.run(io, allocator, c),
        .verify => |c| try cli_lib.verify.run(io, allocator, c),
        .help => print_help(),
    }
}

fn print_help() void {
    std.debug.print(
        \\mzig — mzigRead command-line interface
        \\
        \\Commands:
        \\  convert <input.raw> <output.mzML>
        \\  convert-batch <input_dir> <output_dir>
        \\  dump scan <input.raw> --scan N
        \\  dump scans <input.raw> [--range A:B]
        \\  dump chromatogram <input.raw> --type tic|bpc
        \\  dump metadata <input.raw>
        \\  dump calibration <input.raw> [--scan N]
        \\  dump instrument <input.raw>
        \\  dump packet <input.raw> --scan N
        \\  verify <input.raw>
        \\
    , .{});
}
