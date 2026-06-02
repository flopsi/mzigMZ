const std = @import("std");
const w32 = @import("win32_common");
const app = @import("app_state");
const advanced = @import("advanced_packet");

const IDC_SPECTRUM_CANVAS = 101;

// ============================================================
// Pen Cache
// ============================================================

var g_pen_stick: ?w32.HPEN = null;
var g_pen_line: ?w32.HPEN = null;
var g_pen_axis: ?w32.HPEN = null;
var g_pen_grid: ?w32.HPEN = null;
var g_pen_peak: ?w32.HPEN = null;

// ============================================================
// Binary Search on m/z array
// ============================================================

fn bound(comptime is_upper: bool, mz: []const f64, target: f64) usize {
    var lo: usize = 0;
    var hi: usize = mz.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (if (is_upper) mz[mid] <= target else mz[mid] < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

// ============================================================
// Public API
// ============================================================

pub fn create(parent: w32.HWND, hInstance: w32.HINSTANCE, id: c_int) !w32.HWND {
    const class_name = w32.utf8ToUtf16Z("SpectrumCanvas");

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
        w32.utf8ToUtf16Z(""),
        w32.WS_CHILD | w32.WS_VISIBLE | w32.WS_CLIPSIBLINGS,
        0, 0, 0, 0,
        parent, @ptrFromInt(@as(usize, @intCast(id))), hInstance, null,
    ) orelse return error.CreateWindowFailed;
}

pub fn invalidate(hwnd: w32.HWND) void {
    _ = w32.InvalidateRect(hwnd, null, 1);
}

pub fn releaseCachedPens() void {
    if (g_pen_stick) |p| { _ = w32.DeleteObject(@ptrCast(p)); g_pen_stick = null; }
    if (g_pen_line) |p| { _ = w32.DeleteObject(@ptrCast(p)); g_pen_line = null; }
    if (g_pen_axis) |p| { _ = w32.DeleteObject(@ptrCast(p)); g_pen_axis = null; }
    if (g_pen_grid) |p| { _ = w32.DeleteObject(@ptrCast(p)); g_pen_grid = null; }
    if (g_pen_peak) |p| { _ = w32.DeleteObject(@ptrCast(p)); g_pen_peak = null; }
}

// ============================================================
// Window Procedure
// ============================================================

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
        w32.WM_LBUTTONDOWN => {
            handleMouseDown(hwnd, state, w32.LOWORD(lParam), w32.HIWORD(lParam));
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            handleMouseMove(hwnd, state, wParam, w32.LOWORD(lParam), w32.HIWORD(lParam));
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            if (state) |s| handleMouseWheel(hwnd, s, wParam, lParam);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            if (state) |s| {
                if (s.current_spectrum) |*spec| {
                    s.zoom.reset(spec);
                    invalidate(hwnd);
                }
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            handleMouseUp(hwnd, state);
            return 0;
        },
        w32.WM_DESTROY => {
            releaseCachedPens();
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

// ============================================================
// Paint
// ============================================================

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

    const spectrum = state.current_spectrum orelse {
        drawNoData(hdc, rc);
        return;
    };
    const mz = spectrum.mz;
    const intensity = spectrum.intensity;
    if (mz.len == 0 or intensity.len == 0 or mz.len != intensity.len) {
        drawNoData(hdc, rc);
        return;
    }

    // View range from zoom state
    const x_min = state.zoom.mz_min;
    const x_max = state.zoom.mz_max;
    const x_range = if (x_max > x_min) x_max - x_min else 1.0;

    // Cache binary search results once
    const first_idx = bound(false, mz, x_min);
    const last_idx = bound(true, mz, x_max);

    if (first_idx >= last_idx) return;

    // Compute Y max for visible range
    const y_max = blk: {
        var ym: f64 = 0;
        for (intensity[first_idx..last_idx]) |inten| {
            if (inten > ym) ym = inten;
        }
        break :blk if (ym > 0) ym else 1.0;
    };

    // Draw axes + grid
    drawAxes(hdc, plot_left, plot_top, plot_w, plot_h, x_min, x_max, y_max);

    // Draw spectrum
    switch (state.view_mode) {
        .stick => drawStickPlot(hdc, mz, intensity, first_idx, last_idx, plot_left, plot_top, plot_w, plot_h, x_min, x_range, y_max),
        .line => drawLinePlot(hdc, mz, intensity, first_idx, last_idx, plot_left, plot_top, plot_w, plot_h, x_min, x_range, y_max),
    }

    // Draw peak labels
    drawPeakLabels(hdc, mz, intensity, first_idx, last_idx, plot_left, plot_top, plot_w, plot_h, x_min, x_max, y_max);

    // Info text
    drawInfoText(hdc, &spectrum, rc, state);
}

// ============================================================
// Drawing Functions
// ============================================================

fn drawNoData(hdc: w32.HDC, rc: w32.RECT) void {
    const msg = w32.utf8ToUtf16("No data loaded");
    var rc2 = rc;
    _ = w32.DrawTextW(hdc, msg.ptr, @intCast(msg.len), &rc2, w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE);
}

fn getPen(color: u32, width: c_int) !w32.HPEN {
    return w32.CreatePen(w32.PS_SOLID, width, color) orelse error.PenCreateFailed;
}

fn usePen(hdc: w32.HDC, pen: w32.HPEN) void {
    const old = w32.SelectObject(hdc, @ptrCast(pen));
    // Caller must restore old pen before releasing
    _ = old;
}

fn drawStickPlot(
    hdc: w32.HDC, mz: []const f64, intensity: []const f32,
    first_idx: usize, last_idx: usize,
    plot_left: i32, plot_top: i32, plot_w: i32, plot_h: i32,
    x_min: f64, x_range: f64, y_max: f64,
) void {
    if (g_pen_stick == null) {
        g_pen_stick = getPen(w32.rgb(0, 0, 180), 1) catch return;
    }
    const pen = g_pen_stick.?;
    const old = w32.SelectObject(hdc, @ptrCast(pen));
    defer _ = w32.SelectObject(hdc, old);

    const baseline = plot_top + plot_h;
    for (first_idx..last_idx) |idx| {
        const x = mzToScreen(mz[idx], plot_left, plot_w, x_min, x_range);
        const y = intenToScreen(intensity[idx], plot_top, plot_h, y_max);
        _ = w32.MoveToEx(hdc, x, baseline, null);
        _ = w32.LineTo(hdc, x, y);
    }
}

fn drawLinePlot(
    hdc: w32.HDC, mz: []const f64, intensity: []const f32,
    first_idx: usize, last_idx: usize,
    plot_left: i32, plot_top: i32, plot_w: i32, plot_h: i32,
    x_min: f64, x_range: f64, y_max: f64,
) void {
    if (g_pen_line == null) {
        g_pen_line = getPen(w32.rgb(180, 0, 0), 1) catch return;
    }
    const pen = g_pen_line.?;
    const old = w32.SelectObject(hdc, @ptrCast(pen));
    defer _ = w32.SelectObject(hdc, old);

    var first = true;
    for (first_idx..last_idx) |idx| {
        const x = mzToScreen(mz[idx], plot_left, plot_w, x_min, x_range);
        const y = intenToScreen(intensity[idx], plot_top, plot_h, y_max);
        if (first) {
            _ = w32.MoveToEx(hdc, x, y, null);
            first = false;
        } else {
            _ = w32.LineTo(hdc, x, y);
        }
    }
}

// ============================================================
// Optimized Peak Labels (O(n+400) instead of O(n*20))
// ============================================================

fn drawPeakLabels(
    hdc: w32.HDC, mz: []const f64, intensity: []const f32,
    first_idx: usize, last_idx: usize,
    plot_left: i32, plot_top: i32, plot_w: i32, plot_h: i32,
    x_min: f64, x_max: f64, y_max: f64,
) void {
    const label_count = 20;
    if (last_idx <= first_idx) return;
    const visible_count = last_idx - first_idx;
    if (visible_count == 0) return;

    if (g_pen_peak == null) {
        g_pen_peak = getPen(w32.rgb(0, 128, 0), 1) catch return;
    }
    _ = w32.SelectObject(hdc, @ptrCast(g_pen_peak.?));
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    const PeakEntry = struct { idx: usize, inten: f64 };
    var top_peaks: [label_count]PeakEntry = undefined;

    // Initialize with first elements
    const init_count = @min(label_count, visible_count);
    var min_idx: usize = 0;
    for (0..init_count) |i| {
        const idx = first_idx + i;
        top_peaks[i] = .{ .idx = idx, .inten = intensity[idx] };
        if (top_peaks[i].inten < top_peaks[min_idx].inten) min_idx = i;
    }

    // Single pass: track top peaks with O(1) amortized update
    if (visible_count > label_count) {
        for (first_idx + label_count..last_idx) |idx| {
            const inten = intensity[idx];
            if (inten > top_peaks[min_idx].inten) {
                top_peaks[min_idx] = .{ .idx = idx, .inten = inten };
                // Find new minimum in at most 20 steps
                var new_min: usize = 0;
                for (top_peaks[0..init_count], 0..) |peak, i| {
                    if (peak.inten < top_peaks[new_min].inten) new_min = i;
                }
                min_idx = new_min;
            }
        }
    }

    // Draw labels
    const x_range = if (x_max > x_min) x_max - x_min else 1.0;
    for (top_peaks[0..init_count]) |peak| {
        if (peak.inten <= 0) continue;
        const pt_mz = mz[peak.idx];
        const pt_inten = intensity[peak.idx];
        const x = mzToScreen(pt_mz, plot_left, plot_w, x_min, x_range);
        const y = intenToScreen(pt_inten, plot_top, plot_h, y_max);

        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{d:.2}", .{pt_mz}) catch continue;
        var label16_buf: [32]u16 = undefined;
        const label16 = w32.utf8ToUtf16Buf(&label16_buf, label) catch continue;
        label16_buf[label16.len] = 0;
        _ = w32.TextOutW(hdc, x - 15, y - 15, @as([*:0]u16, @ptrCast(&label16_buf)), @intCast(label16.len));
    }
}

// ============================================================
// Consolidated Axis Drawing
// ============================================================

fn drawAxes(
    hdc: w32.HDC, plot_left: i32, plot_top: i32, plot_w: i32, plot_h: i32,
    x_min: f64, x_max: f64, y_max: f64,
) void {
    if (g_pen_axis == null) {
        g_pen_axis = getPen(w32.rgb(0, 0, 0), 1) catch return;
    }
    const pen = g_pen_axis.?;
    const old = w32.SelectObject(hdc, @ptrCast(pen));
    defer _ = w32.SelectObject(hdc, old);

    // Border rect
    _ = w32.Rectangle(hdc, plot_left, plot_top, plot_left + plot_w, plot_top + plot_h);

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    // X axis labels
    const x_range = x_max - x_min;
    const x_step = niceRound(x_range / 10.0);
    var x_val = @floor(x_min / x_step) * x_step;
    while (x_val <= x_max) : (x_val += x_step) {
        const sx = mzToScreen(x_val, plot_left, plot_w, x_min, x_range);

        // Tick
        _ = w32.MoveToEx(hdc, sx, plot_top + plot_h, null);
        _ = w32.LineTo(hdc, sx, plot_top + plot_h + 5);

        // Label
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.1}", .{x_val}) catch continue;
        var text16_buf: [32]u16 = undefined;
        const text16 = w32.utf8ToUtf16Buf(&text16_buf, text) catch continue;
        text16_buf[text16.len] = 0;

        var sz: w32.SIZE = undefined;
        _ = w32.GetTextExtentPoint32W(hdc, text16.ptr, @intCast(text16.len), &sz);
        _ = w32.TextOutW(hdc, sx - @divTrunc(sz.cx, 2), plot_top + plot_h + 8, @as([*:0]u16, @ptrCast(&text16_buf)), @intCast(text16.len));
    }

    // Y axis labels
    const y_step = niceRound(y_max / 8.0);
    var y_val: f64 = 0;
    while (y_val <= y_max) : (y_val += y_step) {
        const sy = intenToScreen(y_val, plot_top, plot_h, y_max);

        // Tick
        _ = w32.MoveToEx(hdc, plot_left - 5, sy, null);
        _ = w32.LineTo(hdc, plot_left, sy);

        // Label - use compact notation for large values
        var buf: [64]u8 = undefined;
        const text = if (y_val >= 1_000_000)
            std.fmt.bufPrintZ(&buf, "{d:.1}M", .{y_val / 1_000_000.0}) catch continue
        else if (y_val >= 1000)
            std.fmt.bufPrintZ(&buf, "{d:.0}k", .{y_val / 1000.0}) catch continue
        else
            std.fmt.bufPrintZ(&buf, "{d:.0}", .{y_val}) catch continue;
        var text16_buf: [32]u16 = undefined;
        const text16 = w32.utf8ToUtf16Buf(&text16_buf, text) catch continue;
        text16_buf[text16.len] = 0;

        var sz: w32.SIZE = undefined;
        _ = w32.GetTextExtentPoint32W(hdc, text16.ptr, @intCast(text16.len), &sz);
        _ = w32.TextOutW(hdc, plot_left - sz.cx - 8, sy - @divTrunc(sz.cy, 2), @as([*:0]u16, @ptrCast(&text16_buf)), @intCast(text16.len));
    }

    // Axis titles
    const x_title = w32.utf8ToUtf16("m/z");
    _ = w32.TextOutW(hdc, plot_left + @divTrunc(plot_w, 2) - 15, plot_top + plot_h + 25, x_title.ptr, @intCast(x_title.len));

    const y_title = w32.utf8ToUtf16("Intensity");
    _ = w32.TextOutW(hdc, 5, plot_top - 20, y_title.ptr, @intCast(y_title.len));
}

// ============================================================
// Info Text
// ============================================================

fn drawInfoText(hdc: w32.HDC, spectrum: *const advanced.Spectrum, rc: w32.RECT, state: *app.AppState) void {
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    var y_pos: i32 = 5;

    // Line 1: Basic spectrum info
    var buf: [512]u8 = undefined;
    const info = std.fmt.bufPrintZ(&buf, "Points: {d} | m/z: {d:.2} - {d:.2} | Max: {e:.2}",
        .{ spectrum.pointCount(), spectrum.mzMin(), spectrum.mzMax(), spectrum.intensityMax() }) catch return;
    var info16_buf: [512]u16 = undefined;
    const info16 = w32.utf8ToUtf16Buf(&info16_buf, info) catch info16_buf[0..0];
    info16_buf[info16.len] = 0;
    _ = w32.TextOutW(hdc, rc.right - 450, y_pos, @as([*:0]u16, @ptrCast(&info16_buf)), @intCast(info16.len));
    y_pos += 18;

    // Line 2: Scan-level info
    const scan = state.scans[state.current_scan_index];
    const scan_info = if (scan.ms_level > 1 and scan.precursor_mz > 0)
        std.fmt.bufPrintZ(&buf, "Scan {d} | MS{d} | Precursor: {d:.2} | z={d}", .{
            scan.scan_number, scan.ms_level, scan.precursor_mz, scan.charge_state,
        }) catch return
    else
        std.fmt.bufPrintZ(&buf, "Scan {d} | MS{d}", .{
            scan.scan_number, scan.ms_level,
        }) catch return;
    var scan16_buf: [512]u16 = undefined;
    const scan16 = w32.utf8ToUtf16Buf(&scan16_buf, scan_info) catch scan16_buf[0..0];
    scan16_buf[scan16.len] = 0;
    _ = w32.TextOutW(hdc, rc.right - 450, y_pos, @as([*:0]u16, @ptrCast(&scan16_buf)), @intCast(scan16.len));
    y_pos += 18;

    // Line 2b: Filter string (if available)
    if (scan.filter_string) |fs| {
        const filter_info = std.fmt.bufPrintZ(&buf, "{s}", .{fs}) catch return;
        var filter16_buf: [512]u16 = undefined;
        const filter16 = w32.utf8ToUtf16Buf(&filter16_buf, filter_info) catch filter16_buf[0..0];
        filter16_buf[filter16.len] = 0;
        _ = w32.TextOutW(hdc, rc.right - 450, y_pos, @as([*:0]u16, @ptrCast(&filter16_buf)), @intCast(filter16.len));
        y_pos += 18;
    }

    // Line 3: Selected peak info
    if (g_selected_peak_idx) |pi| {
        if (pi < spectrum.mz.len) {
            const features = spectrum.features orelse return;
            const f = features[pi];
            // Build flag string
            var flag_buf: [16]u8 = undefined;
            var flag_len: usize = 0;
            if (f.flags.fragmented) { flag_buf[flag_len] = 'F'; flag_len += 1; }
            if (f.flags.merged) { flag_buf[flag_len] = 'M'; flag_len += 1; }
            if (f.flags.reference) { flag_buf[flag_len] = 'R'; flag_len += 1; }
            if (f.flags.exception) { flag_buf[flag_len] = 'E'; flag_len += 1; }
            if (f.flags.saturated) { flag_buf[flag_len] = 'S'; flag_len += 1; }
            const flag_str = if (flag_len > 0) flag_buf[0..flag_len] else "-";

            const has_res = f.resolution > 0;
            const has_snr = f.sn_ratio > 0;
            const peak_info = if (f.charge > 0 and has_res and has_snr)
                std.fmt.bufPrintZ(&buf, "Peak: m/z {d:.4} | z={d} | R={d:.0} | S/N={d:.1} | flags={s}", .{
                    spectrum.mz[pi], f.charge, f.resolution, f.sn_ratio, flag_str,
                }) catch return
            else if (f.charge > 0 and has_res)
                std.fmt.bufPrintZ(&buf, "Peak: m/z {d:.4} | z={d} | R={d:.0} | flags={s}", .{
                    spectrum.mz[pi], f.charge, f.resolution, flag_str,
                }) catch return
            else if (f.charge > 0)
                std.fmt.bufPrintZ(&buf, "Peak: m/z {d:.4} | z={d} | flags={s}", .{
                    spectrum.mz[pi], f.charge, flag_str,
                }) catch return
            else if (has_res and has_snr)
                std.fmt.bufPrintZ(&buf, "Peak: m/z {d:.4} | R={d:.0} | S/N={d:.1} | flags={s}", .{
                    spectrum.mz[pi], f.resolution, f.sn_ratio, flag_str,
                }) catch return
            else if (has_res)
                std.fmt.bufPrintZ(&buf, "Peak: m/z {d:.4} | R={d:.0} | flags={s}", .{
                    spectrum.mz[pi], f.resolution, flag_str,
                }) catch return
            else
                std.fmt.bufPrintZ(&buf, "Peak: m/z {d:.4} | flags={s}", .{
                    spectrum.mz[pi], flag_str,
                }) catch return;
            var peak16_buf: [512]u16 = undefined;
            const peak16 = w32.utf8ToUtf16Buf(&peak16_buf, peak_info) catch peak16_buf[0..0];
            peak16_buf[peak16.len] = 0;
            _ = w32.TextOutW(hdc, rc.right - 450, y_pos, @as([*:0]u16, @ptrCast(&peak16_buf)), @intCast(peak16.len));
        }
    }
}

// ============================================================
// Coordinate Conversion
// ============================================================

fn mzToScreen(mz: f64, plot_left: i32, plot_w: i32, x_min: f64, x_range: f64) i32 {
    const scale = @as(f64, @floatFromInt(plot_w)) / x_range;
    return plot_left + @as(i32, @intFromFloat(@mulAdd(f64, mz - x_min, scale, 0.0)));
}

fn intenToScreen(inten: f64, plot_top: i32, plot_h: i32, y_max: f64) i32 {
    const scale = @as(f64, @floatFromInt(plot_h)) / y_max;
    return plot_top + plot_h - @as(i32, @intFromFloat(@mulAdd(f64, inten, scale, 0.0)));
}

fn niceRound(val: f64) f64 {
    if (val <= 0) return 1.0;
    const mag = std.math.pow(f64, 10.0, @floor(@log10(val)));
    const norm = val / mag;
    const nice = if (norm <= 1.0) @as(f64, 1.0) else if (norm <= 2.0) @as(f64, 2.0) else if (norm <= 5.0) @as(f64, 5.0) else @as(f64, 10.0);
    return nice * mag;
}

// ============================================================
// Mouse Handling
// ============================================================

var g_dragging = false;
var g_drag_start_x: i32 = 0;
var g_drag_start_y: i32 = 0;
var g_selected_peak_idx: ?usize = null;

fn handleMouseDown(hwnd: w32.HWND, state: ?*app.AppState, x: u16, y: u16) void {
    g_dragging = true;
    g_drag_start_x = @as(i32, @intCast(x));
    g_drag_start_y = @as(i32, @intCast(y));

    // Find nearest peak in X for selection
    if (state) |s| {
        const spectrum = s.current_spectrum orelse return;
        if (spectrum.mz.len == 0) return;

        var rc: w32.RECT = undefined;
        _ = w32.GetClientRect(hwnd, &rc);
        const margin = 60;
        const plot_left = margin;
        const plot_right = rc.right - margin;
        const plot_top = margin;
        const plot_bottom = rc.bottom - margin;
        const plot_w = plot_right - plot_left;
        _ = plot_bottom - plot_top;

        if (x <= margin or x >= rc.right - margin or y <= margin or y >= rc.bottom - margin) return;

        const x_min = s.zoom.mz_min;
        const x_max = s.zoom.mz_max;
        const x_range = if (x_max > x_min) x_max - x_min else 1.0;

        // Convert screen X back to m/z
        const click_mz = x_min + (@as(f64, @floatFromInt(x - margin)) / @as(f64, @floatFromInt(plot_w))) * x_range;

        // Binary search for nearest peak
        var nearest_idx: usize = 0;
        var min_diff: f64 = std.math.inf(f64);
        const first_idx = bound(false, spectrum.mz, x_min);
        const last_idx = bound(true, spectrum.mz, x_max);
        for (first_idx..last_idx) |idx| {
            const diff = @abs(spectrum.mz[idx] - click_mz);
            if (diff < min_diff) {
                min_diff = diff;
                nearest_idx = idx;
            }
        }

        // Only select if within reasonable distance (≈ 1% of visible range)
        if (min_diff < x_range * 0.01) {
            g_selected_peak_idx = nearest_idx;
            invalidate(hwnd);
        }
    }
}

fn handleMouseMove(hwnd: w32.HWND, state: ?*app.AppState, wParam: w32.WPARAM, x: u16, y: u16) void {
    _ = wParam;
    if (state) |s| {
        // Set cursor based on position
        const pt: w32.POINT = .{ .x = @intCast(x), .y = @intCast(y) };
        var rc: w32.RECT = undefined;
        _ = w32.GetClientRect(hwnd, &rc);
        const margin = 60;
        if (pt.x > margin and pt.x < rc.right - margin and pt.y > margin and pt.y < rc.bottom - margin) {
            _ = w32.SetCursor(w32.LoadCursorW(null, @ptrFromInt(@as(usize, @intCast(w32.IDC_CROSS)))));
        } else {
            _ = w32.SetCursor(w32.LoadCursorW(null, @ptrFromInt(@as(usize, @intCast(w32.IDC_ARROW)))));
        }
        _ = s;
    }
}

fn handleMouseWheel(hwnd: w32.HWND, state: *app.AppState, wParam: w32.WPARAM, lParam: w32.LPARAM) void {
    const delta = @as(i32, @as(i16, @bitCast(@as(u16, @intCast(wParam >> 16)))));
    const keys = @as(u16, @truncate(wParam));
    const screen_pt = w32.POINT{ .x = @as(i32, @intCast(lParam & 0xFFFF)), .y = @as(i32, @intCast((lParam >> 16) & 0xFFFF)) };
    const spectrum = state.current_spectrum orelse return;
    if (spectrum.mz.len == 0) return;

    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    const margin = 60;
    const plot_left = margin;
    const plot_right = rc.right - margin;
    const plot_w = plot_right - plot_left;
    if (plot_w <= 0) return;

    // Convert screen point to client coordinates
    var pt = screen_pt;
    _ = w32.ScreenToClient(hwnd, &pt);

    const x_range = state.zoom.mzSpan();

    if (keys & 0x0004 != 0) { // MK_SHIFT — pan left/right
        const pan_factor = @divTrunc(-delta, @as(i32, w32.WHEEL_DELTA));
        state.zoom.panBy(x_range * -@as(f64, @floatFromInt(pan_factor)) * 0.1);
    } else {
        // Zoom centered on cursor position
        if (pt.x >= plot_left and pt.x <= plot_right) {
            const click_mz = state.zoom.mz_min + (@as(f64, @floatFromInt(pt.x - plot_left)) / @as(f64, @floatFromInt(plot_w))) * x_range;
            const factor: f64 = if (delta > 0) 0.85 else 1.18;
            state.zoom.zoomAround(click_mz, factor);
        } else {
            const factor: f64 = if (delta > 0) 0.85 else 1.18;
            const center_mz = (state.zoom.mz_min + state.zoom.mz_max) / 2.0;
            state.zoom.zoomAround(center_mz, factor);
        }
    }
    invalidate(hwnd);
}

fn handleMouseUp(hwnd: w32.HWND, state: ?*app.AppState) void {
    g_dragging = false;
    if (state) |s| {
        _ = s;
    }
    _ = hwnd;
}
