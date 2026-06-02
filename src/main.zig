/// Raw Orbitrap Viewer - fully-featured GUI application.
///
/// Usage:
///   raw-orbitrap-viewer.exe                    (opens GUI with no file)
///   raw-orbitrap-viewer.exe <raw-file>         (opens GUI with file loaded)
///   raw-orbitrap-viewer.exe <raw-file> scan <scan-number>   (legacy CLI mode)
///   raw-orbitrap-viewer.exe <raw-file> offset <absolute-packet-offset>   (legacy)
///   raw-orbitrap-viewer.exe --benchmark-real <dir>          (headless benchmark)
const std = @import("std");
const ap = @import("advanced_packet");
const raw = @import("raw_file");
const main_window = @import("main_window");
const app = @import("app_state");

const MAX_PACKET_BYTES: usize = 8 * 1024 * 1024;

const LPCWSTR = [*:0]const u16;
const LPWSTR = [*:0]u16;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPCWSTR;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, pNumArgs: *i32) callconv(.winapi) ?[*]LPWSTR;
extern "kernel32" fn LocalFree(hMem: ?[*]LPWSTR) callconv(.winapi) ?*anyopaque;

const CliArgs = struct {
    raw_path: ?[]u8,
    mode: ?[]u8,
    value: ?[]u8,
    benchmark_real_dir: ?[]u8,
    benchmark_cold_dir: ?[]u8,

    fn deinit(self: CliArgs, allocator: std.mem.Allocator) void {
        if (self.raw_path) |p| allocator.free(p);
        if (self.mode) |m| allocator.free(m);
        if (self.value) |v| allocator.free(v);
        if (self.benchmark_real_dir) |d| allocator.free(d);
        if (self.benchmark_cold_dir) |d| allocator.free(d);
    }
};

fn utf16ZLen(s: [*:0]const u16) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

fn utf16ZToAsciiAlloc(allocator: std.mem.Allocator, s: [*:0]const u16) ![]u8 {
    const n = utf16ZLen(s);
    const out = try allocator.alloc(u8, n);
    errdefer allocator.free(out);

    for (out, 0..) |*c, i| {
        const ch = s[i];
        if (ch > 0x7f) return error.NonAsciiArgument;
        c.* = @intCast(ch);
    }

    return out;
}

fn getCliArgs(allocator: std.mem.Allocator) !CliArgs {
    var argc: i32 = 0;
    const argv_w = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return error.CommandLineToArgvFailed;
    defer _ = LocalFree(argv_w);

    if (argc < 2) {
        return .{ .raw_path = null, .mode = null, .value = null, .benchmark_real_dir = null, .benchmark_cold_dir = null };
    }

    const first = argv_w[1];
    const first_len = utf16ZLen(first);

    // Check for --benchmark-real <dir>
    if (first_len >= 16 and std.mem.eql(u16, first[0..16], &[_]u16{ '-', '-', 'b', 'e', 'n', 'c', 'h', 'm', 'a', 'r', 'k', '-', 'r', 'e', 'a', 'l' })) {
        if (argc >= 3) {
            const dir = try utf16ZToAsciiAlloc(allocator, argv_w[2]);
            return .{ .raw_path = null, .mode = null, .value = null, .benchmark_real_dir = dir, .benchmark_cold_dir = null };
        }
    }

    // Check for --benchmark-cold <dir>
    if (first_len >= 16 and std.mem.eql(u16, first[0..16], &[_]u16{ '-', '-', 'b', 'e', 'n', 'c', 'h', 'm', 'a', 'r', 'k', '-', 'c', 'o', 'l', 'd' })) {
        if (argc >= 3) {
            const dir = try utf16ZToAsciiAlloc(allocator, argv_w[2]);
            return .{ .raw_path = null, .mode = null, .value = null, .benchmark_real_dir = null, .benchmark_cold_dir = dir };
        }
    }

    const raw_path = try utf16ZToAsciiAlloc(allocator, argv_w[1]);
    errdefer allocator.free(raw_path);

    if (argc < 3) {
        return .{ .raw_path = raw_path, .mode = null, .value = null, .benchmark_real_dir = null, .benchmark_cold_dir = null };
    }

    const mode = try utf16ZToAsciiAlloc(allocator, argv_w[2]);
    errdefer allocator.free(mode);

    if (argc < 4) {
        return .{ .raw_path = raw_path, .mode = mode, .value = null, .benchmark_real_dir = null, .benchmark_cold_dir = null };
    }

    const value = try utf16ZToAsciiAlloc(allocator, argv_w[3]);
    errdefer allocator.free(value);

    return .{
        .raw_path = raw_path,
        .mode = mode,
        .value = value,
        .benchmark_real_dir = null,
        .benchmark_cold_dir = null,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const cli = getCliArgs(allocator) catch |err| {
        std.debug.print("error: failed to parse command line: {}\n", .{err});
        std.process.exit(1);
    };
    defer cli.deinit(allocator);

    // Benchmark-real mode
    if (cli.benchmark_real_dir) |dir| {
        try runBenchmarkReal(allocator, io, dir);
        return;
    }

    // Benchmark-cold mode
    if (cli.benchmark_cold_dir) |dir| {
        try runBenchmarkCold(allocator, io, dir);
        return;
    }

    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    // If CLI args specify a file, try to open it before launching GUI
    if (cli.raw_path) |raw_path| {
        if (cli.mode) |mode| {
            if (std.mem.eql(u8, mode, "benchmark")) {
                try runBenchmark(allocator, io, raw_path);
                return;
            }
            if (cli.value) |value| {
                // Legacy CLI mode: decode and show single scan, then exit
                try runLegacyMode(allocator, io, raw_path, mode, value);
                return;
            }
        }

        // GUI mode with initial file
        state.openFile(raw_path) catch |err| {
            std.debug.print("warning: failed to open '{s}': {}\n", .{ raw_path, err });
            // Continue with empty state
        };

        // Load first scan if available
        if (state.scans.len > 0) {
            state.loadScan(0) catch |err| {
                std.debug.print("warning: failed to load first scan: {}\n", .{err});
            };
        }
    }

    // Launch the full GUI
    try main_window.run(&state);
}

fn runLegacyMode(allocator: std.mem.Allocator, io: std.Io, raw_path: []const u8, mode: []const u8, value: []const u8) !void {
    const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, raw_path, .{}) catch |err| {
        std.debug.print("error: cannot open '{s}': {}\n", .{ raw_path, err });
        std.process.exit(1);
    };
    defer file.close(io);

    const file_size = (try file.stat(io)).size;

    const packet_offset = try resolvePacketOffset(file, io, mode, value, file_size);

    if (packet_offset >= file_size) {
        std.debug.print(
            "error: offset 0x{x} ({d}) is beyond end of file ({d} bytes)\n",
            .{ packet_offset, packet_offset, file_size },
        );
        std.process.exit(1);
    }

    const read_len: usize = @intCast(@min(
        @as(u64, MAX_PACKET_BYTES),
        file_size - packet_offset,
    ));

    const buf = try allocator.alloc(u8, read_len);
    defer allocator.free(buf);

    const bytes_read = try std.Io.File.readPositionalAll(file, io, buf, packet_offset);
    if (bytes_read < read_len) {
        @memset(buf[bytes_read..], 0);
    }

    const spectrum = ap.decodeSimplifiedCentroids(allocator, buf, 0) catch |err| {
        std.debug.print("error: failed to decode packet at absolute offset 0x{x}: {}\n", .{ packet_offset, err });
        std.process.exit(1);
    };
    defer spectrum.deinit(allocator);

    std.debug.print(
        "info: decoded {d} centroid points across {d} segment(s)\n",
        .{ spectrum.pointCount(), spectrum.ranges.len },
    );
    if (spectrum.pointCount() > 0) {
        std.debug.print(
            "info: m/z range {d:.4} – {d:.4},  max intensity {d:.1}\n",
            .{ spectrum.mzMin(), spectrum.mzMax(), spectrum.intensityMax() },
        );
    }

    // In legacy mode, we still launch the simple viewer for backward compat
    const viewer = @import("win32_viewer");
    try viewer.run(&spectrum);
}

fn resolvePacketOffset(file: std.Io.File, io: std.Io, mode: []const u8, value: []const u8, file_size: u64) !u64 {
    if (std.mem.eql(u8, mode, "offset")) {
        return std.fmt.parseInt(u64, value, 0) catch |err| {
            std.debug.print("error: cannot parse absolute offset '{s}': {}\n", .{ value, err });
            std.process.exit(1);
        };
    }

    if (std.mem.eql(u8, mode, "scan")) {
        const scan_number = std.fmt.parseInt(i32, value, 10) catch |err| {
            std.debug.print("error: cannot parse scan number '{s}': {}\n", .{ value, err });
            std.process.exit(1);
        };
        const resolved = raw.resolveScan(file, io, scan_number) catch |err| {
            std.debug.print("error: failed to resolve scan {d}: {}\n", .{ scan_number, err });
            std.process.exit(1);
        };

        std.debug.print(
            "info: file rev {d}, MS controller {d}, scan range {d}-{d}\n",
            .{ resolved.file_revision, resolved.ms_controller_index, resolved.first_spectrum, resolved.last_spectrum },
        );
        std.debug.print(
            "info: scan {d} index @ 0x{x}, packet type {d}, relative DataOffset 0x{x}\n",
            .{ resolved.scan_index.scan_number, resolved.scan_index_pos, resolved.scan_index.packet_type, resolved.scan_index.data_offset },
        );
        std.debug.print(
            "info: PacketPos 0x{x} + DataOffset 0x{x} = absolute packet offset 0x{x}\n",
            .{ resolved.packet_pos, resolved.scan_index.data_offset, resolved.absolute_packet_offset },
        );

        if (resolved.absolute_packet_offset >= file_size) {
            std.debug.print(
                "error: resolved packet offset 0x{x} is beyond end of file ({d} bytes)\n",
                .{ resolved.absolute_packet_offset, file_size },
            );
            std.process.exit(1);
        }
        return resolved.absolute_packet_offset;
    }

    std.debug.print("error: unknown mode '{s}'\n\n", .{mode});
    try printUsage();
    std.process.exit(1);
}

fn runBenchmark(allocator: std.mem.Allocator, io: std.Io, raw_path: []const u8) !void {
    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    const file_size_mb = blk: {
        const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, raw_path, .{}) catch |err| {
            std.debug.print("error: cannot open '{s}': {}\n", .{ raw_path, err });
            std.process.exit(1);
        };
        defer file.close(io);
        const size = (try file.stat(io)).size;
        break :blk @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
    };

    // --- BENCHMARK 1: File Open ---
    const t_open_start = std.Io.Clock.now(.boot, io);
    state.openFile(raw_path) catch |err| {
        std.debug.print("error: failed to open '{s}': {}\n", .{ raw_path, err });
        std.process.exit(1);
    };
    const t_open = t_open_start.untilNow(io, .boot).toMicroseconds();
    const num_scans = state.scans.len;

    std.debug.print("benchmark, file, file_size_mb, num_scans, operation, time_us, points_decoded\n", .{});
    std.debug.print("zig, {s}, {d:.1}, {d}, open, {d}, 0\n", .{ raw_path, file_size_mb, num_scans, t_open });

    if (num_scans == 0) {
        std.debug.print("error: no scans found in file\n", .{});
        std.process.exit(1);
    }

    // --- BENCHMARK 2: First Scan Load ---
    const t_first_start = std.Io.Clock.now(.boot, io);
    state.loadScan(0) catch |err| {
        std.debug.print("error: failed to load first scan: {}\n", .{err});
        std.process.exit(1);
    };
    const t_first = t_first_start.untilNow(io, .boot).toMicroseconds();
    const first_points = if (state.current_spectrum) |s| s.pointCount() else 0;
    std.debug.print("zig, {s}, {d:.1}, {d}, first_scan, {d}, {d}\n", .{ raw_path, file_size_mb, num_scans, t_first, first_points });

    // --- BENCHMARK 3: Random Scan Load (sample 10 scans) ---
    var total_random_time: i64 = 0;
    var total_random_points: usize = 0;
    var sample_idx: usize = 0;
    while (sample_idx < 10) : (sample_idx += 1) {
        const idx = (num_scans * (sample_idx + 1)) / 11;
        const t_rand_start = std.Io.Clock.now(.boot, io);
        state.loadScan(idx) catch |err| {
            std.debug.print("warning: failed to load scan {d}: {}\n", .{ idx, err });
            continue;
        };
        total_random_time += t_rand_start.untilNow(io, .boot).toMicroseconds();
        total_random_points += if (state.current_spectrum) |s| s.pointCount() else 0;
    }
    std.debug.print("zig, {s}, {d:.1}, {d}, random_10, {d}, {d}\n", .{ raw_path, file_size_mb, num_scans, total_random_time, total_random_points });

    // --- BENCHMARK 4: Sequential Scan Load (first 100 scans) ---
    const seq_count = @min(100, num_scans);
    const t_seq_start = std.Io.Clock.now(.boot, io);
    var total_seq_points: usize = 0;
    var seq_idx: usize = 0;
    while (seq_idx < seq_count) : (seq_idx += 1) {
        state.loadScan(seq_idx) catch |err| {
            std.debug.print("warning: failed to load scan {d}: {}\n", .{ seq_idx, err });
            continue;
        };
        total_seq_points += if (state.current_spectrum) |s| s.pointCount() else 0;
    }
    const t_seq = t_seq_start.untilNow(io, .boot).toMicroseconds();
    std.debug.print("zig, {s}, {d:.1}, {d}, sequential_100, {d}, {d}\n", .{ raw_path, file_size_mb, num_scans, t_seq, total_seq_points });

    // --- BENCHMARK 5: Full File Iteration (loadScan - with allocation overhead) ---
    const t_full_start = std.Io.Clock.now(.boot, io);
    var total_full_points: usize = 0;
    var full_idx: usize = 0;
    while (full_idx < num_scans) : (full_idx += 1) {
        state.loadScan(full_idx) catch |err| {
            std.debug.print("warning: failed to load scan {d}: {}\n", .{ full_idx, err });
            continue;
        };
        total_full_points += if (state.current_spectrum) |s| s.pointCount() else 0;
    }
    const t_full = t_full_start.untilNow(io, .boot).toMicroseconds();
    std.debug.print("zig, {s}, {d:.1}, {d}, full_iteration, {d}, {d}\n", .{ raw_path, file_size_mb, num_scans, t_full, total_full_points });

    // --- BENCHMARK 6: Full File Iteration Bulk (loadScanBulk - zero allocation) ---
    const t_bulk_start = std.Io.Clock.now(.boot, io);
    var total_bulk_points: usize = 0;
    var bulk_idx: usize = 0;
    while (bulk_idx < num_scans) : (bulk_idx += 1) {
        const n = state.loadScanBulk(bulk_idx) catch |err| {
            std.debug.print("warning: failed to bulk load scan {d}: {}\n", .{ bulk_idx, err });
            continue;
        };
        total_bulk_points += n;
    }
    const t_bulk = t_bulk_start.untilNow(io, .boot).toMicroseconds();
    std.debug.print("zig, {s}, {d:.1}, {d}, full_iteration_bulk, {d}, {d}\n", .{ raw_path, file_size_mb, num_scans, t_bulk, total_bulk_points });
}

fn runBenchmarkReal(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    // Open directory and collect .raw files
    const dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("error: cannot open directory '{s}': {}\n", .{ dir_path, err });
        std.process.exit(1);
    };
    defer dir.close(io);

    var raw_files = std.ArrayList([]const u8).empty;
    defer {
        for (raw_files.items) |name| allocator.free(name);
        raw_files.deinit(allocator);
    }

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch |err| {
            std.debug.print("warning: directory iteration error: {}\n", .{err});
            break;
        } orelse break;
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len < 4 or !std.mem.eql(u8, name[name.len - 4 ..], ".raw")) continue;
        const name_copy = try allocator.dupe(u8, name);
        try raw_files.append(allocator, name_copy);
    }

    if (raw_files.items.len == 0) {
        std.debug.print("error: no .raw files found in '{s}'\n", .{dir_path});
        std.process.exit(1);
    }

    // Sort for deterministic order
    const SortCtx = struct {
        pub fn lessThan(_: @This(), a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    };
    std.mem.sort([]const u8, raw_files.items, SortCtx{}, SortCtx.lessThan);

    // Print JSONL header comment
    std.debug.print("# benchmark-real: {d} files\n", .{raw_files.items.len});

    const t_total_start = std.Io.Clock.now(.boot, io);
    var files_processed: usize = 0;

    for (raw_files.items) |name| {
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(file_path);

        // Get file size
        const file_size = blk: {
            const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, file_path, .{}) catch |err| {
                std.debug.print("warning: cannot open '{s}': {}\n", .{ file_path, err });
                continue;
            };
            defer file.close(io);
            break :blk (try file.stat(io)).size;
        };

        var state = app.AppState.init(allocator, io);
        defer state.deinit();

        // --- B1: File Open ---
        const t_open_start = std.Io.Clock.now(.boot, io);
        state.openFile(file_path) catch |err| {
            std.debug.print("warning: failed to open '{s}': {}\n", .{ file_path, err });
            continue;
        };
        const t_open = t_open_start.untilNow(io, .boot).toMicroseconds();
        const num_scans = state.scans.len;
        printJsonl(name, file_size, "B1_open", t_open, 0, num_scans);

        if (num_scans == 0) continue;

        // --- B2: First Scan Load ---
        const t_first_start = std.Io.Clock.now(.boot, io);
        state.loadScan(0) catch |err| {
            std.debug.print("warning: failed to load first scan of '{s}': {}\n", .{ file_path, err });
            continue;
        };
        const t_first = t_first_start.untilNow(io, .boot).toMicroseconds();
        const first_points = if (state.current_spectrum) |s| s.pointCount() else 0;
        printJsonl(name, file_size, "B2_first_scan", t_first, first_points, 1);

        // --- B3: Random Scan Load (sample 10,000 scans) ---
        var total_random_time: i64 = 0;
        var total_random_points: usize = 0;
        var random_scans: usize = 0;
        const random_sample_count = @min(10000, num_scans);
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.now(.boot, io).nanoseconds));
        const rand = prng.random();
        var sample_idx: usize = 0;
        while (sample_idx < random_sample_count) : (sample_idx += 1) {
            const idx = rand.intRangeLessThan(usize, 0, num_scans);
            const t_rand_start = std.Io.Clock.now(.boot, io);
            state.loadScan(idx) catch |err| {
                std.debug.print("warning: failed to load scan {d} of '{s}': {}\n", .{ idx, file_path, err });
                continue;
            };
            total_random_time += t_rand_start.untilNow(io, .boot).toMicroseconds();
            total_random_points += if (state.current_spectrum) |s| s.pointCount() else 0;
            random_scans += 1;
        }
        printJsonl(name, file_size, "B3_random", total_random_time, total_random_points, random_scans);

        // --- B4: Sequential Scan Load (first 1,000 scans) ---
        const seq_count = @min(1000, num_scans);
        const t_seq_start = std.Io.Clock.now(.boot, io);
        var total_seq_points: usize = 0;
        var seq_idx: usize = 0;
        while (seq_idx < seq_count) : (seq_idx += 1) {
            state.loadScan(seq_idx) catch |err| {
                std.debug.print("warning: failed to load scan {d} of '{s}': {}\n", .{ seq_idx, file_path, err });
                continue;
            };
            total_seq_points += if (state.current_spectrum) |s| s.pointCount() else 0;
        }
        const t_seq = t_seq_start.untilNow(io, .boot).toMicroseconds();
        printJsonl(name, file_size, "B4_sequential", t_seq, total_seq_points, seq_count);

        // --- B5: Full File Iteration ---
        const t_full_start = std.Io.Clock.now(.boot, io);
        var total_full_points: usize = 0;
        var full_idx: usize = 0;
        while (full_idx < num_scans) : (full_idx += 1) {
            state.loadScan(full_idx) catch |err| {
                std.debug.print("warning: failed to load scan {d} of '{s}': {}\n", .{ full_idx, file_path, err });
                continue;
            };
            total_full_points += if (state.current_spectrum) |s| s.pointCount() else 0;
        }
        const t_full = t_full_start.untilNow(io, .boot).toMicroseconds();
        printJsonl(name, file_size, "B5_full_iteration", t_full, total_full_points, num_scans);
        files_processed += 1;
    }

    const t_total = t_total_start.untilNow(io, .boot).toMicroseconds();
    std.debug.print("# benchmark-real complete: {d}/{d} files processed in {d} us ({d} ms)\n", .{ files_processed, raw_files.items.len, t_total, @divTrunc(t_total, 1000) });
}

fn runBenchmarkCold(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    // Open directory and collect .raw files
    const dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("error: cannot open directory '{s}': {}\n", .{ dir_path, err });
        std.process.exit(1);
    };
    defer dir.close(io);

    var raw_files = std.ArrayList([]const u8).empty;
    defer {
        for (raw_files.items) |name| allocator.free(name);
        raw_files.deinit(allocator);
    }

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch |err| {
            std.debug.print("warning: directory iteration error: {}\n", .{err});
            break;
        } orelse break;
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len < 4 or !std.mem.eql(u8, name[name.len - 4 ..], ".raw")) continue;
        const name_copy = try allocator.dupe(u8, name);
        try raw_files.append(allocator, name_copy);
    }

    if (raw_files.items.len == 0) {
        std.debug.print("error: no .raw files found in '{s}'\n", .{dir_path});
        std.process.exit(1);
    }

    // Sort for deterministic order
    const SortCtx = struct {
        pub fn lessThan(_: @This(), a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    };
    std.mem.sort([]const u8, raw_files.items, SortCtx{}, SortCtx.lessThan);

    std.debug.print("# benchmark-cold: {d} files\n", .{raw_files.items.len});

    const t_total_start = std.Io.Clock.now(.boot, io);
    var files_processed: usize = 0;

    for (raw_files.items) |name| {
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(file_path);

        // Get file size
        const file_size = blk: {
            const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, file_path, .{}) catch |err| {
                std.debug.print("warning: cannot open '{s}': {}\n", .{ file_path, err });
                continue;
            };
            defer file.close(io);
            break :blk (try file.stat(io)).size;
        };

        var state = app.AppState.init(allocator, io);
        defer state.deinit();

        // --- B1: File Open (cold) ---
        const t_open_start = std.Io.Clock.now(.boot, io);
        state.openFile(file_path) catch |err| {
            std.debug.print("warning: failed to open '{s}': {}\n", .{ file_path, err });
            continue;
        };
        const t_open = t_open_start.untilNow(io, .boot).toMicroseconds();
        const num_scans = state.scans.len;
        printJsonl(name, file_size, "B1_open_cold", t_open, 0, num_scans);

        if (num_scans == 0) continue;

        // --- B2: First Scan Load (cold) ---
        const t_first_start = std.Io.Clock.now(.boot, io);
        state.loadScan(0) catch |err| {
            std.debug.print("warning: failed to load first scan of '{s}': {}\n", .{ file_path, err });
            continue;
        };
        const t_first = t_first_start.untilNow(io, .boot).toMicroseconds();
        const first_points = if (state.current_spectrum) |s| s.pointCount() else 0;
        printJsonl(name, file_size, "B2_first_scan_cold", t_first, first_points, 1);

        // --- B3: Random Scan Load (100 cold samples) ---
        // Limited to 100 samples to stay truly cold (no cache warmup)
        var total_random_time: i64 = 0;
        var total_random_points: usize = 0;
        var random_scans: usize = 0;
        const random_sample_count = @min(100, num_scans);
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.now(.boot, io).nanoseconds));
        const rand = prng.random();
        var sample_idx: usize = 0;
        while (sample_idx < random_sample_count) : (sample_idx += 1) {
            const idx = rand.intRangeLessThan(usize, 0, num_scans);
            const t_rand_start = std.Io.Clock.now(.boot, io);
            state.loadScan(idx) catch |err| {
                std.debug.print("warning: failed to load scan {d} of '{s}': {}\n", .{ idx, file_path, err });
                continue;
            };
            total_random_time += t_rand_start.untilNow(io, .boot).toMicroseconds();
            total_random_points += if (state.current_spectrum) |s| s.pointCount() else 0;
            random_scans += 1;
        }
        printJsonl(name, file_size, "B3_random_cold", total_random_time, total_random_points, random_scans);

        files_processed += 1;
    }

    const t_total = t_total_start.untilNow(io, .boot).toMicroseconds();
    std.debug.print("# benchmark-cold complete: {d}/{d} files processed in {d} us ({d} ms)\n", .{ files_processed, raw_files.items.len, t_total, @divTrunc(t_total, 1000) });
}

fn printJsonl(file_name: []const u8, file_size: u64, benchmark: []const u8, elapsed_us: i64, peaks: usize, scans: usize) void {
    std.debug.print("{{\"file\":\"{s}\",\"file_size\":{d},\"benchmark\":\"{s}\",\"elapsed_us\":{d},\"peaks\":{d},\"scans\":{d}}}\n", .{
        file_name, file_size, benchmark, elapsed_us, peaks, scans,
    });
}

fn printUsage() !void {
    std.debug.print(
        \\Raw Orbitrap Viewer
        \\
        \\Usage:
        \\  raw-orbitrap-viewer.exe                    (GUI mode, no file)
        \\  raw-orbitrap-viewer.exe <raw-file>         (GUI mode, open file)
        \\  raw-orbitrap-viewer.exe <raw-file> scan <scan-number>   (legacy)
        \\  raw-orbitrap-viewer.exe <raw-file> offset <offset>      (legacy)
        \\  raw-orbitrap-viewer.exe <raw-file> benchmark            (benchmark)
        \\  raw-orbitrap-viewer.exe --benchmark-real <dir>          (real-file benchmark)
        \\  raw-orbitrap-viewer.exe --benchmark-cold <dir>          (cold-start benchmark)
        \\
        \\GUI Features:
        \\  - File browser with Open dialog
        \\  - Scan list panel with all scans
        \\  - Interactive spectrum (zoom, pan, hover tooltips)
        \\  - Peak labels, stick/line plot modes
        \\  - Keyboard navigation (PgUp/PgDn, Ctrl+Home/End)
        \\
    , .{});
}
