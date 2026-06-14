/// FT Profile packet decoder for Thermo RAW files.
///
/// FT Profile packets (type 21) store frequency-domain data, not masses.
/// Masses are computed at read time using calibration coefficients:
///   mass = coeff1/freq + coeff2/(freq^2) + coeff3/(freq^4) + massOffset
///
/// Based on C# FtProfilePacket.cs from ThermoFisher.CommonCore.RawFileReader.
const std = @import("std");
const advanced = @import("advanced_packet");

pub const ProfileError = error{
    Truncated,
    OffsetOverflow,
    InvalidProfile,
    TooManyPoints,
    OutOfMemory,
};

/// Profile segment struct (24 bytes)
/// C#: ProfileSegmentStruct
pub const ProfileSegment = struct {
    base_abscissa: f64, // Start frequency
    abscissa_spacing: f64, // Frequency step between samples
    num_subsegments: u32,
    num_expanded_words: u32, // Total expected data points (including zeros)
};

/// Decode FT Profile packet into caller-provided buffers.
/// Returns number of (m/z, intensity) points decoded.
///
/// Parameters:
///   - bytes: packet data starting at packet header
///   - calibrators: mass calibration coefficients (from ScanEvent.mass_calibrators)
///     Index mapping: calibrators[2]=coeff1, calibrators[3]=coeff2, calibrators[4]=coeff3
///   - mz_buf: output m/z buffer (must be large enough)
///   - intensity_buf: output intensity buffer
///   - use_subsegment: from header flag (defaultFeatureWord)
pub fn decode_ft_profile(
    bytes: []const u8,
    calibrators: []const f64,
    mz_buf: []f64,
    intensity_buf: []f32,
    use_subsegment: bool,
) ProfileError!usize {
    return decode_ft_profile_with_freq(bytes, calibrators, null, mz_buf, intensity_buf, use_subsegment);
}

/// Decode FT Profile packet into caller-provided buffers, optionally also returning raw frequencies.
/// Returns number of (freq, m/z, intensity) points decoded.
///
/// Parameters:
///   - bytes: packet data starting at packet header
///   - calibrators: mass calibration coefficients (from ScanEvent.mass_calibrators)
///   - freq_buf: optional output frequency buffer (null if not needed)
///   - mz_buf: output m/z buffer (must be large enough)
///   - intensity_buf: output intensity buffer
///   - use_subsegment: from header flag (defaultFeatureWord)
pub fn decode_ft_profile_with_freq(
    bytes: []const u8,
    calibrators: []const f64,
    freq_buf: ?[]f64,
    mz_buf: []f64,
    intensity_buf: []f32,
    use_subsegment: bool,
) ProfileError!usize {
    if (bytes.len < 32) return ProfileError.Truncated;

    // Read packet header
    const h = advanced.read_header(bytes, 0) catch return ProfileError.Truncated;

    if (h.num_profile_words == 0) {
        return 0; // No profile data
    }

    // Extract calibration coefficients
    // C#: FtProfilePacket constructor uses indices 2, 3, 4 only.
    // Index 0 is NOT added as a base mass offset.
    var coeff1: f64 = 0;
    var coeff2: f64 = 0;
    var coeff3: f64 = 0;
    if (calibrators.len >= 5) {
        coeff1 = calibrators[2];
        coeff2 = calibrators[3];
        coeff3 = calibrators[4];
    } else if (calibrators.len >= 4) {
        coeff1 = calibrators[2];
        coeff2 = calibrators[3];
    }

    // Choose mass conversion delegate based on coeff3
    const use_coeff3 = @abs(coeff3) >= 1e-15;

    // Skip header (32 bytes) + mass ranges (8 bytes per segment: 2 x f32)
    const seg_bytes = std.math.mul(usize, @as(usize, h.num_segments), 8) catch return ProfileError.OffsetOverflow;
    var pos = std.math.add(usize, 32, seg_bytes) catch return ProfileError.OffsetOverflow;

    // Profile data blob starts here
    const profile_start = pos;
    const profile_words_bytes = std.math.mul(usize, @as(usize, h.num_profile_words), 4) catch return ProfileError.OffsetOverflow;
    const profile_end = std.math.add(usize, profile_start, profile_words_bytes) catch return ProfileError.OffsetOverflow;
    if (profile_end > bytes.len) return ProfileError.Truncated;

    var out_index: usize = 0;
    var min_mass: f64 = -1.0;

    // Process each segment
    var seg: u32 = 0;
    while (seg < h.num_segments) : (seg += 1) {
        const segment_end = std.math.add(usize, pos, 24) catch return ProfileError.OffsetOverflow;
        if (segment_end > profile_end) return ProfileError.Truncated;

        // Read ProfileSegmentStruct (24 bytes)
        const segment = ProfileSegment{
            .base_abscissa = @as(f64, @bitCast(std.mem.readInt(u64, bytes[pos..][0..8], .little))),
            .abscissa_spacing = @as(f64, @bitCast(std.mem.readInt(u64, bytes[pos + 8 ..][0..8], .little))),
            .num_subsegments = std.mem.readInt(u32, bytes[pos + 16 ..][0..4], .little),
            .num_expanded_words = std.mem.readInt(u32, bytes[pos + 20 ..][0..4], .little),
        };
        pos += 24;

        const num_expanded = segment.num_expanded_words;
        if (num_expanded == 0) continue;

        // Process subsegments (headers and data are interleaved)
        var current_index: u32 = 1; // 1-based packet index
        var last_mass_offset: f32 = 0;
        var subseg: u32 = 0;
        while (subseg < segment.num_subsegments) : (subseg += 1) {
            const subseg_header_end = std.math.add(usize, pos, 8) catch return ProfileError.OffsetOverflow;
            if (subseg_header_end > profile_end) return ProfileError.Truncated;

            const start_idx = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            const word_count = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            pos = std.math.add(usize, pos, 8) catch return ProfileError.OffsetOverflow;

            var mass_offset: f32 = 0;
            if (use_subsegment) {
                const mass_offset_end = std.math.add(usize, pos, 4) catch return ProfileError.OffsetOverflow;
                if (mass_offset_end > profile_end) return ProfileError.Truncated;
                mass_offset = @as(f32, @bitCast(std.mem.readInt(u32, bytes[pos..][0..4], .little)));
                pos = std.math.add(usize, pos, 4) catch return ProfileError.OffsetOverflow;
            }
            last_mass_offset = mass_offset;

            if (word_count == 0) continue;

            // Handle overlap: if start_idx < current_index, backtrack
            if (start_idx < current_index) {
                if (out_index > 0) {
                    out_index -= 1;
                    current_index = start_idx;
                }
            } else if (start_idx > current_index) {
                // Add sparse zero-padded points (matching C# behavior)
                const gap = start_idx - current_index;
                if (gap <= 8) {
                    // Small gap: add all zeros
                    var z: u32 = 0;
                    while (z < gap) : (z += 1) {
                        try addZeroPoint(
                            segment.base_abscissa,
                            segment.abscissa_spacing,
                            mass_offset,
                            current_index + z,
                            coeff1,
                            coeff2,
                            coeff3,
                            use_coeff3,
                            &min_mass,
                            mz_buf,
                            intensity_buf,
                            freq_buf,
                            &out_index,
                        );
                    }
                } else {
                    // Large gap: add first 4 and last 4 zeros only
                    var z: u32 = 0;
                    while (z < 4) : (z += 1) {
                        try addZeroPoint(
                            segment.base_abscissa,
                            segment.abscissa_spacing,
                            mass_offset,
                            current_index + z,
                            coeff1,
                            coeff2,
                            coeff3,
                            use_coeff3,
                            &min_mass,
                            mz_buf,
                            intensity_buf,
                            freq_buf,
                            &out_index,
                        );
                    }
                    z = if (start_idx >= 4) start_idx - 4 else 0;
                    while (z < start_idx) : (z += 1) {
                        try addZeroPoint(
                            segment.base_abscissa,
                            segment.abscissa_spacing,
                            mass_offset,
                            z,
                            coeff1,
                            coeff2,
                            coeff3,
                            use_coeff3,
                            &min_mass,
                            mz_buf,
                            intensity_buf,
                            freq_buf,
                            &out_index,
                        );
                    }
                }
                current_index = start_idx;
            }

            // Read intensities
            const word_bytes = std.math.mul(usize, @as(usize, word_count), 4) catch return ProfileError.OffsetOverflow;
            const intensity_data_end = std.math.add(usize, pos, word_bytes) catch return ProfileError.OffsetOverflow;
            if (intensity_data_end > profile_end) return ProfileError.Truncated;

            var w: u32 = 0;
            while (w < word_count) : (w += 1) {
                const idx = current_index + w; // program-derived: bounded by validated word_count
                const freq = segment.base_abscissa + @as(f64, @floatFromInt(idx)) * segment.abscissa_spacing;
                const inten_offset = std.math.add(usize, pos, std.math.mul(usize, @as(usize, w), 4) catch return ProfileError.OffsetOverflow) catch return ProfileError.OffsetOverflow;
                const inten: f32 = @as(f32, @bitCast(std.mem.readInt(u32, bytes[inten_offset..][0..4], .little)));

                const mass = if (use_coeff3)
                    calculateMass(coeff1, coeff2, coeff3, mass_offset, freq)
                else
                    calculateMassWithoutCoeff3(coeff1, coeff2, mass_offset, freq);

                const final_mass = if (mass <= min_mass) blk: {
                    min_mass = increaseMass(min_mass);
                    break :blk min_mass;
                } else mass;

                if (out_index >= mz_buf.len or out_index >= intensity_buf.len) return ProfileError.TooManyPoints;
                if (freq_buf) |fb| {
                    if (out_index >= fb.len) return ProfileError.TooManyPoints;
                    fb[out_index] = freq;
                }
                mz_buf[out_index] = final_mass;
                intensity_buf[out_index] = inten;
                out_index += 1;
            }

            // Advance pos past intensity data for this subsegment
            pos = std.math.add(usize, pos, word_bytes) catch return ProfileError.OffsetOverflow;
            current_index += word_count;

            // Update min_mass from last point
            if (out_index > 0) {
                min_mass = mz_buf[out_index - 1];
            }
        }

        // Pad with trailing zeros (isAppending=true behavior)
        if (current_index <= num_expanded) {
            const trailing_gap = num_expanded - current_index + 1;
            if (trailing_gap <= 8) {
                // Small trailing gap: add all zeros
                var z: u32 = 0;
                while (z < trailing_gap and out_index < mz_buf.len) : (z += 1) {
                    try addZeroPoint(
                        segment.base_abscissa,
                        segment.abscissa_spacing,
                        last_mass_offset,
                        current_index + z,
                        coeff1,
                        coeff2,
                        coeff3,
                        use_coeff3,
                        &min_mass,
                        mz_buf,
                        intensity_buf,
                        freq_buf,
                        &out_index,
                    );
                }
            } else {
                // Large trailing gap: C# AddZeroPackets(isAppending=true) emits
                // the first 4 zeros and the last 4 zeros.
                var z: u32 = 0;
                while (z < 4 and out_index < mz_buf.len) : (z += 1) {
                    try addZeroPoint(
                        segment.base_abscissa,
                        segment.abscissa_spacing,
                        last_mass_offset,
                        current_index + z,
                        coeff1,
                        coeff2,
                        coeff3,
                        use_coeff3,
                        &min_mass,
                        mz_buf,
                        intensity_buf,
                        freq_buf,
                        &out_index,
                    );
                }
                const start_idx = num_expanded - 3;
                z = start_idx;
                while (z <= num_expanded and out_index < mz_buf.len) : (z += 1) {
                    try addZeroPoint(
                        segment.base_abscissa,
                        segment.abscissa_spacing,
                        last_mass_offset,
                        z,
                        coeff1,
                        coeff2,
                        coeff3,
                        use_coeff3,
                        &min_mass,
                        mz_buf,
                        intensity_buf,
                        freq_buf,
                        &out_index,
                    );
                }
            }
        }
    }

    return out_index;
}

/// Add a single zero-intensity point with monotonicity correction.
fn addZeroPoint(
    base_abscissa: f64,
    spacing: f64,
    mass_offset: f32,
    idx: u32,
    coeff1: f64,
    coeff2: f64,
    coeff3: f64,
    use_coeff3: bool,
    min_mass: *f64,
    mz_buf: []f64,
    intensity_buf: []f32,
    freq_buf: ?[]f64,
    out_index: *usize,
) ProfileError!void {
    const freq = base_abscissa + @as(f64, @floatFromInt(idx)) * spacing;
    const mass = if (use_coeff3)
        calculateMass(coeff1, coeff2, coeff3, mass_offset, freq)
    else
        calculateMassWithoutCoeff3(coeff1, coeff2, mass_offset, freq);

    const final_mass = if (mass <= min_mass.*) blk: {
        min_mass.* = increaseMass(min_mass.*);
        break :blk min_mass.*;
    } else mass;

    if (out_index.* >= mz_buf.len or out_index.* >= intensity_buf.len) return ProfileError.TooManyPoints;
    if (freq_buf) |fb| {
        if (out_index.* >= fb.len) return ProfileError.TooManyPoints;
        fb[out_index.*] = freq;
    }
    mz_buf[out_index.*] = final_mass;
    intensity_buf[out_index.*] = 0;
    out_index.* += 1;
}

/// Calculate mass from frequency using 3 coefficients.
/// C#: CalculateMass(float massOffset, double freq)
/// Formula: mass = coeff1/freq + coeff2/(freq^2) + coeff3/(freq^4) + massOffset
inline fn calculateMass(coeff1: f64, coeff2: f64, coeff3: f64, mass_offset: f32, freq: f64) f64 {
    const num = freq * freq;
    return coeff1 / freq + coeff2 / num + coeff3 / (num * num) + @as(f64, mass_offset);
}

/// Calculate mass from frequency using 2 coefficients (when coeff3 ≈ 0).
/// C#: CalculateMassWithoutCoeff3(float massOffset, double freq)
/// Formula: mass = (coeff1 + coeff2/freq) / freq + massOffset
inline fn calculateMassWithoutCoeff3(coeff1: f64, coeff2: f64, mass_offset: f32, freq: f64) f64 {
    return (coeff1 + coeff2 / freq) / freq + @as(f64, mass_offset);
}

/// Ensure mass increases monotonically.
/// C#: IncreaseMass(double minMass)
inline fn increaseMass(min_mass: f64) f64 {
    return min_mass + 1e-5;
}

// ============================================================================
// Profile Packet Encoder
// ============================================================================

/// Compute encoded size (in bytes) of a single-segment FT Profile packet.
/// The encoder always produces a single segment with a single subsegment.
/// `num_points` is the number of (frequency, intensity) pairs.
pub fn encoded_profile_size(
    num_points: usize,
    num_centroid_words: u32,
    num_non_default_feature_words: u32,
    num_expansion_words: u32,
    num_noise_words: u32,
) ProfileError!usize {
    const profile_words: u32 = if (num_points == 0)
        0
    else
        std.math.cast(u32, 8 + num_points) orelse return ProfileError.TooManyPoints;
    return 32 + // header
        8 + // mass range (single segment)
        @as(usize, profile_words) * 4 +
        @as(usize, num_centroid_words) * 4 +
        @as(usize, num_non_default_feature_words) * 4 +
        @as(usize, num_expansion_words) * 4 +
        @as(usize, num_noise_words) * 4;
}

/// Encode a profile spectrum into a pre-allocated byte buffer.
/// Writes a single-segment, single-subsegment packet.
/// `out_buf` must be at least `encodedProfileSize(...)` bytes.
/// `centroid_data`, `expansion_data`, `noise_data` are optional raw byte slices
/// copied verbatim from the original packet (for passthrough with embedded data).
pub fn encode_ft_profile(
    out_buf: []u8,
    freq: []const f64,
    intensity: []const f32,
    mass_range_low: f32,
    mass_range_high: f32,
    centroid_data: ?[]const u8,
    expansion_data: ?[]const u8,
    noise_data: ?[]const u8,
) ProfileError!usize {
    if (freq.len != intensity.len) return ProfileError.InvalidProfile;
    const num_points = freq.len;

    // SAFETY: optional passthrough slices are caller-controlled, so their word counts are program-derived.
    const num_centroid_words: u32 = @intCast(if (centroid_data) |d| (d.len + 3) / 4 else 0);
    // SAFETY: optional passthrough slices are caller-controlled, so their word counts are program-derived.
    const num_expansion_words: u32 = @intCast(if (expansion_data) |d| (d.len + 3) / 4 else 0);
    // SAFETY: optional passthrough slices are caller-controlled, so their word counts are program-derived.
    const num_noise_words: u32 = @intCast(if (noise_data) |d| (d.len + 3) / 4 else 0);

    const profile_words: u32 = if (num_points == 0)
        0
    else
        std.math.cast(u32, 8 + num_points) orelse return ProfileError.TooManyPoints;
    const required_size = try encoded_profile_size(num_points, num_centroid_words, 0, num_expansion_words, num_noise_words);
    if (out_buf.len < required_size) return ProfileError.Truncated;

    // Derive base_abscissa and abscissa_spacing from freq array.
    // Decoder uses 1-based indexing: freq[i] = base + (i + 1) * spacing
    //  => spacing = freq[1] - freq[0]
    //  => base    = freq[0] - spacing
    const spacing: f64 = if (num_points >= 2) freq[1] - freq[0] else 0.0;
    const base: f64 = if (num_points >= 1) freq[0] - spacing else 0.0;

    // Write header
    std.mem.writeInt(u32, out_buf[0..4], if (num_points == 0) 0 else 1, .little); // num_segments
    std.mem.writeInt(u32, out_buf[4..8], profile_words, .little); // num_profile_words
    std.mem.writeInt(u32, out_buf[8..12], num_centroid_words, .little); // num_centroid_words
    std.mem.writeInt(u32, out_buf[12..16], 0x40, .little); // default_feature_word (std mass, no subsegment)
    std.mem.writeInt(u32, out_buf[16..20], 0, .little); // num_non_default_features
    std.mem.writeInt(u32, out_buf[20..24], num_expansion_words, .little);
    std.mem.writeInt(u32, out_buf[24..28], num_noise_words, .little);
    std.mem.writeInt(u32, out_buf[28..32], 0, .little); // num_debug_info_words

    // SAFETY: all `pos + N` offsets and `pos += N` increments in this encoder are
    // program-derived and bounded by `required_size`, which was validated against
    // `out_buf.len` above, so they cannot overflow or exceed the buffer.
    var pos: usize = 32;

    // Mass range
    std.mem.writeInt(u32, out_buf[pos..][0..4], @bitCast(mass_range_low), .little);
    std.mem.writeInt(u32, out_buf[pos + 4 ..][0..4], @bitCast(mass_range_high), .little);
    pos += 8;

    if (num_points > 0) {
        // ProfileSegmentStruct (24 bytes)
        std.mem.writeInt(u64, out_buf[pos..][0..8], @bitCast(base), .little);
        std.mem.writeInt(u64, out_buf[pos + 8 ..][0..8], @bitCast(spacing), .little);
        std.mem.writeInt(u32, out_buf[pos + 16 ..][0..4], 1, .little); // num_subsegments
        // SAFETY: num_points equals freq.len, a caller-provided slice; it was already validated to fit in the computed required_size.
        std.mem.writeInt(u32, out_buf[pos + 20 ..][0..4], @intCast(num_points), .little);
        pos += 24;

        // Subsegment header (8 bytes)
        std.mem.writeInt(u32, out_buf[pos..][0..4], 1, .little); // start_idx
        // SAFETY: num_points equals freq.len, a caller-provided slice; it was already validated to fit in the computed required_size.
        std.mem.writeInt(u32, out_buf[pos + 4 ..][0..4], @intCast(num_points), .little);
        pos += 8;

        // Intensities
        for (intensity) |inten| {
            std.mem.writeInt(u32, out_buf[pos..][0..4], @bitCast(inten), .little);
            pos += 4;
        }
    }

    // Centroid data (verbatim)
    if (centroid_data) |d| {
        @memcpy(out_buf[pos..][0..d.len], d);
        pos += d.len;
        const pad = (4 - (d.len % 4)) % 4;
        for (0..pad) |i| out_buf[pos + i] = 0;
        pos += pad;
    }

    // Expansion data (verbatim)
    if (expansion_data) |d| {
        @memcpy(out_buf[pos..][0..d.len], d);
        pos += d.len;
        const pad = (4 - (d.len % 4)) % 4;
        for (0..pad) |i| out_buf[pos + i] = 0;
        pos += pad;
    }

    // Noise data (verbatim)
    if (noise_data) |d| {
        @memcpy(out_buf[pos..][0..d.len], d);
        pos += d.len;
        const pad = (4 - (d.len % 4)) % 4;
        for (0..pad) |i| out_buf[pos + i] = 0;
        pos += pad;
    }

    return pos;
}

// ============================================================================
// Tests
// ============================================================================

test "calculateMass with 3 coefficients" {
    const mass = calculateMass(1.0, 2.0, 3.0, 0.5, 10.0);
    // freq=10, num=100
    // mass = 1/10 + 2/100 + 3/10000 + 0.5 = 0.1 + 0.02 + 0.0003 + 0.5 = 0.6203
    try std.testing.expectApproxEqAbs(0.6203, mass, 0.0001);
}

test "calculateMassWithoutCoeff3" {
    const mass = calculateMassWithoutCoeff3(1.0, 2.0, 0.5, 10.0);
    // mass = (1 + 2/10) / 10 + 0.5 = (1.2) / 10 + 0.5 = 0.12 + 0.5 = 0.62
    try std.testing.expectApproxEqAbs(0.62, mass, 0.0001);
}

test "increaseMass" {
    try std.testing.expectApproxEqAbs(1.00001, increaseMass(1.0), 1e-10);
    try std.testing.expectApproxEqAbs(-0.99999, increaseMass(-1.0), 1e-10);
}

test "encodedProfileSize consistent with encodeFtProfile" {
    const freq = [_]f64{ 1000.0, 1001.0, 1002.0 };
    const intensity = [_]f32{ 1.0, 2.0, 3.0 };
    const size = try encoded_profile_size(3, 0, 0, 0, 0);
    const out_buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(out_buf);

    const written = try encode_ft_profile(out_buf, &freq, &intensity, 500.0, 1500.0, null, null, null);
    try std.testing.expectEqual(size, written);
}

test "encodeFtProfile produces valid header" {
    const freq = [_]f64{ 1000.0, 1001.0 };
    const intensity = [_]f32{ 10.0, 20.0 };
    const size = try encoded_profile_size(2, 0, 0, 0, 0);
    const out_buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(out_buf);

    _ = try encode_ft_profile(out_buf, &freq, &intensity, 500.0, 1500.0, null, null, null);

    // Verify header fields
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out_buf[0..4], .little)); // num_segments
    const profile_words = std.mem.readInt(u32, out_buf[4..8], .little);
    try std.testing.expect(profile_words > 0); // has profile data
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out_buf[8..12], .little)); // num_centroid_words
    try std.testing.expectEqual(@as(u32, 0x40), std.mem.readInt(u32, out_buf[12..16], .little)); // default_feature_word
}

test "ProfileError includes OffsetOverflow" {
    try std.testing.expectError(error.OffsetOverflow, @as(ProfileError!void, error.OffsetOverflow));
}

test "encodedProfileSize rejects profile word overflow" {
    try std.testing.expectError(error.TooManyPoints, encoded_profile_size(@as(usize, std.math.maxInt(u32)) + 1, 0, 0, 0, 0));
}

// Profile packet decoder/encoder unit tests.
//
// Per AGENTS.md: no synthetic data. Tests must use real Thermo .raw files.
// Real-data verification is in `src/tools/verify_profile.zig`:
//   zig build verify-profile -- <file.raw>
// That tool walks every FT_PROFILE scan in a real file, round-trips
// encode/decode, and asserts zero mismatches.
