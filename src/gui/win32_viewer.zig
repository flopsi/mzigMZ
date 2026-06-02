const std = @import("std");
const advanced = @import("advanced_packet");
const w32 = @import("win32_common");

const CLASS_NAME = w32.utf8ToUtf16("SpectrumViewer");
var g_spectrum: ?*const advanced.Spectrum = null;
var g_spectrum_max: f64 = 0.0;

pub fn run(spectrum: *const advanced.Spectrum) !void {
    const hInstance = w32.GetModuleHandleW(null) orelse return error.NoModule;
    g_spectrum = spectrum;
    g_spectrum_max = 0;
    for (spectrum.intensity) |inten| {
        if (inten > g_spectrum_max) g_spectrum_max = inten;
    }

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, @ptrFromInt(w32.IDC_ARROW)),
        .hbrBackground = @ptrCast(w32.GetStockObject(w32.WHITE_BRUSH)),
        .lpszMenuName = null,
        .lpszClassName = w32.utf8ToUtf16Z("SpectrumViewer"),
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.ClassRegisterFailed;

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME.ptr,
        w32.utf8ToUtf16Z("Spectrum Viewer"),
        w32.WS_OVERLAPPEDWINDOW | w32.WS_VISIBLE,
        w32.CW_USEDEFAULT, w32.CW_USEDEFAULT,
        800, 600,
        null, null, @ptrCast(hInstance), null,
    ) orelse return error.CreateWindowFailed;

    _ = hwnd;

    var msg: w32.MSG = undefined;
    while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

fn wndProc(hwnd: w32.HWND, msg: w32.UINT, wParam: w32.WPARAM, lParam: w32.LPARAM) callconv(.c) w32.LRESULT {
    switch (msg) {
        w32.WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        w32.WM_DESTROY => {
            w32.PostQuitMessage(0);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn paint(hwnd: w32.HWND) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    _ = w32.FillRect(hdc, &rc, @ptrCast(w32.GetStockObject(w32.WHITE_BRUSH)));

    const spectrum = g_spectrum orelse return;
    const margin = 60;
    const plot_left = margin;
    const plot_right = rc.right - margin;
    const plot_top = margin;
    const plot_bottom = rc.bottom - margin;
    const plot_width = plot_right - plot_left;
    const plot_height = plot_bottom - plot_top;

    if (plot_width <= 0 or plot_height <= 0 or spectrum.mz.len == 0) return;

    const x_min = spectrum.mz[0];
    const x_max = blk: {
        var xm = spectrum.mz[0];
        for (spectrum.mz[1..]) |m| {
            if (m > xm) xm = m;
        }
        break :blk xm;
    };
    const x_range = if (x_max > x_min) x_max - x_min else 1;

    drawSpectrum(hdc, spectrum, plot_left, plot_top, plot_width, plot_height, x_min, x_range);
    drawLabel(hdc, w32.utf8ToUtf16Z("m/z"), plot_left + @divTrunc(plot_width, 2) - 20, plot_bottom + 10);
    drawLabel(hdc, w32.utf8ToUtf16Z("Intensity"), 5, plot_top - 10);
}

fn drawSpectrum(
    hdc: w32.HDC,
    spectrum: *const advanced.Spectrum,
    plot_left: w32.LONG,
    plot_top: w32.LONG,
    plot_width: w32.LONG,
    plot_height: w32.LONG,
    x_min: f64,
    x_range: f64,
) void {
    const y_max = if (g_spectrum_max > 0) g_spectrum_max else 1;
    const pen = w32.CreatePen(w32.PS_SOLID, 1, w32.rgb(0, 0, 255)) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(pen));
    const old = w32.SelectObject(hdc, @ptrCast(pen));
    defer _ = w32.SelectObject(hdc, old);

    for (spectrum.mz, spectrum.intensity) |m, inten| {
        const x = plot_left + @as(w32.LONG, @intFromFloat((m - x_min) / x_range * @as(f64, @floatFromInt(plot_width))));
        const y = plot_top + plot_height - @as(w32.LONG, @intFromFloat((inten / y_max) * @as(f64, @floatFromInt(plot_height))));
        _ = w32.MoveToEx(hdc, x, plot_top + plot_height, null);
        _ = w32.LineTo(hdc, x, y);
    }
}

fn drawLabel(hdc: w32.HDC, text: [*:0]const u16, x: w32.LONG, y: w32.LONG) void {
    _ = w32.TextOutW(hdc, x, y, text, @intCast(std.mem.len(text)));
}
