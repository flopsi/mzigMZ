const std = @import("std");
const w32 = @import("win32_common");
const app = @import("app_state");

pub const ChromatogramType = enum {
    tic,
    bpc,
};

var g_pen_line: ?w32.HPEN = null;
var g_pen_axis: ?w32.HPEN = null;
var g_pen_grid: ?w32.HPEN = null;
var g_chromatogram_type: ChromatogramType = .tic;

// Zoom state (default invalid — reset on first paint)
var g_zoom_rt_min: f64 = 0;
var g_zoom_rt_max: f64 = 0;
var g_zoom_inten_max: f64 = 0;
var g_zoom_active: bool = false;

pub const CreateError = error{
    RegisterClassFailed,
    CreateWindowFailed,
};

pub fn create(parent: w32.HWND, hInstance: w32.HINSTANCE, id: c_int) CreateError!w32.HWND {
    const class_name = w32.utf8_to_utf16_z("ChromatogramCanvas");

    var wc: w32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = canvasWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, @ptrFromInt(@as(usize, @intCast(w32.IDC_ARROW)))),
        .hbrBackground = @ptrCast(w32.GetStockObject(w32.WHITE_BRUSH)),
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    return w32.CreateWindowExW(
        0,
        class_name,
        w32.utf8_to_utf16_z(""),
        w32.WS_CHILD | w32.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        parent,
        @ptrFromInt(@as(usize, @intCast(id))),
        hInstance,
        null,
    ) orelse return error.CreateWindowFailed;
}

pub fn invalidate(hwnd: w32.HWND) void {
    _ = w32.InvalidateRect(hwnd, null, 1);
}

fn canvasWndProc(hwnd: w32.HWND, msg: w32.UINT, wParam: w32.WPARAM, lParam: w32.LPARAM) callconv(.c) w32.LRESULT {
    const state = getState(hwnd);

    switch (msg) {
        w32.WM_PAINT => {
            if (state) |s| paint(hwnd, s);
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_SIZE => {
            invalidate(hwnd);
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            if (state) |s| handleMouseWheel(hwnd, s, wParam, lParam);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            g_zoom_active = false;
            invalidate(hwnd);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            handleMouseDown(hwnd, state, w32.loword(lParam), w32.hiword(lParam));
            return 0;
        },
        w32.WM_DESTROY => {
            release_cached_pens();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn getState(hwnd: w32.HWND) ?*app.AppState {
    const ptr = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

pub fn set_state(hwnd: w32.HWND, state: *app.AppState) void {
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@as(usize, @intFromPtr(state))));
}

pub fn set_chromatogram_type(typ: ChromatogramType) void {
    g_chromatogram_type = typ;
    g_zoom_active = false;
}

fn release_cached_pens() void {
    if (g_pen_line) |p| {
        _ = w32.DeleteObject(@ptrCast(p));
        g_pen_line = null;
    }
    if (g_pen_axis) |p| {
        _ = w32.DeleteObject(@ptrCast(p));
        g_pen_axis = null;
    }
    if (g_pen_grid) |p| {
        _ = w32.DeleteObject(@ptrCast(p));
        g_pen_grid = null;
    }
}

fn paint(hwnd: w32.HWND, state: *app.AppState) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    _ = w32.FillRect(hdc, &rc, @ptrCast(w32.GetStockObject(w32.WHITE_BRUSH)));

    const margin = 60;
    const plot_left = margin;
    const plot_right = rc.right - margin;
    const plot_top = margin;
    const plot_bottom = rc.bottom - margin;
    const plot_w = plot_right - plot_left;
    const plot_h = plot_bottom - plot_top;

    if (plot_w <= 0 or plot_h <= 0) return;

    // Determine which chromatogram to show
    const cg = switch (g_chromatogram_type) {
        .tic => state.tic_chromatogram,
        .bpc => state.bpc_chromatogram,
    } orelse {
        drawNoData(hdc, rc);
        return;
    };
    if (cg.num_points == 0) {
        drawNoData(hdc, rc);
        return;
    }

    // Apply MS level filter
    const ms_filter = state.chromatogram_ms_level_filter;

    // Find full data range (for non-zoomed view)
    var full_rt_min: f64 = std.math.inf(f64);
    var full_rt_max: f64 = -std.math.inf(f64);
    var full_inten_max: f64 = 0;
    var visible_count: usize = 0;

    for (0..cg.num_points) |i| {
        if (ms_filter) |level| {
            if (cg.ms_level[i] != level) continue;
        }
        const rt = cg.rt[i];
        const inten = cg.intensity[i];
        if (rt < full_rt_min) full_rt_min = rt;
        if (rt > full_rt_max) full_rt_max = rt;
        if (inten > full_inten_max) full_inten_max = inten;
        visible_count += 1;
    }

    if (visible_count == 0) {
        drawNoData(hdc, rc);
        return;
    }

    // Use zoom state if active, else full range
    if (!g_zoom_active) {
        g_zoom_rt_min = full_rt_min;
        g_zoom_rt_max = full_rt_max;
        g_zoom_inten_max = full_inten_max;
    }
    const rt_min = g_zoom_rt_min;
    const rt_max = g_zoom_rt_max;
    const inten_max = g_zoom_inten_max;
    const rt_range = if (rt_max > rt_min) rt_max - rt_min else 1.0;

    // Draw axes + grid
    drawAxes(hdc, plot_left, plot_top, plot_w, plot_h, rt_min, rt_max, inten_max);

    // Draw line
    if (g_pen_line == null) {
        g_pen_line = w32.CreatePen(w32.PS_SOLID, 1, w32.rgb(0, 0, 180)) orelse return;
    }
    const pen = g_pen_line.?;
    const old = w32.SelectObject(hdc, @ptrCast(pen));
    defer _ = w32.SelectObject(hdc, old);

    var first = true;
    for (0..cg.num_points) |i| {
        if (ms_filter) |level| {
            if (cg.ms_level[i] != level) continue;
        }
        const x = plot_left + @as(i32, @intFromFloat((cg.rt[i] - rt_min) / rt_range * @as(f64, @floatFromInt(plot_w))));
        const inten_scale = @as(f64, @floatFromInt(plot_h)) / inten_max;
        const y = plot_top + plot_h - @as(i32, @intFromFloat(@mulAdd(f64, cg.intensity[i], inten_scale, 0.0)));
        if (first) {
            _ = w32.MoveToEx(hdc, x, y, null);
            first = false;
        } else {
            _ = w32.LineTo(hdc, x, y);
        }
    }

    // Info text
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    var buf: [256]u8 = undefined;
    const info = std.fmt.bufPrintZ(&buf, "Points: {d} | RT: {d:.2} - {d:.2} min | Max: {e:.2}", .{ visible_count, rt_min, rt_max, inten_max }) catch return;
    var info16_buf: [256]u16 = undefined;
    const info16 = w32.utf8_to_utf16_buf(&info16_buf, info) catch info16_buf[0..0];
    info16_buf[info16.len] = 0;
    _ = w32.TextOutW(hdc, rc.right - 400, 5, @as([*:0]u16, @ptrCast(&info16_buf)), @intCast(info16.len));
}

fn drawNoData(hdc: w32.HDC, rc: w32.RECT) void {
    const msg = w32.utf8_to_utf16("No chromatogram data");
    var rc2 = rc;
    _ = w32.DrawTextW(hdc, msg.ptr, @intCast(msg.len), &rc2, w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE);
}

fn drawAxes(
    hdc: w32.HDC,
    plot_left: i32,
    plot_top: i32,
    plot_w: i32,
    plot_h: i32,
    x_min: f64,
    x_max: f64,
    y_max: f64,
) void {
    if (g_pen_axis == null) {
        g_pen_axis = w32.CreatePen(w32.PS_SOLID, 1, w32.rgb(0, 0, 0)) orelse return;
    }
    const pen = g_pen_axis.?;
    const old = w32.SelectObject(hdc, @ptrCast(pen));
    defer _ = w32.SelectObject(hdc, old);

    // Border rect
    _ = w32.Rectangle(hdc, plot_left, plot_top, plot_left + plot_w, plot_top + plot_h);

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    // X axis labels (RT in minutes)
    const x_range = x_max - x_min;
    const x_step = w32.nice_round(x_range / 10.0);
    var x_val = @floor(x_min / x_step) * x_step;
    while (x_val <= x_max) : (x_val += x_step) {
        const x_scale = @as(f64, @floatFromInt(plot_w)) / x_range;
        const sx = plot_left + @as(i32, @intFromFloat(@mulAdd(f64, x_val - x_min, x_scale, 0.0)));
        _ = w32.MoveToEx(hdc, sx, plot_top + plot_h, null);
        _ = w32.LineTo(hdc, sx, plot_top + plot_h + 5);

        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.1}", .{x_val}) catch continue;
        var text16_buf: [32]u16 = undefined;
        const text16 = w32.utf8_to_utf16_buf(&text16_buf, text) catch continue;
        text16_buf[text16.len] = 0;

        var sz: w32.SIZE = undefined;
        _ = w32.GetTextExtentPoint32W(hdc, text16.ptr, @intCast(text16.len), &sz);
        _ = w32.TextOutW(hdc, sx - @divTrunc(sz.cx, 2), plot_top + plot_h + 8, @as([*:0]u16, @ptrCast(&text16_buf)), @intCast(text16.len));
    }

    // Y axis labels
    const y_step = w32.nice_round(y_max / 8.0);
    var y_val: f64 = 0;
    while (y_val <= y_max) : (y_val += y_step) {
        const y_scale = @as(f64, @floatFromInt(plot_h)) / y_max;
        const sy = plot_top + plot_h - @as(i32, @intFromFloat(@mulAdd(f64, y_val, y_scale, 0.0)));
        _ = w32.MoveToEx(hdc, plot_left - 5, sy, null);
        _ = w32.LineTo(hdc, plot_left, sy);

        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.0}", .{y_val}) catch continue;
        var text16_buf: [32]u16 = undefined;
        const text16 = w32.utf8_to_utf16_buf(&text16_buf, text) catch continue;
        text16_buf[text16.len] = 0;

        var sz: w32.SIZE = undefined;
        _ = w32.GetTextExtentPoint32W(hdc, text16.ptr, @intCast(text16.len), &sz);
        _ = w32.TextOutW(hdc, plot_left - sz.cx - 8, sy - @divTrunc(sz.cy, 2), @as([*:0]u16, @ptrCast(&text16_buf)), @intCast(text16.len));
    }

    // Axis titles
    const x_title = w32.utf8_to_utf16("RT (min)");
    _ = w32.TextOutW(hdc, plot_left + @divTrunc(plot_w, 2) - 25, plot_top + plot_h + 25, x_title.ptr, @intCast(x_title.len));

    const y_title = w32.utf8_to_utf16("Intensity");
    _ = w32.TextOutW(hdc, 5, plot_top - 20, y_title.ptr, @intCast(y_title.len));
}

fn reset_zoom(cg: *const app.Chromatogram, ms_filter: ?u8) void {
    g_zoom_active = false;
    // Compute full range for reset
    g_zoom_rt_min = std.math.inf(f64);
    g_zoom_rt_max = -std.math.inf(f64);
    g_zoom_inten_max = 0;
    for (0..cg.num_points) |i| {
        if (ms_filter) |level| {
            if (cg.ms_level[i] != level) continue;
        }
        if (cg.rt[i] < g_zoom_rt_min) g_zoom_rt_min = cg.rt[i];
        if (cg.rt[i] > g_zoom_rt_max) g_zoom_rt_max = cg.rt[i];
        if (cg.intensity[i] > g_zoom_inten_max) g_zoom_inten_max = cg.intensity[i];
    }
    if (g_zoom_rt_max <= g_zoom_rt_min) {
        g_zoom_rt_min = 0;
        g_zoom_rt_max = 1;
    }
    if (g_zoom_inten_max <= 0) g_zoom_inten_max = 1;
}

fn handleMouseWheel(hwnd: w32.HWND, state: *app.AppState, wParam: w32.WPARAM, lParam: w32.LPARAM) void {
    const delta = @as(i32, @as(i16, @bitCast(@as(u16, @intCast(wParam >> 16)))));
    const screen_pt = w32.POINT{ .x = @as(i32, @intCast(lParam & 0xFFFF)), .y = @as(i32, @intCast((lParam >> 16) & 0xFFFF)) };

    const cg = switch (g_chromatogram_type) {
        .tic => state.tic_chromatogram,
        .bpc => state.bpc_chromatogram,
    } orelse return;
    if (cg.num_points == 0) return;

    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    const margin = 60;
    const plot_left = margin;
    const plot_right = rc.right - margin;
    const plot_w = plot_right - plot_left;
    if (plot_w <= 0) return;

    // Initialize zoom on first wheel event
    if (!g_zoom_active) {
        const ms_filter = state.chromatogram_ms_level_filter;
        reset_zoom(&cg, ms_filter);
        g_zoom_active = true;
    }

    var pt = screen_pt;
    _ = w32.ScreenToClient(hwnd, &pt);
    const rt_range = g_zoom_rt_max - g_zoom_rt_min;

    if (pt.x >= plot_left and pt.x <= plot_right) {
        const click_rt = g_zoom_rt_min + (@as(f64, @floatFromInt(pt.x - plot_left)) / @as(f64, @floatFromInt(plot_w))) * rt_range;
        const factor: f64 = if (delta > 0) 0.85 else 1.18;
        const new_span = rt_range * factor;
        const half = new_span / 2.0;
        g_zoom_rt_min = click_rt - half;
        g_zoom_rt_max = click_rt + half;
    } else {
        const factor: f64 = if (delta > 0) 0.85 else 1.18;
        const center = (g_zoom_rt_min + g_zoom_rt_max) / 2.0;
        const new_span = rt_range * factor;
        const half = new_span / 2.0;
        g_zoom_rt_min = center - half;
        g_zoom_rt_max = center + half;
    }
    invalidate(hwnd);
}

fn handleMouseDown(hwnd: w32.HWND, state: ?*app.AppState, x: u16, y: u16) void {
    _ = y;
    if (state) |s| {
        const cg = switch (g_chromatogram_type) {
            .tic => s.tic_chromatogram,
            .bpc => s.bpc_chromatogram,
        } orelse return;
        if (cg.num_points == 0) return;

        var rc: w32.RECT = undefined;
        _ = w32.GetClientRect(hwnd, &rc);
        const margin = 60;
        const plot_left = margin;
        const plot_right = rc.right - margin;
        const plot_w = plot_right - plot_left;

        if (x <= margin or x >= rc.right - margin) return;

        // Find RT range
        var rt_min: f64 = std.math.inf(f64);
        var rt_max: f64 = -std.math.inf(f64);
        const ms_filter = s.chromatogram_ms_level_filter;
        for (0..cg.num_points) |i| {
            if (ms_filter) |level| {
                if (cg.ms_level[i] != level) continue;
            }
            if (cg.rt[i] < rt_min) rt_min = cg.rt[i];
            if (cg.rt[i] > rt_max) rt_max = cg.rt[i];
        }
        const rt_range = if (rt_max > rt_min) rt_max - rt_min else 1.0;

        // Convert screen X to RT
        const click_rt = rt_min + (@as(f64, @floatFromInt(x - margin)) / @as(f64, @floatFromInt(plot_w))) * rt_range;

        // Find nearest scan by RT
        var nearest_idx: usize = 0;
        var min_diff: f64 = std.math.inf(f64);
        for (s.file.scans, 0..) |scan, i| {
            if (ms_filter) |level| {
                if (scan.ms_level != level) continue;
            }
            const diff = @abs(scan.rt - click_rt);
            if (diff < min_diff) {
                min_diff = diff;
                nearest_idx = i;
            }
        }

        // Load the scan and notify parent to switch to spectrum view
        s.load_scan(nearest_idx) catch {};
        _ = w32.PostMessageW(w32.GetParent(hwnd), 0x0400 + 1, nearest_idx, 0); // WM_APP + 1 = switch to spectrum
    }
}
