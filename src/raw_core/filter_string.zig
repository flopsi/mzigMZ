/// Filter string parsing algorithms.
///
/// Consumes spec/filter_string.zig (grammar constants) and
/// spec/scan_event_info.zig (enum value tables) to parse Thermo
/// filter strings into structured data.
///
/// These are algorithms, not specs — the constants live in src/spec/.
const std = @import("std");
const spec_filter = @import("spec/filter_string");
const spec_sei = @import("spec/scan_event_info");

/// Extract activation type from a Thermo filter string.
/// Returns the short label ("HCD", "CID", etc.) or null if not found.
pub fn extract_activation_type(filter: []const u8) ?[]const u8 {
    const at_pos = std.mem.indexOf(u8, filter, "@");
    if (at_pos == null) return null;
    const after_at = filter[at_pos.? + 1 ..];
    if (spec_filter.ActivationType.parse(after_at)) |at| {
        return at.label();
    }
    return null;
}

/// Parse MS level from a Thermo filter string.
/// Examples:
///   "FTMS + p NSI Full ms [350.00-1800.00]" → 1
///   "FTMS + p NSI d Full ms2 712.35@hcd30.00 [110.00-2000.00]" → 2
pub fn parse_ms_level_from_filter(filter: []const u8) u8 {
    // Check ms3, ms2 first (must check before "ms " to avoid false match)
    for (spec_filter.MS_LEVEL_PATTERNS) |entry| {
        if (index_of_ignore_case(filter, entry.pattern) != null) return entry.level;
    }
    // MS1 patterns: " ms " or " ms["
    if (index_of_ignore_case(filter, " ms ") != null) return 1;
    if (index_of_ignore_case(filter, " ms[") != null) return 1;
    // Default: if it has "ms" anywhere, assume MS1
    if (index_of_ignore_case(filter, "ms") != null) return 1;
    return spec_filter.DEFAULT_MS_LEVEL;
}

/// Parse precursor m/z from filter string.
/// Looks for the number before "@" in MS2 filters.
pub fn parse_precursor_mz_from_filter(filter: []const u8) f64 {
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

/// Case-insensitive substring search.
pub fn index_of_ignore_case(haystack: []const u8, needle: []const u8) ?usize {
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

// ============================================================================
// Tests
// ============================================================================

test "extractActivationType" {
    const t = std.testing;
    const hcd = extract_activation_type("FTMS + p NSI d Full ms2 712.35@hcd30.00 [110.00-2000.00]");
    try t.expectEqualStrings("HCD", hcd.?);

    const cid = extract_activation_type("ITMS + c NSI r d sa Full ms2 445.12@cid35.00 [50.00-910.00]");
    try t.expectEqualStrings("CID", cid.?);

    const none = extract_activation_type("FTMS + p NSI Full ms [350.00-1800.00]");
    try t.expect(none == null);
}

test "parseMsLevelFromFilter" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 1), parse_ms_level_from_filter("FTMS + p NSI Full ms [350.00-1800.00]"));
    try t.expectEqual(@as(u8, 2), parse_ms_level_from_filter("FTMS + p NSI d Full ms2 712.35@hcd30.00 [110.00-2000.00]"));
    try t.expectEqual(@as(u8, 3), parse_ms_level_from_filter("ITMS + c NSI d Full ms3 445.12@cid35.00 [50.00-910.00]"));
    try t.expectEqual(@as(u8, 1), parse_ms_level_from_filter("no ms pattern here"));
}

test "parsePrecursorMzFromFilter" {
    const t = std.testing;
    try t.expectApproxEqAbs(712.35, parse_precursor_mz_from_filter("FTMS + p NSI d Full ms2 712.35@hcd30.00 [110.00-2000.00]"), 0.001);
    try t.expectApproxEqAbs(445.12, parse_precursor_mz_from_filter("ITMS + c NSI r d sa Full ms2 445.12@cid35.00 [50.00-910.00]"), 0.001);
    try t.expectEqual(@as(f64, 0), parse_precursor_mz_from_filter("FTMS + p NSI Full ms [350.00-1800.00]"));
}
