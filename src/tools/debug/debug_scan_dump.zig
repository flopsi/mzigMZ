const std = @import("std");
const app = @import("app_state");
const raw = @import("raw_file");
const advanced = @import("advanced_packet");
const scan_event = @import("scan_event");
const cli = @import("cli_args");
const trailer_extra = @import("trailer_extra");

fn appendJsonString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '"' => try list.appendSlice(allocator, "\\\""),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const sl = try std.fmt.bufPrint(&buf, "\\u{x:04}", .{c});
                    try list.appendSlice(allocator, sl);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
    try list.append(allocator, '"');
}

fn appendFmt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try list.appendSlice(allocator, s);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try cli.get_args(allocator);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len < 3) {
        std.debug.print("Usage: debug_scan_dump <raw-file> <scan-number>\n", .{});
        return;
    }
    const raw_path = args[1];
    const scan_number = try std.fmt.parseInt(usize, args[2], 10);
    const scan_index = scan_number - 1; // convert to 0-based

    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    try state.open_file(raw_path);

    if (scan_index >= state.file.scans.len) {
        std.debug.print("{{\"error\":\"Scan {d} out of range (1..{d})\"}}\n", .{ scan_number, state.file.scans.len });
        return;
    }

    const load_ok = if (state.load_scan(scan_index)) |_| true else |_| false;
    if (!load_ok) {
        std.log.warn("Failed to load spectrum for scan {d}; emitting metadata only", .{scan_number});
    }

    const scan = state.file.scans[scan_index];
    const spec = state.current_spectrum;
    const has_spectrum = load_ok and spec != null and spec.?.point_count() > 0;

    // Get trailer event for extra metadata
    var calibrators: []const f64 = &[_]f64{};
    if (state.file.trailer_events) |te| {
        if (te.get_event(scan_index)) |evt| {
            calibrators = evt.mass_calibrators;
        }
    }

    // Build JSON into a buffer
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\n");

    // Scan metadata
    try appendFmt(&list, allocator, "  \"scan_number\": {d},\n", .{scan_number});
    try appendFmt(&list, allocator, "  \"ms_level\": {d},\n", .{scan.ms_level});
    try appendFmt(&list, allocator, "  \"retention_time\": {d:.6},\n", .{scan.rt});
    try appendFmt(&list, allocator, "  \"tic\": {d:.6},\n", .{scan.tic});
    try appendFmt(&list, allocator, "  \"base_peak_mz\": {d:.6},\n", .{scan.base_peak_mz});
    try appendFmt(&list, allocator, "  \"base_peak_intensity\": {d:.6},\n", .{scan.base_peak_intensity});
    try list.appendSlice(allocator, "  \"filter_string\": ");
    var filter_str: ?[]u8 = scan.filter_string;
    var filter_str_owned: ?[]u8 = null;
    if (filter_str == null) {
        if (state.file.trailer_events) |te| {
            if (te.get_event(scan_index)) |evt| {
                filter_str_owned = try scan_event.build_filter_string(evt.*, allocator);
                filter_str = filter_str_owned;
            }
        }
    }
    if (filter_str) |fs| {
        try appendJsonString(&list, allocator, fs);
    } else {
        try list.appendSlice(allocator, "null");
    }
    if (filter_str_owned) |fs| allocator.free(fs);
    try list.appendSlice(allocator, ",\n");
    try appendFmt(&list, allocator, "  \"precursor_mz\": {d:.6},\n", .{scan.precursor_mz});
    try appendFmt(&list, allocator, "  \"collision_energy\": {d:.6},\n", .{scan.collision_energy});
    try appendFmt(&list, allocator, "  \"isolation_width\": {d:.6},\n", .{scan.isolation_width});
    try appendFmt(&list, allocator, "  \"charge_state\": {d},\n", .{scan.charge_state});
    try appendFmt(&list, allocator, "  \"master_scan_number\": {d},\n", .{scan.master_scan_number});
    try appendFmt(&list, allocator, "  \"monoisotopic_mz\": {d:.6},\n", .{scan.monoisotopic_mz});
    try appendFmt(&list, allocator, "  \"low_mass\": {d:.6},\n", .{scan.low_mass});
    try appendFmt(&list, allocator, "  \"high_mass\": {d:.6},\n", .{scan.high_mass});
    try appendFmt(&list, allocator, "  \"peak_count\": {d},\n", .{scan.peak_count});
    try appendFmt(&list, allocator, "  \"is_centroid\": {},\n", .{if (scan.packet_type & 0xFFFF == raw.PACKET_TYPE_FT_CENTROID) true else false});
    try appendFmt(&list, allocator, "  \"packet_type\": {d},\n", .{scan.packet_type & 0xFFFF});
    try appendFmt(&list, allocator, "  \"data_offset\": {d},\n", .{scan.data_offset});
    try appendFmt(&list, allocator, "  \"calibrators_count\": {d},\n", .{calibrators.len});

    // Spectrum data
    try list.appendSlice(allocator, "  \"peaks\": ");
    if (has_spectrum) {
        const s = spec.?;
        try list.appendSlice(allocator, "[\n");
        const n = s.point_count();
        const has_features = s.features != null;
        for (0..n) |i| {
            try appendFmt(&list, allocator, "    {{\"mz\": {d:.6}, \"intensity\": {d:.2}", .{ s.mz[i], s.intensity[i] });
            if (has_features) {
                const feat = s.features.?[i];
                try appendFmt(&list, allocator, ", \"charge\": {d}, \"resolution\": {d:.2}, \"noise\": {d:.4}, \"baseline\": {d:.4}, \"snr\": {d:.4}", .{
                    feat.charge, feat.resolution, feat.noise, feat.baseline, feat.sn_ratio,
                });
                try list.appendSlice(allocator, ", \"flags\": {");
                try appendFmt(&list, allocator, "\"fragmented\": {}, \"merged\": {}, \"reference\": {}, \"exception\": {}, \"modified\": {}", .{
                    feat.flags.fragmented, feat.flags.merged, feat.flags.reference, feat.flags.exception, feat.flags.modified,
                });
                try list.appendSlice(allocator, "}");
            }
            if (i < n - 1) {
                try list.appendSlice(allocator, "},\n");
            } else {
                try list.appendSlice(allocator, "}\n");
            }
        }
        try list.appendSlice(allocator, "  ]\n");
    } else {
        try list.appendSlice(allocator, "null\n");
    }

    try list.appendSlice(allocator, "}\n");

    // Write to stdout
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, list.items);
}
