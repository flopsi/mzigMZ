/// Shared CLI argument parsing for Win32.
/// Every tool copy-pasted this boilerplate — now it lives in one place.
const std = @import("std");

const LPCWSTR = [*:0]const u16;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPCWSTR;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, pNumArgs: *i32) callconv(.winapi) ?[*]LPCWSTR;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

fn utf16ZLen(s: [*:0]const u16) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

pub const GetArgsError = std.mem.Allocator.Error || std.unicode.Utf16LeToUtf8AllocError || error{
    CommandLineToArgvFailed,
};

/// Get CLI arguments as UTF-8 strings.
/// Caller frees each arg and the slice.
pub fn get_args(allocator: std.mem.Allocator) GetArgsError![][]u8 {
    var argc: i32 = 0;
    const argv_w = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return error.CommandLineToArgvFailed;
    defer _ = LocalFree(@ptrCast(argv_w));

    const args = try allocator.alloc([]u8, @intCast(argc));
    errdefer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }
    for (0..@intCast(argc)) |i| {
        const n = utf16ZLen(argv_w[i]);
        args[i] = try std.unicode.utf16LeToUtf8Alloc(allocator, argv_w[i][0..n]);
    }
    return args;
}
