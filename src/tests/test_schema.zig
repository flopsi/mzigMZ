/// Integration test: schema detection with real .raw file.
/// Requires a .raw file path as CLI argument.
///
/// Usage: test-schema D:/path/to/file.raw
const std = @import("std");
const schema = @import("schema");
const reader = @import("raw_file_reader");
const raw_mod = @import("raw_file");
const cli = @import("cli_args");

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    const args = cli.get_args(allocator) catch {
        std.debug.print("usage: test-schema <raw-file>\n", .{});
        return 1;
    };
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len < 2) {
        std.debug.print("usage: test-schema <raw-file>\n", .{});
        return 1;
    }

    const path = args[1];

    var raw = reader.RawFile.open(allocator, io, path) catch |err| {
        std.debug.print("FAIL: cannot open '{s}': {}\n", .{ path, err });
        return 1;
    };
    defer raw.deinit();

    const detected = schema.detect_schema(
        raw.memory(),
        raw.file_revision,
        raw.scan_table_start,
        raw.scan_table_size,
        raw_mod.scan_index_size(raw.file_revision),
        raw.packet_pos,
        raw.num_scans,
        raw.trailer_scan_events_pos,
    ) catch |err| {
        std.debug.print("FAIL: detectSchema error: {}\n", .{err});
        return 1;
    };

    if (detected == null) {
        std.debug.print("FAIL: no schema detected for rev {d} file\n", .{raw.file_revision});
        return 1;
    }

    const s = detected.?;
    std.debug.print("PASS: schema detected — rev={d} scans={d}\n", .{ s.file_revision, s.num_scans });
    return 0;
}
