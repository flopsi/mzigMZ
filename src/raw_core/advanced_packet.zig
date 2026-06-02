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

    pub fn accurateMassCentroids(self: PacketHeader) bool {
        return (self.default_feature_word & 0x40) == 0 and
            (self.default_feature_word & 0x10000) != 0;
    }
};

pub const MassRange = struct {
    low: f32,
    high: f32,
};

/// Per-peak feature metadata decoded from centroid packet feature words.
/// Per-peak flags decoded from non-default feature words.
pub const PeakFlags = packed struct(u8) {
    fragmented: bool = false,  // bit 0
    merged: bool = false,      // bit 1
    reference: bool = false,   // bit 2
    exception: bool = false,   // bit 3
    saturated: bool = false,   // bit 4 (or fragmented, depending on default word)
    _reserved: u3 = 0,
};

/// Per-peak feature metadata decoded from centroid packet.
/// Sources:
/// - charge, flags: from packet's non-default feature words section
/// - resolution: from expansion words (widths) section
/// - noise, baseline, sn_ratio: interpolated from noise info packets
pub const PeakFeatures = struct {
    charge: i32,        // 0 = unknown; from feature word bits 24-31
    resolution: f32,    // FWHM resolution; from expansion words (0 = not available)
    noise: f32,         // interpolated noise level (0 = not available)
    baseline: f32,      // interpolated baseline level (0 = not available)
    sn_ratio: f32,      // signal-to-noise = (intensity - baseline) / (noise - baseline)
    monoisotopic: bool, // not available from packet
    flags: PeakFlags,   // peak option flags from feature words
};

/// Decode a single non-default feature word.
/// Format from Thermo C#:
/// - bits 0-17 (mask 0x3FFFF): peak index within the segment
/// - bit 19 (0x80000): Saturated (or Fragmented depending on context)
/// - bit 20 (0x100000): Exception
/// - bit 21 (0x200000): Reference
/// - bit 22 (0x400000): Merged
/// - bit 23 (0x800000): Fragmented
/// - bits 24-31: charge state
pub fn decodeFeatureWord(feature_word: u32) struct { charge: i32, flags: PeakFlags } {
    const charge: i32 = @intCast((feature_word >> 24) & 0xFF);
    var flags: PeakFlags = .{};
    // Note: flag bit meanings depend on the default_feature_word context.
    // The C# code uses _isExpand* flags to control which bits are active.
    // For simplified decoding, we map the common flag positions:
    if ((feature_word & 0x800000) != 0) flags.fragmented = true;  // bit 23
    if ((feature_word & 0x400000) != 0) flags.merged = true;      // bit 22
    if ((feature_word & 0x200000) != 0) flags.reference = true;   // bit 21
    if ((feature_word & 0x100000) != 0) flags.exception = true;   // bit 20
    if ((feature_word & 0x80000) != 0) flags.saturated = true;    // bit 19
    return .{ .charge = charge, .flags = flags };
}

/// Extract default flags from the default_feature_word header field.
/// The C# code maps (defaultFlags & 0xF80000) >> 19 to a lookup table.
/// For simplified use, we extract the same flag bits.
pub fn decodeDefaultFlags(default_feature_word: u32) PeakFlags {
    var flags: PeakFlags = .{};
    const flag_bits = (default_feature_word >> 19) & 0x1F;
    if ((flag_bits & 0x10) != 0) flags.fragmented = true;
    if ((flag_bits & 0x08) != 0) flags.merged = true;
    if ((flag_bits & 0x04) != 0) flags.reference = true;
    if ((flag_bits & 0x02) != 0) flags.exception = true;
    if ((flag_bits & 0x01) != 0) flags.saturated = true;
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
pub fn readNoiseInfoPackets(
    bytes: []const u8,
    data_offset: u64,
    noise_buf: []NoiseInfoPacket,
) PacketError!usize {
    const h = try readHeader(bytes, data_offset);

    if (h.num_noise_info_words == 0) return 0;

    // Calculate offset to noise section
    var pos = data_offset + 32; // header
    pos += @as(u64, h.num_segments) * 8; // ranges
    pos += @as(u64, h.num_profile_words) * 4; // profile
    pos += @as(u64, h.num_centroid_words) * 4; // centroid
    pos += @as(u64, h.num_non_default_feature_words) * 4; // features
    pos += @as(u64, h.num_expansion_words) * 4; // expansion

    const packet_size = packetSizeFromHeader(h);
    const noise_end = data_offset + packet_size;
    const max_bytes = noise_end - pos;
    const max_packets = @min(
        h.num_noise_info_words * 4 / @sizeOf(NoiseInfoPacket),
        @as(u32, @intCast(max_bytes / @sizeOf(NoiseInfoPacket))),
    );
    if (max_packets > noise_buf.len) return PacketError.TooManyPoints;

    var i: u32 = 0;
    while (i < max_packets) : (i += 1) {
        const offset = pos + @as(u64, i) * @sizeOf(NoiseInfoPacket);
        noise_buf[i] = .{
            .mass = readF32Direct(bytes, @intCast(offset)),
            .noise = readF32Direct(bytes, @intCast(offset + 4)),
            .baseline = readF32Direct(bytes, @intCast(offset + 8)),
        };
    }
    return max_packets;
}

/// Read resolution widths from expansion words section.
/// The expansion section starts after features, before noise.
/// First word is a header/int (checked for > 0 to indicate HasWidths), remaining words are f32 widths.
pub fn readResolutionWidths(
    bytes: []const u8,
    data_offset: u64,
    widths_buf: []f32,
) PacketError!usize {
    const h = try readHeader(bytes, data_offset);

    if (h.num_expansion_words <= 1) return 0; // need at least header + 1 width

    var pos = data_offset + 32;
    pos += @as(u64, h.num_segments) * 8;
    pos += @as(u64, h.num_profile_words) * 4;
    pos += @as(u64, h.num_centroid_words) * 4;
    pos += @as(u64, h.num_non_default_feature_words) * 4;

    // First expansion word is a header (int) — C# checks if > 0 for HasWidths
    const header_val = std.mem.readInt(u32, bytes[@intCast(pos)..][0..4], .little);
    if (header_val == 0) return 0; // no widths

    const num_widths = h.num_expansion_words - 1;
    if (num_widths > widths_buf.len) return PacketError.TooManyPoints;

    var i: u32 = 0;
    while (i < num_widths) : (i += 1) {
        widths_buf[i] = readF32Direct(bytes, @intCast(pos + 4 + @as(u64, i) * 4));
    }
    return num_widths;
}

/// Interpolate noise and baseline for each peak from sparse noise packets.
/// Modifies features array in-place: sets noise, baseline, and sn_ratio.
/// SNR formula from C#: (intensity - baseline) / (noise - baseline), floored at 0.
pub fn interpolateNoiseBaseline(
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

pub const Spectrum = struct {
    mz: []f64,
    intensity: []f32,
    ranges: []MassRange,
    features: ?[]PeakFeatures,  // null if not decoded
    mz_min: f64,
    mz_max: f64,
    intensity_max: f32,

    pub fn deinit(self: Spectrum, allocator: std.mem.Allocator) void {
        allocator.free(self.mz);
        allocator.free(self.intensity);
        allocator.free(self.ranges);
        if (self.features) |f| allocator.free(f);
    }

    pub fn pointCount(self: Spectrum) usize {
        return self.mz.len;
    }

    pub fn mzMin(self: Spectrum) f64 {
        return self.mz_min;
    }

    pub fn mzMax(self: Spectrum) f64 {
        return self.mz_max;
    }

    pub fn intensityMax(self: Spectrum) f32 {
        return self.intensity_max;
    }
};

pub fn readHeader(bytes: []const u8, offset: u64) PacketError!PacketHeader {
    return .{
        .num_segments = try readU32(bytes, offset + 0),
        .num_profile_words = try readU32(bytes, offset + 4),
        .num_centroid_words = try readU32(bytes, offset + 8),
        .default_feature_word = try readU32(bytes, offset + 12),
        .num_non_default_feature_words = try readU32(bytes, offset + 16),
        .num_expansion_words = try readU32(bytes, offset + 20),
        .num_noise_info_words = try readU32(bytes, offset + 24),
        .num_debug_info_words = try readU32(bytes, offset + 28),
    };
}

pub fn packetSize(bytes: []const u8, offset: u64) PacketError!u64 {
    const h = try readHeader(bytes, offset);
    return packetSizeFromHeader(h);
}

pub fn packetSizeFromHeader(h: PacketHeader) u64 {
    const word_sum =
        @as(u64, h.num_profile_words) +
        @as(u64, h.num_centroid_words) +
        @as(u64, h.num_non_default_feature_words) +
        @as(u64, h.num_expansion_words) +
        @as(u64, h.num_noise_info_words) +
        @as(u64, h.num_debug_info_words);
    return 32 + @as(u64, h.num_segments) * 8 + word_sum * 4;
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

pub fn decodeSimplifiedCentroidsIntoBuffers(
    bytes: []const u8,
    data_offset: u64,
    mz_buf: []f64,
    intensity_buf: []f32,
    features_buf: ?[]PeakFeatures,
) PacketError!usize {
    const h = try readHeader(bytes, data_offset);

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

    var pos = data_offset + 32;
    pos += @as(u64, h.num_segments) * 8; // skip ranges
    pos += @as(u64, h.num_profile_words) * 4; // skip profile

    const centroid_start = pos;
    const accurate = h.accurateMassCentroids();
    const entry_size: u64 = if (accurate) 12 else 8;

    // Feature words are in a separate section after centroid data.
    // Calculate where the feature words section starts.
    const feature_words_start = centroid_start + @as(u64, h.num_centroid_words) * 4;
    const has_features = h.num_non_default_feature_words > 0;
    const default_flags = decodeDefaultFlags(h.default_feature_word);

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
        segment_offsets_ptr[seg] = @intCast(count_pos + 4 - centroid_start);
        count_pos += 4 + @as(u64, count) * entry_size;
        total_points += count;
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
    const required_input_size = data_offset + packetSizeFromHeader(h);
    const buf_len: u64 = @intCast(bytes.len);
    if (required_input_size > buf_len) {
        @branchHint(.unlikely);
        return PacketError.Truncated;
    }

    // Hot decode path: disable runtime safety for raw speed.
    @setRuntimeSafety(false);

    var out_index: usize = 0;
    seg = 0;
    while (seg < h.num_segments) : (seg += 1) {
        const count = segment_counts_ptr[seg];
        var read_pos = centroid_start + segment_offsets_ptr[seg];

        var i: u32 = 0;
        if (accurate) {
            // Accurate mass: 12-byte entries (f64 mz + f32 intensity)
            // Process 4 entries at a time using SIMD loads where possible
            const simd_count = count - (count % 4);
            while (i < simd_count) : (i += 4) {
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
                const o: usize = @intCast(read_pos);
                mz_buf[out_index] = @floatCast(readF32Direct(bytes, o));
                intensity_buf[out_index] = readF32Direct(bytes, o + 4);
                read_pos += 8;
                out_index += 1;
            }
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
                const fw = readU32Direct(bytes, @intCast(fw_pos));
                const peak_idx = fw & 0x3FFFF;
                if (peak_idx < total) {
                    const decoded = decodeFeatureWord(fw);
                    fb[peak_idx].charge = decoded.charge;
                    fb[peak_idx].flags = decoded.flags;
                }
                fw_pos += 4;
            }
        }
    }

    return out_index;
}

/// Original allocator-based decoder (for GUI use where spectrum persists).
pub fn decodeSimplifiedCentroids(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    data_offset: u64,
) PacketError!Spectrum {
    const h = try readHeader(bytes, data_offset);

    if (h.num_segments == 0) return PacketError.InvalidPacket;
    if (h.num_centroid_words == 0) return PacketError.NoCentroidData;
    if (h.num_segments > 4096) return PacketError.InvalidPacket;

    var pos = data_offset + 32;
    pos += @as(u64, h.num_segments) * 8;
    pos += @as(u64, h.num_profile_words) * 4;

    const centroid_start = pos;
    const accurate = h.accurateMassCentroids();
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
        segment_offsets_ptr[seg] = @intCast(count_pos + 4 - centroid_start);
        count_pos += 4 + @as(u64, count) * entry_size;
        total_points += count;
        if (total_points > 50_000_000) return PacketError.TooManyPoints;
    }

    const mz = allocator.alloc(f64, @intCast(total_points)) catch return PacketError.OutOfMemory;
    errdefer allocator.free(mz);
    const intensity = allocator.alloc(f32, @intCast(total_points)) catch return PacketError.OutOfMemory;
    errdefer allocator.free(intensity);
    const features = allocator.alloc(PeakFeatures, @intCast(total_points)) catch return PacketError.OutOfMemory;
    errdefer allocator.free(features);

    // Feature words section starts after centroid data.
    const feature_words_start = centroid_start + @as(u64, h.num_centroid_words) * 4;
    const has_features = h.num_non_default_feature_words > 0;
    const default_flags = decodeDefaultFlags(h.default_feature_word);

    var out_index: usize = 0;
    var mz_min: f64 = std.math.inf(f64);
    var mz_max: f64 = -std.math.inf(f64);
    var intensity_max: f32 = 0;
    seg = 0;
    while (seg < h.num_segments) : (seg += 1) {
        const count = segment_counts_ptr[seg];
        var read_pos = centroid_start + segment_offsets_ptr[seg];

        var i: u32 = 0;
        if (accurate) {
            while (i < count) : (i += 1) {
                const m = try readF64(bytes, read_pos);
                const inten = try readF32(bytes, read_pos + 8);
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
                read_pos += 12;
                out_index += 1;
            }
        } else {
            while (i < count) : (i += 1) {
                const m: f64 = @floatCast(try readF32(bytes, read_pos));
                const inten = try readF32(bytes, read_pos + 4);
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
                read_pos += 8;
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
            const fw = readU32Direct(bytes, @intCast(fw_pos));
            const peak_idx = fw & 0x3FFFF;
            if (peak_idx < out_index) {
                const decoded = decodeFeatureWord(fw);
                features[peak_idx].charge = decoded.charge;
                features[peak_idx].flags = decoded.flags;
            }
            fw_pos += 4;
        }
    }

    if (total_points == 0) {
        mz_min = 0;
        mz_max = 1;
        intensity_max = 1;
    }

    const ranges: []MassRange = &[_]MassRange{};

    return .{
        .mz = mz,
        .intensity = intensity,
        .ranges = ranges,
        .features = features,
        .mz_min = mz_min,
        .mz_max = mz_max,
        .intensity_max = intensity_max,
    };
}

fn readU32(bytes: []const u8, offset: u64) PacketError!u32 {
    const end = std.math.add(u64, offset, 4) catch return PacketError.OffsetOverflow;
    if (end > bytes.len) return PacketError.Truncated;
    return std.mem.readInt(u32, bytes[@intCast(offset)..][0..4], .little);
}

fn readF32(bytes: []const u8, offset: u64) PacketError!f32 {
    const end = std.math.add(u64, offset, 4) catch return PacketError.OffsetOverflow;
    if (end > bytes.len) return PacketError.Truncated;
    return @bitCast(std.mem.readInt(u32, bytes[@intCast(offset)..][0..4], .little));
}

fn readF64(bytes: []const u8, offset: u64) PacketError!f64 {
    const end = std.math.add(u64, offset, 8) catch return PacketError.OffsetOverflow;
    if (end > bytes.len) return PacketError.Truncated;
    return @bitCast(std.mem.readInt(u64, bytes[@intCast(offset)..][0..8], .little));
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
    try std.testing.expect(h.accurateMassCentroids());
}
