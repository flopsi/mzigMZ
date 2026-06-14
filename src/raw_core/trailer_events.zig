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
const unicode = @import("unicode_utils");
const filter_string = @import("filter_string");

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
    pub fn get_event(self: TrailerScanEvents, scan_index: usize) ?*scan_event.ScanEvent {
        if (scan_index >= self.scan_to_unique.len) return null;
        const unique_idx = self.scan_to_unique[scan_index];
        if (unique_idx >= self.unique_events.len) return null;
        return &self.unique_events[unique_idx];
    }
};

/// ScanEvent equality comparison for deduplication.
/// Two events are equal if their info, reactions, mass_ranges, calibrators,
/// fragmentations, and name are all equal.
// scanEventsEqual removed: use scan_event.ScanEvent.eql()

/// Find if an event already exists in the unique_events list.
/// Returns the index if found, null otherwise.
fn findUniqueEvent(unique_events: []scan_event.ScanEvent, evt: scan_event.ScanEvent) ?usize {
    for (unique_events, 0..) |*ue, i| {
        if (scan_event.ScanEvent.eql(ue.*, evt)) return i;
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
pub fn parse_trailer_scan_events(
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
    const table_start = std.math.add(u64, trailer_pos, 4) catch return raw.RawResolveError.OffsetOverflow;
    var pos: usize = std.math.cast(usize, table_start) orelse return raw.RawResolveError.OffsetOverflow;

    // Allocate scan-to-unique mapping
    const scan_to_unique = allocator.alloc(usize, num_scans) catch |err| return err;
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

        const result = scan_event.parse_scan_event(allocator, mm, pos, file_revision) catch |err| switch (err) {
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

        const bytes_read_usz = std.math.cast(usize, result.bytes_read) orelse return raw.RawResolveError.OffsetOverflow;
        pos = std.math.add(usize, pos, bytes_read_usz) catch return raw.RawResolveError.OffsetOverflow;
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

/// Case-insensitive substring search — delegates to filter_string module.
fn index_of_ignore_case(haystack: []const u8, needle: []const u8) ?usize {
    return filter_string.index_of_ignore_case(haystack, needle);
}

/// Parse MS level from a Thermo filter string — delegates to filter_string module.
pub fn parse_ms_level_from_filter(filter: []const u8) u8 {
    return filter_string.parse_ms_level_from_filter(filter);
}

/// Parse precursor m/z from filter string — delegates to filter_string module.
pub fn parse_precursor_mz_from_filter(filter: []const u8) f64 {
    return filter_string.parse_precursor_mz_from_filter(filter);
}

/// Read the per-scan trailer record from the memory-mapped file.
/// `trailer_offset` is the byte offset of the trailer record in the file.
/// This is the legacy / fallback path; the authoritative metadata lives
/// in the TrailerScanEvents table (see parseTrailerScanEvents above).
pub fn read_scan_trailer(
    allocator: std.mem.Allocator,
    mm: std.Io.File.MemoryMap,
    trailer_offset: i32,
) raw.RawResolveError!ScanTrailer {
    if (trailer_offset <= 0) {
        return .{ .filter_string = null, .ms_level = 1, .charge_state = 0, .precursor_mz = 0 };
    }
    const off: usize = std.math.cast(usize, trailer_offset) orelse return raw.RawResolveError.OffsetOverflow;
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
                    const str_len: usize = std.math.cast(usize, value) orelse return raw.RawResolveError.InvalidRawFileInfo;
                    if (pos + str_len * 2 <= mm.memory.len) {
                        const wide_slice = mm.memory[pos .. pos + str_len * 2];
                        // Non-critical metadata: filter string is diagnostic only.
                        // If allocation fails (OOM), skip it. The scan will still
                        // decode with default MS level (1). See GOTCHAS.md and
                        // oom-swizzling task in remaining-bugs-and-discipline.json.
                        const utf8_buf = unicode.utf16_le_to_utf8_alloc(allocator, wide_slice, str_len) catch continue;
                        filter_str = utf8_buf;
                        ms_level = parse_ms_level_from_filter(utf8_buf);
                        precursor = parse_precursor_mz_from_filter(utf8_buf);
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
