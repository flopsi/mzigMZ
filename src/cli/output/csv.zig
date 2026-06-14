const std = @import("std");

pub const CsvWriter = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) CsvWriter {
        return .{ .allocator = allocator, .buf = .empty };
    }

    pub fn deinit(self: *CsvWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn bytes(self: CsvWriter) []const u8 {
        return self.buf.items;
    }

    pub fn writeRow(self: *CsvWriter, values: []const []const u8) !void {
        for (values, 0..) |v, i| {
            if (i > 0) try self.buf.append(self.allocator, ',');
            const needs_quote = for (v) |c| {
                if (c == ',' or c == '"' or c == '\n' or c == '\r') break true;
            } else false;
            if (needs_quote) {
                try self.buf.append(self.allocator, '"');
                for (v) |c| {
                    if (c == '"') try self.buf.appendSlice(self.allocator, "\"\"") else try self.buf.append(self.allocator, c);
                }
                try self.buf.append(self.allocator, '"');
            } else {
                try self.buf.appendSlice(self.allocator, v);
            }
        }
        try self.buf.append(self.allocator, '\n');
    }
};

test "csv writer quotes values with commas" {
    var cw = CsvWriter.init(std.testing.allocator);
    defer cw.deinit();
    try cw.writeRow(&[_][]const u8{ "a", "b,c" });
    try std.testing.expectEqualStrings("a,\"b,c\"\n", cw.bytes());
}
