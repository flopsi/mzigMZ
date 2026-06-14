const std = @import("std");
const w32 = @import("win32_common");

pub fn show_open_file_dialog(parent: w32.HWND, allocator: std.mem.Allocator) ?[]const u8 {
    var file_buf: [512]u16 = undefined;
    @memset(&file_buf, 0);

    // Build filter string: UTF-16 pairs, each pair terminated by 0, double 0 at end
    const filter_text = "RAW Files\x00*.raw\x00All Files\x00*.*\x00";
    var filter_buf: [64]u16 = undefined;
    @memset(&filter_buf, 0);
    for (filter_text, 0..) |c, i| filter_buf[i] = c;

    var ofn: w32.OPENFILENAMEW = std.mem.zeroes(w32.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(w32.OPENFILENAMEW);
    ofn.hwndOwner = parent;
    ofn.lpstrFilter = @ptrCast(&filter_buf[0]);
    ofn.nFilterIndex = 1;
    ofn.lpstrFile = @ptrCast(&file_buf);
    ofn.nMaxFile = file_buf.len;
    ofn.Flags = 0x00001000 | 0x00000008; // OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST

    if (w32.GetOpenFileNameW(&ofn) == 0) return null;

    // Find null terminator in file_buf
    var len: usize = 0;
    while (len < file_buf.len and file_buf[len] != 0) : (len += 1) {}

    const result = allocator.alloc(u8, len * 3) catch return null;
    const actual_len = std.unicode.utf16LeToUtf8(result, file_buf[0..len]) catch {
        allocator.free(result);
        return null;
    };

    if (actual_len < result.len) {
        const trimmed = allocator.realloc(result, actual_len) catch result;
        return trimmed;
    }
    return result;
}
