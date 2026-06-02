/// Golden file validation test suite.
const std = @import("std");
const advanced = @import("advanced_packet");

// ============================================================================
// Test: PacketHeader accurate mass flag detection
// ============================================================================
test "packet header accurate mass flag" {
    const h = advanced.PacketHeader{
        .num_segments = 1,
        .num_profile_words = 0,
        .num_centroid_words = 10,
        .default_feature_word = 0x10000,
        .num_non_default_feature_words = 0,
        .num_expansion_words = 0,
        .num_noise_info_words = 0,
        .num_debug_info_words = 0,
    };
    try std.testing.expect(h.accurateMassCentroids() == true);
}

// ============================================================================
// Test: Feature word decoding
// ============================================================================
test "decodeFeatureWord" {
    // Feature word: peak_idx=5, charge=3, flags=fragmented|merged
    // bits 0-17: peak index = 5
    // bit 23 (0x800000): fragmented = true
    // bit 22 (0x400000): merged = true
    // bits 24-31: charge = 3
    const word: u32 = 5 | (1 << 23) | (1 << 22) | (3 << 24);
    const decoded = advanced.decodeFeatureWord(word);

    try std.testing.expectEqual(@as(i32, 3), decoded.charge);
    try std.testing.expect(decoded.flags.fragmented);
    try std.testing.expect(decoded.flags.merged);
    try std.testing.expect(!decoded.flags.reference);
    try std.testing.expect(!decoded.flags.exception);
}

test "decodeDefaultFlags" {
    // Default feature word with flag bits set in upper nibble
    // (defaultFlags & 0xF80000) >> 19 maps to flag bits
    const word: u32 = (0x1F << 19); // all flag bits set
    const flags = advanced.decodeDefaultFlags(word);

    try std.testing.expect(flags.fragmented);
    try std.testing.expect(flags.merged);
    try std.testing.expect(flags.reference);
    try std.testing.expect(flags.exception);
    try std.testing.expect(flags.saturated);
}

// ============================================================================
// Test: Noise/baseline interpolation
// ============================================================================
test "interpolateNoiseBaseline" {
    // Two noise packets: mass=100 (noise=10, baseline=5), mass=200 (noise=20, baseline=8)
    // Peaks at mass=100, 150, 200
    const noise_packets = [_]advanced.NoiseInfoPacket{
        .{ .mass = 100.0, .noise = 10.0, .baseline = 5.0 },
        .{ .mass = 200.0, .noise = 20.0, .baseline = 8.0 },
    };

    var mz = [_]f64{ 100.0, 150.0, 200.0 };
    var intensity = [_]f32{ 100.0, 150.0, 200.0 };
    var features = [_]advanced.PeakFeatures{
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
    };

    advanced.interpolateNoiseBaseline(&mz, &intensity, &features, &noise_packets);

    // Peak at mass=100: exact match with first noise packet
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), features[0].noise, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), features[0].baseline, 0.001);
    // SNR = (100 - 5) / (10 - 5) = 95 / 5 = 19
    try std.testing.expectApproxEqAbs(@as(f32, 19.0), features[0].sn_ratio, 0.001);

    // Peak at mass=150: interpolated halfway
    // noise = 10 + (20-10) * (150-100)/(200-100) = 10 + 5 = 15
    // baseline = 5 + (8-5) * 0.5 = 5 + 1.5 = 6.5
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), features[1].noise, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.5), features[1].baseline, 0.001);
    // SNR = (150 - 6.5) / (15 - 6.5) = 143.5 / 8.5 = 16.88
    try std.testing.expectApproxEqAbs(@as(f32, 16.882), features[1].sn_ratio, 0.01);

    // Peak at mass=200: exact match with second noise packet
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), features[2].noise, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), features[2].baseline, 0.001);
    // SNR = (200 - 8) / (20 - 8) = 192 / 12 = 16
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), features[2].sn_ratio, 0.001);
}

test "interpolateNoiseBaseline before first packet" {
    // Peak before first noise packet gets first packet's values
    const noise_packets = [_]advanced.NoiseInfoPacket{
        .{ .mass = 200.0, .noise = 20.0, .baseline = 8.0 },
    };

    var mz = [_]f64{ 100.0 };
    var intensity = [_]f32{ 50.0 };
    var features = [_]advanced.PeakFeatures{
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
    };

    advanced.interpolateNoiseBaseline(&mz, &intensity, &features, &noise_packets);

    try std.testing.expectApproxEqAbs(@as(f32, 20.0), features[0].noise, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), features[0].baseline, 0.001);
}

test "interpolateNoiseBaseline after last packet" {
    // Peak after last noise packet gets last packet's values
    const noise_packets = [_]advanced.NoiseInfoPacket{
        .{ .mass = 100.0, .noise = 10.0, .baseline = 5.0 },
    };

    var mz = [_]f64{ 200.0 };
    var intensity = [_]f32{ 50.0 };
    var features = [_]advanced.PeakFeatures{
        .{ .charge = 0, .resolution = 0, .noise = 0, .baseline = 0, .sn_ratio = 0, .monoisotopic = false, .flags = .{} },
    };

    advanced.interpolateNoiseBaseline(&mz, &intensity, &features, &noise_packets);

    try std.testing.expectApproxEqAbs(@as(f32, 10.0), features[0].noise, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), features[0].baseline, 0.001);
}
