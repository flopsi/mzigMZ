/// Instrument inference algorithms.
///
/// Consumes spec/scan_event_info.zig (MassAnalyzerType enum) and
/// spec/packet_header.zig (PacketType enum) to infer which mass
/// analyzers are present in a .raw file.
///
/// These are heuristic algorithms, not specs — the enum constants
/// live in src/spec/.
const std = @import("std");
const spec_sei = @import("spec/scan_event_info");
const spec_ph = @import("spec/packet_header");
const raw = @import("raw_file");

/// Which mass analyzers are present in the file.
pub const AnalyzerPresence = struct {
    has_orbitrap: bool = false,
    has_astral: bool = false,
    has_ion_trap: bool = false,
    has_tq: bool = false,
};

/// Infer which mass analyzers are present by examining packet types and
/// scan-event mass_analyzer_type values. Decoupled from AppState/FileState —
/// callers pass the raw data this function needs.
pub fn infer_analyzers(file_revision: u16, scan_events: []const raw.ScanEventInfo, packet_types: []const u32) AnalyzerPresence {
    var ap = AnalyzerPresence{};

    // Tier 1: packet type codes (FT_* → orbitrap, LINEAR_TRAP_* / LOW_RES_* → ion_trap).
    for (packet_types) |pt| {
        const packet_type: u32 = pt & 0xFFFF;
        if (packet_type == @intFromEnum(spec_ph.PacketType.ft_profile) or
            packet_type == @intFromEnum(spec_ph.PacketType.ft_centroid) or
            packet_type == @intFromEnum(spec_ph.PacketType.high_res_compressed_profile))
        {
            ap.has_orbitrap = true;
        }
        if (packet_type == @intFromEnum(spec_ph.PacketType.linear_trap_profile) or
            packet_type == @intFromEnum(spec_ph.PacketType.linear_trap_centroid) or
            packet_type == @intFromEnum(spec_ph.PacketType.low_res_spectrum) or
            packet_type == @intFromEnum(spec_ph.PacketType.low_res_compressed_profile))
        {
            ap.has_ion_trap = true;
        }
    }

    // Tier 2: scan-event mass_analyzer_type field (present from rev 54 onward).
    if (file_revision >= 54) {
        for (scan_events) |info| {
            const mat: u8 = info.mass_analyzer_type;
            if (mat == @intFromEnum(spec_sei.MassAnalyzerType.ion_trap)) ap.has_ion_trap = true;
            if (mat == @intFromEnum(spec_sei.MassAnalyzerType.triple_quad)) ap.has_tq = true;
            if (mat == @intFromEnum(spec_sei.MassAnalyzerType.orbitrap)) ap.has_orbitrap = true;
            if (mat == @intFromEnum(spec_sei.MassAnalyzerType.astral)) ap.has_astral = true;
        }
    }

    return ap;
}

test "inferAnalyzers returns empty for no data" {
    const ap = infer_analyzers(65, &[_]raw.ScanEventInfo{}, &[_]u32{});
    try std.testing.expect(!ap.has_orbitrap);
    try std.testing.expect(!ap.has_astral);
    try std.testing.expect(!ap.has_ion_trap);
    try std.testing.expect(!ap.has_tq);
}

test "inferAnalyzers detects orbitrap from packet type" {
    const ap = infer_analyzers(65, &[_]raw.ScanEventInfo{}, &[_]u32{@intFromEnum(spec_ph.PacketType.ft_centroid)});
    try std.testing.expect(ap.has_orbitrap);
    try std.testing.expect(!ap.has_ion_trap);
}

test "inferAnalyzers detects ion trap from mass_analyzer_type" {
    var info = std.mem.zeroes(raw.ScanEventInfo);
    info.mass_analyzer_type = @intFromEnum(spec_sei.MassAnalyzerType.ion_trap);
    const ap = infer_analyzers(65, &[_]raw.ScanEventInfo{info}, &[_]u32{});
    try std.testing.expect(ap.has_ion_trap);
    try std.testing.expect(!ap.has_orbitrap);
}

test "inferAnalyzers ignores mass_analyzer_type for old revisions" {
    var info = std.mem.zeroes(raw.ScanEventInfo);
    info.mass_analyzer_type = @intFromEnum(spec_sei.MassAnalyzerType.astral);
    const ap = infer_analyzers(50, &[_]raw.ScanEventInfo{info}, &[_]u32{});
    try std.testing.expect(!ap.has_astral);
}
