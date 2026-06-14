/// Shared UTF-16LE → UTF-8 conversion with stack optimization.
/// Used by raw_file_reader, scan_event, and trailer_events.
const std = @import("std");

/// Convert a UTF-16LE byte slice to an owned UTF-8 string.
///
/// Uses a stack buffer for strings up to 256 characters, falling back to
/// heap allocation for larger strings. The caller receives an allocated
/// `[]u8` regardless of path.
///
/// `wide_bytes` is the raw UTF-16LE bytes (str_len * 2 bytes).
/// `str_len` is the number of UTF-16 code units (not bytes).
pub fn utf16_le_to_utf8_alloc(
    allocator: std.mem.Allocator,
    wide_bytes: []const u8,
    str_len: usize,
) (error{OutOfMemory} || std.unicode.Utf16LeToUtf8Error)![]u8 {
    const stack_chars = 256;

    if (str_len <= stack_chars) {
        // Fast path: convert on stack, then copy to heap
        var stack_wide: [stack_chars]u16 = undefined;
        @memcpy(std.mem.sliceAsBytes(stack_wide[0..str_len]), wide_bytes);
        var stack_utf8: [stack_chars * 3]u8 = undefined;
        const utf8_len = std.unicode.utf16LeToUtf8(&stack_utf8, stack_wide[0..str_len]) catch return error.OutOfMemory;
        const result = try allocator.alloc(u8, utf8_len);
        errdefer allocator.free(result);
        @memcpy(result, stack_utf8[0..utf8_len]);
        return result;
    }

    // Slow path: allocate UTF-16 buffer, then convert
    const wide_u16 = try allocator.alloc(u16, str_len);
    defer allocator.free(wide_u16);
    @memcpy(std.mem.sliceAsBytes(wide_u16), wide_bytes);
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide_u16);
}

test "utf16LeToUtf8Alloc small string" {
    const utf16le = [_]u8{
        'H', 0, 'e', 0, 'l', 0, 'l', 0, 'o', 0,
    };
    const result = try utf16_le_to_utf8_alloc(std.testing.allocator, &utf16le, 5);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "utf16LeToUtf8Alloc empty" {
    const result = try utf16_le_to_utf8_alloc(std.testing.allocator, &[_]u8{}, 0);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}
