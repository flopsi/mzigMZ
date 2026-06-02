const std = @import("std");
const app = @import("app_state");

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: [*:0]const u16, pNumArgs: *i32) callconv(.winapi) ?[*][*:0]const u16;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

fn utf16ZLen(s: [*:0]const u16) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

fn utf16ZToAsciiAlloc(allocator: std.mem.Allocator, s: [*:0]const u16) ![]u8 {
    const n = utf16ZLen(s);
    const out = try allocator.alloc(u8, n);
    errdefer allocator.free(out);
    for (out, 0..) |*c, i| {
        const ch = s[i];
        if (ch > 0x7f) return error.NonAsciiArgument;
        c.* = @intCast(ch);
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    
    var argc: i32 = 0;
    const argv_w = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return error.CommandLineToArgvFailed;
    defer _ = LocalFree(@ptrCast(argv_w));
    
    if (argc < 3) {
        std.debug.print("Usage: debug_mass <raw-file> <scan-number>\n", .{});
        return;
    }
    
    const raw_path = try utf16ZToAsciiAlloc(allocator, argv_w[1]);
    defer allocator.free(raw_path);
    
    // Parse scan number from argv_w[2]
    const scan_arg = try utf16ZToAsciiAlloc(allocator, argv_w[2]);
    defer allocator.free(scan_arg);
    const scan_num = try std.fmt.parseInt(usize, scan_arg, 10);
    
    var state = app.AppState.init(allocator, io);
    defer state.deinit();
    
    try state.openFile(raw_path);
    
    if (scan_num >= state.scans.len) {
        std.debug.print("Scan {} out of range ({} scans)\n", .{scan_num, state.scans.len});
        return;
    }
    
    try state.loadScan(scan_num);
    
    const spec = state.current_spectrum.?;
    std.debug.print("Scan {}: {} points\n", .{scan_num + 1, spec.pointCount()});
    std.debug.print("  First mass: {d:.4}\n", .{spec.mz[0]});
    std.debug.print("  Last mass:  {d:.4}\n", .{spec.mz[spec.pointCount() - 1]});
    
    // Find actual max intensity
    var max_inten: f32 = 0;
    for (spec.intensity) |inten| {
        if (inten > max_inten) max_inten = inten;
    }
    std.debug.print("  Actual max intensity: {d:.2}\n", .{max_inten});
    
    // Print calibrators
    const event = state.trailer_events.?.getEvent(scan_num).?;
    std.debug.print("  Calibrators ({} values):\n", .{event.mass_calibrators.len});
    for (event.mass_calibrators, 0..) |c, i| {
        std.debug.print("    [{d}] = {e:.15}\n", .{i, c});
    }
}
