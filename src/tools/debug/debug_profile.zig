const std = @import("std");
const app = @import("app_state");
const raw = @import("raw_file");
const advanced = @import("advanced_packet");
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
        std.debug.print("Usage: debug_profile <raw-file> [scan_index]\n", .{});
        return;
    }

    const raw_path = args[1];

    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    try state.open_file(raw_path);

    var scan_index: usize = 0;
    if (args.len >= 3) {
        const scan_arg = args[2];
        scan_index = try std.fmt.parseInt(usize, scan_arg, 10);
        scan_index -= 1; // convert to 0-based
    } else {
        // Find first FT_PROFILE with num_centroid_words == 0
        for (state.file.scans, 0..) |scan, i| {
            const pt = scan.packet_type & 0xFFFF;
            if (pt == raw.PACKET_TYPE_FT_PROFILE) {
                const packet_offset = state.file.raw_file.?.packet_pos + scan.data_offset;
                if (packet_offset + 32 > state.file.raw_file.?.file_size) continue;
                const header_bytes = state.file.raw_file.?.mm.memory[packet_offset .. packet_offset + 32];
                const num_centroid_words = std.mem.readInt(u32, header_bytes[8..12], .little);
                if (num_centroid_words == 0) {
                    scan_index = i;
                    break;
                }
            }
        }
    }

    if (scan_index >= state.file.scans.len) {
        std.debug.print("Scan index out of range\n", .{});
        return;
    }

    const scan = state.file.scans[scan_index];
    const packet_offset = state.file.raw_file.?.packet_pos + scan.data_offset;
    const header_bytes = state.file.raw_file.?.mm.memory[packet_offset .. packet_offset + 32];

    const h = try advanced.read_header(header_bytes, 0);

    std.debug.print("\n========================================\n", .{});
    std.debug.print("Scan {d} (1-based: {d})\n", .{ scan_index, scan_index + 1 });
    std.debug.print("Packet type: 0x{x:04} (FT_PROFILE=0x{x:04})\n", .{ scan.packet_type & 0xFFFF, raw.PACKET_TYPE_FT_PROFILE });
    std.debug.print("Packet offset: 0x{x}\n", .{packet_offset});
    std.debug.print("Number packets: {d}\n", .{scan.number_packets});
    std.debug.print("Data size: {d}\n", .{scan.data_size});
    std.debug.print("\n--- Header ---\n", .{});
    std.debug.print("num_segments:              {d}\n", .{h.num_segments});
    std.debug.print("num_profile_words:         {d}\n", .{h.num_profile_words});
    std.debug.print("num_centroid_words:        {d}\n", .{h.num_centroid_words});
    std.debug.print("default_feature_word:      0x{x:08}\n", .{h.default_feature_word});
    std.debug.print("num_non_default_features:  {d}\n", .{h.num_non_default_feature_words});
    std.debug.print("num_expansion_words:       {d}\n", .{h.num_expansion_words});
    std.debug.print("num_noise_info_words:      {d}\n", .{h.num_noise_info_words});
    std.debug.print("num_debug_info_words:      {d}\n", .{h.num_debug_info_words});

    // Check for second packet
    if (scan.number_packets > 1) {
        const packet_size = try advanced.packet_size_from_header(h);
        const next_packet_offset = packet_offset + packet_size;
        if (next_packet_offset < state.file.raw_file.?.file_size) {
            const next_header = state.file.raw_file.?.mm.memory[next_packet_offset .. next_packet_offset + 32];
            const next_type = std.mem.readInt(u32, next_header[16..20], .little);
            std.debug.print("\n--- Second packet at offset 0x{x} ---\n", .{next_packet_offset});
            std.debug.print("Packet type: 0x{x:04}\n", .{next_type});
        }
    }

    const packet_size = try advanced.packet_size_from_header(h);
    std.debug.print("\nComputed packet_size: {d} bytes (0x{x})\n", .{ packet_size, packet_size });

    // Try decoding with current profile decoder
    std.debug.print("\n--- Profile decode attempt ---\n", .{});
    const actual_size: usize = @intCast(@min(packet_size, state.file.raw_file.?.file_size - packet_offset));
    const packet_slice = state.file.raw_file.?.mm.memory[packet_offset .. packet_offset + actual_size];

    var calibrators: []const f64 = &[_]f64{};
    if (state.file.trailer_events) |te| {
        if (te.get_event(scan_index)) |evt| {
            calibrators = evt.mass_calibrators;
            std.debug.print("Calibrators ({d}): ", .{calibrators.len});
            for (calibrators) |c| {
                std.debug.print("{e} ", .{c});
            }
            std.debug.print("\n", .{});
        }
    }

    const use_subsegment = (h.default_feature_word & 0x40) == 0 and (h.default_feature_word & 0x80) != 0;
    std.debug.print("use_subsegment: {}\n", .{use_subsegment});

    // Allocate a buffer to test decode
    const test_buf_size: usize = 2_000_000;
    const mz_buf = try allocator.alloc(f64, test_buf_size);
    defer allocator.free(mz_buf);
    const int_buf = try allocator.alloc(f32, test_buf_size);
    defer allocator.free(int_buf);

    const profile = @import("profile_packet");
    const num_points = profile.decode_ft_profile(packet_slice, calibrators, mz_buf, int_buf, use_subsegment) catch |err| {
        std.debug.print("decodeFtProfile FAILED: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Decoded {d} points\n", .{num_points});
    if (num_points > 0) {
        std.debug.print("First m/z: {e}, intensity: {e}\n", .{ mz_buf[0], int_buf[0] });
        std.debug.print("Last m/z:  {e}, intensity: {e}\n", .{ mz_buf[num_points - 1], int_buf[num_points - 1] });

        var non_zero: usize = 0;
        for (int_buf[0..num_points]) |inten| {
            if (inten > 0) non_zero += 1;
        }
        std.debug.print("Non-zero intensities: {d} ({d:.1}%)\n", .{ non_zero, 100.0 * @as(f64, @floatFromInt(non_zero)) / @as(f64, @floatFromInt(num_points)) });

        // Check monotonicity
        var violations: usize = 0;
        for (1..@min(num_points, 100_000)) |i| {
            if (mz_buf[i] <= mz_buf[i - 1]) violations += 1;
        }
        if (num_points > 100_000) {
            std.debug.print("(checked first 100k points for monotonicity)\n", .{});
        }
        std.debug.print("Monotonicity violations: {d}\n", .{violations});

        // Write to TSV for ground truth comparison
        const out_file = try std.Io.Dir.cwd().createFile(io, "zig_profile_scan1.tsv", .{});
        defer out_file.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = out_file.writer(io, &write_buf);
        try writer.interface.print("mz\tintensity\n", .{});
        for (0..num_points) |i| {
            try writer.interface.print("{d:.17}\t{d:.9}\n", .{ mz_buf[i], int_buf[i] });
        }
        std.debug.print("Wrote Zig decode to zig_profile_scan1.tsv\n", .{});
    }

    std.debug.print("========================================\n", .{});
}
