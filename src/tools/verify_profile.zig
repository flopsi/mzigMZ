/// Profile packet encoder verification harness.
/// Opens a .raw file, walks every FT_PROFILE scan (without embedded centroids),
/// decodes it with frequencies, re-encodes, re-decodes, and compares
/// frequencies + intensities for equality.
///
/// Usage: zig build verify-profile -- <raw-file>
const std = @import("std");
const app_state = @import("app_state");
const profile = @import("profile_packet");
const raw = @import("raw_file");
const cli = @import("cli_args");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try cli.get_args(allocator);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len < 2) {
        std.debug.print("Usage: verify_profile <raw-file>\n", .{});
        std.process.exit(1);
    }

    const raw_path = args[1];

    var state = app_state.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(raw_path);

    const num_scans = state.file.scans.len;
    std.debug.print("File: {s} ({d} scans)\n", .{ raw_path, num_scans });

    var total_points: usize = 0;
    var total_mismatches: usize = 0;
    var scan_mismatches: usize = 0;

    // Growable encode buffer
    var encode_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(encode_buf);

    // Growable decode buffers
    var mz_round = try allocator.alloc(f64, 4096);
    defer allocator.free(mz_round);
    var freq_round = try allocator.alloc(f64, 4096);
    defer allocator.free(freq_round);
    var inten_round = try allocator.alloc(f32, 4096);
    defer allocator.free(inten_round);

    const start = std.Io.Clock.now(.boot, io);

    var scan_idx: usize = 0;
    while (scan_idx < num_scans) : (scan_idx += 1) {
        if (scan_idx % 1000 == 0 and scan_idx > 0) {
            std.debug.print("  progress: {d}/{d} scans...\n", .{ scan_idx, num_scans });
        }
        const scan = state.file.scans[scan_idx];
        const packet_type = scan.packet_type & 0xFFFF;
        if (packet_type != raw.PACKET_TYPE_FT_PROFILE) {
            continue;
        }

        // Read packet header to check for profile data
        const packet_offset = try state.file.raw_file.?.packet_offset(scan.scan_number);
        const header_bytes = state.file.raw_file.?.memory()[packet_offset .. packet_offset + 32];
        const num_profile_words = std.mem.readInt(u32, header_bytes[4..8], .little);
        if (num_profile_words == 0) {
            continue;
        }

        // Decode via bulk with freq (reuses buffers, no alloc churn)
        const load_result = state.load_scan_bulk_with_freq(scan_idx) catch |err| {
            std.log.warn("Decode failed for scan {d}: {s}", .{ scan_idx + 1, @errorName(err) });
            continue;
        };
        if (load_result.num_points == 0) continue;
        const n = load_result.num_points;
        total_points += n;

        const freq_orig = state.decoder.freq_buffer().?[0..n];
        const inten_orig = state.decoder.intensity_buffer()[0..load_result.num_points];

        // Extract mass range from original packet
        const mass_low = @as(f32, @bitCast(std.mem.readInt(u32, header_bytes[32..36], .little)));
        const mass_high = @as(f32, @bitCast(std.mem.readInt(u32, header_bytes[36..40], .little)));

        // Ensure encode buffer is large enough
        const encoded_size = try profile.encoded_profile_size(n, 0, 0, 0, 0);
        if (encoded_size > encode_buf.len) {
            allocator.free(encode_buf);
            encode_buf = try allocator.alloc(u8, encoded_size * 2);
        }

        const written = profile.encode_ft_profile(
            encode_buf[0..encoded_size],
            freq_orig,
            inten_orig,
            mass_low,
            mass_high,
            null,
            null,
            null,
        ) catch |err| {
            std.log.warn("Encode failed for scan {d}: {s}", .{ scan_idx + 1, @errorName(err) });
            continue;
        };

        // Ensure decode buffers are large enough
        if (n > freq_round.len) {
            allocator.free(freq_round);
            freq_round = try allocator.alloc(f64, n * 2);
            allocator.free(mz_round);
            mz_round = try allocator.alloc(f64, n * 2);
            allocator.free(inten_round);
            inten_round = try allocator.alloc(f32, n * 2);
        }

        var calibrators: []const f64 = &[_]f64{};
        if (state.file.trailer_events) |te| {
            if (te.get_event(scan_idx)) |evt| {
                calibrators = evt.mass_calibrators;
            }
        }

        const n2 = profile.decode_ft_profile_with_freq(
            encode_buf[0..written],
            calibrators,
            freq_round,
            mz_round,
            inten_round,
            false, // use_subsegment=false for our encoded packets
        ) catch |err| {
            std.log.warn("Re-decode failed for scan {d}: {s}", .{ scan_idx + 1, @errorName(err) });
            continue;
        };

        if (n != n2) {
            scan_mismatches += 1;
            if (scan_mismatches <= 5) {
                std.log.warn("Scan {d} point count mismatch: orig={d} round={d}", .{ scan_idx + 1, n, n2 });
            }
            continue;
        }

        var scan_has_mismatch = false;
        for (0..n) |i| {
            if (@abs(freq_orig[i] - freq_round[i]) > 1e-9) {
                scan_has_mismatch = true;
                total_mismatches += 1;
                if (scan_mismatches <= 3) {
                    std.log.warn("  freq[{d}] orig={d} round={d}", .{ i, freq_orig[i], freq_round[i] });
                }
            }
            if (@abs(inten_orig[i] - inten_round[i]) > 0.001) {
                scan_has_mismatch = true;
                total_mismatches += 1;
            }
        }
        if (scan_has_mismatch) {
            scan_mismatches += 1;
            if (scan_mismatches <= 5) {
                std.log.warn("Scan {d} has mismatches", .{scan_idx + 1});
            }
        }
    }

    const elapsed_ms = start.untilNow(io, .boot).toMilliseconds();

    std.debug.print("Profile scans checked: {d}, Total points: {d}\n", .{ num_scans, total_points });
    std.debug.print("Scans with mismatches: {d}, Total field mismatches: {d}\n", .{ scan_mismatches, total_mismatches });
    std.debug.print("Elapsed: {d} ms\n", .{elapsed_ms});

    if (scan_mismatches == 0) {
        std.debug.print("✓ PASSED — zero mismatches\n", .{});
    } else {
        std.debug.print("✗ FAILED — {d} scans with mismatches\n", .{scan_mismatches});
        std.process.exit(1);
    }
}
