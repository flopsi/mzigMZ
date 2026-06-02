/// TrailerScanEvents table parser for Thermo RAW files.
///
/// File layout (from C# TrailerScanEvents.Load):
///   Offset 0:   i32 marker (skipped via ReadIntExt)
///   Offset 4:   ScanEvent[0] (variable length)
///   Offset 4+len0: ScanEvent[1]
///   ... repeated for NumTrailerScanEvents scans
///
/// There is NO index array in the file. The C# code deduplicates scan events
/// in memory using a SortedSet<ScanEvent>. We do the same: parse all events,
/// then build the scan→unique mapping by comparing events for equality.
const std = @import("std");
const raw = @import("raw_file");
const scan_event = @import("scan_event");

/// Parsed TrailerScanEvents table.
pub const TrailerScanEvents = struct {
    /// Unique scan events (deduplicated).
    unique_events: []scan_event.ScanEvent,
    /// Maps scan index → unique_events index.
    scan_to_unique: []usize,

    pub fn deinit(self: *TrailerScanEvents, allocator: std.mem.Allocator) void {
        for (self.unique_events) |*evt| {
            evt.deinit(allocator);
        }
        allocator.free(self.unique_events);
        allocator.free(self.scan_to_unique);
    }

    /// Get the ScanEvent for a given scan index.
    pub fn getEvent(self: TrailerScanEvents, scan_index: usize) ?*scan_event.ScanEvent {
        if (scan_index >= self.scan_to_unique.len) return null;
        const unique_idx = self.scan_to_unique[scan_index];
        if (unique_idx >= self.unique_events.len) return null;
        return &self.unique_events[unique_idx];
    }
};

/// ScanEvent equality comparison for deduplication.
/// Two events are equal if their info, reactions, mass_ranges, calibrators,
/// fragmentations, and name are all equal.
fn scanEventsEqual(a: scan_event.ScanEvent, b: scan_event.ScanEvent) bool {
    // Compare info fields
    if (!std.meta.eql(a.info, b.info)) return false;

    // Compare reactions
    if (a.reactions.len != b.reactions.len) return false;
    for (a.reactions, b.reactions) |ra, rb| {
        if (!std.meta.eql(ra, rb)) return false;
    }

    // Compare mass ranges
    if (a.mass_ranges.len != b.mass_ranges.len) return false;
    for (a.mass_ranges, b.mass_ranges) |ma, mb| {
        if (!std.meta.eql(ma, mb)) return false;
    }

    // Compare calibrators
    if (a.mass_calibrators.len != b.mass_calibrators.len) return false;
    for (a.mass_calibrators, b.mass_calibrators) |ca, cb| {
        if (ca != cb) return false;
    }

    // Compare fragmentations
    if (a.source_fragmentations.len != b.source_fragmentations.len) return false;
    for (a.source_fragmentations, b.source_fragmentations) |fa, fb| {
        if (fa != fb) return false;
    }

    // Compare source fragmentation mass ranges
    if (a.source_fragmentation_mass_ranges.len != b.source_fragmentation_mass_ranges.len) return false;
    for (a.source_fragmentation_mass_ranges, b.source_fragmentation_mass_ranges) |fa, fb| {
        if (!std.meta.eql(fa, fb)) return false;
    }

    // Compare names
    if (a.name == null and b.name == null) return true;
    if (a.name == null or b.name == null) return false;
    return std.mem.eql(u8, a.name.?, b.name.?);
}

/// Find if an event already exists in the unique_events list.
/// Returns the index if found, null otherwise.
fn findUniqueEvent(unique_events: []scan_event.ScanEvent, evt: scan_event.ScanEvent) ?usize {
    for (unique_events, 0..) |*ue, i| {
        if (scanEventsEqual(ue.*, evt)) return i;
    }
    return null;
}

/// Parse the TrailerScanEvents table from memory-mapped file.
///
/// Parameters:
///   - allocator: memory allocator
///   - mm: memory-mapped file
///   - trailer_pos: file offset from RunHeader.TrailerScanEventsPos
///   - num_scans: number of scans (= RunHeader.NumTrailerScanEvents)
///   - file_revision: RAW file revision
pub fn parseTrailerScanEvents(
    allocator: std.mem.Allocator,
    mm: std.Io.File.MemoryMap,
    trailer_pos: u64,
    num_scans: usize,
    file_revision: u16,
) raw.RawResolveError!TrailerScanEvents {
    if (trailer_pos + 4 > mm.memory.len) {
        return raw.RawResolveError.Truncated;
    }

    // Skip first 4 bytes (marker, same as C# viewer.ReadIntExt)
    var pos: usize = @intCast(trailer_pos + 4);

    // Allocate scan-to-unique mapping
    const scan_to_unique = allocator.alloc(usize, num_scans) catch return raw.RawResolveError.InvalidRawFileInfo;
    errdefer allocator.free(scan_to_unique);

    // Parse all scan events sequentially, deduplicating as we go
    var unique_events = std.ArrayList(scan_event.ScanEvent).empty;
    // Note: defer cleanup handled manually in error paths

    var scan_idx: usize = 0;
    while (scan_idx < num_scans) : (scan_idx += 1) {
        if (pos >= mm.memory.len) {
            // Truncated — fill rest with defaults and return what we have
            for (scan_idx..num_scans) |i| scan_to_unique[i] = 0;
            break;
        }

        const result = scan_event.parseScanEvent(allocator, mm, pos, file_revision) catch |err| switch (err) {
            raw.RawResolveError.Truncated => {
                // Fill rest with defaults
                for (scan_idx..num_scans) |i| scan_to_unique[i] = 0;
                break;
            },
            else => {
                // Clean up already parsed unique events
                for (unique_events.items) |*evt| evt.deinit(allocator);
                unique_events.deinit(allocator);
                allocator.free(scan_to_unique);
                return err;
            },
        };

        // Check if this event is already in unique_events
        const existing_idx = findUniqueEvent(unique_events.items, result.event);
        if (existing_idx) |idx| {
            // Event already exists — free the duplicate and use existing index
            var dup = result.event;
            dup.deinit(allocator);
            scan_to_unique[scan_idx] = idx;
        } else {
            // New unique event
            const new_idx = unique_events.items.len;
            unique_events.append(allocator, result.event) catch {
                var dup = result.event;
                dup.deinit(allocator);
                for (unique_events.items) |*evt| evt.deinit(allocator);
                unique_events.deinit(allocator);
                allocator.free(scan_to_unique);
                return raw.RawResolveError.InvalidRawFileInfo;
            };
            scan_to_unique[scan_idx] = new_idx;
        }

        pos += @intCast(result.bytes_read);
    }

    // Move unique_events from ArrayList to owned slice
    const unique_slice = unique_events.toOwnedSlice(allocator) catch {
        for (unique_events.items) |*evt| evt.deinit(allocator);
        unique_events.deinit(allocator);
        allocator.free(scan_to_unique);
        return raw.RawResolveError.InvalidRawFileInfo;
    };

    return TrailerScanEvents{
        .unique_events = unique_slice,
        .scan_to_unique = scan_to_unique,
    };
}

// =============================================================================
// Per-scan trailer record (label table). Each Thermo RAW scan has a small
// structured record keyed by integer labels: label 9 is the filter string,
// label 18 is the charge state, etc. This is the legacy / fallback path
// for the trailer-events table (TrailerScanEvents above), and is also used
// by callers that only need a single scan's filter string and charge.
// =============================================================================

/// Per-scan trailer record extracted from the on-disk label table.
pub const ScanTrailer = struct {
    filter_string: ?[]u8, // allocator-owned UTF-8, null if not available
    ms_level: u8, // 1=MS1, 2=MS2, etc.
    charge_state: i32, // 0 = unknown
    precursor_mz: f64, // 0 = none
};

/// Case-insensitive substring search. Returns the byte offset of the first
/// match, or null if `needle` does not occur in `haystack`.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != needle[j]) break;
        } else return i;
    }
    return null;
}

/// Parse MS level from a Thermo filter string.
/// Examples: "FTMS + p NSI Full ms [350.0000-1800.0000]" → MS1
///           "FTMS + p NSI d Full ms2 712.35@hcd30.00 [110.0000-2000.0000]" → MS2
///           "ITMS + c NSI r d sa Full ms2 445.12@cid35.00 [50.00-910.00]" → MS2
pub fn parseMsLevelFromFilter(filter: []const u8) u8 {
    // Look for "ms2" or "ms3" first (must check before "ms " to avoid false match)
    if (indexOfIgnoreCase(filter, "ms3") != null) return 3;
    if (indexOfIgnoreCase(filter, "ms2") != null) return 2;
    // MS1 patterns: "Full ms [", "Full ms2" would have been caught above
    // Look for " ms " or " ms[" as MS1 indicator
    if (indexOfIgnoreCase(filter, " ms ") != null) return 1;
    if (indexOfIgnoreCase(filter, " ms[") != null) return 1;
    // Default: if it has "ms" anywhere, assume MS1
    if (indexOfIgnoreCase(filter, "ms") != null) return 1;
    return 1; // default to MS1
}

/// Parse charge state from filter string.
/// Looks for pattern like "712.35@hcd30.00" — charge is usually in trailer, not filter.
/// For now, return 0 (unknown) — charge is better extracted from centroid feature words.
pub fn parseChargeFromFilter(filter: []const u8) i32 {
    _ = filter;
    return 0;
}

/// Parse precursor m/z from filter string.
/// Looks for number before "@" symbol in MS2 filters.
pub fn parsePrecursorMzFromFilter(filter: []const u8) f64 {
    const at_pos = std.mem.indexOf(u8, filter, "@");
    if (at_pos == null) return 0;
    // Find the start of the number before @
    var start = at_pos.?;
    while (start > 0 and filter[start - 1] == ' ') start -= 1;
    var num_start = start;
    while (num_start > 0 and (std.ascii.isDigit(filter[num_start - 1]) or filter[num_start - 1] == '.')) {
        num_start -= 1;
    }
    if (num_start >= start) return 0;
    const num_str = filter[num_start..start];
    return std.fmt.parseFloat(f64, num_str) catch 0;
}

/// Read the per-scan trailer record from the memory-mapped file.
/// `trailer_offset` is the byte offset of the trailer record in the file.
/// This is the legacy / fallback path; the authoritative metadata lives
/// in the TrailerScanEvents table (see parseTrailerScanEvents above).
pub fn readScanTrailer(
    allocator: std.mem.Allocator,
    mm: std.Io.File.MemoryMap,
    trailer_offset: i32,
) raw.RawResolveError!ScanTrailer {
    if (trailer_offset <= 0) {
        return .{ .filter_string = null, .ms_level = 1, .charge_state = 0, .precursor_mz = 0 };
    }
    const off: usize = @intCast(trailer_offset);
    if (off + 8 > mm.memory.len) return raw.RawResolveError.Truncated;

    // Trailer format: i32 count, then count pairs of (i32 label, value)
    // Label 9 = filter string (wide string)
    const num_entries = std.mem.readInt(i32, mm.memory[off..][0..4], .little);
    if (num_entries < 0 or num_entries > 1000) return raw.RawResolveError.InvalidRawFileInfo;

    var filter_str: ?[]u8 = null;
    var ms_level: u8 = 1;
    var charge: i32 = 0;
    var precursor: f64 = 0;

    var pos: usize = off + 4;
    var i: i32 = 0;
    while (i < num_entries) : (i += 1) {
        if (pos + 8 > mm.memory.len) break;
        const label = std.mem.readInt(i32, mm.memory[pos..][0..4], .little);
        const value = std.mem.readInt(i32, mm.memory[pos + 4 ..][0..4], .little);
        pos += 8;

        switch (label) {
            9 => { // Filter string
                if (value > 0 and value < raw.MAX_STRING_CHARS) {
                    const str_len: usize = @intCast(value);
                    if (pos + str_len * 2 <= mm.memory.len) {
                        const wide_slice = mm.memory[pos .. pos + str_len * 2];

                        // Fast path: small strings on stack
                        const stack_chars = 256;
                        if (str_len <= stack_chars) {
                            var stack_wide: [stack_chars]u16 = undefined;
                            @memcpy(std.mem.sliceAsBytes(stack_wide[0..str_len]), wide_slice);
                            var stack_utf8: [stack_chars * 3]u8 = undefined;
                            const utf8_len = std.unicode.utf16LeToUtf8(&stack_utf8, stack_wide[0..str_len]) catch continue;
                            const utf8_buf = allocator.alloc(u8, utf8_len) catch continue;
                            @memcpy(utf8_buf, stack_utf8[0..utf8_len]);
                            filter_str = utf8_buf;
                            ms_level = parseMsLevelFromFilter(utf8_buf);
                            precursor = parsePrecursorMzFromFilter(utf8_buf);
                        } else {
                            const wide_u16 = allocator.alloc(u16, str_len) catch continue;
                            defer allocator.free(wide_u16);
                            @memcpy(std.mem.sliceAsBytes(wide_u16), wide_slice);
                            const utf8_buf = std.unicode.utf16LeToUtf8Alloc(allocator, wide_u16) catch continue;
                            filter_str = utf8_buf;
                            ms_level = parseMsLevelFromFilter(utf8_buf);
                            precursor = parsePrecursorMzFromFilter(utf8_buf);
                        }
                    }
                    pos += str_len * 2;
                }
            },
            18 => { // Charge state
                if (value > 0 and value < 20) charge = value;
            },
            else => {},
        }
    }

    return .{
        .filter_string = filter_str,
        .ms_level = ms_level,
        .charge_state = charge,
        .precursor_mz = precursor,
    };
}
