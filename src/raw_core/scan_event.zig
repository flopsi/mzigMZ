/// ScanEvent parser for Thermo RAW files.
///
/// Parses ScanEventInfoStruct (136 bytes for rev >= 65), Reaction array, MassRange array,
/// MassCalibrators, SourceFragmentations, and Name from the TrailerScanEvents table.
const std = @import("std");
const raw = @import("raw_file");
const unicode = @import("unicode_utils");

/// Public error set for ScanEvent public functions (parseScanEvent,
/// buildFilterString, etc.). Per zig-quality R1, public APIs declare named
/// error sets for exhaustive switch support.
pub const ScanEventError = error{
    OutOfMemory,
    InvalidRawFileInfo,
    Truncated,
    NoSpaceLeft,
};

/// Complete ScanEvent parsed from trailer.
pub const ScanEvent = struct {
    info: raw.ScanEventInfo,
    reactions: []raw.Reaction,
    mass_ranges: []raw.ScanEventMassRange,
    mass_calibrators: []f64,
    source_fragmentations: []f64,
    source_fragmentation_mass_ranges: []raw.ScanEventMassRange,
    name: ?[]u8,

    pub fn deinit(self: *ScanEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.reactions);
        allocator.free(self.mass_ranges);
        allocator.free(self.mass_calibrators);
        allocator.free(self.source_fragmentations);
        allocator.free(self.source_fragmentation_mass_ranges);
        if (self.name) |n| allocator.free(n);
    }

    /// Deep equality comparison including all sub-arrays and optional name.
    pub fn eql(a: ScanEvent, b: ScanEvent) bool {
        if (!std.meta.eql(a.info, b.info)) return false;
        if (a.reactions.len != b.reactions.len) return false;
        for (a.reactions, b.reactions) |ra, rb| {
            if (!std.meta.eql(ra, rb)) return false;
        }
        if (a.mass_ranges.len != b.mass_ranges.len) return false;
        for (a.mass_ranges, b.mass_ranges) |ma, mb| {
            if (!std.meta.eql(ma, mb)) return false;
        }
        if (a.mass_calibrators.len != b.mass_calibrators.len) return false;
        for (a.mass_calibrators, b.mass_calibrators) |ca, cb| {
            if (ca != cb) return false;
        }
        if (a.source_fragmentations.len != b.source_fragmentations.len) return false;
        for (a.source_fragmentations, b.source_fragmentations) |fa, fb| {
            if (fa != fb) return false;
        }
        if (a.source_fragmentation_mass_ranges.len != b.source_fragmentation_mass_ranges.len) return false;
        for (a.source_fragmentation_mass_ranges, b.source_fragmentation_mass_ranges) |fa, fb| {
            if (!std.meta.eql(fa, fb)) return false;
        }
        if (a.name == null and b.name == null) return true;
        if (a.name == null or b.name == null) return false;
        return std.mem.eql(u8, a.name.?, b.name.?);
    }
};

/// Parse a single ScanEvent from memory-mapped file at given offset.
/// Returns the parsed event and bytes consumed.
pub fn parse_scan_event(
    allocator: std.mem.Allocator,
    mm: std.Io.File.MemoryMap,
    offset: u64,
    file_revision: u16,
) raw.RawResolveError!struct { event: ScanEvent, bytes_read: u64 } {
    const scan_event_info_size = raw.scan_event_info_size(file_revision);
    const offset_usz = std.math.cast(usize, offset) orelse return raw.RawResolveError.OffsetOverflow;
    const info_end = std.math.add(usize, offset_usz, scan_event_info_size) catch return raw.RawResolveError.OffsetOverflow;
    if (info_end > mm.memory.len) {
        return raw.RawResolveError.Truncated;
    }

    var pos: usize = offset_usz;

    // 1. Read ScanEventInfoStruct (size depends on file revision)
    const info = try raw.ScanEventInfo.read(mm.memory, pos, scan_event_info_size);
    pos = info_end;

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

    const start_offset = std.math.cast(usize, offset) orelse return raw.RawResolveError.OffsetOverflow;
    return .{ .event = event, .bytes_read = std.math.cast(u64, std.math.sub(usize, pos, start_offset) catch return raw.RawResolveError.OffsetOverflow) orelse return raw.RawResolveError.OffsetOverflow };
}

/// Skip a ScanEvent without allocating. Returns the number of bytes consumed.
pub fn skip_scan_event(
    mm: []const u8,
    offset: u64,
    file_revision: u16,
) raw.RawResolveError!u64 {
    const scan_event_info_size = raw.scan_event_info_size(file_revision);
    const offset_usz = std.math.cast(usize, offset) orelse return raw.RawResolveError.OffsetOverflow;
    const info_end = std.math.add(usize, offset_usz, scan_event_info_size) catch return raw.RawResolveError.OffsetOverflow;
    if (info_end > mm.len) {
        return raw.RawResolveError.Truncated;
    }
    var pos: usize = info_end;

    // Reactions
    var field_end = std.math.add(usize, pos, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    const num_reactions = std.mem.readInt(i32, mm[pos..][0..4], .little);
    pos = field_end;
    if (num_reactions < 0 or num_reactions > 100) return raw.RawResolveError.InvalidRawFileInfo;
    const reaction_size = raw.reaction_size(file_revision);
    const num_reactions_usz = std.math.cast(usize, num_reactions) orelse return raw.RawResolveError.InvalidRawFileInfo;
    const reactions_bytes = std.math.mul(usize, num_reactions_usz, reaction_size) catch return raw.RawResolveError.OffsetOverflow;
    field_end = std.math.add(usize, pos, reactions_bytes) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    pos = field_end;

    // Mass ranges
    field_end = std.math.add(usize, pos, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    const num_mass_ranges = std.mem.readInt(i32, mm[pos..][0..4], .little);
    pos = field_end;
    if (num_mass_ranges < 0 or num_mass_ranges > 100) return raw.RawResolveError.InvalidRawFileInfo;
    const num_mass_ranges_usz = std.math.cast(usize, num_mass_ranges) orelse return raw.RawResolveError.InvalidRawFileInfo;
    const mass_ranges_bytes = std.math.mul(usize, num_mass_ranges_usz, 16) catch return raw.RawResolveError.OffsetOverflow;
    field_end = std.math.add(usize, pos, mass_ranges_bytes) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    pos = field_end;

    // Calibrators
    field_end = std.math.add(usize, pos, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    const num_calibrators = std.mem.readInt(i32, mm[pos..][0..4], .little);
    pos = field_end;
    if (num_calibrators < 0 or num_calibrators > 1000) return raw.RawResolveError.InvalidRawFileInfo;
    const num_calibrators_usz = std.math.cast(usize, num_calibrators) orelse return raw.RawResolveError.InvalidRawFileInfo;
    const calibrators_bytes = std.math.mul(usize, num_calibrators_usz, 8) catch return raw.RawResolveError.OffsetOverflow;
    field_end = std.math.add(usize, pos, calibrators_bytes) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    pos = field_end;

    // Source fragmentations
    field_end = std.math.add(usize, pos, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    const num_frags = std.mem.readInt(i32, mm[pos..][0..4], .little);
    pos = field_end;
    if (num_frags < 0 or num_frags > 1000) return raw.RawResolveError.InvalidRawFileInfo;
    const num_frags_usz = std.math.cast(usize, num_frags) orelse return raw.RawResolveError.InvalidRawFileInfo;
    const frags_bytes = std.math.mul(usize, num_frags_usz, 8) catch return raw.RawResolveError.OffsetOverflow;
    field_end = std.math.add(usize, pos, frags_bytes) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    pos = field_end;

    // Source fragmentation mass ranges
    field_end = std.math.add(usize, pos, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    const num_sf_ranges = std.mem.readInt(i32, mm[pos..][0..4], .little);
    pos = field_end;
    if (num_sf_ranges < 0 or num_sf_ranges > 100) return raw.RawResolveError.InvalidRawFileInfo;
    const num_sf_ranges_usz = std.math.cast(usize, num_sf_ranges) orelse return raw.RawResolveError.InvalidRawFileInfo;
    const sf_ranges_bytes = std.math.mul(usize, num_sf_ranges_usz, 16) catch return raw.RawResolveError.OffsetOverflow;
    field_end = std.math.add(usize, pos, sf_ranges_bytes) catch return raw.RawResolveError.OffsetOverflow;
    if (field_end > mm.len) return raw.RawResolveError.Truncated;
    pos = field_end;

    // Name (rev >= 65)
    if (file_revision >= 65) {
        field_end = std.math.add(usize, pos, 4) catch return raw.RawResolveError.OffsetOverflow;
        if (field_end > mm.len) return raw.RawResolveError.Truncated;
        const name_len = std.mem.readInt(i32, mm[pos..][0..4], .little);
        pos = field_end;
        if (name_len < 0 or name_len > raw.MAX_STRING_CHARS) return raw.RawResolveError.InvalidRawFileInfo;
        const name_len_usz = std.math.cast(usize, name_len) orelse return raw.RawResolveError.InvalidRawFileInfo;
        const name_bytes = std.math.mul(usize, name_len_usz, 2) catch return raw.RawResolveError.OffsetOverflow;
        field_end = std.math.add(usize, pos, name_bytes) catch return raw.RawResolveError.OffsetOverflow;
        if (field_end > mm.len) return raw.RawResolveError.Truncated;
        pos = field_end;
    }

    return std.math.sub(u64, @as(u64, @intCast(pos)), offset) catch return raw.RawResolveError.OffsetOverflow;
}

/// Read reactions array from memory map.
fn readReactions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
    file_revision: u16,
) raw.RawResolveError![]raw.Reaction {
    const count_end = std.math.add(usize, pos.*, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (count_end > bytes.len) return raw.RawResolveError.Truncated;
    const num_reactions = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
    pos.* = count_end;

    if (num_reactions < 0 or num_reactions > 100) {
        return raw.RawResolveError.InvalidRawFileInfo;
    }
    const n: usize = std.math.cast(usize, num_reactions) orelse return raw.RawResolveError.InvalidRawFileInfo;
    if (n == 0) return &[_]raw.Reaction{};

    const reactions = allocator.alloc(raw.Reaction, n) catch |err| return err;
    errdefer allocator.free(reactions);

    const reaction_size: usize = raw.reaction_size(file_revision);

    for (reactions) |*rxn| {
        const rxn_end = std.math.add(usize, pos.*, reaction_size) catch return raw.RawResolveError.OffsetOverflow;
        if (rxn_end > bytes.len) return raw.RawResolveError.Truncated;
        rxn.* = try raw.Reaction.read(bytes, pos.*, reaction_size);
        pos.* = rxn_end;
    }

    return reactions;
}

/// Read mass ranges array from memory map.
fn readMassRanges(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
) raw.RawResolveError![]raw.ScanEventMassRange {
    const count_end = std.math.add(usize, pos.*, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (count_end > bytes.len) return raw.RawResolveError.Truncated;
    const num_ranges = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
    pos.* = count_end;

    if (num_ranges < 0 or num_ranges > 100) {
        return raw.RawResolveError.InvalidRawFileInfo;
    }
    const n: usize = std.math.cast(usize, num_ranges) orelse return raw.RawResolveError.InvalidRawFileInfo;
    if (n == 0) return &[_]raw.ScanEventMassRange{};

    const ranges = allocator.alloc(raw.ScanEventMassRange, n) catch |err| return err;
    errdefer allocator.free(ranges);

    for (ranges) |*range| {
        const range_end = std.math.add(usize, pos.*, 16) catch return raw.RawResolveError.OffsetOverflow;
        if (range_end > bytes.len) return raw.RawResolveError.Truncated;
        const high_offset = std.math.add(usize, pos.*, 8) catch return raw.RawResolveError.OffsetOverflow;
        range.* = .{
            .low = @bitCast(std.mem.readInt(u64, bytes[pos.*..][0..8], .little)),
            .high = @bitCast(std.mem.readInt(u64, bytes[high_offset..][0..8], .little)),
        };
        pos.* = range_end;
    }

    return ranges;
}

/// Read length-prefixed double array from memory map.
fn readDoubleArray(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
) raw.RawResolveError![]f64 {
    const count_end = std.math.add(usize, pos.*, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (count_end > bytes.len) return raw.RawResolveError.Truncated;
    const len = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
    pos.* = count_end;

    if (len < 0 or len > 1000) {
        return raw.RawResolveError.InvalidRawFileInfo;
    }
    const n: usize = std.math.cast(usize, len) orelse return raw.RawResolveError.InvalidRawFileInfo;
    if (n == 0) return &[_]f64{};

    const arr = allocator.alloc(f64, n) catch |err| return err;
    errdefer allocator.free(arr);

    const array_bytes = std.math.mul(usize, n, 8) catch return raw.RawResolveError.OffsetOverflow;
    const array_end = std.math.add(usize, pos.*, array_bytes) catch return raw.RawResolveError.OffsetOverflow;
    if (array_end > bytes.len) return raw.RawResolveError.Truncated;
    for (arr, 0..) |*val, i| {
        const element_offset = std.math.add(usize, pos.*, std.math.mul(usize, i, 8) catch return raw.RawResolveError.OffsetOverflow) catch return raw.RawResolveError.OffsetOverflow;
        val.* = @bitCast(std.mem.readInt(u64, bytes[element_offset..][0..8], .little));
    }
    pos.* = array_end;

    return arr;
}

/// Read length-prefixed wide string (UTF-16LE) and convert to UTF-8.
fn readWideString(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
) raw.RawResolveError!?[]u8 {
    const count_end = std.math.add(usize, pos.*, 4) catch return raw.RawResolveError.OffsetOverflow;
    if (count_end > bytes.len) return raw.RawResolveError.Truncated;
    const len = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
    pos.* = count_end;

    if (len < 0 or len > raw.MAX_STRING_CHARS) {
        return raw.RawResolveError.InvalidRawFileInfo;
    }
    const n: usize = std.math.cast(usize, len) orelse return raw.RawResolveError.InvalidRawFileInfo;
    if (n == 0) return null;

    const name_bytes = std.math.mul(usize, n, 2) catch return raw.RawResolveError.OffsetOverflow;
    const name_end = std.math.add(usize, pos.*, name_bytes) catch return raw.RawResolveError.OffsetOverflow;
    if (name_end > bytes.len) return raw.RawResolveError.Truncated;
    const wide_slice = bytes[pos.*..name_end];
    defer pos.* = name_end;
    return unicode.utf16_le_to_utf8_alloc(allocator, wide_slice, n) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRawFileInfo, // surrogate errors are data format issues
    };
}

/// Build a Thermo-style filter string from scan event fields.
/// Matches C# IScanFilter.ToString() output as closely as possible.
/// Caller owns the returned slice.
pub fn build_filter_string(event: ScanEvent, allocator: std.mem.Allocator) ScanEventError!?[]u8 {
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
    // Matches Thermo IonizationModeType enum values.
    const ion_mode = switch (info.ionization_mode) {
        0 => "EI",
        1 => "CI",
        2 => "FAB",
        3 => "ESI",
        4 => "APCI",
        5 => "NSI",
        6 => "TSP",
        7 => "FD",
        8 => "MALDI",
        9 => "GD",
        10 => "", // Any / not recorded
        11 => "PSI",
        12 => "cNSI",
        13 => "IM1",
        14 => "IM2",
        else => "",
    };
    if (ion_mode.len > 0) {
        try parts.appendSlice(allocator, ion_mode);
        try parts.append(allocator, ' ');
    }

    // 4.5. FAIMS compensation voltage
    // Thermo stores two bytes at ScanEventInfo offsets 122-123:
    //   compensation_voltage:      OnOffTypes (0=On, 1=Off, 2=Any)
    //   compensation_voltage_type: VoltageTypes (0=NoValue, 1=SingleValue, 2=Ramp, ...)
    // The actual voltage value is in event.source_fragmentations[framentationsOffset],
    // where the offset depends on whether SourceFragmentation is also active
    // (1 if SingleValue, 2 if Ramp, else 0). See ScanEvent.cs:FormatCompensationVoltage.
    if (info.compensation_voltage == 0) {
        // FAIMS on
        if (info.compensation_voltage_type == 1 or info.compensation_voltage_type == 2) {
            // SingleValue or Ramp — emit cv=<value> or cv=<low>-<high>
            var frag_offset: usize = 0;
            if (info.source_fragmentation == 0) {
                if (info.source_fragmentation_type == 1) frag_offset = 1;
                if (info.source_fragmentation_type == 2) frag_offset = 2;
            }
            if (frag_offset < event.source_fragmentations.len) {
                const v1 = event.source_fragmentations[frag_offset];
                if (info.compensation_voltage_type == 2 and frag_offset + 1 < event.source_fragmentations.len) {
                    // Ramp: emit as cv=<value1>-<value2> with no space before the hyphen
                    // and a trailing space so the next token is separated.
                    var cv_buf: [64]u8 = undefined;
                    const cv_str = try std.fmt.bufPrint(
                        &cv_buf,
                        "cv={d:.2}-{d:.2} ",
                        .{ v1, event.source_fragmentations[frag_offset + 1] },
                    );
                    try parts.appendSlice(allocator, cv_str);
                } else {
                    // SingleValue: emit as cv=<value> with a trailing space.
                    var cv_buf: [32]u8 = undefined;
                    const cv_str = try std.fmt.bufPrint(&cv_buf, "cv={d:.2} ", .{v1});
                    try parts.appendSlice(allocator, cv_str);
                }
            }
        }
    } else if (info.compensation_voltage == 1) {
        // FAIMS off
        try parts.appendSlice(allocator, "!cv ");
    }
    // compensation_voltage == 2 (Any) → emit nothing

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
        const activation = if (info.hcd_value != 0) "@hcd" else if (info.etd_value != 0) "@etd" else if (info.ecd_value != 0) "@ecd" else if (info.pqd_value != 0) "@pqd" else if (info.mpd_value != 0) "@mpd" else if (info.hcd_type == 1) "@hcd" else if (info.etd_type == 1) "@etd" else if (info.ecd_type == 1) "@ecd" else if (info.pqd_type == 1) "@pqd" else if (info.mpd_type == 1) "@mpd" else "@cid";
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

test "FAIMS ramp CV formatting" {
    const allocator = std.testing.allocator;
    var info = std.mem.zeroes(raw.ScanEventInfo);
    info.mass_analyzer_type = 4;
    info.polarity = 1;
    info.scan_data_type = 0;
    info.ionization_mode = 3;
    info.scan_type = 0;
    info.ms_order = 1;
    info.compensation_voltage = 0;
    info.compensation_voltage_type = 2;

    const event = ScanEvent{
        .info = info,
        .reactions = &[_]raw.Reaction{},
        .mass_ranges = &[_]raw.ScanEventMassRange{},
        .mass_calibrators = &[_]f64{},
        .source_fragmentations = &[_]f64{ 1.0, 2.0 },
        .source_fragmentation_mass_ranges = &[_]raw.ScanEventMassRange{},
        .name = null,
    };

    const filter = try build_filter_string(event, allocator);
    defer if (filter) |f| allocator.free(f);
    try std.testing.expectEqualStrings("FTMS + c ESI cv=1.00-2.00 Full ms", filter.?);
}

test "FAIMS single-value CV formatting" {
    const allocator = std.testing.allocator;
    var info = std.mem.zeroes(raw.ScanEventInfo);
    info.mass_analyzer_type = 4;
    info.polarity = 1;
    info.scan_data_type = 0;
    info.ionization_mode = 3;
    info.scan_type = 0;
    info.ms_order = 1;
    info.compensation_voltage = 0;
    info.compensation_voltage_type = 1;

    const event = ScanEvent{
        .info = info,
        .reactions = &[_]raw.Reaction{},
        .mass_ranges = &[_]raw.ScanEventMassRange{},
        .mass_calibrators = &[_]f64{},
        .source_fragmentations = &[_]f64{1.5},
        .source_fragmentation_mass_ranges = &[_]raw.ScanEventMassRange{},
        .name = null,
    };

    const filter = try build_filter_string(event, allocator);
    defer if (filter) |f| allocator.free(f);
    try std.testing.expectEqualStrings("FTMS + c ESI cv=1.50 Full ms", filter.?);
}
