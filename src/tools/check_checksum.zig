/// Diagnose: compute and verify RAW file checksum.
/// Compares the stored checksum at offset 148 with a freshly-computed one.
const std = @import("std");
const raw = @import("raw_file");
const checksum = @import("checksum");
const cli = @import("cli_args");
const spec_file_header = @import("spec/file_header");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try cli.get_args(allocator);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len < 2) {
        std.debug.print("Usage: check_checksum <file.raw>\n", .{});
        std.process.exit(1);
    }

    const path = args[1];

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const stat = try file.stat(io);
    const file_length = stat.size;
    var rev_buf: [2]u8 = undefined;
    _ = try file.readPositionalAll(io, &rev_buf, spec_file_header.FILE_REV_OFFSET);
    const file_rev = std.mem.readInt(u16, &rev_buf, .little);
    const header_size: usize = std.math.cast(usize, spec_file_header.FILE_HEADER_SIZE) orelse return error.FileTooLarge;

    const stored = try checksum.read_stored_checksum(file, io);
    const computed = try checksum.compute_raw_checksum(allocator, file, io, file_rev, header_size, file_length);

    std.debug.print("File: {s}\n", .{path});
    std.debug.print("  File length: {d} bytes\n", .{file_length});
    std.debug.print("  File revision: {d}\n", .{file_rev});
    std.debug.print("  Stored checksum (@148):   0x{x:0>8}\n", .{stored});
    std.debug.print("  Computed checksum:        0x{x:0>8}\n", .{computed});
    if (stored == computed) {
        std.debug.print("  ✓ MATCH\n", .{});
    } else {
        std.debug.print("  ✗ MISMATCH — Spectronaut will likely reject this file\n", .{});
    }
}
