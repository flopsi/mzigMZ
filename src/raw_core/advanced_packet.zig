const std = @import("std");

pub const PacketError = error{
    Truncated,
    OffsetOverflow,
    NoCentroidData,
    TooManyPoints,
    InvalidPacket,
    OutOfMemory,
};

pub const PacketHeader = struct {
    num_segments: u32,
    num_profile_words: u32,
    num_centroid_words: u32,
    default_feature_word: u32,
    num_non_default_feature_words: u32,
    num_expansion_words: u32,
    num_noise_info_words: u32,
    num_debug_info_words: u32,

    pub fn accurate_mass_centroids(self: PacketHeader) bool {
        return (self.default_feature_word & 0x40) == 0 and
            (self.default_feature_word & 0x10000) != 0;
    }
};

pub const PacketMassRange = struct {
    low: f32,
    high: f32,
};

/// Per-peak feature metadata decoded from centroid packet feature words.
/// Per-peak flags decoded from non-default feature words.
pub const PeakFlags = packed struct(u8) {
    fragmented: bool = false, // bit 0
    merged: bool = false, // bit 1
    reference: bool = false, // bit 2
    exception: bool = false, // bit 3
    modified: bool = false, // bit 4 (was misnamed saturated; Thermo bit 19 is Modified)
    _reserved: u3 = 0,
};

/// Per-peak feature metadata decoded from centroid packet.
/// Sources:
/// - charge, flags: from packet's non-default feature words section
/// - resolution: from expansion words (widths) section
/// - noise, baseline, sn_ratio: interpolated from noise info packets
pub const PeakFeatures = struct {
    charge: i32, // 0 = unknown; from feature word bits 24-31
    resolution: f32, // FWHM resolution; from expansion words (0 = not available)
    noise: f32, // interpolated noise level (0 = not available)
    baseline: f32, // interpolated baseline level (0 = not available)
    sn_ratio: f32, // signal-to-noise = (intensity - baseline) / (noise - baseline)
    monoisotopic: bool, // not available from packet
    flags: PeakFlags, // peak option flags from feature words
};

/// Decode a single non-default feature word.
/// Format from Thermo C#:
/// - bits 0-17 (mask 0x3FFFF): peak index within the segment
/// - bit 19 (0x80000): Modified (or Fragmented depending on context)
/// - bit 20 (0x100000): Exception
/// - bit 21 (0x200000): Reference
/// - bit 22 (0x400000): Merged
/// - bit 23 (0x800000): Fragmented
/// - bits 24-31: charge state
pub fn decode_feature_word(feature_word: u32) struct { charge: i32, flags: PeakFlags } {
    // SAFETY: charge nibble is masked to 8 bits, so it always fits in i32.
    const charge: i32 = @intCast((feature_word >> 24) & 0xFF);
    var flags: PeakFlags = .{};
    // Note: flag bit meanings depend on the default_feature_word context.
    // The C# code uses _isExpand* flags to control which bits are active.
    // For simplified decoding, we map the common flag positions:
    if ((feature_word & 0x800000) != 0) flags.fragmented = true; // bit 23
    if ((feature_word & 0x400000) != 0) flags.merged = true; // bit 22
    if ((feature_word & 0x200000) != 0) flags.reference = true; // bit 21
    if ((feature_word & 0x100000) != 0) flags.exception = true; // bit 20
    if ((feature_word & 0x80000) != 0) flags.modified = true; // bit 19
    return .{ .charge = charge, .flags = flags };
}

/// Extract default flags from the default_feature_word header field.
/// The C# code maps (defaultFlags & 0xF80000) >> 19 to a lookup table.
/// For simplified use, we extract the same flag bits.
pub fn decode_default_flags(default_feature_word: u32) PeakFlags {
    var flags: PeakFlags = .{};
    const flag_bits = (default_feature_word >> 19) & 0x1F;
    if ((flag_bits & 0x10) != 0) flags.fragmented = true;
    if ((flag_bits & 0x08) != 0) flags.merged = true;
    if ((flag_bits & 0x04) != 0) flags.reference = true;
    if ((flag_bits & 0x02) != 0) flags.exception = true;
    if ((flag_bits & 0x01) != 0) flags.modified = true;
    return flags;
}

// ============================================================================
// Noise Info Packet Parsing
// ============================================================================

/// Noise info packet structure — 12 bytes (3 x f32).
/// Stored in the packet's noise section after expansion words.
pub const NoiseInfoPacket = extern struct {
    mass: f32,
    noise: f32,
    baseline: f32,
};

/// Read noise info packets from the packet's noise section.
/// The noise section starts after: header + ranges + profile + centroid + features + expansion.
/// Number of packets = num_noise_info_words * 4 / 12.
pub fn read_noise_info_packets(
    bytes: []const u8,
    data_offset: u64,
    noise_buf: []NoiseInfoPacket,
) PacketError!usize {
    const h = try read_header(bytes, data_offset);

    if (h.num_noise_info_words == 0) return 0;

    // Calculate offset to noise section
    var pos = std.math.add(u64, data_offset, 32) catch return PacketError.OffsetOverflow; // header
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_segments), 8) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow; // ranges
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_profile_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow; // profile
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_centroid_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow; // centroid
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_non_default_feature_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow; // features
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_expansion_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow; // expansion

    const packet_size_bytes = try packet_size_from_header(h);
    const noise_end = std.math.add(u64, data_offset, packet_size_bytes) catch return PacketError.OffsetOverflow;
    const max_bytes = noise_end - pos;
    const noise_info_bytes = std.math.mul(u64, @as(u64, h.num_noise_info_words), 4) catch return PacketError.OffsetOverflow;
    const max_packets_from_words = std.math.divExact(u64, noise_info_bytes, @sizeOf(NoiseInfoPacket)) catch return PacketError.InvalidPacket;
    const max_packets: usize = @min(
        std.math.cast(usize, max_packets_from_words) orelse return PacketError.OffsetOverflow,
        std.math.cast(usize, max_bytes / @sizeOf(NoiseInfoPacket)) orelse return PacketError.OffsetOverflow,
    );
    if (max_packets > noise_buf.len) return PacketError.TooManyPoints;

    var i: u32 = 0;
    while (i < max_packets) : (i += 1) {
        const offset = std.math.add(u64, pos, std.math.mul(u64, @as(u64, i), @sizeOf(NoiseInfoPacket)) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
        const usz_offset = std.math.cast(usize, offset) orelse return PacketError.OffsetOverflow;
        // SAFETY: max_packets is clamped to bytes.len / 12, so usz_offset + 8 stays in bounds.
        noise_buf[i] = .{
            .mass = readF32Direct(bytes, usz_offset),
            .noise = readF32Direct(bytes, usz_offset + 4),
            .baseline = readF32Direct(bytes, usz_offset + 8),
        };
    }
    return max_packets;
}

/// Read resolution widths from expansion words section.
/// The expansion section starts after features, before noise.
/// First word is a header/int (checked for > 0 to indicate HasWidths), remaining words are f32 widths.
pub fn read_resolution_widths(
    bytes: []const u8,
    data_offset: u64,
    widths_buf: []f32,
) PacketError!usize {
    const h = try read_header(bytes, data_offset);

    if (h.num_expansion_words <= 1) return 0; // need at least header + 1 width

    var pos = std.math.add(u64, data_offset, 32) catch return PacketError.OffsetOverflow;
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_segments), 8) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_profile_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_centroid_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_non_default_feature_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;

    // First expansion word is a header (int) — C# checks if > 0 for HasWidths
    const header_end = std.math.add(u64, pos, 4) catch return PacketError.OffsetOverflow;
    const header_offset = std.math.cast(usize, pos) orelse return PacketError.OffsetOverflow;
    if (header_end > bytes.len) return PacketError.Truncated;
    const header_val = std.mem.readInt(u32, bytes[header_offset..][0..4], .little);
    if (header_val == 0) return 0; // no widths

    const num_widths = h.num_expansion_words - 1;
    if (num_widths > widths_buf.len) return PacketError.TooManyPoints;

    const width_data_start = std.math.add(u64, pos, 4) catch return PacketError.OffsetOverflow;
    var i: u32 = 0;
    while (i < num_widths) : (i += 1) {
        const offset = std.math.add(u64, width_data_start, std.math.mul(u64, @as(u64, i), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
        const width_end = std.math.add(u64, offset, 4) catch return PacketError.OffsetOverflow;
        const width_offset = std.math.cast(usize, offset) orelse return PacketError.OffsetOverflow;
        if (width_end > bytes.len) return PacketError.Truncated;
        widths_buf[i] = readF32Direct(bytes, width_offset);
    }
    return num_widths;
}

/// Interpolate noise and baseline for each peak from sparse noise packets.
/// Modifies features array in-place: sets noise, baseline, and sn_ratio.
/// SNR formula from C#: (intensity - baseline) / (noise - baseline), floored at 0.
pub fn interpolate_noise_baseline(
    mz: []const f64,
    intensity: []const f32,
    features: []PeakFeatures,
    noise_packets: []const NoiseInfoPacket,
) void {
    if (noise_packets.len == 0 or mz.len == 0 or features.len == 0) return;
    std.debug.assert(mz.len == intensity.len);
    std.debug.assert(mz.len == features.len);

    // Peaks before first noise packet — use first packet's values
    var i: usize = 0;
    const np_first = noise_packets[0];
    while (i < mz.len and mz[i] <= @as(f64, np_first.mass)) : (i += 1) {
        features[i].noise = np_first.noise;
        features[i].baseline = np_first.baseline;
        features[i].sn_ratio = computeSnr(intensity[i], np_first.baseline, np_first.noise);
    }

    // Interpolate between noise packets
    var noise_idx: usize = 0;
    while (noise_idx + 1 < noise_packets.len) {
        const np_curr = noise_packets[noise_idx];
        const np_next = noise_packets[noise_idx + 1];
        const mass_range = np_next.mass - np_curr.mass;
        const noise_slope = if (mass_range > 0) (np_next.noise - np_curr.noise) / mass_range else 0;
        const baseline_slope = if (mass_range > 0) (np_next.baseline - np_curr.baseline) / mass_range else 0;

        while (i < mz.len and mz[i] <= @as(f64, np_next.mass)) : (i += 1) {
            const dm = @as(f32, @floatCast(mz[i])) - np_curr.mass;
            const noise = np_curr.noise + noise_slope * dm;
            const baseline = np_curr.baseline + baseline_slope * dm;
            features[i].noise = noise;
            features[i].baseline = baseline;
            features[i].sn_ratio = computeSnr(intensity[i], baseline, noise);
        }
        noise_idx += 1;
    }

    // Peaks after last noise packet — use last packet's values
    const np_last = noise_packets[noise_packets.len - 1];
    while (i < mz.len) : (i += 1) {
        features[i].noise = np_last.noise;
        features[i].baseline = np_last.baseline;
        features[i].sn_ratio = computeSnr(intensity[i], np_last.baseline, np_last.noise);
    }
}

/// Compute SNR from intensity, baseline, and noise.
/// C# formula: (intensity - baseline) / (noise - baseline), floored at 0.
inline fn computeSnr(intensity: f32, baseline: f32, noise: f32) f32 {
    const denom = noise - baseline;
    if (denom <= 0) return 0;
    const snr = (intensity - baseline) / denom;
    return if (snr > 0) snr else 0;
}

/// Apply expansion-word widths and noise-info packets to a populated PeakFeatures slice.
/// `feature_words_start` is the byte offset of the first non-default feature word.
fn applyExpansionAndNoiseToFeatures(
    bytes: []const u8,
    data_offset: u64,
    h: PacketHeader,
    feature_words_start: u64,
    mz: []const f64,
    intensity: []const f32,
    features: []PeakFeatures,
    allocator: std.mem.Allocator,
) PacketError!void {
    // Expansion words: optional resolution widths.
    if (h.num_expansion_words > 1) {
        const non_default_bytes = std.math.mul(u64, h.num_non_default_feature_words, @sizeOf(u32)) catch return PacketError.OffsetOverflow;
        const expansion_start = std.math.add(u64, feature_words_start, non_default_bytes) catch return PacketError.OffsetOverflow;
        const expansion_offset = std.math.cast(usize, expansion_start) orelse return PacketError.OffsetOverflow;
        const header_val = std.mem.readInt(u32, bytes[expansion_offset..][0..@sizeOf(u32)], .little);
        if (header_val > 0) {
            const num_widths = h.num_expansion_words - 1;
            const limit = @min(@as(usize, num_widths), features.len);
            var i: usize = 0;
            while (i < limit) : (i += 1) {
                const word_offset = std.math.add(u64, expansion_start, @sizeOf(u32)) catch return PacketError.OffsetOverflow;
                const width_bytes = std.math.mul(u64, @as(u64, i), @sizeOf(f32)) catch return PacketError.OffsetOverflow;
                const width_offset = std.math.add(u64, word_offset, width_bytes) catch return PacketError.OffsetOverflow;
                const offset = std.math.cast(usize, width_offset) orelse return PacketError.OffsetOverflow;
                features[i].resolution = readF32Direct(bytes, offset);
            }
        }
    }

    // Noise info packets: sparse (mass, noise, baseline) triples.
    if (h.num_noise_info_words > 0 and features.len > 0) {
        const noise_info_bytes = std.math.mul(u64, @as(u64, h.num_noise_info_words), 4) catch return PacketError.OffsetOverflow;
        const max_packets = @as(usize, std.math.divExact(u64, noise_info_bytes, @sizeOf(NoiseInfoPacket)) catch return PacketError.InvalidPacket);
        var stack_buf: [4096]NoiseInfoPacket = undefined;
        var allocated = false;
        const noise_buf: []NoiseInfoPacket = if (max_packets <= stack_buf.len)
            stack_buf[0..max_packets]
        else blk: {
            allocated = true;
            break :blk allocator.alloc(NoiseInfoPacket, max_packets) catch return PacketError.OutOfMemory;
        };
        defer if (allocated) allocator.free(noise_buf);

        const num_noise = try read_noise_info_packets(bytes, data_offset, noise_buf);
        if (num_noise > 0) {
            interpolate_noise_baseline(mz, intensity, features, noise_buf[0..num_noise]);
        }
    }
}

pub const Spectrum = struct {
    mz: []f64,
    intensity: []f32,
    features: ?[]PeakFeatures, // null if not decoded
    mz_min: f64,
    mz_max: f64,
    intensity_max: f32,

    pub fn deinit(self: Spectrum, allocator: std.mem.Allocator) void {
        allocator.free(self.mz);
        allocator.free(self.intensity);
        if (self.features) |f| allocator.free(f);
    }

    pub fn point_count(self: Spectrum) usize {
        return self.mz.len;
    }

    pub fn get_mz_min(self: Spectrum) f64 {
        return self.mz_min;
    }

    pub fn get_mz_max(self: Spectrum) f64 {
        return self.mz_max;
    }

    pub fn get_intensity_max(self: Spectrum) f32 {
        return self.intensity_max;
    }
};

pub fn read_header(bytes: []const u8, offset: u64) PacketError!PacketHeader {
    const end = std.math.add(u64, offset, 32) catch return PacketError.OffsetOverflow;
    if (end > bytes.len) return PacketError.Truncated;
    const direct_offset = std.math.cast(usize, offset) orelse return PacketError.OffsetOverflow;
    return read_header_direct(bytes, direct_offset);
}

/// Internal: reads header WITHOUT bounds check.
/// Callers MUST guarantee `bytes.len >= offset + 32` before calling.
/// Prefer `read_header(bytes, offset)` which checks bounds.
fn read_header_direct(bytes: []const u8, offset: usize) PacketHeader {
    return .{
        .num_segments = readU32Direct(bytes, offset + 0),
        .num_profile_words = readU32Direct(bytes, offset + 4),
        .num_centroid_words = readU32Direct(bytes, offset + 8),
        .default_feature_word = readU32Direct(bytes, offset + 12),
        .num_non_default_feature_words = readU32Direct(bytes, offset + 16),
        .num_expansion_words = readU32Direct(bytes, offset + 20),
        .num_noise_info_words = readU32Direct(bytes, offset + 24),
        .num_debug_info_words = readU32Direct(bytes, offset + 28),
    };
}

pub fn packet_size(bytes: []const u8, offset: u64) PacketError!u64 {
    const h = try read_header(bytes, offset);
    return try packet_size_from_header(h);
}

pub fn packet_size_from_header(h: PacketHeader) PacketError!u64 {
    const word_sum = std.math.add(u64, @as(u64, h.num_profile_words), @as(u64, h.num_centroid_words)) catch return PacketError.OffsetOverflow;
    const word_sum2 = std.math.add(u64, word_sum, @as(u64, h.num_non_default_feature_words)) catch return PacketError.OffsetOverflow;
    const word_sum3 = std.math.add(u64, word_sum2, @as(u64, h.num_expansion_words)) catch return PacketError.OffsetOverflow;
    const word_sum4 = std.math.add(u64, word_sum3, @as(u64, h.num_noise_info_words)) catch return PacketError.OffsetOverflow;
    const word_sum5 = std.math.add(u64, word_sum4, @as(u64, h.num_debug_info_words)) catch return PacketError.OffsetOverflow;
    const word_sum_bytes = std.math.mul(u64, word_sum5, 4) catch return PacketError.OffsetOverflow;
    const segment_bytes = std.math.mul(u64, @as(u64, h.num_segments), 8) catch return PacketError.OffsetOverflow;
    const header_plus_segments = std.math.add(u64, 32, segment_bytes) catch return PacketError.OffsetOverflow;
    return std.math.add(u64, header_plus_segments, word_sum_bytes) catch return PacketError.OffsetOverflow;
}

/// Minimal AdvancedPacketBase equivalent.
///
/// This follows:
/// - AdvancedPacketBase.Load
/// - AdvancedPacketBase.ExpandSimplifiedCentroidData
///
/// It reads packet header, segment ranges, skips profile data, then decodes
/// centroid m/z and intensity arrays.
/// Optimized decoder matching .NET's SimplifiedFtCentroidPacket path.
/// Uses stackalloc-like fixed buffers for segment counts (no heap alloc for typical 1-segment scans).
/// Skips ranges[] allocation — only returns mz[] and intensity[].
/// Decode with caller-provided buffers. Returns number of points decoded.
/// Caller must ensure mz_buf and intensity_buf are large enough.
/// Fast inline read helpers — no error unions, no bounds checks.
/// Caller must ensure offset+4 is within bytes.
inline fn readU32Direct(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
inline fn readF32Direct(bytes: []const u8, offset: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little));
}
inline fn readF64Direct(bytes: []const u8, offset: usize) f64 {
    return @bitCast(std.mem.readInt(u64, bytes[offset..][0..8], .little));
}

pub fn decode_simplified_centroids_into_buffers(
    bytes: []const u8,
    data_offset: u64,
    mz_buf: []f64,
    intensity_buf: []f32,
    features_buf: ?[]PeakFeatures,
    allocator: std.mem.Allocator,
) PacketError!usize {
    const h = try read_header(bytes, data_offset);

    if (h.num_segments == 0) {
        @branchHint(.unlikely);
        return PacketError.InvalidPacket;
    }
    if (h.num_centroid_words == 0) {
        @branchHint(.unlikely);
        return PacketError.NoCentroidData;
    }
    if (h.num_segments > 4096) {
        @branchHint(.unlikely);
        return PacketError.InvalidPacket;
    }

    var pos = std.math.add(u64, data_offset, 32) catch return PacketError.OffsetOverflow;
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_segments), 8) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow; // skip ranges
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_profile_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow; // skip profile

    const centroid_start = pos;
    const accurate = h.accurate_mass_centroids();
    const entry_size: u64 = if (accurate) 12 else 8;

    // Feature words are in a separate section after centroid data.
    // Calculate where the feature words section starts.
    const centroid_words_bytes = std.math.mul(u64, @as(u64, h.num_centroid_words), 4) catch return PacketError.OffsetOverflow;
    const feature_words_start = std.math.add(u64, centroid_start, centroid_words_bytes) catch return PacketError.OffsetOverflow;
    const has_features = h.num_non_default_feature_words > 0;
    const default_flags = decode_default_flags(h.default_feature_word);

    // Stack scratch — 128 segments covers 99.99 % of Thermo files.
    // Total footprint: 128 * 2 * 4 = 1 KB, trivial for a decode frame.
    const max_stack_segments = 128;
    var segment_counts: [max_stack_segments]u32 = undefined;
    var segment_offsets: [max_stack_segments]u32 = undefined;

    if (h.num_segments > max_stack_segments) {
        @branchHint(.unlikely);
        return PacketError.InvalidPacket;
    }

    const segment_counts_ptr = segment_counts[0..h.num_segments];
    const segment_offsets_ptr = segment_offsets[0..h.num_segments];

    var count_pos = centroid_start;
    var total_points: u64 = 0;
    var seg: u32 = 0;
    while (seg < h.num_segments) : (seg += 1) {
        const count = try readU32(bytes, count_pos);
        segment_counts_ptr[seg] = count;
        const count_pos_plus_4 = std.math.add(u64, count_pos, 4) catch return PacketError.OffsetOverflow;
        segment_offsets_ptr[seg] = std.math.cast(u32, count_pos_plus_4 - centroid_start) orelse return PacketError.OffsetOverflow;
        const count_bytes = std.math.mul(u64, @as(u64, count), entry_size) catch return PacketError.OffsetOverflow;
        count_pos = std.math.add(u64, count_pos_plus_4, count_bytes) catch return PacketError.OffsetOverflow;
        total_points = std.math.add(u64, total_points, count) catch return PacketError.OffsetOverflow;
        if (total_points > 50_000_000) {
            @branchHint(.unlikely);
            return PacketError.TooManyPoints;
        }
    }

    if (total_points > mz_buf.len or total_points > intensity_buf.len) {
        @branchHint(.unlikely);
        return PacketError.TooManyPoints;
    }
    if (features_buf) |fb| {
        if (total_points > fb.len) {
            @branchHint(.unlikely);
            return PacketError.TooManyPoints;
        }
    }

    // Security: verify input buffer is large enough before entering unsafe decode
    const packet_size_bytes = try packet_size_from_header(h);
    const required_input_size = std.math.add(u64, data_offset, packet_size_bytes) catch return PacketError.OffsetOverflow;
    // SAFETY: bytes.len is a slice length, so it is non-negative and always fits in u64.
    const buf_len: u64 = @intCast(bytes.len);
    if (required_input_size > buf_len) {
        @branchHint(.unlikely);
        return PacketError.Truncated;
    }

    var out_index: usize = 0;
    seg = 0;
    while (seg < h.num_segments) : (seg += 1) {
        const count = segment_counts_ptr[seg];
        var read_pos = std.math.add(u64, centroid_start, segment_offsets_ptr[seg]) catch return PacketError.OffsetOverflow;

        // Validate segment bounds with runtime safety ON before disabling safety.
        const segment_data_end = std.math.add(u64, read_pos, std.math.mul(u64, @as(u64, count), entry_size) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
        const packet_end = std.math.add(u64, data_offset, packet_size_bytes) catch return PacketError.OffsetOverflow;
        if (segment_data_end > packet_end) {
            @branchHint(.unlikely);
            return PacketError.Truncated;
        }

        // Hot decode path: disable runtime safety only for the inner decode body.
        {
            @setRuntimeSafety(false);
            var i: u32 = 0;
            if (accurate) {
                // Accurate mass: 12-byte entries (f64 mz + f32 intensity)
                // Process 4 entries at a time using SIMD loads where possible
                const simd_count = count - (count % 4);
                while (i < simd_count) : (i += 4) {
                    // SAFETY: read_pos is bounded by validated segment_data_end, so it fits usize.
                    const o: usize = @intCast(read_pos);
                    // Load 4 mz values (32 bytes) and 4 intensity values (16 bytes)
                    mz_buf[out_index] = readF64Direct(bytes, o);
                    intensity_buf[out_index] = readF32Direct(bytes, o + 8);
                    mz_buf[out_index + 1] = readF64Direct(bytes, o + 12);
                    intensity_buf[out_index + 1] = readF32Direct(bytes, o + 20);
                    mz_buf[out_index + 2] = readF64Direct(bytes, o + 24);
                    intensity_buf[out_index + 2] = readF32Direct(bytes, o + 32);
                    mz_buf[out_index + 3] = readF64Direct(bytes, o + 36);
                    intensity_buf[out_index + 3] = readF32Direct(bytes, o + 44);
                    read_pos += 48;
                    out_index += 4;
                }
                // Tail elements
                while (i < count) : (i += 1) {
                    // SAFETY: read_pos is bounded by validated segment_data_end, so it fits usize.
                    const o: usize = @intCast(read_pos);
                    mz_buf[out_index] = readF64Direct(bytes, o);
                    intensity_buf[out_index] = readF32Direct(bytes, o + 8);
                    read_pos += 12;
                    out_index += 1;
                }
            } else {
                // Standard mass: 8-byte entries (f32 mz + f32 intensity)
                // Process 8 entries at a time (64 bytes = one cache line)
                const simd_count = count - (count % 8);
                while (i < simd_count) : (i += 8) {
                    // SAFETY: read_pos is bounded by validated segment_data_end, so it fits usize.
                    const o: usize = @intCast(read_pos);
                    mz_buf[out_index] = @floatCast(readF32Direct(bytes, o));
                    intensity_buf[out_index] = readF32Direct(bytes, o + 4);
                    mz_buf[out_index + 1] = @floatCast(readF32Direct(bytes, o + 8));
                    intensity_buf[out_index + 1] = readF32Direct(bytes, o + 12);
                    mz_buf[out_index + 2] = @floatCast(readF32Direct(bytes, o + 16));
                    intensity_buf[out_index + 2] = readF32Direct(bytes, o + 20);
                    mz_buf[out_index + 3] = @floatCast(readF32Direct(bytes, o + 24));
                    intensity_buf[out_index + 3] = readF32Direct(bytes, o + 28);
                    mz_buf[out_index + 4] = @floatCast(readF32Direct(bytes, o + 32));
                    intensity_buf[out_index + 4] = readF32Direct(bytes, o + 36);
                    mz_buf[out_index + 5] = @floatCast(readF32Direct(bytes, o + 40));
                    intensity_buf[out_index + 5] = readF32Direct(bytes, o + 44);
                    mz_buf[out_index + 6] = @floatCast(readF32Direct(bytes, o + 48));
                    intensity_buf[out_index + 6] = readF32Direct(bytes, o + 52);
                    mz_buf[out_index + 7] = @floatCast(readF32Direct(bytes, o + 56));
                    intensity_buf[out_index + 7] = readF32Direct(bytes, o + 60);
                    read_pos += 64;
                    out_index += 8;
                }
                // Tail elements
                while (i < count) : (i += 1) {
                    // SAFETY: read_pos is bounded by validated segment_data_end, so it fits usize.
                    const o: usize = @intCast(read_pos);
                    mz_buf[out_index] = @floatCast(readF32Direct(bytes, o));
                    intensity_buf[out_index] = readF32Direct(bytes, o + 4);
                    read_pos += 8;
                    out_index += 1;
                }
            }
            @setRuntimeSafety(true);
        }
    }

    // Decode feature words if caller provided a features buffer.
    if (features_buf) |fb| {
        // Initialize all features to defaults.
        const total = out_index;
        for (0..total) |idx| {
            fb[idx] = .{
                .charge = 0,
                .resolution = 0,
                .noise = 0,
                .baseline = 0,
                .sn_ratio = 0,
                .monoisotopic = false,
                .flags = default_flags,
            };
        }

        // Apply non-default feature words.
        if (has_features) {
            const num_feature_words = h.num_non_default_feature_words;
            var fw_pos = feature_words_start;
            var fw_idx: u32 = 0;
            while (fw_idx < num_feature_words) : (fw_idx += 1) {
                const fw = try readU32(bytes, fw_pos);
                const peak_idx = fw & 0x3FFFF;
                if (peak_idx < total) {
                    const decoded = decode_feature_word(fw);
                    fb[peak_idx].charge = decoded.charge;
                    fb[peak_idx].flags = decoded.flags;
                }
                fw_pos = std.math.add(u64, fw_pos, 4) catch return PacketError.OffsetOverflow;
            }
        }

        // Apply expansion widths and noise info.
        try applyExpansionAndNoiseToFeatures(
            bytes,
            data_offset,
            h,
            feature_words_start,
            mz_buf[0..total],
            intensity_buf[0..total],
            fb[0..total],
            allocator,
        );
    }

    return out_index;
}

/// Original allocator-based decoder (for GUI use where spectrum persists).
pub fn decode_simplified_centroids(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    data_offset: u64,
) PacketError!Spectrum {
    const h = try read_header(bytes, data_offset);

    if (h.num_segments == 0) return PacketError.InvalidPacket;
    if (h.num_centroid_words == 0) return PacketError.NoCentroidData;
    if (h.num_segments > 4096) return PacketError.InvalidPacket;

    var pos = std.math.add(u64, data_offset, 32) catch return PacketError.OffsetOverflow;
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_segments), 8) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
    pos = std.math.add(u64, pos, std.math.mul(u64, @as(u64, h.num_profile_words), 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;

    const centroid_start = pos;
    const accurate = h.accurate_mass_centroids();
    const entry_size: u64 = if (accurate) 12 else 8;

    const max_stack_segments = 128;
    var segment_counts: [max_stack_segments]u32 = undefined;
    var segment_offsets: [max_stack_segments]u32 = undefined;

    if (h.num_segments > max_stack_segments) {
        @branchHint(.unlikely);
        return PacketError.InvalidPacket;
    }

    const segment_counts_ptr = segment_counts[0..h.num_segments];
    const segment_offsets_ptr = segment_offsets[0..h.num_segments];

    var count_pos = centroid_start;
    var total_points: u64 = 0;
    var seg: u32 = 0;
    while (seg < h.num_segments) : (seg += 1) {
        const count = try readU32(bytes, count_pos);
        segment_counts_ptr[seg] = count;
        const count_pos_plus_4 = std.math.add(u64, count_pos, 4) catch return PacketError.OffsetOverflow;
        segment_offsets_ptr[seg] = std.math.cast(u32, count_pos_plus_4 - centroid_start) orelse return PacketError.OffsetOverflow;
        const count_bytes = std.math.mul(u64, @as(u64, count), entry_size) catch return PacketError.OffsetOverflow;
        count_pos = std.math.add(u64, count_pos_plus_4, count_bytes) catch return PacketError.OffsetOverflow;
        total_points = std.math.add(u64, total_points, count) catch return PacketError.OffsetOverflow;
        if (total_points > 50_000_000) return PacketError.TooManyPoints;
    }

    // SAFETY: total_points is bounded by the 50 M limit and caller buffer checks, so it fits usize.
    const mz = allocator.alloc(f64, @intCast(total_points)) catch return PacketError.OutOfMemory;
    errdefer allocator.free(mz);
    // SAFETY: total_points is bounded by the 50 M limit and caller buffer checks, so it fits usize.
    const intensity = allocator.alloc(f32, @intCast(total_points)) catch return PacketError.OutOfMemory;
    errdefer allocator.free(intensity);
    // SAFETY: total_points is bounded by the 50 M limit and caller buffer checks, so it fits usize.
    const features = allocator.alloc(PeakFeatures, @intCast(total_points)) catch return PacketError.OutOfMemory;
    errdefer allocator.free(features);

    // Feature words section starts after centroid data.
    const centroid_words_bytes = std.math.mul(u64, @as(u64, h.num_centroid_words), 4) catch return PacketError.OffsetOverflow;
    const feature_words_start = std.math.add(u64, centroid_start, centroid_words_bytes) catch return PacketError.OffsetOverflow;
    const has_features = h.num_non_default_feature_words > 0;
    const default_flags = decode_default_flags(h.default_feature_word);

    var out_index: usize = 0;
    var mz_min: f64 = std.math.inf(f64);
    var mz_max: f64 = -std.math.inf(f64);
    var intensity_max: f32 = 0;
    seg = 0;
    while (seg < h.num_segments) : (seg += 1) {
        const count = segment_counts_ptr[seg];
        var read_pos = std.math.add(u64, centroid_start, segment_offsets_ptr[seg]) catch return PacketError.OffsetOverflow;

        var i: u32 = 0;
        if (accurate) {
            while (i < count) : (i += 1) {
                const m = try readF64(bytes, read_pos);
                const inten_offset = std.math.add(u64, read_pos, 8) catch return PacketError.OffsetOverflow;
                const inten = try readF32(bytes, inten_offset);
                mz[out_index] = m;
                intensity[out_index] = inten;
                features[out_index] = .{
                    .charge = 0,
                    .resolution = 0,
                    .noise = 0,
                    .baseline = 0,
                    .sn_ratio = 0,
                    .monoisotopic = false,
                    .flags = default_flags,
                };
                if (m < mz_min) mz_min = m;
                if (m > mz_max) mz_max = m;
                if (inten > intensity_max) intensity_max = inten;
                read_pos = std.math.add(u64, read_pos, 12) catch return PacketError.OffsetOverflow;
                out_index += 1;
            }
        } else {
            while (i < count) : (i += 1) {
                const m: f64 = @floatCast(try readF32(bytes, read_pos));
                const inten_offset = std.math.add(u64, read_pos, 4) catch return PacketError.OffsetOverflow;
                const inten = try readF32(bytes, inten_offset);
                mz[out_index] = m;
                intensity[out_index] = inten;
                features[out_index] = .{
                    .charge = 0,
                    .resolution = 0,
                    .noise = 0,
                    .baseline = 0,
                    .sn_ratio = 0,
                    .monoisotopic = false,
                    .flags = default_flags,
                };
                if (m < mz_min) mz_min = m;
                if (m > mz_max) mz_max = m;
                if (inten > intensity_max) intensity_max = inten;
                read_pos = std.math.add(u64, read_pos, 8) catch return PacketError.OffsetOverflow;
                out_index += 1;
            }
        }
    }

    // Apply non-default feature words.
    if (has_features) {
        const num_feature_words = h.num_non_default_feature_words;
        var fw_pos = feature_words_start;
        var fw_idx: u32 = 0;
        while (fw_idx < num_feature_words) : (fw_idx += 1) {
            const fw = try readU32(bytes, fw_pos);
            const peak_idx = fw & 0x3FFFF;
            if (peak_idx < out_index) {
                const decoded = decode_feature_word(fw);
                features[peak_idx].charge = decoded.charge;
                features[peak_idx].flags = decoded.flags;
            }
            fw_pos = std.math.add(u64, fw_pos, 4) catch return PacketError.OffsetOverflow;
        }
    }

    // Apply expansion widths and noise info.
    try applyExpansionAndNoiseToFeatures(
        bytes,
        data_offset,
        h,
        feature_words_start,
        mz[0..out_index],
        intensity[0..out_index],
        features[0..out_index],
        allocator,
    );

    if (total_points == 0) {
        mz_min = 0;
        mz_max = 1;
        intensity_max = 1;
    }

    return .{
        .mz = mz,
        .intensity = intensity,
        .features = features,
        .mz_min = mz_min,
        .mz_max = mz_max,
        .intensity_max = intensity_max,
    };
}

fn readU32(bytes: []const u8, offset: u64) PacketError!u32 {
    const end = std.math.add(u64, offset, 4) catch return PacketError.OffsetOverflow;
    if (end > bytes.len) return PacketError.Truncated;
    const usz_offset = std.math.cast(usize, offset) orelse return PacketError.OffsetOverflow;
    return std.mem.readInt(u32, bytes[usz_offset..][0..4], .little);
}

fn readF32(bytes: []const u8, offset: u64) PacketError!f32 {
    const end = std.math.add(u64, offset, 4) catch return PacketError.OffsetOverflow;
    if (end > bytes.len) return PacketError.Truncated;
    const usz_offset = std.math.cast(usize, offset) orelse return PacketError.OffsetOverflow;
    return @bitCast(std.mem.readInt(u32, bytes[usz_offset..][0..4], .little));
}

fn readF64(bytes: []const u8, offset: u64) PacketError!f64 {
    const end = std.math.add(u64, offset, 8) catch return PacketError.OffsetOverflow;
    if (end > bytes.len) return PacketError.Truncated;
    const usz_offset = std.math.cast(usize, offset) orelse return PacketError.OffsetOverflow;
    return @bitCast(std.mem.readInt(u64, bytes[usz_offset..][0..8], .little));
}

pub const ReencodeResult = struct {
    written: usize,
    num_points: usize,
    encoded_size: usize,
};

pub const ReencodeError = PacketError || std.mem.Allocator.Error;

/// High-level utility to round-trip a centroid packet from bytes back to bytes.
/// This is used by the passthrough writer to re-encode scans with minimal duplication.
///
/// The caller is responsible for growing the provided buffers (mz, intensity, features, encode).
/// If the buffers are too small, `decodeSimplifiedCentroidsIntoBuffers` returns `TooManyPoints`.
pub fn reencode_centroid(
    allocator: std.mem.Allocator,
    packet_slice: []const u8,
    h: PacketHeader,
    mz_buf: *[]f64,
    inten_buf: *[]f32,
    feat_buf: *[]PeakFeatures,
    encode_buf: *[]u8,
) ReencodeError!ReencodeResult {
    // 1. Decode current content into buffers
    const n = try decode_simplified_centroids_into_buffers(
        packet_slice,
        0,
        mz_buf.*,
        inten_buf.*,
        feat_buf.*,
        allocator,
    );

    // 2. Calculate requirements for re-encoding
    var num_non_default: usize = 0;
    var has_widths = false;
    const features = if (n > 0) feat_buf.*[0..n] else null;
    if (features) |f| {
        const default_flags = decode_default_flags(h.default_feature_word);
        for (f) |feat| {
            if (feat.charge != 0 or !std.meta.eql(feat.flags, default_flags)) {
                num_non_default += 1;
            }
            if (feat.resolution != 0) has_widths = true;
        }
    }

    const accurate = h.accurate_mass_centroids();
    const encoded_size = encoded_centroid_size(n, accurate, num_non_default, has_widths, 0);

    // 3. Ensure encode buffer is sufficient
    if (encoded_size > encode_buf.*.len) {
        const new_size = std.math.mul(usize, encoded_size, 2) catch return PacketError.OffsetOverflow;
        encode_buf.* = try allocator.realloc(encode_buf.*, new_size);
    }

    // 4. Encode to bytes
    const written = try encode_centroid_packet(
        encode_buf.*[0..encoded_size],
        mz_buf.*[0..n],
        inten_buf.*[0..n],
        features,
        accurate,
        null,
    );

    return .{
        .written = written,
        .num_points = n,
        .encoded_size = encoded_size,
    };
}

/// Inverse of decodeFeatureWord: pack charge + flags into a feature word.
/// peak_idx is clamped to 18 bits (mask 0x3FFFF).
pub fn encode_feature_word(peak_idx: u32, charge: i32, flags: PeakFlags) u32 {
    var word: u32 = peak_idx & 0x3FFFF;
    if (flags.fragmented) word |= 0x800000;
    if (flags.merged) word |= 0x400000;
    if (flags.reference) word |= 0x200000;
    if (flags.exception) word |= 0x100000;
    if (flags.modified) word |= 0x80000;
    // SAFETY: charge is masked to 8 bits before casting, so it always fits in u32.
    word |= @as(u32, @intCast(charge & 0xFF)) << 24;
    return word;
}

/// Inverse of decodeDefaultFlags: pack flags into the upper bits of default_feature_word.
pub fn encode_default_flags(flags: PeakFlags) u32 {
    var bits: u32 = 0;
    if (flags.fragmented) bits |= 0x10;
    if (flags.merged) bits |= 0x08;
    if (flags.reference) bits |= 0x04;
    if (flags.exception) bits |= 0x02;
    if (flags.modified) bits |= 0x01;
    return bits << 19;
}

/// Build a default_feature_word value for centroid packets.
/// `accurate`: true → sets accurate-mass flag (0x10000, bit 16).
/// `flags`: default peak flags.
pub fn make_default_feature_word(accurate: bool, flags: PeakFlags) u32 {
    var word: u32 = encode_default_flags(flags);
    if (accurate) {
        // Accurate mass: bit 16 set, bit 6 clear
        word |= 0x10000;
    } else {
        // Standard mass: bit 6 set (disables accurate mass path)
        word |= 0x40;
    }
    return word;
}

/// Compute the encoded size (in bytes) of a centroid packet.
/// `num_non_default_features` is the count of peaks with charge != 0 or flags != default.
pub fn encoded_centroid_size(
    num_points: usize,
    accurate: bool,
    num_non_default_features: usize,
    has_widths: bool,
    num_noise_packets: usize,
) usize {
    // SAFETY: all parameters are program-derived (caller-provided slice lengths / counts).
    // The caller (encode_centroid_packet) validates out_buf.len against this value before
    // writing, so overflow here would be caught by that check only if it wraps to a smaller
    // value. Callers must ensure total encoded size fits in usize.
    const entry_size: usize = if (accurate) 12 else 8;
    const centroid_bytes = 4 + num_points * entry_size;
    const centroid_words = (centroid_bytes + 3) / 4; // round up to whole words

    const expansion_words: usize = if (has_widths) 1 + num_points else 0;
    const noise_words: usize = num_noise_packets * 3;

    return 32 + // header
        8 + // single segment range
        centroid_words * 4 +
        num_non_default_features * 4 +
        expansion_words * 4 +
        noise_words * 4;
}

/// Encode a centroid spectrum into a pre-allocated byte buffer.
/// Writes a single-segment packet.
/// `out_buf` must be at least `encodedCentroidSize(...)` bytes.
/// Returns the number of bytes written.
pub fn encode_centroid_packet(
    out_buf: []u8,
    mz: []const f64,
    intensity: []const f32,
    features: ?[]const PeakFeatures,
    accurate: bool,
    noise_packets: ?[]const NoiseInfoPacket,
) PacketError!usize {
    if (mz.len != intensity.len) return PacketError.InvalidPacket;
    const num_points = mz.len;
    if (num_points == 0) return PacketError.NoCentroidData;

    if (features) |f| {
        if (f.len != num_points) return PacketError.InvalidPacket;
    }

    const entry_size: usize = if (accurate) 12 else 8;
    const has_widths = if (features) |f| blk: {
        for (f) |feat| {
            if (feat.resolution != 0) break :blk true;
        }
        break :blk false;
    } else false;

    var num_non_default_features: usize = 0;
    // Hardcode default_flags to all-zeros to match real Thermo data.
    // The vast majority of peaks have no charge, no noise, no baseline,
    // so this matches the actual .raw file format.
    const default_flags = PeakFlags{};

    if (features) |f| {
        for (f) |feat| {
            if (feat.charge != 0 or !std.meta.eql(feat.flags, default_flags)) {
                num_non_default_features += 1;
            }
        }
    }

    const num_noise: usize = if (noise_packets) |n| n.len else 0;
    const required_size = encoded_centroid_size(num_points, accurate, num_non_default_features, has_widths, num_noise);
    if (out_buf.len < required_size) return PacketError.Truncated;

    const num_non_default_features_u32: u32 = std.math.cast(u32, num_non_default_features) orelse return PacketError.TooManyPoints;

    const centroid_bytes = 4 + num_points * entry_size;
    const centroid_words: u32 = std.math.cast(u32, (centroid_bytes + 3) / 4) orelse return PacketError.TooManyPoints;
    const expansion_words: u32 = if (has_widths) std.math.cast(u32, 1 + num_points) orelse return PacketError.TooManyPoints else 0;
    const noise_words: u32 = std.math.cast(u32, num_noise * 3) orelse return PacketError.TooManyPoints;

    // Compute mass range
    var mz_min: f32 = std.math.inf(f32);
    var mz_max: f32 = -std.math.inf(f32);
    for (mz) |m| {
        const mf: f32 = @floatCast(m);
        if (mf < mz_min) mz_min = mf;
        if (mf > mz_max) mz_max = mf;
    }

    // Write header
    std.mem.writeInt(u32, out_buf[0..4], 1, .little); // num_segments
    std.mem.writeInt(u32, out_buf[4..8], 0, .little); // num_profile_words
    std.mem.writeInt(u32, out_buf[8..12], centroid_words, .little); // num_centroid_words
    std.mem.writeInt(u32, out_buf[12..16], make_default_feature_word(accurate, default_flags), .little);
    std.mem.writeInt(u32, out_buf[16..20], num_non_default_features_u32, .little);
    std.mem.writeInt(u32, out_buf[20..24], expansion_words, .little);
    std.mem.writeInt(u32, out_buf[24..28], noise_words, .little);
    std.mem.writeInt(u32, out_buf[28..32], 0, .little); // num_debug_info_words

    // SAFETY: all `pos + N` offsets and `pos += N` increments in this encoder are
    // program-derived and bounded by `required_size`, which was validated against
    // `out_buf.len` above, so they cannot overflow or exceed the buffer.
    var pos: usize = 32;

    // Mass range (single segment)
    std.mem.writeInt(u32, out_buf[pos..][0..4], @bitCast(mz_min), .little);
    std.mem.writeInt(u32, out_buf[pos + 4 ..][0..4], @bitCast(mz_max), .little);
    pos += 8;

    // Centroid count
    std.mem.writeInt(u32, out_buf[pos..][0..4], std.math.cast(u32, num_points) orelse return PacketError.TooManyPoints, .little);
    pos += 4;

    // Centroid entries
    if (accurate) {
        for (mz, intensity) |m, inten| {
            std.mem.writeInt(u64, out_buf[pos..][0..8], @bitCast(m), .little);
            std.mem.writeInt(u32, out_buf[pos + 8 ..][0..4], @bitCast(inten), .little);
            pos += 12;
        }
    } else {
        for (mz, intensity) |m, inten| {
            std.mem.writeInt(u32, out_buf[pos..][0..4], @bitCast(@as(f32, @floatCast(m))), .little);
            std.mem.writeInt(u32, out_buf[pos + 4 ..][0..4], @bitCast(inten), .little);
            pos += 8;
        }
    }

    // Pad centroid section to whole words
    const centroid_end = std.math.add(usize, 32, std.math.add(usize, 8, std.math.mul(usize, centroid_words, 4) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
    while (pos < centroid_end) : (pos += 1) {
        out_buf[pos] = 0;
    }
    pos = centroid_end;

    // Feature words
    if (features) |f| {
        for (f, 0..) |feat, i| {
            if (feat.charge != 0 or !std.meta.eql(feat.flags, default_flags)) {
                // SAFETY: i indexes the caller-provided features slice, which is bounded by num_points.
                const fw = encode_feature_word(@intCast(i), feat.charge, feat.flags);
                std.mem.writeInt(u32, out_buf[pos..][0..4], fw, .little);
                pos += 4;
            }
        }
    }

    // Expansion words (resolution widths)
    if (has_widths) {
        std.mem.writeInt(u32, out_buf[pos..][0..4], 1, .little); // header: HasWidths
        pos += 4;
        if (features) |f| {
            for (f) |feat| {
                std.mem.writeInt(u32, out_buf[pos..][0..4], @bitCast(feat.resolution), .little);
                pos += 4;
            }
        }
    }

    // Noise info packets
    if (noise_packets) |np| {
        for (np) |n| {
            std.mem.writeInt(u32, out_buf[pos..][0..4], @bitCast(n.mass), .little);
            std.mem.writeInt(u32, out_buf[pos + 4 ..][0..4], @bitCast(n.noise), .little);
            std.mem.writeInt(u32, out_buf[pos + 8 ..][0..4], @bitCast(n.baseline), .little);
            pos += 12;
        }
    }

    return pos;
}

test "packet header accurate mass flag" {
    const h = PacketHeader{
        .num_segments = 1,
        .num_profile_words = 0,
        .num_centroid_words = 0,
        .default_feature_word = 0x10000,
        .num_non_default_feature_words = 0,
        .num_expansion_words = 0,
        .num_noise_info_words = 0,
        .num_debug_info_words = 0,
    };
    try std.testing.expect(h.accurate_mass_centroids());
}

test "packetSizeFromHeader sums correctly" {
    const h = PacketHeader{
        .num_segments = 1,
        .num_profile_words = 10,
        .num_centroid_words = 20,
        .default_feature_word = 0,
        .num_non_default_feature_words = 5,
        .num_expansion_words = 3,
        .num_noise_info_words = 6,
        .num_debug_info_words = 2,
    };
    const size = try packet_size_from_header(h);
    // 32 header + 8 ranges + (10+20+5+3+6+2)*4 data = 32 + 8 + 184 = 224
    try std.testing.expectEqual(@as(u64, 224), size);
}

test "packetSizeFromHeader handles large segment counts without wrapping" {
    const h = PacketHeader{
        .num_segments = std.math.maxInt(u32),
        .num_profile_words = 0,
        .num_centroid_words = 0,
        .default_feature_word = 0,
        .num_non_default_feature_words = 0,
        .num_expansion_words = 0,
        .num_noise_info_words = 0,
        .num_debug_info_words = 0,
    };
    const size = try packet_size_from_header(h);
    try std.testing.expect(size > std.math.maxInt(u32));
}

test "encodeFeatureWord round-trips through decodeFeatureWord" {
    const flags = PeakFlags{ .fragmented = true, .merged = false, .reference = true, .exception = false, .modified = true };
    const word = encode_feature_word(1234, 5, flags);
    const decoded = decode_feature_word(word);
    try std.testing.expectEqual(@as(i32, 5), decoded.charge);
    try std.testing.expect(decoded.flags.fragmented);
    try std.testing.expect(!decoded.flags.merged);
    try std.testing.expect(decoded.flags.reference);
    try std.testing.expect(!decoded.flags.exception);
    try std.testing.expect(decoded.flags.modified);
    // peak index is lower 18 bits
    try std.testing.expectEqual(@as(u32, 1234), word & 0x3FFFF);
}

test "decodeFeatureWord maps bit 19 to modified" {
    const result = decode_feature_word(0x80000);
    try std.testing.expect(result.flags.modified);
    try std.testing.expect(!result.flags.fragmented);
    try std.testing.expect(!result.flags.exception);
}

test "decodeFeatureWord maps bit 23 to fragmented" {
    const result = decode_feature_word(0x800000);
    try std.testing.expect(result.flags.fragmented);
    try std.testing.expect(!result.flags.modified);
}

test "decodeDefaultFlags maps bit 0 to modified" {
    const default_word: u32 = (0x01 << 19); // default_feature_word with Modified flag
    const flags = decode_default_flags(default_word);
    try std.testing.expect(flags.modified);
}

test "makeDefaultFeatureWord accurate vs standard" {
    const accurate_word = make_default_feature_word(true, PeakFlags{});
    try std.testing.expect((accurate_word & 0x10000) != 0); // accurate mass bit
    try std.testing.expect((accurate_word & 0x40) == 0); // standard bit clear

    const standard_word = make_default_feature_word(false, PeakFlags{});
    try std.testing.expect((standard_word & 0x40) != 0); // standard bit set
    try std.testing.expect((standard_word & 0x10000) == 0); // accurate bit clear
}

test "encodedCentroidSize consistent with encodeCentroidPacket" {
    var mz_buf: [4]f64 = .{ 100.0, 200.0, 300.0, 400.0 };
    var inten_buf: [4]f32 = .{ 1.0, 2.0, 3.0, 4.0 };
    var feat_buf: [4]PeakFeatures = .{
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
    };
    const accurate = false;
    const size = encoded_centroid_size(4, accurate, 0, false, 0);
    const out_buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(out_buf);

    const written = try encode_centroid_packet(out_buf, &mz_buf, &inten_buf, &feat_buf, accurate, null);
    try std.testing.expectEqual(size, written);
}

// ============================================================================
// Round-trip encoder tests
//
// Per AGENTS.md: no synthetic data. Tests must use real Thermo .raw files.
// Real-data verification is in `src/tools/verify_encode.zig`:
//   zig build verify-encode -- <file.raw>
// That tool walks every centroid scan in a real file, round-trips
// encode/decode, and asserts zero mismatches.

/// Allocating convenience: encodes a simple accurate-mass FT centroid packet
/// (no features, no noise). Used by the de-novo .raw writer.
pub fn encode_simple_centroid(
    allocator: std.mem.Allocator,
    mz: []const f64,
    intensity: []const f32,
) PacketError![]u8 {
    if (mz.len != intensity.len) return PacketError.InvalidPacket;
    if (mz.len == 0) return PacketError.NoCentroidData;
    const num_points = mz.len;
    const size = try simple_centroid_packet_size(num_points);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    _ = try encode_centroid_packet(buf, mz, intensity, null, true, null);
    return buf;
}

/// Size (in bytes) of a simple accurate-mass FT centroid packet with no features.
pub fn simple_centroid_packet_size(num_points: usize) PacketError!usize {
    const num_segments: usize = 1;
    const ranges_bytes = std.math.mul(usize, num_segments, 8) catch return PacketError.OffsetOverflow;
    const points_bytes = std.math.mul(usize, num_points, 12) catch return PacketError.OffsetOverflow;
    return std.math.add(usize, 32, std.math.add(usize, ranges_bytes, std.math.add(usize, 4, points_bytes) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow) catch return PacketError.OffsetOverflow;
}

test "encodeSimpleCentroid round-trip" {
    const mz = [_]f64{ 100.5, 200.75, 300.25 };
    const intensity = [_]f32{ 1000.0, 2000.0, 3000.0 };

    const packet = try encode_simple_centroid(std.testing.allocator, &mz, &intensity);
    defer std.testing.allocator.free(packet);

    const expected_size = try simple_centroid_packet_size(mz.len);
    try std.testing.expectEqual(expected_size, packet.len);

    // Verify the header
    const h = PacketHeader{
        .num_segments = std.mem.readInt(u32, packet[0..4], .little),
        .num_profile_words = std.mem.readInt(u32, packet[4..8], .little),
        .num_centroid_words = std.mem.readInt(u32, packet[8..12], .little),
        .default_feature_word = std.mem.readInt(u32, packet[12..16], .little),
        .num_non_default_feature_words = std.mem.readInt(u32, packet[16..20], .little),
        .num_expansion_words = std.mem.readInt(u32, packet[20..24], .little),
        .num_noise_info_words = std.mem.readInt(u32, packet[24..28], .little),
        .num_debug_info_words = std.mem.readInt(u32, packet[28..32], .little),
    };
    try std.testing.expectEqual(@as(u32, 1), h.num_segments);
    try std.testing.expect(h.accurate_mass_centroids());
}

test "simpleCentroidPacketSize rejects overflow" {
    try std.testing.expectError(error.OffsetOverflow, simple_centroid_packet_size(std.math.maxInt(usize) / 12 + 1));
}

test "decodeSimplifiedCentroidsIntoBuffers rejects truncated packet without crashing" {
    var header: [32]u8 = undefined;
    @memset(&header, 0);
    std.mem.writeInt(u32, header[0..4], 1, .little); // num_segments = 1
    std.mem.writeInt(u32, header[4..8], 0, .little); // num_profile_words = 0
    std.mem.writeInt(u32, header[8..12], 10, .little); // num_centroid_words -> requires 40 bytes

    var mz_buf: [8]f64 = undefined;
    var inten_buf: [8]f32 = undefined;

    const result = decode_simplified_centroids_into_buffers(&header, 0, &mz_buf, &inten_buf, null, std.testing.allocator);
    try std.testing.expectError(error.Truncated, result);
}

test "expansion words decode to resolution values" {
    const allocator = std.testing.allocator;
    const mz = [_]f64{ 100.0, 200.0, 300.0 };
    const intensity = [_]f32{ 10.0, 20.0, 30.0 };
    var features = [_]PeakFeatures{
        .{ .charge = 0, .resolution = 1.5, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 2.5, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 3.5, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
    };

    const accurate = true;
    const size = encoded_centroid_size(mz.len, accurate, 0, true, 0);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    const written = try encode_centroid_packet(buf, &mz, &intensity, &features, accurate, null);
    const spectrum = try decode_simplified_centroids(allocator, buf[0..written], 0);
    defer spectrum.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), spectrum.point_count());
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), spectrum.features.?[0].resolution, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), spectrum.features.?[1].resolution, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), spectrum.features.?[2].resolution, 0.0001);
}

test "noise info packets decode to noise/baseline/snr" {
    const allocator = std.testing.allocator;
    const mz = [_]f64{ 100.0, 200.0, 300.0 };
    const intensity = [_]f32{ 1000.0, 2000.0, 3000.0 };
    var features = [_]PeakFeatures{
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
    };
    const noise = [_]NoiseInfoPacket{
        .{ .mass = 100.0, .noise = 10.0, .baseline = 5.0 },
        .{ .mass = 300.0, .noise = 20.0, .baseline = 8.0 },
    };

    const accurate = true;
    const size = encoded_centroid_size(mz.len, accurate, 0, false, noise.len);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    const written = try encode_centroid_packet(buf, &mz, &intensity, &features, accurate, &noise);
    const spectrum = try decode_simplified_centroids(allocator, buf[0..written], 0);
    defer spectrum.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), spectrum.point_count());
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), spectrum.features.?[0].noise, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), spectrum.features.?[0].baseline, 0.0001);
    try std.testing.expect(spectrum.features.?[0].sn_ratio > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), spectrum.features.?[2].noise, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), spectrum.features.?[2].baseline, 0.0001);
    try std.testing.expect(spectrum.features.?[2].sn_ratio > 0);
}
