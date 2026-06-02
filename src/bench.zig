/// Benchmark harness for measuring scan loading performance.
/// Run with: zig build run-bench -- <raw-file>
const std = @import("std");
const app = @import("app_state");

const LPCWSTR = [*:0]const u16;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPCWSTR;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, pNumArgs: *i32) callconv(.winapi) ?[*]LPCWSTR;
extern "kernel32" fn LocalFree(hMem: ?[*]LPCWSTR) callconv(.winapi) ?*anyopaque;

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

const Benchmark = struct {
    name: []const u8,
    elapsed_us: i64,
    points: usize,
    scans: usize,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var argc: i32 = 0;
    const argv_w = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return error.CommandLineToArgvFailed;
    defer _ = LocalFree(argv_w);

    if (argc < 2) {
        std.debug.print("Usage: bench <raw-file>\n", .{});
        std.process.exit(1);
    }

    const raw_path = try utf16ZToAsciiAlloc(allocator, argv_w[1]);
    defer allocator.free(raw_path);

    try run(allocator, io, raw_path);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, raw_path: []const u8) !void {
    const file_size = blk: {
        const file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, raw_path, .{});
        defer file.close(io);
        break :blk (try file.stat(io)).size;
    };

    var benchmarks = std.ArrayList(Benchmark).empty;
    defer benchmarks.deinit(allocator);

    // --- Open file ---
    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    const t_open_start = std.Io.Clock.now(.boot, io);
    try state.openFile(raw_path);
    const t_open = t_open_start.untilNow(io, .boot).toMicroseconds();
    const num_scans = state.scans.len;

    try benchmarks.append(allocator, .{
        .name = "open",
        .elapsed_us = t_open,
        .points = 0,
        .scans = num_scans,
    });

    if (num_scans == 0) {
        std.debug.print("error: no scans found\n", .{});
        return;
    }

    // --- loadScan (current, with alloc/free per scan) ---
    {
        const t_start = std.Io.Clock.now(.boot, io);
        var total_points: usize = 0;
        var scans_ok: usize = 0;
        var i: usize = 0;
        while (i < num_scans) : (i += 1) {
            state.loadScan(i) catch |err| {
                std.debug.print("# loadScan scan {d} failed: {s}\n", .{i + 1, @errorName(err)});
                continue;
            };
            total_points += if (state.current_spectrum) |s| s.pointCount() else 0;
            scans_ok += 1;
        }
        const t_elapsed = t_start.untilNow(io, .boot).toMicroseconds();
        try benchmarks.append(allocator, .{
            .name = "loadScan_full",
            .elapsed_us = t_elapsed,
            .points = total_points,
            .scans = scans_ok,
        });
    }

    // --- loadScanArena (arena allocator, ~10x faster) ---
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const t_start = std.Io.Clock.now(.boot, io);
        var total_points: usize = 0;
        var scans_ok: usize = 0;
        var i: usize = 0;
        while (i < num_scans) : (i += 1) {
            const n = state.loadScanArena(i, &arena) catch |err| {
                std.debug.print("# loadScanArena scan {d} failed: {s}\n", .{i + 1, @errorName(err)});
                continue;
            };
            total_points += n;
            scans_ok += 1;
            _ = arena.reset(.retain_capacity);
        }
        const t_elapsed = t_start.untilNow(io, .boot).toMicroseconds();
        try benchmarks.append(allocator, .{
            .name = "loadScanArena_full",
            .elapsed_us = t_elapsed,
            .points = total_points,
            .scans = scans_ok,
        });
    }

    // --- loadScanBulk (zero allocation) ---
    {
        const t_start = std.Io.Clock.now(.boot, io);
        var total_points: usize = 0;
        var scans_ok: usize = 0;
        var i: usize = 0;
        while (i < num_scans) : (i += 1) {
            const n = state.loadScanBulk(i) catch |err| {
                std.debug.print("# loadScanBulk scan {d} failed: {s}\n", .{i + 1, @errorName(err)});
                continue;
            };
            total_points += n;
            scans_ok += 1;
        }
        const t_elapsed = t_start.untilNow(io, .boot).toMicroseconds();
        try benchmarks.append(allocator, .{
            .name = "loadScanBulk_full",
            .elapsed_us = t_elapsed,
            .points = total_points,
            .scans = scans_ok,
        });
    }

    // --- Random access (1000 samples) ---
    {
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.now(.boot, io).nanoseconds));
        const rand = prng.random();

        // loadScan random
        {
            const t_start = std.Io.Clock.now(.boot, io);
            var total_points: usize = 0;
            var s: usize = 0;
            while (s < 1000) : (s += 1) {
                const idx = rand.intRangeLessThan(usize, 0, num_scans);
                try state.loadScan(idx);
                total_points += if (state.current_spectrum) |sp| sp.pointCount() else 0;
            }
            const t_elapsed = t_start.untilNow(io, .boot).toMicroseconds();
            try benchmarks.append(allocator, .{
                .name = "loadScan_random_1000",
                .elapsed_us = t_elapsed,
                .points = total_points,
                .scans = 1000,
            });
        }

        // loadScanBulk random
        {
            const t_start = std.Io.Clock.now(.boot, io);
            var total_points: usize = 0;
            var s: usize = 0;
            while (s < 1000) : (s += 1) {
                const idx = rand.intRangeLessThan(usize, 0, num_scans);
                total_points += try state.loadScanBulk(idx);
            }
            const t_elapsed = t_start.untilNow(io, .boot).toMicroseconds();
            try benchmarks.append(allocator, .{
                .name = "loadScanBulk_random_1000",
                .elapsed_us = t_elapsed,
                .points = total_points,
                .scans = 1000,
            });
        }
    }

    // --- Print results as JSONL ---
    std.debug.print("# Benchmark Results for {s}\n", .{raw_path});
    std.debug.print("# File size: {d} bytes, Scans: {d}\n", .{ file_size, num_scans });

    for (benchmarks.items) |b| {
        const us_per_scan = @as(f64, @floatFromInt(b.elapsed_us)) / @as(f64, @floatFromInt(b.scans));
        const points_per_sec = if (b.elapsed_us > 0)
            @as(f64, @floatFromInt(b.points)) * 1_000_000.0 / @as(f64, @floatFromInt(b.elapsed_us))
        else
            @as(f64, 0);
        std.debug.print("{{\"benchmark\":\"{s}\",\"elapsed_us\":{d},\"points\":{d},\"scans\":{d},\"us_per_scan\":{d:.2},\"points_per_sec\":{d:.0}}}\n", .{
            b.name,
            b.elapsed_us,
            b.points,
            b.scans,
            us_per_scan,
            points_per_sec,
        });
    }
}
