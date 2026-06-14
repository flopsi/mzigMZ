const std = @import("std");

/// Write value as JSON to the provided writer.
pub fn write(value: anytype, writer: anytype, pretty: bool) !void {
    const options: std.json.Stringify.Options = .{
        .whitespace = if (pretty) .indent_2 else .minified,
    };
    try std.json.Stringify.value(value, options, writer);
}

test "json helper serializes struct" {
    const S = struct { scan_number: i32, ms_level: u8 };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(S{ .scan_number = 42, .ms_level = 2 }, &out.writer, false);
    try std.testing.expectEqualStrings("{\"scan_number\":42,\"ms_level\":2}", out.written());
}
