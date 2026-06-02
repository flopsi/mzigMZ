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
pub fn decodeFtProfile(
    bytes: []const u8,
    calibrators: []const f64,
    mz_buf: []f64,
    intensity_buf: []f32,
    use_subsegment: bool,
) ProfileError!usize {
    return decodeFtProfileWithFreq(bytes, calibrators, null, mz_buf, intensity_buf, use_subsegment);
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
pub fn decodeFtProfileWithFreq(
    bytes: []const u8,
    calibrators: []const f64,
    freq_buf: ?[]f64,
    mz_buf: []f64,
    intensity_buf: []f32,
    use_subsegment: bool,
) ProfileError!usize {
    if (bytes.len < 32) return ProfileError.Truncated;

    // Read packet header
    const h = advanced.PacketHeader{
        .num_segments = std.mem.readInt(u32, bytes[0..4], .little),
        .num_profile_words = std.mem.readInt(u32, bytes[4..8], .little),
        .num_centroid_words = std.mem.readInt(u32, bytes[8..12], .little),
        .default_feature_word = std.mem.readInt(u32, bytes[12..16], .little),
        .num_non_default_feature_words = std.mem.readInt(u32, bytes[16..20], .little),
        .num_expansion_words = std.mem.readInt(u32, bytes[20..24], .little),
        .num_noise_info_words = std.mem.readInt(u32, bytes[24..28], .little),
        .num_debug_info_words = std.mem.readInt(u32, bytes[28..32], .little),
    };

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
    var pos: usize = 32 + @as(usize, h.num_segments) * 8;

    // Profile data blob starts here
    const profile_start = pos;
    const profile_end = profile_start + @as(usize, h.num_profile_words) * 4;
    if (profile_end > bytes.len) return ProfileError.Truncated;

    var out_index: usize = 0;
    var min_mass: f64 = -1.0;

    // Process each segment
    var seg: u32 = 0;
    while (seg < h.num_segments) : (seg += 1) {
        if (pos + 24 > profile_end) return ProfileError.Truncated;

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
            if (pos + 8 > profile_end) return ProfileError.Truncated;

            const start_idx = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            const word_count = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            pos += 8;

            var mass_offset: f32 = 0;
            if (use_subsegment) {
                if (pos + 4 > profile_end) return ProfileError.Truncated;
                mass_offset = @as(f32, @bitCast(std.mem.readInt(u32, bytes[pos..][0..4], .little)));
                pos += 4;
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
                            segment.base_abscissa, segment.abscissa_spacing, mass_offset,
                            current_index + z, coeff1, coeff2, coeff3, use_coeff3,
                            &min_mass, mz_buf, intensity_buf, freq_buf, &out_index,
                        );
                    }
                } else {
                    // Large gap: add first 4 and last 4 zeros only
                    var z: u32 = 0;
                    while (z < 4) : (z += 1) {
                        try addZeroPoint(
                            segment.base_abscissa, segment.abscissa_spacing, mass_offset,
                            current_index + z, coeff1, coeff2, coeff3, use_coeff3,
                            &min_mass, mz_buf, intensity_buf, freq_buf, &out_index,
                        );
                    }
                    z = start_idx - 4;
                    while (z < start_idx) : (z += 1) {
                        try addZeroPoint(
                            segment.base_abscissa, segment.abscissa_spacing, mass_offset,
                            z, coeff1, coeff2, coeff3, use_coeff3,
                            &min_mass, mz_buf, intensity_buf, freq_buf, &out_index,
                        );
                    }
                }
                current_index = start_idx;
            }

            // Read intensities
            if (pos + @as(usize, word_count) * 4 > profile_end) return ProfileError.Truncated;

            var w: u32 = 0;
            while (w < word_count) : (w += 1) {
                const idx = current_index + w;
                const freq = segment.base_abscissa + @as(f64, @floatFromInt(idx)) * segment.abscissa_spacing;
                const inten: f32 = @as(f32, @bitCast(std.mem.readInt(u32, bytes[pos + @as(usize, w) * 4 ..][0..4], .little)));

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
            pos += @as(usize, word_count) * 4;
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
                        segment.base_abscissa, segment.abscissa_spacing, last_mass_offset,
                        current_index + z, coeff1, coeff2, coeff3, use_coeff3,
                        &min_mass, mz_buf, intensity_buf, freq_buf, &out_index,
                    );
                }
            } else {
                // Large trailing gap: add last 4 zeros only (isAppending=true)
                const start_idx = num_expanded - 3;
                var z: u32 = start_idx;
                while (z <= num_expanded and out_index < mz_buf.len) : (z += 1) {
                    try addZeroPoint(
                        segment.base_abscissa, segment.abscissa_spacing, last_mass_offset,
                        z, coeff1, coeff2, coeff3, use_coeff3,
                        &min_mass, mz_buf, intensity_buf, freq_buf, &out_index,
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

// Build a synthetic FT Profile packet and verify decode produces correct m/z + intensity.
test "decodeFtProfile synthetic single segment" {
    // Calibrators: index 2 = coeff1, 3 = coeff2, 4 = coeff3
    const calibrators = [_]f64{ 0, 0, 10000.0, 0, 0 };

    // Build packet bytes
    var packet: [128]u8 = undefined;
    @memset(&packet, 0);

    // PacketHeader (32 bytes)
    std.mem.writeInt(u32, packet[0..4], 1, .little); // num_segments
    std.mem.writeInt(u32, packet[4..8], 13, .little); // num_profile_words (24+8+20)/4
    std.mem.writeInt(u32, packet[8..12], 0, .little); // num_centroid_words
    std.mem.writeInt(u32, packet[12..16], 0, .little); // default_feature_word (use_subsegment=false)
    std.mem.writeInt(u32, packet[16..20], 0, .little); // num_non_default_features
    std.mem.writeInt(u32, packet[20..24], 0, .little); // num_expansion_words
    std.mem.writeInt(u32, packet[24..28], 0, .little); // num_noise_info_words
    std.mem.writeInt(u32, packet[28..32], 0, .little); // num_debug_info_words

    // Mass range (8 bytes) - 2 x f32
    // low = 0, high = 0

    // ProfileSegmentStruct (24 bytes) at offset 40
    const seg_base: f64 = 101.0; // base_abscissa
    const seg_spacing: f64 = -1.0; // abscissa_spacing
    std.mem.writeInt(u64, packet[40..48], @bitCast(seg_base), .little);
    std.mem.writeInt(u64, packet[48..56], @bitCast(seg_spacing), .little);
    std.mem.writeInt(u32, packet[56..60], 1, .little); // num_subsegments
    std.mem.writeInt(u32, packet[60..64], 5, .little); // num_expanded_words

    // Subsegment header (8 bytes, no mass_offset since use_subsegment=false)
    std.mem.writeInt(u32, packet[64..68], 1, .little); // start_index
    std.mem.writeInt(u32, packet[68..72], 5, .little); // word_count

    // Intensities (5 x f32 = 20 bytes)
    const intensities = [_]f32{ 10.0, 20.0, 30.0, 40.0, 50.0 };
    for (intensities, 0..) |inten, i| {
        std.mem.writeInt(u32, packet[72 + i * 4 ..][0..4], @bitCast(inten), .little);
    }

    var mz_buf: [16]f64 = undefined;
    var int_buf: [16]f32 = undefined;

    const n = try decodeFtProfile(&packet, &calibrators, &mz_buf, &int_buf, false);

    // Should decode exactly 5 points (no zero padding needed)
    try std.testing.expectEqual(@as(usize, 5), n);

    // Verify intensities
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), int_buf[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), int_buf[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), int_buf[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), int_buf[3], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), int_buf[4], 0.001);

    // Verify masses: mass = 10000 / freq
    // freq = 101 + idx * (-1)
    // idx=1 -> freq=100 -> mass=100.0
    // idx=2 -> freq=99  -> mass=101.0101...
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), mz_buf[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 101.010101), mz_buf[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 102.040816), mz_buf[2], 0.001);

    // Verify monotonicity
    for (1..n) |i| {
        try std.testing.expect(mz_buf[i] > mz_buf[i - 1]);
    }
}

// Test zero-padding between subsegments.
test "decodeFtProfile with zero padding" {
    const calibrators = [_]f64{ 0, 0, 10000.0, 0, 0 };

    var packet: [128]u8 = undefined;
    @memset(&packet, 0);

    // Header
    std.mem.writeInt(u32, packet[0..4], 1, .little); // num_segments
    std.mem.writeInt(u32, packet[4..8], 14, .little); // num_profile_words (24+8+8+12)/4=13 -> 14 to be safe
    std.mem.writeInt(u32, packet[8..12], 0, .little);
    std.mem.writeInt(u32, packet[12..16], 0, .little);
    std.mem.writeInt(u32, packet[16..20], 0, .little);
    std.mem.writeInt(u32, packet[20..24], 0, .little);
    std.mem.writeInt(u32, packet[24..28], 0, .little);
    std.mem.writeInt(u32, packet[28..32], 0, .little);

    // ProfileSegmentStruct at offset 40
    std.mem.writeInt(u64, packet[40..48], @bitCast(@as(f64, 101.0)), .little);
    std.mem.writeInt(u64, packet[48..56], @bitCast(@as(f64, -1.0)), .little);
    std.mem.writeInt(u32, packet[56..60], 2, .little); // 2 subsegments
    std.mem.writeInt(u32, packet[60..64], 5, .little); // num_expanded_words = 5

    // Subsegment 1: start=1, count=2 (indices 1, 2)
    std.mem.writeInt(u32, packet[64..68], 1, .little);
    std.mem.writeInt(u32, packet[68..72], 2, .little);
    std.mem.writeInt(u32, packet[72..76], @bitCast(@as(f32, 10.0)), .little);
    std.mem.writeInt(u32, packet[76..80], @bitCast(@as(f32, 20.0)), .little);

    // Subsegment 2: start=4, count=1 (index 4)
    // gap at index 3 should be zero-padded (gap=1, small)
    std.mem.writeInt(u32, packet[80..84], 4, .little);
    std.mem.writeInt(u32, packet[84..88], 1, .little);
    std.mem.writeInt(u32, packet[88..92], @bitCast(@as(f32, 40.0)), .little);

    var mz_buf: [16]f64 = undefined;
    var int_buf: [16]f32 = undefined;

    const n = try decodeFtProfile(&packet, &calibrators, &mz_buf, &int_buf, false);

    // Points: idx=1(data), idx=2(data), idx=3(zero), idx=4(data), idx=5(trailing zero)
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), int_buf[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), int_buf[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), int_buf[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), int_buf[3], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), int_buf[4], 0.001);

    for (1..n) |i| {
        try std.testing.expect(mz_buf[i] > mz_buf[i - 1]);
    }
}

// Test large-gap sparse zero-padding (matching C# behavior).
test "decodeFtProfile with large gap sparse padding" {
    const calibrators = [_]f64{ 0, 0, 10000.0, 0, 0 };

    var packet: [256]u8 = undefined;
    @memset(&packet, 0);

    // Header
    std.mem.writeInt(u32, packet[0..4], 1, .little);
    std.mem.writeInt(u32, packet[4..8], 30, .little); // enough words
    std.mem.writeInt(u32, packet[8..12], 0, .little);
    std.mem.writeInt(u32, packet[12..16], 0, .little);
    std.mem.writeInt(u32, packet[16..20], 0, .little);
    std.mem.writeInt(u32, packet[20..24], 0, .little);
    std.mem.writeInt(u32, packet[24..28], 0, .little);
    std.mem.writeInt(u32, packet[28..32], 0, .little);

    // ProfileSegmentStruct at offset 40
    std.mem.writeInt(u64, packet[40..48], @bitCast(@as(f64, 101.0)), .little);
    std.mem.writeInt(u64, packet[48..56], @bitCast(@as(f64, -1.0)), .little);
    std.mem.writeInt(u32, packet[56..60], 2, .little); // 2 subsegments
    std.mem.writeInt(u32, packet[60..64], 20, .little); // num_expanded_words = 20

    // Subsegment 1: start=1, count=2
    std.mem.writeInt(u32, packet[64..68], 1, .little);
    std.mem.writeInt(u32, packet[68..72], 2, .little);
    std.mem.writeInt(u32, packet[72..76], @bitCast(@as(f32, 10.0)), .little);
    std.mem.writeInt(u32, packet[76..80], @bitCast(@as(f32, 20.0)), .little);

    // Subsegment 2: start=15, count=1 (large gap: 15 - 3 = 12)
    // C# should add first 4 zeros (indices 3,4,5,6) and last 4 zeros (11,12,13,14)
    std.mem.writeInt(u32, packet[80..84], 15, .little);
    std.mem.writeInt(u32, packet[84..88], 1, .little);
    std.mem.writeInt(u32, packet[88..92], @bitCast(@as(f32, 40.0)), .little);

    var mz_buf: [32]f64 = undefined;
    var int_buf: [32]f32 = undefined;

    const n = try decodeFtProfile(&packet, &calibrators, &mz_buf, &int_buf, false);

    // Expected: 2 data + 8 gap zeros + 1 data + 6 trailing zeros (gap=20-16+1=5, small)
    // = 2 + 8 + 1 + 5 = 16
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), int_buf[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), int_buf[1], 0.001);
    // 8 zeros
    for (2..10) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), int_buf[i], 0.001);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), int_buf[10], 0.001);
    // 5 trailing zeros
    for (11..16) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), int_buf[i], 0.001);
    }

    for (1..n) |i| {
        try std.testing.expect(mz_buf[i] > mz_buf[i - 1]);
    }
}

// Test large trailing gap (isAppending=true adds only last 4 zeros).
test "decodeFtProfile with large trailing gap" {
    const calibrators = [_]f64{ 0, 0, 10000.0, 0, 0 };

    var packet: [256]u8 = undefined;
    @memset(&packet, 0);

    // Header
    std.mem.writeInt(u32, packet[0..4], 1, .little);
    std.mem.writeInt(u32, packet[4..8], 20, .little);
    std.mem.writeInt(u32, packet[8..12], 0, .little);
    std.mem.writeInt(u32, packet[12..16], 0, .little);
    std.mem.writeInt(u32, packet[16..20], 0, .little);
    std.mem.writeInt(u32, packet[20..24], 0, .little);
    std.mem.writeInt(u32, packet[24..28], 0, .little);
    std.mem.writeInt(u32, packet[28..32], 0, .little);

    // ProfileSegmentStruct at offset 40
    std.mem.writeInt(u64, packet[40..48], @bitCast(@as(f64, 101.0)), .little);
    std.mem.writeInt(u64, packet[48..56], @bitCast(@as(f64, -1.0)), .little);
    std.mem.writeInt(u32, packet[56..60], 1, .little);
    std.mem.writeInt(u32, packet[60..64], 20, .little); // num_expanded_words = 20

    // Subsegment: start=1, count=2
    std.mem.writeInt(u32, packet[64..68], 1, .little);
    std.mem.writeInt(u32, packet[68..72], 2, .little);
    std.mem.writeInt(u32, packet[72..76], @bitCast(@as(f32, 10.0)), .little);
    std.mem.writeInt(u32, packet[76..80], @bitCast(@as(f32, 20.0)), .little);

    var mz_buf: [32]f64 = undefined;
    var int_buf: [32]f32 = undefined;

    const n = try decodeFtProfile(&packet, &calibrators, &mz_buf, &int_buf, false);

    // Expected: 2 data + 4 trailing zeros (large gap: 20 - 3 + 1 = 18 > 8)
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), int_buf[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), int_buf[1], 0.001);
    // 4 trailing zeros at indices 18, 19, 20, 21? No, indices 17, 18, 19, 20
    for (2..6) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), int_buf[i], 0.001);
    }

    for (1..n) |i| {
        try std.testing.expect(mz_buf[i] > mz_buf[i - 1]);
    }
}
