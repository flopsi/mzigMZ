const std = @import("std");

/// Wraps either stdout or an open file so every CLI command writes the same way.
pub const OutputSink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: ?std.Io.File,

    /// Creates a sink that writes to stdout.
    pub fn init_stdout(io: std.Io, allocator: std.mem.Allocator) OutputSink {
        return .{
            .io = io,
            .allocator = allocator,
            .file = null,
        };
    }

    /// Creates a sink that writes to `path`, creating or truncating the file.
    pub fn init_file(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !OutputSink {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        return .{
            .io = io,
            .allocator = allocator,
            .file = file,
        };
    }

    /// Writes `bytes` to the underlying output.
    pub fn write(self: *OutputSink, bytes: []const u8) !void {
        if (self.file) |file| {
            try file.writeStreamingAll(self.io, bytes);
        } else {
            try std.Io.File.stdout().writeStreamingAll(self.io, bytes);
        }
    }

    /// Closes the underlying file if one was opened.
    pub fn deinit(self: *OutputSink) void {
        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
        }
    }
};

test "file sink writes and closes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const path = "test_output_sink.tmp";
    {
        var sink = try OutputSink.init_file(io, std.testing.allocator, path);
        try sink.write("hello");
        try sink.write(" world");
        sink.deinit();
    }

    {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buf: [64]u8 = undefined;
        const n = try file.readPositionalAll(io, &buf, 0);
        try std.testing.expectEqualStrings("hello world", buf[0..n]);
    }

    try std.Io.Dir.cwd().deleteFile(io, path);
}
