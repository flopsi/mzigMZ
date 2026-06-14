/// Ground truth verifier — Phase 2.
/// Compares mzigRead decoded spectra against cached ThermoRawFileParser output.
///
/// IMPORTANT: Must be run from repo root. GT directory path is relative to CWD.
/// Usage: zig build verify-ground-truth -- <raw-file>
const std = @import("std");
const app = @import("app_state");
const cli = @import("cli_args");
const reader = @import("raw_file_reader");

const MZ_TOLERANCE: f64 = 0.001;
const INTENSITY_REL_TOLERANCE: f64 = 0.001;
const DEFAULT_SAMPLE_SIZE: usize = 100;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    const args = cli.get_args(allocator) catch {
        std.debug.print("usage: verify-ground-truth <raw-file>\n", .{});
        return 1;
    };
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }
    if (args.len < 2) {
        std.debug.print("usage: verify-ground-truth <raw-file>\n", .{});
        return 1;
    }
    const raw_path = args[1];

    const raw_filename = std.fs.path.basename(raw_path);
    const dot = std.mem.lastIndexOfScalar(u8, raw_filename, '.') orelse raw_filename.len;
    const base_name = raw_filename[0..dot];
    const gt_dir = try std.fmt.allocPrint(allocator, "tests/ground_truth/{s}", .{base_name});
    defer allocator.free(gt_dir);

    const cwd = std.Io.Dir.cwd();
    cwd.access(io, gt_dir, .{}) catch {
        std.debug.print("Ground truth not found: {s}\nRun generate-ground-truth first.\n", .{gt_dir});
        return 1;
    };

    var rf = reader.RawFile.open(allocator, io, raw_path) catch |err| {
        std.debug.print("error: cannot open '{s}': {}\n", .{ raw_path, err });
        return 1;
    };
    defer rf.deinit();

    std.debug.print("file:         {s}\n", .{raw_filename});
    std.debug.print("total_scans:  {d}\n", .{rf.num_scans});
    std.debug.print("ground_truth: {s}\n\n", .{gt_dir});

    const count = @min(DEFAULT_SAMPLE_SIZE, rf.num_scans);
    var sample = try allocator.alloc(usize, count);
    defer allocator.free(sample);
    var sample_len: usize = count; // actual number of valid samples (may be < count)

    // If a _sample_indices.txt file exists (written by sample-ground-truth),
    // use those exact indices. Otherwise, generate a random sample.
    const sample_indices_path = try std.fmt.allocPrint(allocator, "{s}/_sample_indices.txt", .{gt_dir});
    defer allocator.free(sample_indices_path);

    if (cwd.access(io, sample_indices_path, .{})) |_| {
        // Read the pre-generated sample indices.
        const content = cwd.readFileAlloc(io, sample_indices_path, allocator, .unlimited) catch {
            std.debug.print("error: cannot read sample indices file\n", .{});
            return 1;
        };
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var i: usize = 0;
        while (lines.next()) |line| {
            if (i >= count) break;
            if (line.len == 0) continue;
            sample[i] = std.fmt.parseInt(usize, line, 10) catch continue;
            i += 1;
        }
        sample_len = i;
        std.debug.print("Using {d} sample indices from _sample_indices.txt\n", .{i});
    } else |_| {
        // Generate a random sample.
        var seed: u64 = 42;
        for (0..count) |i| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            sample[i] = @as(usize, @intCast(seed % rf.num_scans));
        }
    }

    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    state.open_file(raw_path) catch |err| {
        std.debug.print("error: AppState.openFile: {}\n", .{err});
        return 1;
    };

    // Accumulators.
    var scans_good: usize = 0;
    var scans_fail_decode: usize = 0;
    var scans_fail_count: usize = 0;
    var scans_fail_mz: usize = 0;
    var scans_fail_intensity: usize = 0;
    var count_diff_max: u32 = 0;
    var mz_dev_sum: f64 = 0;
    var mz_dev_max: f64 = 0;
    var mz_dev_count: usize = 0;
    var int_dev_sum: f64 = 0;
    var int_dev_max: f64 = 0;
    var total_peaks: usize = 0;

    const t0 = std.Io.Clock.now(.boot, io);

    std.debug.print("sample_len={d}\n", .{sample_len});
    for (sample[0..sample_len]) |scan_index| {
        // mzigRead is 0-indexed, Thermo .raw files and MGF output are 1-indexed.
        // Some files have gaps (controller scans, skipped scans) so the MGF
        // scan number is NOT always scan_index + 1. We must look up the
        // actual scan number from the scan index entry.
        const entry = rf.scan_at(@intCast(scan_index + 1)) catch {
            scans_fail_decode += 1;
            continue;
        };
        const scan_number: u32 = @intCast(entry.scan_number);
        const gt_file = try std.fmt.allocPrint(allocator, "{s}/{d:0>5}.json", .{ gt_dir, scan_number });
        defer allocator.free(gt_file);

        const gt_data = cwd.readFileAlloc(io, gt_file, allocator, .unlimited) catch {
            scans_fail_decode += 1;
            continue;
        };
        defer allocator.free(gt_data);

        const parsed = std.json.parseFromSlice(struct {
            mzs: []f64,
            intensities: []f64,
        }, allocator, gt_data, .{}) catch {
            scans_fail_decode += 1;
            continue;
        };
        defer parsed.deinit();

        const ref = parsed.value;

        // Decode with mzigRead.
        state.load_scan(scan_index) catch {
            scans_fail_decode += 1;
            continue;
        };

        const our = state.current_spectrum orelse {
            scans_fail_decode += 1;
            continue;
        };

        const n = @min(our.point_count(), ref.mzs.len);

        var scan_good = true;
        if (our.point_count() != ref.mzs.len) {
            scans_fail_count += 1;
            scan_good = false;
            const diff: u32 = @intCast(if (our.point_count() > ref.mzs.len)
                our.point_count() - ref.mzs.len
            else
                ref.mzs.len - our.point_count());
            if (diff > count_diff_max) count_diff_max = diff;
        }

        for (0..n) |j| {
            total_peaks += 1;

            const m = @abs(our.mz[j] - ref.mzs[j]);
            mz_dev_sum += m;
            mz_dev_count += 1;
            if (m > mz_dev_max) mz_dev_max = m;
            if (m > MZ_TOLERANCE) {
                scans_fail_mz += 1;
                scan_good = false;
            }

            const denom = @max(@abs(ref.intensities[j]), 1e-6);
            const rel = @abs(@as(f64, @floatCast(our.intensity[j])) - ref.intensities[j]) / denom;
            int_dev_sum += rel;
            if (rel > int_dev_max) int_dev_max = rel;
            if (rel > INTENSITY_REL_TOLERANCE) {
                scans_fail_intensity += 1;
                scan_good = false;
            }
        }

        if (scan_good) scans_good += 1;
    }

    const elapsed = t0.untilNow(io, .boot).toMicroseconds();
    const nf: f64 = @floatFromInt(sample_len);
    const match_rate = if (nf > 0) @as(f64, @floatFromInt(scans_good)) / nf * 100 else 0;

    std.debug.print("--- Results ---\n", .{});
    std.debug.print("scans_compared:  {d}\n", .{sample_len});
    std.debug.print("peak_count_match:{d:.1}% ({d} scans good)\n", .{ match_rate, scans_good });
    std.debug.print("decode_failures: {d}\n", .{scans_fail_decode});
    std.debug.print("count_mismatches:{d}\n", .{scans_fail_count});
    std.debug.print("count_max_diff:  {d}\n", .{count_diff_max});
    std.debug.print("\n", .{});
    std.debug.print("mz_mad:          {d:.6} Da\n", .{if (mz_dev_count > 0) mz_dev_sum / @as(f64, @floatFromInt(mz_dev_count)) else 0});
    std.debug.print("mz_max_dev:      {d:.6} Da\n", .{mz_dev_max});
    std.debug.print("mz_exceed:       {d} scans had peaks > {d:.3} Da\n", .{ scans_fail_mz, MZ_TOLERANCE });
    std.debug.print("\n", .{});
    std.debug.print("intensity_mad:   {d:.6}\n", .{if (mz_dev_count > 0) int_dev_sum / @as(f64, @floatFromInt(mz_dev_count)) else 0});
    std.debug.print("intensity_max:   {d:.6}\n", .{int_dev_max});
    std.debug.print("intensity_exceed:{d} scans\n", .{scans_fail_intensity});
    std.debug.print("\n", .{});
    std.debug.print("total_peaks:     {d}\n", .{total_peaks});
    std.debug.print("elapsed_us:      {d}\n", .{elapsed});

    return 0;
}
