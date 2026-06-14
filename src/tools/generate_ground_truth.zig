/// Ground truth generator — Phase 1.
/// Runs ThermoRawFileParser in MGF mode, parses output, saves per-scan JSON.
///
/// IMPORTANT: Must be run from repo root. Output paths are relative to CWD.
/// Usage: zig build generate-ground-truth -- <raw-file>
const std = @import("std");
const cli = @import("cli_args");

const TRFP_EXE = "D:/000projects/newRawFileReader/ThermoRawFileParser-master/ThermoRawFileParser-master/bin/x64/Release/net8.0/ThermoRawFileParser.exe";
const READ_CHUNK: usize = 8 * 1024 * 1024; // 8 MB chunks for streaming the MGF

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    const args = cli.get_args(gpa) catch {
        std.debug.print("usage: generate-ground-truth <raw-file>\n", .{});
        return 1;
    };
    defer {
        for (args) |a| gpa.free(a);
        gpa.free(args);
    }
    if (args.len < 2) {
        std.debug.print("usage: generate-ground-truth <raw-file>\n", .{});
        return 1;
    }
    const raw_path = args[1];

    const raw_filename = std.fs.path.basename(raw_path);
    const dot = std.mem.lastIndexOfScalar(u8, raw_filename, '.') orelse raw_filename.len;
    const base_name = raw_filename[0..dot];
    const out_dir = try std.fmt.allocPrint(gpa, "tests/ground_truth/{s}", .{base_name});
    defer gpa.free(out_dir);

    // MGF goes to a file (not stdout) so we can stream-parse multi-GB output.
    const mgf_path = try std.fmt.allocPrint(gpa, "{s}/_temp.mgf", .{out_dir});
    defer gpa.free(mgf_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "tests/ground_truth");
    try cwd.createDirPath(io, out_dir);

    std.debug.print("Generating: {s}\n", .{raw_path});
    std.debug.print("Output:     {s}\n", .{out_dir});
    std.debug.print("MGF temp:   {s}\n\n", .{mgf_path});

    const argv = &[_][]const u8{
        TRFP_EXE,
        "-i",
        raw_path,
        "-f",
        "0",
        "-b", // output to a single file (MGF)
        mgf_path,
    };

    std.debug.print("Command: {s} -i {s} -f 0 -b {s}\n", .{ TRFP_EXE, raw_path, mgf_path });

    const t0 = std.Io.Clock.now(.boot, io);

    const result = std.process.run(gpa, io, .{
        .argv = argv,
    }) catch |err| {
        std.debug.print("error: TRFP failed: {}\n", .{err});
        return 1;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("TRFP exit: {}\n", .{result.term});
        if (result.stderr.len > 0) std.debug.print("stderr: {s}\n", .{result.stderr});
        return 1;
    }

    const trfp_elapsed = t0.untilNow(io, .boot).toMicroseconds();
    std.debug.print("TRFP done in {d:.1}s\n", .{@as(f64, @floatFromInt(trfp_elapsed)) / 1_000_000.0});

    // Stream-parse the MGF file in chunks.
    const scans = parseMgfStream(gpa, io, mgf_path, out_dir) catch |err| {
        std.debug.print("error parsing MGF: {}\n", .{err});
        return 1;
    };

    // Delete the temp MGF file (it's multi-GB for large raw files).
    cwd.deleteFile(io, mgf_path) catch {};

    const elapsed = t0.untilNow(io, .boot).toMicroseconds();
    std.debug.print("\nDone: {d} scans in {d:.1}s\n", .{ scans, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 });
    return 0;
}

/// Stream-parses the MGF file in 8MB chunks, writing one JSON per scan.
/// Returns the number of scans written.
fn parseMgfStream(
    gpa: std.mem.Allocator,
    io: std.Io,
    mgf_path: []const u8,
    out_dir: []const u8,
) !usize {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.open_file(io, mgf_path, .{});
    defer file.close(io);

    var in_block = false;
    var scn: ?u32 = null;
    var mzs: std.ArrayList(f64) = .empty;
    defer mzs.deinit(gpa);
    var ints: std.ArrayList(f64) = .empty;
    defer ints.deinit(gpa);

    var scans: usize = 0;
    var errs: usize = 0;

    // Accumulator: lines from the previous chunk that didn't end with \n.
    var line_acc: std.ArrayList(u8) = .empty;
    defer line_acc.deinit(gpa);

    // Read buffer: 8MB.
    var read_buf: [READ_CHUNK]u8 = undefined;
    var file_offset: u64 = 0;

    while (true) {
        const n = try file.readPositionalAll(io, &read_buf, file_offset);
        if (n == 0) break; // EOF
        file_offset += n;

        // Split chunk on '\n'. The last segment (after the final \n, or the
        // whole chunk if no \n) is the "tail" and may be a partial line.
        var start: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (read_buf[i] == '\n') {
                // We have a complete line in read_buf[start..i].
                try line_acc.appendSlice(gpa, read_buf[start..i]);
                const line = std.mem.trimEnd(u8, line_acc.items, "\r");
                try processLine(gpa, io, out_dir, line, &in_block, &scn, &mzs, &ints, &scans, &errs);
                line_acc.clearRetainingCapacity();
                start = i + 1;
            }
        }
        // Stash the tail (partial last line) for the next chunk.
        if (start < n) {
            try line_acc.appendSlice(gpa, read_buf[start..n]);
        }
    }

    // Process any final partial line at EOF.
    if (line_acc.items.len > 0) {
        const line = std.mem.trimEnd(u8, line_acc.items, "\r");
        try processLine(gpa, io, out_dir, line, &in_block, &scn, &mzs, &ints, &scans, &errs);
    }

    if (errs > 0) std.debug.print("  ({d} errors)\n", .{errs});
    return scans;
}

fn processLine(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    line: []const u8,
    in_block: *bool,
    scn: *?u32,
    mzs: *std.ArrayList(f64),
    ints: *std.ArrayList(f64),
    scans: *usize,
    errs: *usize,
) !void {
    if (std.mem.startsWith(u8, line, "BEGIN IONS")) {
        in_block.* = true;
        return;
    }
    if (!in_block.*) return;

    if (std.mem.startsWith(u8, line, "END IONS")) {
        if (scn.*) |sn| {
            writeOne(gpa, io, out_dir, sn, mzs.items, ints.items) catch {
                errs.* += 1;
            };
            scans.* += 1;
            if (scans.* % 500 == 0) std.debug.print("  {d} scans...\n", .{scans.*});
        }
        in_block.* = false;
        scn.* = null;
        mzs.clearRetainingCapacity();
        ints.clearRetainingCapacity();
        return;
    }

    if (std.mem.startsWith(u8, line, "TITLE=")) {
        if (std.mem.indexOf(u8, line, "scan=")) |p| {
            const r = line[p + 5 ..];
            const e = std.mem.indexOfScalar(u8, r, ' ') orelse r.len;
            scn.* = std.fmt.parseInt(u32, r[0..e], 10) catch null;
        }
        return;
    } else if (std.mem.startsWith(u8, line, "RTINSECONDS=") or
        std.mem.startsWith(u8, line, "PEPMASS=") or
        std.mem.startsWith(u8, line, "CHARGE="))
    {
        return;
    }

    // Parse m/z intensity pair.
    var parts = std.mem.splitScalar(u8, line, ' ');
    const mz_s = parts.next() orelse return;
    const int_s = parts.next() orelse return;
    const mz = std.fmt.parseFloat(f64, mz_s) catch return;
    const intensity = std.fmt.parseFloat(f64, int_s) catch return;
    try mzs.append(gpa, mz);
    try ints.append(gpa, intensity);
}

fn writeOne(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    idx: u32,
    mzs: []f64,
    ints: []f64,
) !void {
    const name = try std.fmt.allocPrint(gpa, "{s}/{d:0>5}.json", .{ out_dir, idx });
    defer gpa.free(name);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, name, .{});
    defer file.close(io);

    // Build JSON in memory, then write in one drain call.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\"mzs\":[");
    for (mzs, 0..) |v, i| {
        if (i > 0) try buf.append(gpa, ',');
        var nb: [64]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nb, "{d}", .{v}));
    }
    try buf.appendSlice(gpa, "],\"intensities\":[");
    for (ints, 0..) |v, i| {
        if (i > 0) try buf.append(gpa, ',');
        var nb: [64]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nb, "{d}", .{v}));
    }
    try buf.appendSlice(gpa, "]}");

    try file.writePositionalAll(io, buf.items, 0);
}
