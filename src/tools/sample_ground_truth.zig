/// Sampled ground truth generator — generates per-scan JSON for N random scans.
/// Used for large .raw files where generating ground truth for every scan is
/// impractical (profile-mode Astral files produce 10s of GB of MGF/JSON).
///
/// IMPORTANT: Must be run from repo root. Output paths are relative to CWD.
/// Usage: zig build sample-ground-truth -- <raw-file> [N]
///        N defaults to 1000.
///
/// Strategy: pick N random scan INDICES (0-based, mzigRead convention), convert
/// to scan NUMBERS (1-based, Thermo convention with possible gaps), run TRFP
/// query subcommand for just those scans, parse the JSON output, write per-scan
/// JSON files. The same N random indices are used by the verifier (same seed).
const std = @import("std");
const cli = @import("cli_args");
const reader = @import("raw_file_reader");

const TRFP_EXE = "D:/000projects/newRawFileReader/ThermoRawFileParser-master/ThermoRawFileParser-master/bin/x64/Release/net8.0/ThermoRawFileParser.exe";
const DEFAULT_SAMPLE_SIZE: usize = 1000;
const RNG_SEED: u64 = 0xC0FFEE_BEEF;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    const args = cli.get_args(gpa) catch {
        std.debug.print("usage: sample-ground-truth <raw-file> [N]\n", .{});
        return 1;
    };
    defer {
        for (args) |a| gpa.free(a);
        gpa.free(args);
    }
    if (args.len < 2) {
        std.debug.print("usage: sample-ground-truth <raw-file> [N]\n", .{});
        return 1;
    }
    const raw_path = args[1];
    const n: usize = if (args.len >= 3)
        std.fmt.parseInt(usize, args[2], 10) catch DEFAULT_SAMPLE_SIZE
    else
        DEFAULT_SAMPLE_SIZE;

    const raw_filename = std.fs.path.basename(raw_path);
    const dot = std.mem.lastIndexOfScalar(u8, raw_filename, '.') orelse raw_filename.len;
    const base_name = raw_filename[0..dot];
    const out_dir = try std.fmt.allocPrint(gpa, "tests/ground_truth/{s}", .{base_name});
    defer gpa.free(out_dir);

    // TRFP query subcommand adds .json extension to the output file.
    const temp_path = try std.fmt.allocPrint(gpa, "{s}/_temp_sampled", .{out_dir});
    defer gpa.free(temp_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "tests/ground_truth");
    try cwd.createDirPath(io, out_dir);

    // Open the raw file to get scan count and convert indices → scan numbers.
    var rf = reader.RawFile.open(gpa, io, raw_path) catch |err| {
        std.debug.print("error: cannot open '{s}': {}\n", .{ raw_path, err });
        return 1;
    };
    defer rf.deinit();

    const total = rf.num_scans;
    if (total == 0) {
        std.debug.print("error: raw file has 0 scans\n", .{});
        return 1;
    }

    const sample_n = @min(n, total);
    std.debug.print("File:        {s}\n", .{raw_filename});
    std.debug.print("Total scans: {d}\n", .{total});
    std.debug.print("Sampling:    {d} random scans (seed=0x{X})\n", .{ sample_n, RNG_SEED });
    std.debug.print("Output:      {s}\n\n", .{out_dir});

    // Pick sample_n random scan indices, then convert to scan numbers.
    // Using a deterministic PRNG (xorshift64) with a fixed seed so the same
    // indices are picked every run. The verifier uses the same seed.
    var sample_indices: std.ArrayList(usize) = .empty;
    defer sample_indices.deinit(gpa);
    try sample_indices.ensureTotalCapacity(gpa, sample_n);

    var sample_numbers: std.ArrayList(u32) = .empty;
    defer sample_numbers.deinit(gpa);
    try sample_numbers.ensureTotalCapacity(gpa, sample_n);

    var seed: u64 = RNG_SEED;
    var picked: usize = 0;
    while (picked < sample_n) : (picked += 1) {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        const idx = @as(usize, @intCast(seed % total));
        const scan_num = rf.scan_at(@intCast(idx + 1)) catch continue;
        sample_indices.appendAssumeCapacity(idx);
        sample_numbers.appendAssumeCapacity(@intCast(scan_num.scan_number));
    }

    // Sort scan numbers ascending — TRFP's -n parser interprets the comma
    // list as intervals, so they must be in ascending order.
    std.mem.sort(u32, sample_numbers.items, {}, std.sort.asc(u32));

    // Build the -n argument: comma-separated scan numbers, e.g. "1,5,42,..."
    var n_arg: std.ArrayList(u8) = .empty;
    defer n_arg.deinit(gpa);
    for (sample_numbers.items, 0..) |sn, i| {
        if (i > 0) try n_arg.append(gpa, ',');
        var nb: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&nb, "{d}", .{sn});
        try n_arg.appendSlice(gpa, s);
    }

    // Run TRFP query with just the sampled scan numbers.
    // Note: query subcommand outputs JSON (not MGF) and adds .json extension.
    const argv = &[_][]const u8{
        TRFP_EXE,
        "query",
        "-i",
        raw_path,
        "-n",
        n_arg.items,
        "-b",
        temp_path,
    };

    std.debug.print("Running TRFP query for {d} scans...\n", .{sample_n});
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

    // Parse the JSON output and write per-scan files.
    // The TRFP query output is a JSON array of scan objects, each with:
    //   "mzs": [f64, ...], "intensities": [f64, ...], "attributes": [{accession, name, value}, ...]
    // We need scan number, RT, MS level from attributes, plus mzs and intensities.
    const json_path = try std.fmt.allocPrint(gpa, "{s}.json", .{temp_path});
    defer gpa.free(json_path);

    const scans_written = parseAndWrite(gpa, io, json_path, out_dir) catch |err| {
        std.debug.print("error parsing JSON: {}\n", .{err});
        return 1;
    };

    // Clean up the temp JSON file.
    cwd.deleteFile(io, json_path) catch {};

    // Save the sample indices for the verifier.
    const sample_path = try std.fmt.allocPrint(gpa, "{s}/_sample_indices.txt", .{out_dir});
    defer gpa.free(sample_path);
    const sample_file = try cwd.createFile(io, sample_path, .{});
    defer sample_file.close(io);
    var sample_buf: std.ArrayList(u8) = .empty;
    defer sample_buf.deinit(gpa);
    for (sample_indices.items) |idx| {
        var nb: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&nb, "{d}\n", .{idx});
        try sample_buf.appendSlice(gpa, s);
    }
    try sample_file.writePositionalAll(io, sample_buf.items, 0);

    const elapsed = t0.untilNow(io, .boot).toMicroseconds();
    std.debug.print("\nDone: {d} JSONs in {d:.1}s\n", .{ scans_written, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 });
    return 0;
}

/// Parse the TRFP JSON output and write one per-scan JSON file per scan.
/// The TRFP JSON is a single array of scan objects.
fn parseAndWrite(
    gpa: std.mem.Allocator,
    io: std.Io,
    json_path: []const u8,
    out_dir: []const u8,
) !usize {
    const cwd = std.Io.Dir.cwd();
    const content = try cwd.readFileAlloc(io, json_path, gpa, .unlimited);
    defer gpa.free(content);

    // Parse as an array of generic JSON values, then extract mzs/intensities
    // from each. We use std.json.ValueTree for flexibility.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return error.UnexpectedJsonFormat;

    var scans_written: usize = 0;
    for (root.array.items) |scan_value| {
        if (scan_value != .object) continue;

        const obj = scan_value.object;

        // Extract mzs and intensities.
        const mzs_val = obj.get("mzs") orelse continue;
        const int_val = obj.get("intensities") orelse continue;
        if (mzs_val != .array or int_val != .array) continue;

        // Extract scan number from attributes.
        var scan_num: u32 = 0;
        var rt_min: f64 = 0;
        var ms_level: u8 = 0;

        if (obj.get("attributes")) |attrs| {
            if (attrs == .array) {
                for (attrs.array.items) |attr| {
                    if (attr != .object) continue;
                    const name = attr.object.get("name") orelse continue;
                    if (name != .string) continue;
                    const value = attr.object.get("value") orelse continue;

                    if (std.mem.eql(u8, name.string, "scan number")) {
                        if (value == .string) {
                            scan_num = std.fmt.parseInt(u32, value.string, 10) catch 0;
                        } else if (value == .integer) {
                            scan_num = @intCast(value.integer);
                        }
                    } else if (std.mem.eql(u8, name.string, "scan start time")) {
                        if (value == .string) {
                            rt_min = std.fmt.parseFloat(f64, value.string) catch 0;
                        } else if (value == .float) {
                            rt_min = value.float;
                        }
                    } else if (std.mem.eql(u8, name.string, "ms level")) {
                        if (value == .string) {
                            ms_level = std.fmt.parseInt(u8, value.string, 10) catch 0;
                        } else if (value == .integer) {
                            ms_level = @intCast(value.integer);
                        }
                    }
                }
            }
        }

        if (scan_num == 0) continue;

        try writeScanJson(gpa, io, out_dir, scan_num, mzs_val.array.items, int_val.array.items);
        scans_written += 1;
    }

    return scans_written;
}

fn writeScanJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    scan_num: u32,
    mzs: []const std.json.Value,
    intensities: []const std.json.Value,
) !void {
    const name = try std.fmt.allocPrint(gpa, "{s}/{d:0>5}.json", .{ out_dir, scan_num });
    defer gpa.free(name);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, name, .{});
    defer file.close(io);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // Write {"mzs":[...],"intensities":[...],"rt":<f64>,"ms_level":<u8>}
    // The verifier only reads mzs and intensities, but we include RT and MS
    // level for future use.
    try buf.appendSlice(gpa, "{\"mzs\":[");
    for (mzs, 0..) |v, i| {
        if (i > 0) try buf.append(gpa, ',');
        const f = jsonToFloat(v) orelse continue;
        var nb: [64]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nb, "{d}", .{f}));
    }
    try buf.appendSlice(gpa, "],\"intensities\":[");
    for (intensities, 0..) |v, i| {
        if (i > 0) try buf.append(gpa, ',');
        const f = jsonToFloat(v) orelse continue;
        var nb: [64]u8 = undefined;
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&nb, "{d}", .{f}));
    }
    try buf.append(gpa, ']');
    try buf.append(gpa, '}');

    try file.writePositionalAll(io, buf.items, 0);
}

fn jsonToFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}
