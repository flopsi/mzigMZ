/// Benchmark harness for measuring scan loading performance.
/// Run with: zig build bench -- <raw-file>
const std = @import("std");
const app = @import("app_state");
const cli = @import("cli_args");

const BenchmarkResult = struct {
    name: []const u8,
    elapsed_us: i64,
    points: usize,
    scans: usize,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try cli.get_args(allocator);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len < 2) {
        std.debug.print("Usage: bench <raw-file>\n", .{});
        return;
    }

    const raw_path = args[1];

    const file_size = blk: {
        const file = std.Io.Dir.cwd().openFile(io, raw_path, .{}) catch |err| {
            std.debug.print("error: cannot open '{s}': {}\n", .{ raw_path, err });
            return;
        };
        defer file.close(io);
        break :blk (try file.stat(io)).size;
    };

    const file_size_mb = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);

    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    // Open file
    state.open_file(raw_path) catch |err| {
        std.debug.print("error: failed to open '{s}': {}\n", .{ raw_path, err });
        return;
    };

    const num_scans = state.file.scans.len;
    if (num_scans == 0) {
        std.debug.print("error: no scans found in file\n", .{});
        return;
    }

    // First scan
    const t_first_start = std.Io.Clock.now(.boot, io);
    state.load_scan(0) catch |err| {
        std.debug.print("error: failed to load first scan: {}\n", .{err});
        return;
    };
    const t_first = t_first_start.untilNow(io, .boot).toMicroseconds();
    const first_points = if (state.current_spectrum) |s| s.point_count() else 0;

    std.debug.print(" zig benchmark, file_size_mb={d:.1}, num_scans={d}, operation=open_first, time_us={d}, points={d}\n", .{ file_size_mb, num_scans, t_first, first_points });

    // Full iteration
    const t_full_start = std.Io.Clock.now(.boot, io);
    var total_points: usize = 0;
    var i: usize = 0;
    while (i < num_scans) : (i += 1) {
        state.load_scan(i) catch continue;
        total_points += if (state.current_spectrum) |s| s.point_count() else 0;
    }
    const t_full = t_full_start.untilNow(io, .boot).toMicroseconds();

    std.debug.print(" zig benchmark, file_size_mb={d:.1}, num_scans={d}, operation=full_iteration, time_us={d}, points={d}\n", .{ file_size_mb, num_scans, t_full, total_points });
}
