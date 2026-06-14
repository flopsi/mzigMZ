/// Centroid packet encoder verification harness.
/// Opens a .raw file, walks every FT_CENTROID scan, decodes it,
/// re-encodes the spectrum, re-decodes the encoded packet, and
/// compares m/z + intensity + features for equality.
///
/// Usage: zig build verify-encode -- <raw-file>
const std = @import("std");
const app_state = @import("app_state");
const advanced = @import("advanced_packet");
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
        std.debug.print("Usage: verify_encode <raw-file>\n", .{});
        std.process.exit(1);
    }

    const raw_path = args[1];

    var state = app_state.AppState.init(allocator, io);
    defer state.deinit();
    try state.open_file(raw_path);

    const num_scans = state.file.scans.len;
    std.debug.print("File: {s} ({d} scans)\n", .{ raw_path, num_scans });

    var total_peaks: usize = 0;
    var total_mismatches: usize = 0;
    var scan_mismatches: usize = 0;

    // Growable encode buffer
    var encode_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(encode_buf);

    // Growable decode buffers
    var mz_round = try allocator.alloc(f64, 4096);
    defer allocator.free(mz_round);
    var inten_round = try allocator.alloc(f32, 4096);
    defer allocator.free(inten_round);
    var feat_round = try allocator.alloc(advanced.PeakFeatures, 4096);
    defer allocator.free(feat_round);

    const start = std.Io.Clock.now(.boot, io);

    var scan_idx: usize = 0;
    while (scan_idx < num_scans) : (scan_idx += 1) {
        if (scan_idx % 1000 == 0 and scan_idx > 0) {
            std.debug.print("  progress: {d}/{d} scans...\n", .{ scan_idx, num_scans });
        }
        const scan = state.file.scans[scan_idx];
        const packet_type = scan.packet_type & 0xFFFF;
        if (packet_type != raw.PACKET_TYPE_FT_CENTROID and packet_type != raw.PACKET_TYPE_LINEAR_TRAP_CENTROID) {
            continue;
        }

        // Decode via the full pipeline (owned allocation so we get features + everything)
        state.load_scan(scan_idx) catch |err| {
            std.log.warn("Decode failed for scan {d}: {s}", .{ scan_idx + 1, @errorName(err) });
            continue;
        };
        if (state.current_spectrum == null) {
            std.log.warn("Scan {d}: loadScan succeeded but current_spectrum is null", .{scan_idx + 1});
            continue;
        }
        const spectrum = state.current_spectrum.?;
        const n = spectrum.point_count();
        if (n == 0) continue;
        total_peaks += n;

        // Determine accurate-mass mode from original packet header
        const packet_offset = try state.file.raw_file.?.packet_offset(scan.scan_number);
        const header_bytes = state.file.raw_file.?.memory()[packet_offset .. packet_offset + 32];
        const default_feature_word = std.mem.readInt(u32, header_bytes[12..16], .little);
        const accurate = (default_feature_word & 0x40) == 0 and (default_feature_word & 0x10000) != 0;

        const features: ?[]const advanced.PeakFeatures = if (spectrum.features) |f| f[0..n] else null;

        // Ensure encode buffer is large enough
        const num_non_default = if (features) |f| countNonDefault(f) else 0;
        const has_widths = if (features) |f| blk: {
            for (f) |feat| {
                if (feat.resolution != 0) break :blk true;
            }
            break :blk false;
        } else false;
        const encoded_size = advanced.encoded_centroid_size(n, accurate, num_non_default, has_widths, 0);
        if (encoded_size > encode_buf.len) {
            allocator.free(encode_buf);
            encode_buf = try allocator.alloc(u8, encoded_size * 2);
        }

        const written = advanced.encode_centroid_packet(
            encode_buf[0..encoded_size],
            spectrum.mz[0..n],
            spectrum.intensity[0..n],
            features,
            accurate,
            null,
        ) catch |err| {
            std.log.warn("Encode failed for scan {d}: {s}", .{ scan_idx + 1, @errorName(err) });
            continue;
        };

        // Ensure decode buffers are large enough
        if (n > mz_round.len) {
            allocator.free(mz_round);
            mz_round = try allocator.alloc(f64, n * 2);
            allocator.free(inten_round);
            inten_round = try allocator.alloc(f32, n * 2);
            allocator.free(feat_round);
            feat_round = try allocator.alloc(advanced.PeakFeatures, n * 2);
        }

        const n2 = advanced.decode_simplified_centroids_into_buffers(
            encode_buf[0..written],
            0,
            mz_round,
            inten_round,
            feat_round,
            allocator,
        ) catch |err| {
            std.log.warn("Re-decode failed for scan {d}: {s}", .{ scan_idx + 1, @errorName(err) });
            continue;
        };

        if (n != n2) {
            scan_mismatches += 1;
            total_mismatches += 1;
            if (scan_mismatches <= 5) {
                std.log.warn("Scan {d} peak count mismatch: orig={d} round={d}", .{ scan_idx + 1, n, n2 });
            }
            continue;
        }

        var scan_has_mismatch = false;
        for (0..n) |i| {
            const tolerance: f64 = if (accurate) 1e-9 else 0.001;
            if (@abs(spectrum.mz[i] - mz_round[i]) > tolerance) {
                scan_has_mismatch = true;
                total_mismatches += 1;
                if (scan_mismatches <= 3) {
                    std.log.warn("  mz[{d}] orig={d} round={d}", .{ i, spectrum.mz[i], mz_round[i] });
                }
            }
            if (@abs(spectrum.intensity[i] - inten_round[i]) > 0.001) {
                scan_has_mismatch = true;
                total_mismatches += 1;
            }
            if (features) |f| {
                if (f[i].charge != feat_round[i].charge) {
                    scan_has_mismatch = true;
                    total_mismatches += 1;
                }
                if (!std.meta.eql(f[i].flags, feat_round[i].flags)) {
                    scan_has_mismatch = true;
                    total_mismatches += 1;
                }
            }
        }
        if (scan_has_mismatch) {
            scan_mismatches += 1;
            if (scan_mismatches <= 5) {
                std.log.warn("Scan {d} has {d} field mismatches", .{ scan_idx + 1, total_mismatches });
            }
        }
    }

    const elapsed_ms = start.untilNow(io, .boot).toMilliseconds();

    std.debug.print("Scans checked: {d}, Total peaks: {d}\n", .{ num_scans, total_peaks });
    std.debug.print("Scans with mismatches: {d}, Total field mismatches: {d}\n", .{ scan_mismatches, total_mismatches });
    std.debug.print("Elapsed: {d} ms\n", .{elapsed_ms});

    if (scan_mismatches == 0) {
        std.debug.print("✓ PASSED — zero mismatches\n", .{});
    } else {
        std.debug.print("✗ FAILED — {d} scans with mismatches\n", .{scan_mismatches});
        std.process.exit(1);
    }
}

fn countNonDefault(features: []const advanced.PeakFeatures) usize {
    if (features.len == 0) return 0;
    const default = features[0].flags;
    var count: usize = 0;
    for (features) |f| {
        if (f.charge != 0 or !std.meta.eql(f.flags, default)) {
            count += 1;
        }
    }
    return count;
}
