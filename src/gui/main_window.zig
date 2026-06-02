const std = @import("std");
const w32 = @import("win32_common");
const app = @import("app_state");
const scan_list = @import("scan_list");
const spectrum_canvas = @import("spectrum_canvas");
const file_dialog = @import("file_dialog");
const chromatogram_canvas = @import("chromatogram_canvas");

const IDC_SCAN_LIST = 100;
const IDC_SPECTRUM_CANVAS = 101;
const IDC_CHROMATOGRAM_CANVAS = 102;
const IDC_SPLITTER = 103;
const IDC_STATUS = 104;

const SPLITTER_WIDTH = 4;

// Menu command IDs
const IDM_FILE_OPEN = 1001;
const IDM_FILE_EXIT = 1002;
const IDM_NAV_PREV = 1101;
const IDM_NAV_NEXT = 1102;
const IDM_NAV_FIRST = 1103;
const IDM_NAV_LAST = 1104;
const IDM_VIEW_STICK = 1201;
const IDM_VIEW_LINE = 1202;
const IDM_VIEW_SPECTRUM = 1203;
const IDM_VIEW_TIC = 1204;
const IDM_VIEW_BPC = 1205;
const IDM_HELP_ABOUT = 1301;
const IDM_PARSE_METADATA = 1401;

const MainView = enum {
    spectrum,
    tic,
    bpc,
};

const CLASS_NAME = "RawMSIMainWindow";
const SPLITTER_CLASS = "SplitterBar";

var g_instance: ?w32.HINSTANCE = null;
var g_hwnd: ?w32.HWND = null;
var g_scan_list_hwnd: ?w32.HWND = null;
var g_canvas_hwnd: ?w32.HWND = null;
var g_chromatogram_hwnd: ?w32.HWND = null;
var g_menu: ?w32.HMENU = null;
var g_main_view: MainView = .spectrum;

// Splitter
var g_splitter_x: i32 = 360;
var g_splitter_hwnd: ?w32.HWND = null;
var g_splitter_dragging: bool = false;

// Status bar
var g_status_hwnd: ?w32.HWND = null;

pub fn run(state: *app.AppState) !void {
    app.setGlobalState(state);

    // Initialize common controls
    var icc: w32.INITCOMMONCONTROLSEX = undefined;
    icc.dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX);
    icc.dwICC = w32.ICC_LISTVIEW_CLASSES | w32.ICC_BAR_CLASSES;
    _ = w32.InitCommonControlsEx(&icc);

    const hInstance = w32.GetModuleHandleW(null);

    // Register splitter class
    var swc: w32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW | w32.CS_DBLCLKS,
        .lpfnWndProc = splitterWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, @ptrFromInt(@as(usize, @intCast(w32.IDC_SIZEWE)))),
        .hbrBackground = @ptrCast(w32.GetStockObject(w32.LTGRAY_BRUSH)),
        .lpszMenuName = null,
        .lpszClassName = w32.utf8ToUtf16Z(SPLITTER_CLASS),
        .hIconSm = null,
    };
    _ = w32.RegisterClassExW(&swc);

    const hwnd = try create(hInstance, state);
    show(hwnd);
    runMessageLoop(state);
}

pub fn create(hInstance: w32.HINSTANCE, state: *app.AppState) !w32.HWND {
    const class_name = w32.utf8ToUtf16Z(CLASS_NAME);

    var wc: w32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = mainWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, @ptrFromInt(@as(usize, @intCast(w32.IDC_ARROW)))),
        .hbrBackground = @ptrCast(w32.GetStockObject(w32.COLOR_BTNFACE + 1)),
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    g_instance = hInstance;

    g_menu = createMenu();

    const hwnd = w32.CreateWindowExW(
        0,
        class_name,
        w32.utf8ToUtf16Z("RawMSI"),
        w32.WS_OVERLAPPEDWINDOW,
        w32.CW_USEDEFAULT, w32.CW_USEDEFAULT,
        1200, 800,
        null, g_menu orelse null, hInstance, null,
    ) orelse return error.CreateWindowFailed;

    g_hwnd = hwnd;

    // Create child controls
    g_scan_list_hwnd = try scan_list.create(hwnd, hInstance, IDC_SCAN_LIST);
    g_canvas_hwnd = spectrum_canvas.create(hwnd, hInstance, IDC_SPECTRUM_CANVAS) catch null;
    g_chromatogram_hwnd = chromatogram_canvas.create(hwnd, hInstance, IDC_CHROMATOGRAM_CANVAS) catch null;

    // Create splitter bar
    g_splitter_hwnd = w32.CreateWindowExW(
        0,
        w32.utf8ToUtf16Z(SPLITTER_CLASS),
        w32.utf8ToUtf16Z(""),
        w32.WS_CHILD | w32.WS_VISIBLE | w32.WS_CLIPSIBLINGS,
        g_splitter_x, 0, SPLITTER_WIDTH, 100,
        hwnd, @ptrFromInt(@as(usize, @intCast(IDC_SPLITTER))), hInstance, null,
    );

    // Create status bar
    g_status_hwnd = w32.CreateStatusWindowW(0, w32.utf8ToUtf16Z("Ready"), hwnd, IDC_STATUS);
    if (g_status_hwnd) |sb| {
        // Set 3 parts: file info, scan count, current scan info
        const parts = [_]i32{ 350, 500, -1 };
        _ = w32.SendMessageW(sb, w32.SB_SETPARTS, 3, @intCast(@intFromPtr(&parts)));
    }

    // Store state pointer on main window and canvases
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @as(isize, @bitCast(@intFromPtr(state))));
    if (g_canvas_hwnd) |cv| {
        _ = w32.SetWindowLongPtrW(cv, w32.GWLP_USERDATA, @as(isize, @bitCast(@intFromPtr(state))));
    }
    if (g_chromatogram_hwnd) |cv| {
        chromatogram_canvas.setState(cv, state);
    }

    updateTitle(hwnd, state);
    syncViewMenu();

    // Populate scan list if file is already open
    if (state.scans.len > 0) {
        if (g_scan_list_hwnd) |sl| {
            scan_list.populate(sl, state);
        }
    }

    return hwnd;
}

pub fn show(hwnd: w32.HWND) void {
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWDEFAULT);
    _ = w32.UpdateWindow(hwnd);
}

pub fn runMessageLoop(state: *app.AppState) void {
    var msg: w32.MSG = undefined;
    while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
    _ = state;
}

fn mainWndProc(hwnd: w32.HWND, msg: w32.UINT, wParam: w32.WPARAM, lParam: w32.LPARAM) callconv(.c) w32.LRESULT {
    const state = getState(hwnd);

    switch (msg) {
        w32.WM_SIZE => {
            if (state) |s| layoutChildren(hwnd, s);
            return 0;
        },
        w32.WM_COMMAND => {
            const id = w32.LOWORD(@as(w32.LPARAM, @intCast(wParam)));
            if (id >= 2001 and id <= 2003) {
                if (state) |s| scan_list.handleFilterCommand(s, id, hwnd);
            } else if (id == 2004 or id == 2005) {
                if (state) |s| scan_list.handleNavCommand(s, id);
            } else if (id == 2006) {
                // Scan edit control - handle Enter key via WM_KEYDOWN (see below),
                // but also update on focus loss
                const notify_code = w32.HIWORD(@as(w32.LPARAM, @intCast(wParam)));
                if (notify_code == w32.EN_KILLFOCUS) {
                    if (state) |s| scan_list.handleScanEditEnter(s);
                }
            } else {
                handleCommand(hwnd, state, wParam);
            }
            return 0;
        },
        w32.WM_NOTIFY => {
            const pnmh = @as(*w32.NMHDR, @ptrFromInt(@as(usize, @bitCast(lParam))));
            if (pnmh.idFrom == IDC_SCAN_LIST) {
                if (state) |s| scan_list.handleNotify(pnmh, s);
            }
            return 0;
        },
        w32.WM_KEYDOWN => {
            if (state) |s| {
                const vk: u16 = @truncate(wParam);
                // Check if scan edit has focus - handle Enter to navigate
                if (vk == 0x0D) { // VK_RETURN
                    const focus = w32.GetFocus();
                    if (focus == scan_list.getScanEditHwnd()) {
                        scan_list.handleScanEditEnter(s);
                        return 0;
                    }
                }
                handleKeyDown(hwnd, s, vk);
            }
            return 0;
        },
        0x0400 + 1 => { // WM_USER + 1
            // Chromatogram click → switch to spectrum view and navigate to scan
            if (state) |s| {
                const scan_index: usize = @intCast(wParam);
                s.current_scan_index = scan_index;
                switchToView(.spectrum);
                afterScanChange(hwnd, s);
            }
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_DESTROY => {
            w32.PostQuitMessage(0);
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

fn layoutChildren(hwnd: w32.HWND, state: *app.AppState) void {
    _ = state;
    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);

    // Reserve space for status bar at bottom
    const sb_height: i32 = 22;
    const usable_bottom = rc.bottom - sb_height;
    const list_width = g_splitter_x;
    const pad = 4;

    if (g_splitter_hwnd) |sph| {
        _ = w32.MoveWindow(sph, list_width, 0, SPLITTER_WIDTH, usable_bottom, 1);
    }

    if (g_scan_list_hwnd) |sl| {
        scan_list.resize(sl, list_width - pad * 2, usable_bottom - pad * 2);
    }
    if (g_canvas_hwnd) |cv| {
        const canvas_x = list_width + SPLITTER_WIDTH + pad;
        const canvas_w = rc.right - canvas_x - pad;
        _ = w32.MoveWindow(cv, canvas_x, pad, canvas_w, usable_bottom - pad * 2, 1);
    }
    if (g_chromatogram_hwnd) |cv| {
        const canvas_x = list_width + SPLITTER_WIDTH + pad;
        const canvas_w = rc.right - canvas_x - pad;
        _ = w32.MoveWindow(cv, canvas_x, pad, canvas_w, usable_bottom - pad * 2, 1);
    }
}

// ============================================================
// Consolidated Generic Navigation Handler
// ============================================================

fn handleNavScan(hwnd: w32.HWND, state: *app.AppState, nav_fn: *const fn (*app.AppState) anyerror!void) void {
    nav_fn(state) catch {
        showError(hwnd, "Navigation failed");
        return;
    };
    afterScanChange(hwnd, state);
}

fn switchToView(view: MainView) void {
    g_main_view = view;
    switch (view) {
        .spectrum => {
            if (g_canvas_hwnd) |cv| _ = w32.ShowWindow(cv, w32.SW_SHOW);
            if (g_chromatogram_hwnd) |cv| _ = w32.ShowWindow(cv, w32.SW_HIDE);
        },
        .tic => {
            if (g_canvas_hwnd) |cv| _ = w32.ShowWindow(cv, w32.SW_HIDE);
            if (g_chromatogram_hwnd) |cv| {
                // Compute chromatograms on-demand if not already done
                const state = app.getGlobalState();
                if (state) |s| {
                    if (s.tic_chromatogram == null) {
                        s.computeChromatograms();
                    }
                }
                chromatogram_canvas.setChromatogramType(.tic);
                _ = w32.ShowWindow(cv, w32.SW_SHOW);
                chromatogram_canvas.invalidate(cv);
            }
        },
        .bpc => {
            if (g_canvas_hwnd) |cv| _ = w32.ShowWindow(cv, w32.SW_HIDE);
            if (g_chromatogram_hwnd) |cv| {
                // Compute chromatograms on-demand if not already done
                const state = app.getGlobalState();
                if (state) |s| {
                    if (s.bpc_chromatogram == null) {
                        s.computeChromatograms();
                    }
                }
                chromatogram_canvas.setChromatogramType(.bpc);
                _ = w32.ShowWindow(cv, w32.SW_SHOW);
                chromatogram_canvas.invalidate(cv);
            }
        },
    }
    syncViewMenu();
}

fn afterScanChange(hwnd: w32.HWND, state: *app.AppState) void {
    updateTitle(hwnd, state);
    updateStatusBar(state);
    if (g_canvas_hwnd) |cv| {
        spectrum_canvas.invalidate(cv);
    }
    if (g_chromatogram_hwnd) |cv| {
        chromatogram_canvas.invalidate(cv);
    }
    if (g_scan_list_hwnd) |sl| {
        scan_list.selectScan(sl, state.current_scan_index);
    }
}

// ============================================================
// Command Handler
// ============================================================

fn handleCommand(hwnd: w32.HWND, state: ?*app.AppState, wParam: w32.WPARAM) void {
    const id = w32.LOWORD(@as(w32.LPARAM, @intCast(wParam)));
    const s = state orelse return;

    switch (id) {
        IDM_FILE_OPEN => handleFileOpen(hwnd, s),
        IDM_FILE_EXIT => _ = w32.DestroyWindow(hwnd),

        IDM_NAV_PREV => handleNavScan(hwnd, s, app.AppState.goToPreviousScan),
        IDM_NAV_NEXT => handleNavScan(hwnd, s, app.AppState.goToNextScan),
        IDM_NAV_FIRST => handleNavScan(hwnd, s, app.AppState.goToFirstScan),
        IDM_NAV_LAST => handleNavScan(hwnd, s, app.AppState.goToLastScan),

        IDM_VIEW_STICK => {
            s.view_mode = .stick;
            syncViewMenu();
            if (g_canvas_hwnd) |cv| spectrum_canvas.invalidate(cv);
        },
        IDM_VIEW_LINE => {
            s.view_mode = .line;
            syncViewMenu();
            if (g_canvas_hwnd) |cv| spectrum_canvas.invalidate(cv);
        },
        IDM_VIEW_SPECTRUM => switchToView(.spectrum),
        IDM_VIEW_TIC => switchToView(.tic),
        IDM_VIEW_BPC => switchToView(.bpc),

        IDM_PARSE_METADATA => {
            s.parse_peak_metadata = !s.parse_peak_metadata;
            syncViewMenu();
            reloadCurrentScan(s);
        },

        else => {},
    }
}

fn handleFileOpen(hwnd: w32.HWND, state: *app.AppState) void {
    const allocator = std.heap.page_allocator;
    const path = file_dialog.showOpenFileDialog(hwnd, allocator) orelse return;

    state.openFile(path) catch {
        showError(hwnd, "Failed to open file");
        allocator.free(path);
        return;
    };

    // NOTE: Chromatograms and trailers are computed on-demand:
    // - Chromatograms: computed on first View -> TIC/BPC click
    // - Trailers: parsed when scan is selected (ensureScanTrailer)
    // This keeps file open fast and GUI responsive for large files.

    // Load first scan data so the canvas isn't empty
    if (state.scans.len > 0) {
        state.loadScan(0) catch |err| {
            std.debug.print("warning: failed to load first scan: {}\n", .{err});
        };
    }

    if (g_scan_list_hwnd) |sl| {
        scan_list.populate(sl, state);
    }
    updateTitle(hwnd, state);
    updateStatusBar(state);
    if (g_canvas_hwnd) |cv| spectrum_canvas.invalidate(cv);
    if (g_chromatogram_hwnd) |cv| chromatogram_canvas.invalidate(cv);
}

// ============================================================
// Keyboard Navigation
// ============================================================

fn handleKeyDown(hwnd: w32.HWND, state: *app.AppState, vk: u16) void {
    switch (vk) {
        0x25 => handleNavScan(hwnd, state, app.AppState.goToPreviousScan), // VK_LEFT
        0x26 => handleNavScan(hwnd, state, app.AppState.goToNextScan),     // VK_UP
        0x27 => handleNavScan(hwnd, state, app.AppState.goToNextScan),     // VK_RIGHT
        0x28 => handleNavScan(hwnd, state, app.AppState.goToPreviousScan), // VK_DOWN
        0x21 => handleNavScan(hwnd, state, app.AppState.goToPreviousScan), // VK_PRIOR
        0x22 => handleNavScan(hwnd, state, app.AppState.goToNextScan),     // VK_NEXT
        0x24 => handleNavScan(hwnd, state, app.AppState.goToFirstScan),    // VK_HOME
        0x23 => handleNavScan(hwnd, state, app.AppState.goToLastScan),     // VK_END
        else => {},
    }
}

// ============================================================
// Menu
// ============================================================

fn createMenu() ?w32.HMENU {
    const hMenu = w32.CreateMenu() orelse return null;

    // File menu
    const hFile = w32.CreatePopupMenu() orelse return null;
    _ = w32.AppendMenuW(hFile, w32.MF_STRING, IDM_FILE_OPEN, w32.utf8ToUtf16Z("&Open...\tCtrl+O"));
    _ = w32.AppendMenuW(hFile, w32.MF_STRING, IDM_FILE_EXIT, w32.utf8ToUtf16Z("E&xit"));
    _ = w32.AppendMenuW(hMenu, w32.MF_POPUP, @intFromPtr(hFile), w32.utf8ToUtf16Z("&File"));

    // Navigate menu
    const hNav = w32.CreatePopupMenu() orelse return null;
    _ = w32.AppendMenuW(hNav, w32.MF_STRING, IDM_NAV_PREV, w32.utf8ToUtf16Z("&Previous Scan\tPgUp"));
    _ = w32.AppendMenuW(hNav, w32.MF_STRING, IDM_NAV_NEXT, w32.utf8ToUtf16Z("&Next Scan\tPgDn"));
    _ = w32.AppendMenuW(hNav, w32.MF_STRING, IDM_NAV_FIRST, w32.utf8ToUtf16Z("&First Scan\tHome"));
    _ = w32.AppendMenuW(hNav, w32.MF_STRING, IDM_NAV_LAST, w32.utf8ToUtf16Z("&Last Scan\tEnd"));
    _ = w32.AppendMenuW(hMenu, w32.MF_POPUP, @intFromPtr(hNav), w32.utf8ToUtf16Z("&Navigate"));

    // View menu
    const hView = w32.CreatePopupMenu() orelse return null;
    _ = w32.AppendMenuW(hView, w32.MF_STRING, IDM_VIEW_SPECTRUM, w32.utf8ToUtf16Z("&Spectrum"));
    _ = w32.AppendMenuW(hView, w32.MF_STRING, IDM_VIEW_TIC, w32.utf8ToUtf16Z("&TIC Chromatogram"));
    _ = w32.AppendMenuW(hView, w32.MF_STRING, IDM_VIEW_BPC, w32.utf8ToUtf16Z("&BPC Chromatogram"));
    _ = w32.AppendMenuW(hView, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(hView, w32.MF_STRING, IDM_VIEW_STICK, w32.utf8ToUtf16Z("&Stick Plot"));
    _ = w32.AppendMenuW(hView, w32.MF_STRING, IDM_VIEW_LINE, w32.utf8ToUtf16Z("&Line Plot"));
    _ = w32.AppendMenuW(hView, w32.MF_SEPARATOR, 0, null);

    _ = w32.AppendMenuW(hView, w32.MF_STRING, IDM_PARSE_METADATA, w32.utf8ToUtf16Z("Parse &Peak Metadata"));
    _ = w32.AppendMenuW(hMenu, w32.MF_POPUP, @intFromPtr(hView), w32.utf8ToUtf16Z("&View"));

    return hMenu;
}

/// Reload current scan after profile mode or metadata setting changes.
fn reloadCurrentScan(state: *app.AppState) void {
    if (!state.hasFileOpen()) return;
    state.loadScan(state.current_scan_index) catch {};
    if (g_canvas_hwnd) |cv| spectrum_canvas.invalidate(cv);
}

fn syncViewMenu() void {
    const hMenu = g_menu orelse return;
    const state = app.getGlobalState() orelse return;

    _ = w32.CheckMenuItem(hMenu, IDM_PARSE_METADATA, if (state.parse_peak_metadata) w32.MF_CHECKED else w32.MF_UNCHECKED);

    // Spectrum view mode (stick/line)
    switch (g_main_view) {
        .spectrum => {
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_SPECTRUM, w32.MF_CHECKED);
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_TIC, 0);
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_BPC, 0);
        },
        .tic => {
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_SPECTRUM, 0);
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_TIC, w32.MF_CHECKED);
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_BPC, 0);
        },
        .bpc => {
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_SPECTRUM, 0);
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_TIC, 0);
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_BPC, w32.MF_CHECKED);
        },
    }
    // Plot mode (stick/line) — only meaningful in spectrum view but keep state
    switch (state.view_mode) {
        .stick => {
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_STICK, w32.MF_CHECKED);
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_LINE, 0);
        },
        .line => {
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_STICK, 0);
            _ = w32.CheckMenuItem(hMenu, IDM_VIEW_LINE, w32.MF_CHECKED);
        },
    }
}

// ============================================================
// Title
// ============================================================

fn updateTitle(hwnd: w32.HWND, state: *app.AppState) void {
    var buf: [512]u8 = undefined;
    const title = if (state.current_spectrum) |_| blk: {
        const scan = state.scans[state.current_scan_index];
        if (scan.ms_level > 1 and scan.precursor_mz > 0) {
            break :blk std.fmt.bufPrint(&buf, "RawMSI - Scan {d} (MS{d}, {d:.2} m/z, z={d})", .{
                scan.scan_number, scan.ms_level, scan.precursor_mz, scan.charge_state,
            }) catch "RawMSI";
        } else {
            break :blk std.fmt.bufPrint(&buf, "RawMSI - Scan {d} (MS{d})", .{
                scan.scan_number, scan.ms_level,
            }) catch "RawMSI";
        }
    } else
        "RawMSI - No file";
    var buf16: [512]u16 = undefined;
    const title16 = w32.utf8ToUtf16Buf(&buf16, title) catch buf16[0..0];
    buf16[title16.len] = 0;
    _ = w32.SetWindowTextW(hwnd, @as([*:0]u16, @ptrCast(&buf16)));
}

// ============================================================
// Error Display
// ============================================================

fn showError(hwnd: w32.HWND, msg: []const u8) void {
    var buf: [256]u16 = undefined;
    const msg16 = w32.utf8ToUtf16Buf(&buf, msg) catch buf[0..0];
    buf[msg16.len] = 0;
    _ = w32.MessageBoxW(hwnd, @as([*:0]u16, @ptrCast(&buf)), w32.utf8ToUtf16Z("Error"), w32.MB_OK | w32.MB_ICONERROR);
}

// ============================================================
// Splitter Window Proc
// ============================================================

fn splitterWndProc(hwnd: w32.HWND, msg: w32.UINT, wParam: w32.WPARAM, lParam: w32.LPARAM) callconv(.c) w32.LRESULT {
    switch (msg) {
        w32.WM_LBUTTONDOWN => {
            g_splitter_dragging = true;
            _ = w32.SetCapture(hwnd);
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            if (g_splitter_dragging) {
                var pt: w32.POINT = undefined;
                _ = w32.GetCursorPos(&pt);
                const parent = w32.GetParent(hwnd) orelse return 0;
                _ = w32.ScreenToClient(parent, &pt);
                var rc: w32.RECT = undefined;
                _ = w32.GetClientRect(parent, &rc);
                const min_x: i32 = 120;
                const max_x: i32 = rc.right - 200;
                g_splitter_x = @max(min_x, @min(max_x, pt.x));
                if (g_hwnd) |main| {
                    layoutChildren(main, app.getGlobalState() orelse return 0);
                }
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            g_splitter_dragging = false;
            _ = w32.ReleaseCapture();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

// ============================================================
// Status Bar Update
// ============================================================

fn updateStatusBar(state: *app.AppState) void {
    const sb = g_status_hwnd orelse return;
    const allocator = std.heap.page_allocator;

    // Part 0: File path
    const file_text = if (state.file_path) |fp|
        std.fmt.allocPrint(allocator, "  File: {s}", .{fp}) catch return
    else
        allocator.dupe(u8, "  No file open") catch return;
    defer allocator.free(file_text);
    {
        const wide = w32.utf8ToUtf16Alloc(allocator, file_text) catch return;
        defer allocator.free(wide);
        _ = w32.SendMessageW(sb, w32.SB_SETTEXTW, 0, @intCast(@intFromPtr(wide.ptr)));
    }

    // Part 1: Scan count
    const scan_text = std.fmt.allocPrint(allocator, "Scans: {d}", .{state.scans.len}) catch return;
    defer allocator.free(scan_text);
    {
        const wide = w32.utf8ToUtf16Alloc(allocator, scan_text) catch return;
        defer allocator.free(wide);
        _ = w32.SendMessageW(sb, w32.SB_SETTEXTW, 1, @intCast(@intFromPtr(wide.ptr)));
    }

    // Part 2: Current scan info
    if (state.scans.len > 0 and state.current_scan_index < state.scans.len) {
        const scan = state.scans[state.current_scan_index];
        const info = if (scan.ms_level > 1 and scan.precursor_mz > 0)
            std.fmt.allocPrint(allocator, "Scan {d}  |  MS{d}  |  Precursor: {d:.2} m/z", .{
                scan.scan_number, scan.ms_level, scan.precursor_mz,
            }) catch return
        else
            std.fmt.allocPrint(allocator, "Scan {d}  |  MS{d}", .{
                scan.scan_number, scan.ms_level,
            }) catch return;
        defer allocator.free(info);
        {
            const wide = w32.utf8ToUtf16Alloc(allocator, info) catch return;
            defer allocator.free(wide);
            _ = w32.SendMessageW(sb, w32.SB_SETTEXTW, 2, @intCast(@intFromPtr(wide.ptr)));
        }
    } else {
        const wide = w32.utf8ToUtf16Alloc(allocator, "") catch return;
        defer allocator.free(wide);
        _ = w32.SendMessageW(sb, w32.SB_SETTEXTW, 2, @intCast(@intFromPtr(wide.ptr)));
    }
}
