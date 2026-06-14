/// Thermo filter string grammar — canonical format specification.
///
/// Thermo RAW files encode scan metadata in a text "filter string" with a
/// fixed grammar. This spec defines the activation type codes, MS level
/// patterns, and structure of the filter string format.
///
/// Example: "FTMS + p NSI d Full ms2 712.35@hcd30.00 [110.00-2000.00]"
///
/// Verified from decompiled ThermoFisher.CommonCore.RawFileReader
/// (IScanFilter.ToString, ScanFilterTextParser).
const std = @import("std");

/// Activation type codes extracted from the "@" segment of filter strings.
/// The code is the 3-character lowercase prefix after "@" (e.g., "@hcd30.00" → HCD).
pub const ActivationType = enum(u8) {
    hcd,
    cid,
    etd,
    ecd,
    pqd,
    mpd,
    _,

    /// Parse activation type from the 3 characters after "@" in a filter string.
    /// Returns null if the code doesn't match any known activation type.
    pub fn parse(after_at: []const u8) ?ActivationType {
        if (after_at.len < 3) return null;
        const c0 = std.ascii.toLower(after_at[0]);
        const c1 = std.ascii.toLower(after_at[1]);
        const c2 = std.ascii.toLower(after_at[2]);
        if (c0 == 'h' and c1 == 'c' and c2 == 'd') return .hcd;
        if (c0 == 'c' and c1 == 'i' and c2 == 'd') return .cid;
        if (c0 == 'e' and c1 == 't' and c2 == 'd') return .etd;
        if (c0 == 'e' and c1 == 'c' and c2 == 'd') return .ecd;
        if (c0 == 'p' and c1 == 'q' and c2 == 'd') return .pqd;
        if (c0 == 'm' and c1 == 'p' and c2 == 'd') return .mpd;
        return null;
    }

    /// PSI-MS CV name for mzML export.
    pub fn cv_name(at: ActivationType) []const u8 {
        return switch (at) {
            .hcd => "beam-type collision-induced dissociation",
            .cid => "collision-induced dissociation",
            .etd => "electron transfer dissociation",
            .ecd => "electron capture dissociation",
            .pqd => "pulsed q dissociation",
            .mpd => "multiphoton dissociation",
            _ => "collision-induced dissociation",
        };
    }

    /// Short label for display (e.g., "HCD").
    pub fn label(at: ActivationType) []const u8 {
        return switch (at) {
            .hcd => "HCD",
            .cid => "CID",
            .etd => "ETD",
            .ecd => "ECD",
            .pqd => "PQD",
            .mpd => "MPD",
            _ => "?",
        };
    }
};

/// MS level patterns in filter strings.
/// "ms" alone = MS1, "ms2" = MS2, "ms3" = MS3, etc.
pub const MS_LEVEL_PATTERNS = [_]struct { pattern: []const u8, level: u8 }{
    .{ .pattern = "ms3", .level = 3 },
    .{ .pattern = "ms2", .level = 2 },
};

/// Default MS level when no pattern matches.
pub const DEFAULT_MS_LEVEL: u8 = 1;

/// Filter string structure markers.
pub const AT_MARKER: u8 = '@'; // separates precursor m/z from activation
pub const RANGE_OPEN: u8 = '['; // opens mass range
pub const RANGE_CLOSE: u8 = ']'; // closes mass range

test "ActivationType.parse" {
    const t = std.testing;
    try t.expectEqual(ActivationType.hcd, ActivationType.parse("hcd30.00"));
    try t.expectEqual(ActivationType.cid, ActivationType.parse("cid35.00"));
    try t.expectEqual(ActivationType.etd, ActivationType.parse("etd15.00"));
    try t.expectEqual(ActivationType.ecd, ActivationType.parse("ecd20.00"));
    try t.expectEqual(ActivationType.pqd, ActivationType.parse("pqd25.00"));
    try t.expectEqual(ActivationType.mpd, ActivationType.parse("mpd10.00"));
    try t.expect(ActivationType.parse("xyz") == null);
    try t.expect(ActivationType.parse("ab") == null);
}

test "ActivationType.label" {
    const t = std.testing;
    try t.expectEqualStrings("HCD", ActivationType.hcd.label());
    try t.expectEqualStrings("CID", ActivationType.cid.label());
    try t.expectEqualStrings("ETD", ActivationType.etd.label());
}
