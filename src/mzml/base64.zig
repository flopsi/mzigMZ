/// Base64 encode/decode for mzML binary arrays.
/// mzML requires LITTLE-ENDIAN byte order for all binary data (f64/f32 arrays).
/// This module wraps std.base64 with little-endian float serialization helpers.
const std = @import("std");

const standard = std.base64.standard;

pub const Base64Error = error{
    InvalidAlignment,
    InvalidBase64,
};

/// Full error surface for the module's public helpers.
pub const Error = std.mem.Allocator.Error || Base64Error || std.base64.Error;

// ============================================================================
// Raw bytes
// ============================================================================

/// Encode raw bytes to a Base64 string. Caller frees result.
pub fn encode(allocator: std.mem.Allocator, data: []const u8) Error![]u8 {
    if (data.len == 0) return allocator.dupe(u8, "");
    const encoded_len = standard.Encoder.calcSize(data.len);
    const result = try allocator.alloc(u8, encoded_len);
    _ = standard.Encoder.encode(result, data);
    return result;
}

/// Decode a Base64 string to raw bytes. Caller frees result.
pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) Error![]u8 {
    const trimmed = std.mem.trim(u8, encoded, &std.ascii.whitespace);
    if (trimmed.len == 0) return allocator.alloc(u8, 0);
    const decoded_len = try standard.Decoder.calcSizeForSlice(trimmed);
    const result = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(result);
    try standard.Decoder.decode(result, trimmed);
    return result;
}

// ============================================================================
// f64 arrays (little-endian) — DIRECT ENCODING (no intermediate buffer)
// ============================================================================

/// Encode []f64 to Base64 with little-endian byte order (mzML spec requirement).
/// Byte-swaps in-place into a single temporary buffer, then encodes in one call.
/// This is faster than chunked encoding because std.base64.Encoder has a u128 fast path.
pub fn encode_f64_array(allocator: std.mem.Allocator, data: []const f64) Error![]u8 {
    if (data.len == 0) return allocator.dupe(u8, "");
    const byte_len = data.len * @sizeOf(f64);
    const encoded_len = standard.Encoder.calcSize(byte_len);

    // Allocate both buffers together: byte-swapped data + base64 result
    const total_alloc = byte_len + encoded_len;
    const combined = try allocator.alloc(u8, total_alloc);
    defer allocator.free(combined);

    const bytes = combined[0..byte_len];
    const result = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(result);

    // Write all f64 values as little-endian in one pass
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        inline for (0..4) |j| {
            const val = data[i + j];
            const raw = @as(u64, @bitCast(val));
            @as(*align(1) u64, @ptrCast(bytes[(i + j) * 8 ..][0..8])).* = raw;
        }
    }
    while (i < data.len) : (i += 1) {
        const val = data[i];
        const raw = @as(u64, @bitCast(val));
        @as(*align(1) u64, @ptrCast(bytes[i * 8 ..][0..8])).* = raw;
    }

    _ = standard.Encoder.encode(result, bytes);
    return result;
}

/// Decode Base64 string to []f64 (little-endian).
pub fn decode_f64_array(allocator: std.mem.Allocator, encoded: []const u8) Error![]f64 {
    const decoded_bytes = try decode(allocator, encoded);
    defer allocator.free(decoded_bytes);
    if (decoded_bytes.len == 0) return allocator.alloc(f64, 0);
    if (decoded_bytes.len % 8 != 0) return Base64Error.InvalidAlignment;
    const count = decoded_bytes.len / 8;
    const result = try allocator.alloc(f64, count);
    errdefer allocator.free(result);
    for (0..count) |i| {
        const raw = std.mem.readInt(u64, decoded_bytes[i * 8 ..][0..8], .little);
        result[i] = @bitCast(raw);
    }
    return result;
}

// ============================================================================
// f32 arrays (little-endian) — DIRECT ENCODING (no intermediate buffer)
// ============================================================================

/// Encode []f32 to Base64 with little-endian byte order.
/// Byte-swaps in-place into a single temporary buffer, then encodes in one call.
pub fn encode_f32_array(allocator: std.mem.Allocator, data: []const f32) Error![]u8 {
    if (data.len == 0) return allocator.dupe(u8, "");
    const byte_len = data.len * @sizeOf(f32);
    const encoded_len = standard.Encoder.calcSize(byte_len);

    const total_alloc = byte_len + encoded_len;
    const combined = try allocator.alloc(u8, total_alloc);
    defer allocator.free(combined);

    const bytes = combined[0..byte_len];
    const result = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(result);

    // Write all f32 values as little-endian in one pass
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        inline for (0..4) |j| {
            const val = data[i + j];
            const raw = @as(u32, @bitCast(val));
            @as(*align(1) u32, @ptrCast(bytes[(i + j) * 4 ..][0..4])).* = raw;
        }
    }
    while (i < data.len) : (i += 1) {
        const val = data[i];
        const raw = @as(u32, @bitCast(val));
        @as(*align(1) u32, @ptrCast(bytes[i * 4 ..][0..4])).* = raw;
    }

    _ = standard.Encoder.encode(result, bytes);
    return result;
}

/// Decode Base64 string to []f32 (little-endian).
pub fn decode_f32_array(allocator: std.mem.Allocator, encoded: []const u8) Error![]f32 {
    const decoded_bytes = try decode(allocator, encoded);
    defer allocator.free(decoded_bytes);
    if (decoded_bytes.len == 0) return allocator.alloc(f32, 0);
    if (decoded_bytes.len % 4 != 0) return Base64Error.InvalidAlignment;
    const count = decoded_bytes.len / 4;
    const result = try allocator.alloc(f32, count);
    errdefer allocator.free(result);
    for (0..count) |i| {
        const raw = std.mem.readInt(u32, decoded_bytes[i * 4 ..][0..4], .little);
        result[i] = @bitCast(raw);
    }
    return result;
}

// ============================================================================
// f32 → f64 conversion + base64 (for when scan stores f32 but mzML wants f64)
// ============================================================================

/// Encode []f32 as f64 Base64 with little-endian byte order.
/// Converts to f64, writes into a temp buffer, then encodes in one call.
pub fn encode_f32_as_f64_array(allocator: std.mem.Allocator, data: []const f32) Error![]u8 {
    if (data.len == 0) return allocator.dupe(u8, "");
    const byte_len = data.len * @sizeOf(f64);
    const encoded_len = standard.Encoder.calcSize(byte_len);

    const total_alloc = byte_len + encoded_len;
    const combined = try allocator.alloc(u8, total_alloc);
    defer allocator.free(combined);

    const bytes = combined[0..byte_len];
    const result = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(result);

    // Convert f32 → f64 and write as little-endian in one pass
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        inline for (0..4) |j| {
            const val_f64: f64 = @floatCast(data[i + j]);
            const raw = @as(u64, @bitCast(val_f64));
            @as(*align(1) u64, @ptrCast(bytes[(i + j) * 8 ..][0..8])).* = raw;
        }
    }
    while (i < data.len) : (i += 1) {
        const val_f64: f64 = @floatCast(data[i]);
        const raw = @as(u64, @bitCast(val_f64));
        @as(*align(1) u64, @ptrCast(bytes[i * 8 ..][0..8])).* = raw;
    }

    _ = standard.Encoder.encode(result, bytes);
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "encode/decode empty" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const enc = try encode(allocator, "");
    defer allocator.free(enc);
    try std.testing.expectEqualStrings("", enc);
}

test "f64 roundtrip" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = &[_]f64{ 1.5, 2.5, 3.141592653589793 };
    const encoded = try encode_f64_array(allocator, data);
    defer allocator.free(encoded);

    // Should be valid Base64
    try std.testing.expect(encoded.len > 0);

    const decoded = try decode_f64_array(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    try std.testing.expectEqual(data[0], decoded[0]);
    try std.testing.expectEqual(data[1], decoded[1]);
    try std.testing.expectEqual(data[2], decoded[2]);
}

test "f32 roundtrip" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = &[_]f32{ 1.5, 2.5, 3.14159 };
    const encoded = try encode_f32_array(allocator, data);
    defer allocator.free(encoded);

    const decoded = try decode_f32_array(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    try std.testing.expectEqual(data[0], decoded[0]);
    try std.testing.expectEqual(data[1], decoded[1]);
    try std.testing.expectEqual(data[2], decoded[2]);
}

test "f64 empty" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = &[_]f64{};
    const encoded = try encode_f64_array(allocator, data);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("", encoded);

    const decoded = try decode_f64_array(allocator, "");
    defer allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "little-endian verification" {
    // Verify that encoding preserves little-endian byte order.
    // f64 value 1.0 = 0x3FF0000000000000 (little-endian)
    // Little-endian bytes: 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = &[_]f64{1.0};
    const encoded = try encode_f64_array(allocator, data);
    defer allocator.free(encoded);

    // Decode the base64 manually to check byte order
    const decoded_bytes = try decode(allocator, encoded);
    defer allocator.free(decoded_bytes);

    // In little-endian, 1.0f64 = 0x3FF0000000000000
    // Bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F]
    try std.testing.expectEqual(@as(u8, 0x00), decoded_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x00), decoded_bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x00), decoded_bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x00), decoded_bytes[3]);
    try std.testing.expectEqual(@as(u8, 0x00), decoded_bytes[4]);
    try std.testing.expectEqual(@as(u8, 0x00), decoded_bytes[5]);
    try std.testing.expectEqual(@as(u8, 0xF0), decoded_bytes[6]);
    try std.testing.expectEqual(@as(u8, 0x3F), decoded_bytes[7]);
}

test "f64 various lengths" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test lengths that exercise different remainder paths (0, 1, 2 remainders after groups of 3)
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) |len| {
        const data = try allocator.alloc(f64, len);
        defer allocator.free(data);
        for (data, 0..) |*d, i| d.* = @floatFromInt(i + 1);

        const encoded = try encode_f64_array(allocator, data);
        defer allocator.free(encoded);

        const decoded = try decode_f64_array(allocator, encoded);
        defer allocator.free(decoded);

        try std.testing.expectEqual(len, decoded.len);
        for (data, decoded) |expected, actual| {
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "f32-as-f64 roundtrip" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const f32_data = &[_]f32{ 1.5, 2.5, 3.14159 };
    const encoded = try encode_f32_as_f64_array(allocator, f32_data);
    defer allocator.free(encoded);

    // Decode as f64 and verify
    const decoded_bytes = try decode(allocator, encoded);
    defer allocator.free(decoded_bytes);

    try std.testing.expectEqual(@as(usize, 24), decoded_bytes.len); // 3 * 8 bytes

    // Read back as f64 little-endian
    const f64_0 = std.mem.readInt(u64, decoded_bytes[0..8], .little);
    const f64_1 = std.mem.readInt(u64, decoded_bytes[8..16], .little);
    const f64_2 = std.mem.readInt(u64, decoded_bytes[16..24], .little);

    try std.testing.expectEqual(@as(f64, 1.5), @as(f64, @bitCast(f64_0)));
    try std.testing.expectEqual(@as(f64, 2.5), @as(f64, @bitCast(f64_1)));
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), @as(f64, @bitCast(f64_2)), 0.0001);
}

test "f32 various lengths" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) |len| {
        const data = try allocator.alloc(f32, len);
        defer allocator.free(data);
        for (data, 0..) |*d, i| d.* = @floatFromInt(i + 1);

        const encoded = try encode_f32_array(allocator, data);
        defer allocator.free(encoded);

        const decoded = try decode_f32_array(allocator, encoded);
        defer allocator.free(decoded);

        try std.testing.expectEqual(len, decoded.len);
        for (data, decoded) |expected, actual| {
            try std.testing.expectEqual(expected, actual);
        }
    }
}
