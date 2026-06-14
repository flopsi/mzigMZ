//! Win32 file dialog for the imguinz2 viewer.
//! Direct port of src/gui/file_dialog.zig, with utf16LeToUtf8 replaced by the
//! Zig 0.16 std.unicode API.
const std = @import("std");
const w32 = @import("win32_common");

// Win32 OPENFILENAMEW struct + GetOpenFileNameW / GetSaveFileNameW — minimal subset we need.
pub const OPENFILENAMEW = extern struct {
    lStructSize: u32,
    hwndOwner: ?*anyopaque,
    hInstance: ?*anyopaque,
    lpstrFilter: [*c]const u16,
    lpstrCustomFilter: [*c]u16,
    nMaxCustFilter: u32,
    nFilterIndex: u32,
    lpstrFile: [*c]u16,
    nMaxFile: u32,
    lpstrFileTitle: [*c]u16,
    nMaxFileTitle: u32,
    lpstrInitialDir: [*c]const u16,
    lpstrTitle: [*c]const u16,
    Flags: u32,
    nFileOffset: u16,
    nFileExtension: u16,
    lpstrDefExt: [*c]const u16,
    lCustData: ?*anyopaque,
    lpfnHook: ?*anyopaque,
    lpTemplateName: [*c]const u16,
    pvReserved: ?*anyopaque,
    dwReserved: u32,
    FlagsEx: u32,
};

pub extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) i32;
pub extern "comdlg32" fn GetSaveFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) i32;

const OFN_FILEMUSTEXIST: u32 = 0x00001000;
const OFN_PATHMUSTEXIST: u32 = 0x00000008;
const OFN_OVERWRITEPROMPT: u32 = 0x00000002;
const OFN_HIDEREADONLY: u32 = 0x00000004;
const OFN_NOCHANGEDIR: u32 = 0x00000008;

/// Show a Win32 Open File dialog. Returns the selected path as UTF-8, or null
/// if the user cancelled. Caller owns the returned slice and must free it.
pub fn show_open_file_dialog(allocator: std.mem.Allocator) ?[]const u8 {
    var file_buf: [512]u16 = undefined;
    @memset(&file_buf, 0);

    // Build filter string: UTF-16 pairs, each pair terminated by 0, double 0 at end
    // "RAW Files\0*.raw\0All Files\0*.*\0"
    var filter_buf: [64]u16 = undefined;
    @memset(&filter_buf, 0);
    const filter_patterns = [_]u16{
        'R', 'A', 'W', ' ', 'F', 'i', 'l', 'e', 's', 0,
        '*', '.', 'r', 'a', 'w', 0,   'A', 'l', 'l', ' ',
        'F', 'i', 'l', 'e', 's', 0,   '*', '.', '*', 0,
        0,
    };
    @memcpy(filter_buf[0..filter_patterns.len], &filter_patterns);

    var ofn: OPENFILENAMEW = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.lpstrFilter = &filter_buf;
    ofn.nFilterIndex = 1;
    ofn.lpstrFile = &file_buf;
    ofn.nMaxFile = file_buf.len;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;

    if (GetOpenFileNameW(&ofn) == 0) return null;

    // Find null terminator in file_buf
    var len: usize = 0;
    while (len < file_buf.len and file_buf[len] != 0) : (len += 1) {}

    // Convert UTF-16LE to UTF-8
    const result = std.unicode.utf16LeToUtf8Alloc(allocator, file_buf[0..len]) catch return null;
    return result;
}

/// Show a Win32 Save File dialog. Returns the selected path as UTF-8, or null
/// if the user cancelled. Caller owns the returned slice and must free it.
/// `default_extension` should not include the leading dot (e.g. "raw" or "mzML").
pub fn show_save_file_dialog(
    allocator: std.mem.Allocator,
    title: []const u8,
    filter_description: []const u8,
    filter_pattern: []const u8,
    default_extension: []const u8,
) ?[]const u8 {
    var file_buf: [512]u16 = undefined;
    @memset(&file_buf, 0);

    var filter_buf: [128]u16 = undefined;
    @memset(&filter_buf, 0);
    var def_ext_buf: [16]u16 = undefined;
    @memset(&def_ext_buf, 0);
    var title_buf: [128]u16 = undefined;
    @memset(&title_buf, 0);

    // Build filter string: "Description\0*.ext\0\0"
    const filter_z = std.fmt.allocPrint(allocator, "{s}\x00{s}\x00", .{ filter_description, filter_pattern }) catch return null;
    defer allocator.free(filter_z);
    const filter_u16 = std.unicode.utf8ToUtf16LeAlloc(allocator, filter_z) catch return null;
    defer allocator.free(filter_u16);
    const filter_len = @min(filter_u16.len, filter_buf.len);
    @memcpy(filter_buf[0..filter_len], filter_u16[0..filter_len]);

    const def_ext_z = std.fmt.allocPrint(allocator, "{s}\x00", .{default_extension}) catch return null;
    defer allocator.free(def_ext_z);
    const def_ext_u16 = std.unicode.utf8ToUtf16LeAlloc(allocator, def_ext_z) catch return null;
    defer allocator.free(def_ext_u16);
    const def_ext_len = @min(def_ext_u16.len, def_ext_buf.len);
    @memcpy(def_ext_buf[0..def_ext_len], def_ext_u16[0..def_ext_len]);

    const title_z = std.fmt.allocPrint(allocator, "{s}\x00", .{title}) catch return null;
    defer allocator.free(title_z);
    const title_u16 = std.unicode.utf8ToUtf16LeAlloc(allocator, title_z) catch return null;
    defer allocator.free(title_u16);
    const title_len = @min(title_u16.len, title_buf.len);
    @memcpy(title_buf[0..title_len], title_u16[0..title_len]);

    var ofn: OPENFILENAMEW = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.lpstrFilter = &filter_buf;
    ofn.nFilterIndex = 1;
    ofn.lpstrFile = &file_buf;
    ofn.nMaxFile = file_buf.len;
    ofn.lpstrTitle = &title_buf;
    ofn.lpstrDefExt = &def_ext_buf;
    ofn.Flags = OFN_OVERWRITEPROMPT | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;

    if (GetSaveFileNameW(&ofn) == 0) return null;

    var len: usize = 0;
    while (len < file_buf.len and file_buf[len] != 0) : (len += 1) {}

    const result = std.unicode.utf16LeToUtf8Alloc(allocator, file_buf[0..len]) catch return null;
    return result;
}

// Suppress unused import warning (we may need w32 for future HWND parenting)
const _ = w32;
