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
