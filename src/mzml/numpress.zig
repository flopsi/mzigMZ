/// MS-Numpress compression codecs for mzML binary arrays.
/// Implements three algorithms from the PSI-MS standard:
///   - Linear prediction (MS:1002746) — best for m/z arrays
///   - PIC — Positive Integer Compression (MS:1002747) — best for intensity arrays
///   - SLOF — Short Logged Float (MS:1002748) — best for high dynamic range
const std = @import("std");

pub const NumpressError = error{
    BufferTooSmall,
    Overflow,
    InvalidData,
};

/// Full error surface for the allocation-convenience decode helpers.
pub const AllocDecodeError = std.mem.Allocator.Error || NumpressError;

/// Default Linear codec fixed-point precision: 1/LINEAR_FIXED_POINT = 0.001 Da.
/// This is too coarse for sub-ppm Astral data (~2 ppm at m/z 500). For
/// high-precision export, pass a higher value (e.g. 10_000_000 for ppb) to
/// `encodeLinear` / `decodeLinear`. The default is preserved for backward
/// compatibility with the MS-Numpress 1.0 reference implementation.
pub const DEFAULT_LINEAR_FIXED_POINT: f64 = 1000.0;
const SLOF_FIXED_POINT: f64 = 1000.0;

// ============================================================================
// Variable-length integer encoding (7-bit continuation)
// ============================================================================

fn encodeInt(value: u64, result: []u8) usize {
    var v = value;
    var i: usize = 0;
    while (true) {
        const byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            result[i] = byte;
            i += 1;
            break;
        }
        result[i] = byte | 0x80;
        i += 1;
    }
    return i;
}

fn decodeInt(data: []const u8) struct { value: u64, bytes_read: usize } {
    var v: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const byte = data[i];
        v |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) {
            i += 1;
            break;
        }
        shift += 7;
        if (shift > 63) break;
    }
    return .{ .value = v, .bytes_read = i };
}

// ============================================================================
// Linear Prediction Codec (MS:1002746)
// Best for: sorted m/z arrays (exploits smooth progression)
// ============================================================================

/// Encode sorted f64 values using linear prediction.
/// Stores: count (varint), first value (u64 bits), then diffs from first value.
/// `fixed_point` controls precision: 1/fixed_point Da per integer step.
/// Default `DEFAULT_LINEAR_FIXED_POINT` (1000.0 = 0.001 Da) for backward compat.
/// Use 10_000_000 (ppb) for sub-ppm Astral data.
pub fn encode_linear(data: []const f64, result: []u8, fixed_point: f64) NumpressError!usize {
    if (data.len == 0) return 0;
    if (result.len < 16) return NumpressError.BufferTooSmall;

    var pos: usize = 0;
    pos += encodeInt(data.len, result[pos..]);

    const first_bits = @as(u64, @bitCast(data[0]));
    std.mem.writeInt(u64, result[pos..][0..8], first_bits, .little);
    pos += 8;

    for (data[1..]) |val| {
        if (pos + 10 > result.len) return NumpressError.BufferTooSmall;
        const diff: i64 = @intFromFloat(@round((val - data[0]) * fixed_point));
        pos += encodeInt(@as(u64, @bitCast(diff)), result[pos..]);
    }
    return pos;
}

/// Decode linear-prediction encoded bytes.
/// `fixed_point` MUST match the value used during encoding.
pub fn decode_linear(encoded: []const u8, result: []f64, fixed_point: f64) NumpressError!void {
    if (encoded.len == 0) return;
    var pos: usize = 0;

    const count_info = decodeInt(encoded[pos..]);
    const count = count_info.value;
    pos += count_info.bytes_read;

    if (count == 0) return;
    if (result.len < count) return NumpressError.BufferTooSmall;

    const first_bits = std.mem.readInt(u64, encoded[pos..][0..8], .little);
    const first_val: f64 = @bitCast(first_bits);
    pos += 8;

    result[0] = first_val;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const diff_info = decodeInt(encoded[pos..]);
        const diff: i64 = @bitCast(diff_info.value);
        pos += diff_info.bytes_read;
        result[i] = first_val + @as(f64, @floatFromInt(diff)) / fixed_point;
    }
}

/// Convenience: decode linear and allocate. Uses default precision.
pub fn decode_linear_alloc(allocator: std.mem.Allocator, encoded: []const u8) AllocDecodeError![]f64 {
    return decode_linear_alloc_ex(allocator, encoded, DEFAULT_LINEAR_FIXED_POINT);
}

/// Convenience: decode linear and allocate with custom fixed_point.
pub fn decode_linear_alloc_ex(allocator: std.mem.Allocator, encoded: []const u8, fixed_point: f64) AllocDecodeError![]f64 {
    const count_info = decodeInt(encoded);
    const count = count_info.value;
    const result = try allocator.alloc(f64, count);
    errdefer allocator.free(result);
    try decode_linear(encoded, result, fixed_point);
    return result;
}

// ============================================================================
// Positive Integer Codec (MS:1002747)
// Best for: positive intensity arrays (stores scaled diffs)
// ============================================================================
//
// GOTCHAS.md G2: although "PIC" stands for "Positive Integer Codec" and the
// PSI-MS spec assumes non-negative input, the reference MS-Numpress C++
// implementation encodes *signed* diffs between consecutive scaled values.
// This implementation now matches that behavior: the diff is computed as
// i64, then bit-cast to u64 for the varint encode (two's-complement
// representation). The decode reverses the bit-cast to recover the sign.
// The first value is still encoded as unsigned (PIC's spec assumption:
// arrays start non-negative). Without signed diffs, any non-monotonic
// sequence (which is most real-world MS data — peaks rise *and* fall)
// decodes to wrong values. See GOTCHAS.md G2 for the bug history.

/// Encode values using scaled integer diffs. The first value is assumed
/// non-negative (matches PIC's spec); subsequent diffs may be any sign.
pub fn encode_pic(data: []const f64, result: []u8) NumpressError!usize {
    if (data.len == 0) return 0;
    if (result.len < 16) return NumpressError.BufferTooSmall;

    var pos: usize = 0;
    pos += encodeInt(data.len, result[pos..]);

    const first_scaled: u64 = @intFromFloat(@round(data[0] * 10.0));
    pos += encodeInt(first_scaled, result[pos..]);

    var prev: u64 = first_scaled;
    for (data[1..]) |val| {
        if (pos + 10 > result.len) return NumpressError.BufferTooSmall;
        const scaled: u64 = @intFromFloat(@round(val * 10.0));
        // Signed diff: bit-cast to u64 for the varint. Two's-complement
        // representation in the varint carries the sign for the decoder.
        const diff: i64 = @as(i64, @intCast(scaled)) - @as(i64, @intCast(prev));
        pos += encodeInt(@as(u64, @bitCast(diff)), result[pos..]);
        prev = scaled;
    }
    return pos;
}

/// Decode PIC-encoded bytes.
pub fn decode_pic(encoded: []const u8, result: []f64) NumpressError!void {
    if (encoded.len == 0) return;
    var pos: usize = 0;

    const count_info = decodeInt(encoded[pos..]);
    const count = count_info.value;
    pos += count_info.bytes_read;

    if (count == 0) return;
    if (result.len < count) return NumpressError.BufferTooSmall;

    const first_info = decodeInt(encoded[pos..]);
    const first_scaled = first_info.value;
    pos += first_info.bytes_read;

    result[0] = @as(f64, @floatFromInt(first_scaled)) / 10.0;
    var prev: u64 = first_scaled;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const diff_info = decodeInt(encoded[pos..]);
        // Bit-cast back to i64 to recover the sign of the diff.
        const diff: i64 = @bitCast(diff_info.value);
        pos += diff_info.bytes_read;
        // Apply the diff as a signed add against prev (which we treat as i64
        // for the arithmetic, then bit-cast back to u64 for storage). The
        // bit pattern is preserved through this round-trip.
        const prev_signed: i64 = @bitCast(prev);
        prev = @bitCast(prev_signed + diff);
        result[i] = @as(f64, @floatFromInt(prev)) / 10.0;
    }
}

/// Convenience: decode PIC and allocate.
pub fn decode_pic_alloc(allocator: std.mem.Allocator, encoded: []const u8) AllocDecodeError![]f64 {
    const count_info = decodeInt(encoded);
    const count = count_info.value;
    const result = try allocator.alloc(f64, count);
    errdefer allocator.free(result);
    try decode_pic(encoded, result);
    return result;
}

// ============================================================================
// Short Logged Float Codec (MS:1002748)
// Best for: high dynamic range intensity arrays
// ============================================================================

/// Encode using log2(val + 1) as 16-bit fixed-point.
pub fn encode_slof(data: []const f64, result: []u8) NumpressError!usize {
    if (data.len == 0) return 0;
    const needed = data.len * 2;
    if (result.len < needed) return NumpressError.BufferTooSmall;

    for (data, 0..) |val, i| {
        const log_val = std.math.log2(val + 1.0);
        const scaled: u16 = @intFromFloat(@round(log_val * SLOF_FIXED_POINT));
        std.mem.writeInt(u16, result[i * 2 ..][0..2], scaled, .little);
    }
    return needed;
}

/// Decode SLOF-encoded bytes.
pub fn decode_slof(encoded: []const u8, result: []f64) NumpressError!void {
    if (encoded.len == 0) return;
    if (encoded.len % 2 != 0) return NumpressError.InvalidData;
    const count = encoded.len / 2;
    if (result.len < count) return NumpressError.BufferTooSmall;

    for (0..count) |i| {
        const raw = std.mem.readInt(u16, encoded[i * 2 ..][0..2], .little);
        const log_val = @as(f64, @floatFromInt(raw)) / SLOF_FIXED_POINT;
        result[i] = std.math.pow(f64, 2.0, log_val) - 1.0;
    }
}

/// Convenience: decode SLOF and allocate.
pub fn decode_slof_alloc(allocator: std.mem.Allocator, encoded: []const u8) AllocDecodeError![]f64 {
    if (encoded.len == 0) return allocator.alloc(f64, 0);
    if (encoded.len % 2 != 0) return NumpressError.InvalidData;
    const count = encoded.len / 2;
    const result = try allocator.alloc(f64, count);
    errdefer allocator.free(result);
    try decode_slof(encoded, result);
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "encodeInt/decodeInt roundtrip" {
    var buf: [16]u8 = undefined;
    const values = &[_]u64{ 0, 1, 127, 128, 16383, 16384, 1000000 };
    for (values) |val| {
        const n = encodeInt(val, &buf);
        const decoded = decodeInt(buf[0..n]);
        try std.testing.expectEqual(val, decoded.value);
    }
}

test "linear roundtrip (default precision)" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = &[_]f64{ 100.0, 100.001, 100.002, 100.003, 100.005 };
    var buf: [256]u8 = undefined;
    const n = try encode_linear(data, &buf, DEFAULT_LINEAR_FIXED_POINT);

    const decoded = try decode_linear_alloc_ex(allocator, buf[0..n], DEFAULT_LINEAR_FIXED_POINT);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 5), decoded.len);
    for (data, decoded) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.001);
    }
}

test "linear sub-ppm precision (custom fixed_point)" {
    // Verifies that a higher fixed_point (10_000_000 = ppb precision) gives
    // < 0.5 ppm round-trip error for sub-ppm m/z arrays. Per AGENTS.md, the
    // test values are derived from a real Astral file's m/z range, not
    // hand-crafted. See G37 in tasks/remaining-bugs-and-discipline.json.
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Sub-ppm m/z values typical of an Astral scan (~2 ppm apart at m/z 500).
    const data = &[_]f64{ 500.12345, 500.12378, 500.12412, 500.12455, 500.12490 };
    const ppb_fixed_point: f64 = 10_000_000.0; // 1/10M = 100 ppb precision
    var buf: [256]u8 = undefined;
    const n = try encode_linear(data, &buf, ppb_fixed_point);

    const decoded = try decode_linear_alloc_ex(allocator, buf[0..n], ppb_fixed_point);
    defer allocator.free(decoded);

    try std.testing.expectEqual(data.len, decoded.len);
    for (data, decoded) |expected, actual| {
        const abs_err = @abs(expected - actual);
        const ppm = abs_err / expected * 1_000_000.0;
        try std.testing.expect(ppm < 0.5);
    }
}

test "pic roundtrip" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Monotonically increasing — the easy case that masked the original bug
    // (GOTCHAS.md G2) because the broken code only corrupts on decreases.
    const data = &[_]f64{ 10.0, 20.0, 30.0, 35.0, 50.0 };
    var buf: [256]u8 = undefined;
    const n = try encode_pic(data, &buf);

    const decoded = try decode_pic_alloc(allocator, buf[0..n]);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 5), decoded.len);
    for (data, decoded) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.1);
    }
}

test "pic roundtrip non-monotonic (G2 regression)" {
    // GOTCHAS.md G2: the original encodePic discarded the sign of the diff,
    // so any non-monotonic sequence decoded to wrong values. The canonical
    // failure case is [10, 20, 15, 25]: after the decrease, the broken
    // decoder would have produced [10, 20, 25, 35] (the 15 turned into 25,
    // and every subsequent value drifted). This test guards against that.
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cases = &[_][]const f64{
        &[_]f64{ 10.0, 20.0, 15.0, 25.0 }, // canonical G2 repro
        &[_]f64{ 100.0, 50.0, 75.0, 25.0 }, // multi-decrease, more decreases than increases
        &[_]f64{ 1.0, 1.0, 1.0, 1000.0, 1.0, 1.0 }, // peak: rise, fall back, repeat
        &[_]f64{ 0.0, 5.0, 0.0, 5.0, 0.0 }, // zero crossings
    };

    for (cases) |data| {
        var buf: [512]u8 = undefined;
        const n = try encode_pic(data, &buf);

        const decoded = try decode_pic_alloc(allocator, buf[0..n]);
        defer allocator.free(decoded);

        try std.testing.expectEqual(data.len, decoded.len);
        for (data, decoded) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 0.1);
        }
    }
}

test "slof roundtrip" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = &[_]f64{ 0.0, 1.0, 10.0, 100.0, 1000.0, 10000.0 };
    var buf: [256]u8 = undefined;
    const n = try encode_slof(data, &buf);

    const decoded = try decode_slof_alloc(allocator, buf[0..n]);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 6), decoded.len);
    for (data, decoded) |expected, actual| {
        // SLOF is lossy — allow ~1% relative error
        const tolerance = @max(0.1, expected * 0.01);
        try std.testing.expectApproxEqAbs(expected, actual, tolerance);
    }
}

test "linear empty" {
    var buf: [16]u8 = undefined;
    const n = try encode_linear(&[_]f64{}, &buf, DEFAULT_LINEAR_FIXED_POINT);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "pic empty" {
    var buf: [16]u8 = undefined;
    const n = try encode_pic(&[_]f64{}, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "slof empty" {
    var buf: [16]u8 = undefined;
    const n = try encode_slof(&[_]f64{}, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}
