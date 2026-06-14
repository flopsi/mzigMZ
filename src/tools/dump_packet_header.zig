/// Quick diagnostic: dump packet header bytes for a given scan.
const std = @import("std");
const app_state = @import("app_state");
const raw = @import("raw_file");
const advanced = @import("advanced_packet");
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
        std.debug.print("Usage: dump-packet-header <raw-file> <scan-number>\n", .{});
        return;
    }

    const raw_path = args[1];
    const scan_str = args[2];

    const scan_number = std.fmt.parseInt(i32, scan_str, 10) catch |e| {
        std.debug.print("error: invalid scan number '{s}': {s}\n", .{ scan_str, @errorName(e) });
        return;
    };

    var state = app_state.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(raw_path);
    const scan_idx = @as(usize, @intCast(scan_number - 1));
    state.load_scan(scan_idx) catch |e| {
        std.debug.print("error: failed to load scan {d}: {s}\n", .{ scan_number, @errorName(e) });
        return;
    };

    // Find the packet
    const packet_offset = state.file.raw_file.?.packet_offset(scan_number) catch |e| {
        std.debug.print("error: failed to compute packet offset: {s}\n", .{@errorName(e)});
        return;
    };

    const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, raw_path, .{}) catch |e| {
        std.debug.print("error: cannot open '{s}': {s}\n", .{ raw_path, @errorName(e) });
        return;
    };
    defer file.close(io);

    // Read packet header (32 bytes)
    var header_bytes: [32]u8 = undefined;
    _ = try file.readPositionalAll(io, header_bytes[0..], packet_offset);

    std.debug.print("Packet header for scan {d} at offset 0x{x}:\n", .{ scan_number, packet_offset });
    var i: usize = 0;
    while (i < 32) : (i += 8) {
        std.debug.print("  ", .{});
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            var buf: [2]u8 = undefined;
            const hex = try std.fmt.bufPrint(&buf, "{x:0>2}", .{header_bytes[i + j]});
            std.debug.print("{s} ", .{hex});
        }
        std.debug.print("\n", .{});
    }
}
