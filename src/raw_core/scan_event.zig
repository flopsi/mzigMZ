/// ScanEvent parser for Thermo RAW files.
///
/// Parses ScanEventInfoStruct (136 bytes for rev >= 65), Reaction array, MassRange array,
/// MassCalibrators, SourceFragmentations, and Name from the TrailerScanEvents table.
const std = @import("std");
const raw = @import("raw_file");

/// Complete ScanEvent parsed from trailer.
pub const ScanEvent = struct {
    info: raw.ScanEventInfo,
    reactions: []raw.Reaction,
    mass_ranges: []raw.MassRange,
    mass_calibrators: []f64,
    source_fragmentations: []f64,
    source_fragmentation_mass_ranges: []raw.MassRange,
    name: ?[]u8,

    pub fn deinit(self: *ScanEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.reactions);
        allocator.free(self.mass_ranges);
        allocator.free(self.mass_calibrators);
        allocator.free(self.source_fragmentations);
        allocator.free(self.source_fragmentation_mass_ranges);
        if (self.name) |n| allocator.free(n);
    }
};

/// Parse a single ScanEvent from memory-mapped file at given offset.
/// Returns the parsed event and bytes consumed.
pub fn parseScanEvent(
    allocator: std.mem.Allocator,
    mm: std.Io.File.MemoryMap,
    offset: u64,
    file_revision: u16,
) raw.RawResolveError!struct { event: ScanEvent, bytes_read: u64 } {
    const scan_event_info_size = raw.scanEventInfoSize(file_revision);
    if (offset + scan_event_info_size > mm.memory.len) {
        return raw.RawResolveError.Truncated;
    }

    var pos: usize = @intCast(offset);

    // 1. Read ScanEventInfoStruct (size depends on file revision)
    const info = try raw.ScanEventInfo.read(mm.memory, pos, scan_event_info_size);
    pos += scan_event_info_size;

    // 2. Read reactions array: i32 num_reactions → Reaction[]
    const reactions = try readReactions(allocator, mm.memory, &pos, file_revision);
    errdefer allocator.free(reactions);

    // 3. Read mass ranges: i32 num_ranges → (f64, f64)[]
    const mass_ranges = try readMassRanges(allocator, mm.memory, &pos);
    errdefer allocator.free(mass_ranges);

    // 4. Read mass calibrators: i32 len → f64[]
    const calibrators = try readDoubleArray(allocator, mm.memory, &pos);
    errdefer allocator.free(calibrators);

    // 5. Read source fragmentations: i32 len → f64[]
    const fragmentations = try readDoubleArray(allocator, mm.memory, &pos);
    errdefer allocator.free(fragmentations);

    // 6. Read source fragmentation mass ranges: i32 len → (f64, f64)[]
    const sf_mass_ranges = try readMassRanges(allocator, mm.memory, &pos);
    errdefer allocator.free(sf_mass_ranges);

    // 7. Read name: i32 len → UTF-16LE → UTF-8 (rev >= 65 only)
    const name = if (file_revision >= 65)
        try readWideString(allocator, mm.memory, &pos)
    else
        null;
    errdefer if (name) |n| allocator.free(n);

    const event = ScanEvent{
        .info = info,
        .reactions = reactions,
        .mass_ranges = mass_ranges,
        .mass_calibrators = calibrators,
        .source_fragmentations = fragmentations,
        .source_fragmentation_mass_ranges = sf_mass_ranges,
        .name = name,
    };

    return .{ .event = event, .bytes_read = pos - @as(usize, @intCast(offset)) };
}

/// Read reactions array from memory map.
fn readReactions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
    file_revision: u16,
) raw.RawResolveError![]raw.Reaction {
    if (pos.* + 4 > bytes.len) return raw.RawResolveError.Truncated;
    const num_reactions = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
    pos.* += 4;

    if (num_reactions < 0 or num_reactions > 100) {
        return raw.RawResolveError.InvalidRawFileInfo;
    }
    const n: usize = @intCast(num_reactions);
    if (n == 0) return &[_]raw.Reaction{};

    const reactions = allocator.alloc(raw.Reaction, n) catch return raw.RawResolveError.InvalidRawFileInfo;
    errdefer allocator.free(reactions);

    const reaction_size: usize = raw.reactionSize(file_revision);

    for (reactions) |*rxn| {
        if (pos.* + reaction_size > bytes.len) return raw.RawResolveError.Truncated;
        rxn.* = try raw.Reaction.read(bytes, pos.*);
        pos.* += reaction_size;
    }

    return reactions;
}

/// Read mass ranges array from memory map.
fn readMassRanges(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
) raw.RawResolveError![]raw.MassRange {
    if (pos.* + 4 > bytes.len) return raw.RawResolveError.Truncated;
    const num_ranges = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
    pos.* += 4;

    if (num_ranges < 0 or num_ranges > 100) {
        return raw.RawResolveError.InvalidRawFileInfo;
    }
    const n: usize = @intCast(num_ranges);
    if (n == 0) return &[_]raw.MassRange{};

    const ranges = allocator.alloc(raw.MassRange, n) catch return raw.RawResolveError.InvalidRawFileInfo;
    errdefer allocator.free(ranges);

    for (ranges) |*range| {
        if (pos.* + 16 > bytes.len) return raw.RawResolveError.Truncated;
        range.* = .{
            .low = @bitCast(std.mem.readInt(u64, bytes[pos.*..][0..8], .little)),
            .high = @bitCast(std.mem.readInt(u64, bytes[pos.* + 8 ..][0..8], .little)),
        };
        pos.* += 16;
    }

    return ranges;
}

/// Read length-prefixed double array from memory map.
fn readDoubleArray(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
) raw.RawResolveError![]f64 {
    if (pos.* + 4 > bytes.len) return raw.RawResolveError.Truncated;
    const len = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
    pos.* += 4;

    if (len < 0 or len > 1000) {
        return raw.RawResolveError.InvalidRawFileInfo;
    }
    const n: usize = @intCast(len);
    if (n == 0) return &[_]f64{};

    const arr = allocator.alloc(f64, n) catch return raw.RawResolveError.InvalidRawFileInfo;
    errdefer allocator.free(arr);

    if (pos.* + n * 8 > bytes.len) return raw.RawResolveError.Truncated;
    for (arr, 0..) |*val, i| {
        val.* = @bitCast(std.mem.readInt(u64, bytes[pos.* + i * 8 ..][0..8], .little));
    }
    pos.* += n * 8;

    return arr;
}

/// Read length-prefixed wide string (UTF-16LE) and convert to UTF-8.
fn readWideString(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
) raw.RawResolveError!?[]u8 {
    if (pos.* + 4 > bytes.len) return raw.RawResolveError.Truncated;
    const len = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
    pos.* += 4;

    if (len < 0 or len > raw.MAX_STRING_CHARS) {
        return raw.RawResolveError.InvalidRawFileInfo;
    }
    const n: usize = @intCast(len);
    if (n == 0) return null;

    if (pos.* + n * 2 > bytes.len) return raw.RawResolveError.Truncated;
    const wide_slice = bytes[pos.* .. pos.* + n * 2];

    // Fast path: small strings on stack
    const stack_chars = 256;
    if (n <= stack_chars) {
        var stack_wide: [stack_chars]u16 = undefined;
        @memcpy(std.mem.sliceAsBytes(stack_wide[0..n]), wide_slice);
        var stack_utf8: [stack_chars * 3]u8 = undefined;
        const utf8_len = std.unicode.utf16LeToUtf8(&stack_utf8, stack_wide[0..n]) catch return raw.RawResolveError.InvalidRawFileInfo;
        const utf8 = allocator.alloc(u8, utf8_len) catch return raw.RawResolveError.InvalidRawFileInfo;
        @memcpy(utf8, stack_utf8[0..utf8_len]);
        pos.* += n * 2;
        return utf8;
    }

    // Slow path: large strings
    const wide_u16 = allocator.alloc(u16, n) catch return raw.RawResolveError.InvalidRawFileInfo;
    defer allocator.free(wide_u16);
    @memcpy(std.mem.sliceAsBytes(wide_u16), wide_slice);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, wide_u16) catch return raw.RawResolveError.InvalidRawFileInfo;
    pos.* += n * 2;
    return utf8;
}

/// Build a Thermo-style filter string from scan event fields.
/// Matches C# IScanFilter.ToString() output as closely as possible.
/// Caller owns the returned slice.
pub fn buildFilterString(event: ScanEvent, allocator: std.mem.Allocator) !?[]u8 {
    const info = event.info;
    if (info.ms_order < 1) return null;

    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(allocator);

    // 1. Mass analyzer
    const analyzer = switch (info.mass_analyzer_type) {
        0 => "ITMS",
        1 => "TQMS",
        2 => "SQMS",
        3 => "TOFMS",
        4 => "FTMS",
        5 => "Sector",
        7 => "ASTMS",
        else => "",
    };
    if (analyzer.len > 0) {
        try parts.appendSlice(allocator, analyzer);
        try parts.append(allocator, ' ');
    }

    // 2. Polarity
    const polarity = switch (info.polarity) {
        0 => "-",
        1 => "+",
        else => "",
    };
    if (polarity.len > 0) {
        try parts.appendSlice(allocator, polarity);
        try parts.append(allocator, ' ');
    }

    // 3. Scan data type (centroid/profile)
    const scan_data = switch (info.scan_data_type) {
        0 => "c",
        1 => "p",
        else => "",
    };
    if (scan_data.len > 0) {
        try parts.appendSlice(allocator, scan_data);
        try parts.append(allocator, ' ');
    }

    // 4. Ionization mode
    const ion_mode = switch (info.ionization_mode) {
        0 => "EI",
        1 => "CI",
        2 => "FAB",
        3 => "ESI",
        4 => "APCI",
        5 => "NSI",
        else => "",
    };
    if (ion_mode.len > 0) {
        try parts.appendSlice(allocator, ion_mode);
        try parts.append(allocator, ' ');
    }

    // 5. Scan mode
    const scan_mode = switch (info.scan_type) {
        0 => "Full",
        1 => "Zoom",
        2 => "SIM",
        3 => "SRM",
        4 => "CRM",
        else => "",
    };
    if (scan_mode.len > 0) {
        try parts.appendSlice(allocator, scan_mode);
        try parts.append(allocator, ' ');
    }

    // 6. MS order
    const ms_order_str = switch (info.ms_order) {
        1 => "ms",
        2 => "2",
        3 => "3",
        else => "",
    };
    if (info.ms_order == 1) {
        try parts.appendSlice(allocator, "ms");
    } else if (info.ms_order >= 2) {
        try parts.appendSlice(allocator, "ms");
        try parts.appendSlice(allocator, ms_order_str);
    }

    // 7. Precursor + activation (for MS2+)
    if (info.ms_order >= 2 and event.reactions.len > 0) {
        const rxn = event.reactions[0];
        // Precursor mass (4 decimal places)
        var buf: [64]u8 = undefined;
        const precursor = try std.fmt.bufPrint(&buf, " {d:.4}", .{rxn.precursor_mass});
        try parts.appendSlice(allocator, precursor);

        // Activation type
        // C# wrapper derives activation type from non-zero value, not just type field
        const activation = if (info.hcd_value != 0) "@hcd"
            else if (info.etd_value != 0) "@etd"
            else if (info.ecd_value != 0) "@ecd"
            else if (info.pqd_value != 0) "@pqd"
            else if (info.mpd_value != 0) "@mpd"
            else if (info.hcd_type == 1) "@hcd"
            else if (info.etd_type == 1) "@etd"
            else if (info.ecd_type == 1) "@ecd"
            else if (info.pqd_type == 1) "@pqd"
            else if (info.mpd_type == 1) "@mpd"
            else "@cid";
        try parts.appendSlice(allocator, activation);

        // Collision energy (2 decimal places)
        var ce_buf: [32]u8 = undefined;
        const ce_str = try std.fmt.bufPrint(&ce_buf, "{d:.2}", .{rxn.collision_energy});
        try parts.appendSlice(allocator, ce_str);
    }

    // 8. Mass range
    if (event.mass_ranges.len > 0) {
        const range = event.mass_ranges[0];
        var range_buf: [128]u8 = undefined;
        const range_str = try std.fmt.bufPrint(&range_buf, " [{d:.4}-{d:.4}]", .{ range.low, range.high });
        try parts.appendSlice(allocator, range_str);
    }

    if (parts.items.len == 0) return null;
    return try allocator.dupe(u8, parts.items);
}
