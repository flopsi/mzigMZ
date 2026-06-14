const std = @import("std");
const w32 = @import("win32_common");
const app = @import("app_state");

// Control IDs
const IDB_FILTER_ALL = 2001;
const IDB_FILTER_MS1 = 2002;
const IDB_FILTER_MS2 = 2003;
const IDB_NAV_PREV = 2004;
const IDB_NAV_NEXT = 2005;
const IDC_SCAN_EDIT = 2006;

const BUTTON_HEIGHT = 24;
const NAV_BUTTON_WIDTH = 30;
const SCAN_EDIT_WIDTH = 60;
const CONTROL_GAP = 4;
const FILTER_BUTTON_WIDTH = 58;
const FILTER_BUTTON_SPACING = 60;

// ============================================================
// Helpers
// ============================================================

fn packetTypeName(ptype: u32) [:0]const u16 {
    return switch (ptype) {
        0 => w32.utf8_to_utf16("Prof"),
        1 => w32.utf8_to_utf16("LowRes"),
        2 => w32.utf8_to_utf16("HighRes"),
        4 => w32.utf8_to_utf16("LT-Prof"),
        5 => w32.utf8_to_utf16("LT-Cent"),
        20 => w32.utf8_to_utf16("FT-Cent"),
        21 => w32.utf8_to_utf16("FT-Prof"),
        22 => w32.utf8_to_utf16("HR-Comp"),
        23 => w32.utf8_to_utf16("LR-Comp"),
        24 => w32.utf8_to_utf16("LR-Type"),
        else => w32.utf8_to_utf16("?"),
    };
}

// ============================================================
// Public API
// ============================================================

var g_filter_buttons: [3]w32.HWND = .{ null, null, null };
var g_nav_prev_btn: w32.HWND = null;
var g_nav_next_btn: w32.HWND = null;
var g_scan_edit: w32.HWND = null;
var g_list_hwnd: w32.HWND = null;
var g_parent_hwnd: w32.HWND = null;

// When true, suppress LVN_ITEMCHANGED loadScan to avoid double-loading
// (the caller already loaded the scan before programmatically selecting it).
var g_selecting_programmatically: bool = false;

// Starting X position for filter buttons (after nav controls)
fn filterButtonsStartX() c_int {
    return NAV_BUTTON_WIDTH + CONTROL_GAP + SCAN_EDIT_WIDTH + CONTROL_GAP + NAV_BUTTON_WIDTH + CONTROL_GAP * 3;
}

pub const CreateError = error{
    CreateFailed,
};

pub fn create(parent: w32.HWND, hInstance: w32.HINSTANCE, id: c_int) CreateError!w32.HWND {
    g_parent_hwnd = parent;

    // Row 1: Navigation controls (Prev, Scan#, Next) then Filter buttons
    var x: c_int = 0;

    g_nav_prev_btn = w32.CreateWindowExW(
        0,
        w32.utf8_to_utf16_z("BUTTON"),
        w32.utf8_to_utf16_z("<"),
        w32.WS_CHILD | w32.WS_VISIBLE | w32.BS_PUSHBUTTON,
        x,
        0,
        NAV_BUTTON_WIDTH,
        BUTTON_HEIGHT,
        parent,
        @ptrFromInt(@as(usize, @intCast(IDB_NAV_PREV))),
        hInstance,
        null,
    );
    x += NAV_BUTTON_WIDTH + CONTROL_GAP;

    g_scan_edit = w32.CreateWindowExW(
        w32.WS_EX_CLIENTEDGE,
        w32.utf8_to_utf16_z("EDIT"),
        w32.utf8_to_utf16_z(""),
        w32.WS_CHILD | w32.WS_VISIBLE | w32.ES_NUMBER | w32.ES_AUTOHSCROLL,
        x,
        0,
        SCAN_EDIT_WIDTH,
        BUTTON_HEIGHT,
        parent,
        @ptrFromInt(@as(usize, @intCast(IDC_SCAN_EDIT))),
        hInstance,
        null,
    );
    x += SCAN_EDIT_WIDTH + CONTROL_GAP;

    g_nav_next_btn = w32.CreateWindowExW(
        0,
        w32.utf8_to_utf16_z("BUTTON"),
        w32.utf8_to_utf16_z(">"),
        w32.WS_CHILD | w32.WS_VISIBLE | w32.BS_PUSHBUTTON,
        x,
        0,
        NAV_BUTTON_WIDTH,
        BUTTON_HEIGHT,
        parent,
        @ptrFromInt(@as(usize, @intCast(IDB_NAV_NEXT))),
        hInstance,
        null,
    );
    x += NAV_BUTTON_WIDTH + CONTROL_GAP * 3;

    // Filter buttons (radio-button style for visual state)
    const btn_labels = .{ "All", "MS1", "MS2" };
    const btn_ids = .{ IDB_FILTER_ALL, IDB_FILTER_MS1, IDB_FILTER_MS2 };
    inline for (btn_labels, btn_ids, 0..) |label, bid, i| {
        const btn_hwnd = w32.CreateWindowExW(
            0,
            w32.utf8_to_utf16_z("BUTTON"),
            w32.utf8_to_utf16_z(label),
            w32.WS_CHILD | w32.WS_VISIBLE | w32.BS_AUTORADIOBUTTON,
            x + @as(c_int, @intCast(i * FILTER_BUTTON_SPACING)),
            0,
            FILTER_BUTTON_WIDTH,
            BUTTON_HEIGHT,
            parent,
            @ptrFromInt(@as(usize, @intCast(bid))),
            hInstance,
            null,
        );
        g_filter_buttons[i] = btn_hwnd;
    }

    const hwnd = w32.CreateWindowExW(
        w32.WS_EX_CLIENTEDGE,
        w32.utf8_to_utf16_z("SysListView32"),
        w32.utf8_to_utf16_z(""),
        w32.WS_CHILD | w32.WS_VISIBLE | w32.WS_CLIPSIBLINGS | w32.LVS_REPORT | w32.LVS_SINGLESEL | w32.LVS_SHOWSELALWAYS | w32.LVS_OWNERDATA,
        0,
        BUTTON_HEIGHT,
        0,
        0,
        parent,
        @ptrFromInt(@as(usize, @intCast(id))),
        hInstance,
        null,
    ) orelse return error.CreateFailed;
    g_list_hwnd = hwnd;

    _ = w32.list_view_set_extended_list_view_style(hwnd, w32.LVS_EX_FULLROWSELECT | w32.LVS_EX_GRIDLINES);

    const col_names = .{ "Scan", "MS", "Type", "z", "Precursor", "Peaks", "Size" };
    const col_widths = .{ 60, 35, 50, 30, 80, 55, 55 };
    const col_fmts = .{ w32.LVCFMT_RIGHT, w32.LVCFMT_CENTER, w32.LVCFMT_CENTER, w32.LVCFMT_CENTER, w32.LVCFMT_RIGHT, w32.LVCFMT_RIGHT, w32.LVCFMT_RIGHT };

    inline for (col_names, col_widths, col_fmts, 0..) |name, width, fmt, i| {
        const name16 = w32.utf8_to_utf16(name);
        var col: w32.LVCOLUMNW = .{
            .mask = w32.LVCF_FMT | w32.LVCF_WIDTH | w32.LVCF_TEXT,
            .fmt = fmt,
            .cx = width,
            .pszText = @ptrCast(@constCast(name16.ptr)),
            .cchTextMax = @intCast(name16.len),
            .iSubItem = @intCast(i),
            .iImage = 0,
            .iOrder = 0,
            .cxMin = 0,
            .cxDefault = 0,
            .cxIdeal = 0,
        };
        _ = w32.list_view_insert_column(hwnd, @intCast(i), &col);
    }

    return hwnd;
}

/// Set the visual state of filter buttons to match current filter
fn syncFilterButtons(level: ?u8) void {
    inline for (0..3) |i| {
        if (g_filter_buttons[i]) |btn| {
            const check: w32.WPARAM = if ((i == 0 and level == null) or
                (i == 1 and level == 1) or
                (i == 2 and level == 2)) 1 else 0;
            _ = w32.SendMessageW(btn, 0x00F3, check, 0); // BM_SETCHECK
        }
    }
}

/// Build the filtered index mapping and set virtual item count.
/// This is O(n) but only allocates one array, no Win32 calls per item.
pub fn populate(hwnd: w32.HWND, state: *app.AppState) void {
    // Free old filtered index if any
    if (state.filtered_indices) |fi| {
        state.allocator.free(fi);
        state.filtered_indices = null;
    }

    // Sync button visual state with filter
    syncFilterButtons(state.view.filter_ms_level);

    if (state.file.scans.len == 0) {
        _ = w32.list_view_set_item_count(hwnd, 0);
        updateScanEdit(state);
        return;
    }

    // Count filtered items
    var filtered_count: usize = 0;
    for (state.file.scans) |scan| {
        if (state.view.filter_ms_level) |level| {
            if (scan.ms_level != level) continue;
        }
        filtered_count += 1;
    }

    // Build filtered index mapping
    if (filtered_count > 0) {
        const indices = state.allocator.alloc(usize, filtered_count) catch {
            _ = w32.list_view_set_item_count(hwnd, 0);
            return;
        };
        var idx: usize = 0;
        for (state.file.scans, 0..) |scan, i| {
            if (state.view.filter_ms_level) |level| {
                if (scan.ms_level != level) continue;
            }
            indices[idx] = i;
            idx += 1;
        }
        state.filtered_indices = indices;
    }

    // Set virtual count - the ListView now knows how many rows there are
    // but doesn't store any data. It will ask via LVN_GETDISPINFO.
    _ = w32.list_view_set_item_count(hwnd, @intCast(filtered_count));
    updateScanEdit(state);
}

/// Update the scan number edit field to show current scan
fn updateScanEdit(state: *app.AppState) void {
    if (g_scan_edit == null) return;
    if (state.file.scans.len == 0) {
        _ = w32.SendMessageW(g_scan_edit, w32.WM_SETTEXT, 0, @intCast(@intFromPtr(w32.utf8_to_utf16("").ptr)));
        return;
    }
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{d}", .{state.file.scans[state.current_scan_index].scan_number}) catch "";
    var buf16: [32]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf16, text) catch 0;
    buf16[len] = 0;
    _ = w32.SendMessageW(g_scan_edit, w32.WM_SETTEXT, 0, @intCast(@intFromPtr(&buf16)));
}

/// Read scan number from edit field and navigate to it
pub fn handle_scan_edit_enter(state: *app.AppState) void {
    if (g_scan_edit == null or state.file.scans.len == 0) return;
    var buf16: [32]u16 = undefined;
    const len = w32.SendMessageW(g_scan_edit, w32.WM_GETTEXT, 32, @intCast(@intFromPtr(&buf16)));
    if (len <= 0) return;
    var utf8_buf: [64]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, buf16[0..@intCast(len)]) catch return;
    const target_scan_num = std.fmt.parseInt(i32, utf8_buf[0..utf8_len], 10) catch return;

    // Find scan with matching scan number
    for (state.file.scans, 0..) |scan, i| {
        if (scan.scan_number == target_scan_num) {
            // Check if scan is visible under current filter
            const is_visible = if (state.filtered_indices) |fi| blk: {
                for (fi) |idx| {
                    if (idx == i) break :blk true;
                }
                break :blk false;
            } else true;
            if (!is_visible) {
                // Auto-switch to "All" filter to show the requested scan
                state.set_ms_level_filter(null);
                if (g_list_hwnd) |list| {
                    populate(list, state);
                    syncFilterButtons(null);
                }
            }
            navigateToScanIndex(state, i);
            return;
        }
    }
}

pub fn select_scan(hwnd: w32.HWND, scan_index: usize) void {
    g_selecting_programmatically = true;
    defer g_selecting_programmatically = false;

    // In virtual mode, the item index is the position in the filtered list.
    // We need to find which filtered position corresponds to this scan index.
    const state = app.get_global_state() orelse {
        _ = w32.list_view_set_item_state(hwnd, @intCast(scan_index), w32.LVIS_SELECTED, w32.LVIS_SELECTED);
        _ = w32.list_view_ensure_visible(hwnd, @intCast(scan_index), 0);
        return;
    };
    if (state.filtered_indices) |fi| {
        for (fi, 0..) |idx, i| {
            if (idx == scan_index) {
                _ = w32.list_view_set_item_state(hwnd, @intCast(i), w32.LVIS_SELECTED, w32.LVIS_SELECTED);
                _ = w32.list_view_ensure_visible(hwnd, @intCast(i), 0);
                updateScanEdit(state);
                return;
            }
        }
    }
    // Fallback: direct index
    _ = w32.list_view_set_item_state(hwnd, @intCast(scan_index), w32.LVIS_SELECTED, w32.LVIS_SELECTED);
    _ = w32.list_view_ensure_visible(hwnd, @intCast(scan_index), 0);
    updateScanEdit(state);
}

pub fn get_selected_scan_index(hwnd: w32.HWND) ?usize {
    const sel = w32.list_view_get_next_item(hwnd, -1, w32.LVNI_SELECTED);
    if (sel < 0) return null;
    const state = app.get_global_state() orelse return @intCast(sel);
    if (state.filtered_indices) |fi| {
        const idx: usize = @intCast(sel);
        if (idx < fi.len) return fi[idx];
    }
    return @intCast(sel);
}

/// Navigate to a specific scan index (updates state, list selection, canvas)
fn navigateToScanIndex(state: *app.AppState, scan_index: usize) void {
    if (scan_index >= state.file.scans.len) return;
    state.load_scan(scan_index) catch {};
    state.current_scan_index = scan_index;
    if (g_list_hwnd) |list| {
        select_scan(list, scan_index);
    }
    // Notify parent to update canvas and title
    if (g_parent_hwnd) |parent| {
        const canvas = w32.GetDlgItem(parent, 101) orelse return;
        _ = w32.InvalidateRect(canvas, null, 0);
        // Also invalidate chromatogram canvas if visible
        const chroma = w32.GetDlgItem(parent, 102);
        if (chroma) |cv| _ = w32.InvalidateRect(cv, null, 0);
    }
}

/// Handle LVN_GETDISPINFO for virtual list view.
/// The ListView asks for text for only the visible rows.
pub fn handle_get_disp_info(pnmh: *w32.NMHDR) void {
    const pdi = @as(*w32.NMLVDISPINFOW, @ptrCast(pnmh));
    const state = app.get_global_state() orelse return;
    if (state.file.scans.len == 0) return;

    const item_idx: usize = @intCast(pdi.item.iItem);
    const scan_idx = if (state.filtered_indices) |fi| blk: {
        if (item_idx >= fi.len) return;
        break :blk fi[item_idx];
    } else item_idx;

    if (scan_idx >= state.file.scans.len) return;
    const scan = state.file.scans[scan_idx];

    const pszText = pdi.item.pszText orelse return;
    const max_chars: usize = @intCast(pdi.item.cchTextMax);
    if (max_chars < 1) return;
    const max_write = max_chars - 1;

    var buf: [128]u8 = undefined;

    switch (pdi.item.iSubItem) {
        0 => { // Scan number
            const text = std.fmt.bufPrintZ(&buf, "{d}", .{scan.scan_number}) catch "0";
            const len = @min(text.len, max_write);
            for (0..len) |i| pszText[i] = text[i];
            pszText[len] = 0;
        },
        1 => { // MS level
            const text = std.fmt.bufPrintZ(&buf, "{d}", .{scan.ms_level}) catch "?";
            const len = @min(text.len, max_write);
            for (0..len) |i| pszText[i] = text[i];
            pszText[len] = 0;
        },
        2 => { // Type
            const type16 = packetTypeName(scan.packet_type);
            const len = @min(type16.len, max_write);
            for (0..len) |i| pszText[i] = type16[i];
            pszText[len] = 0;
        },
        3 => { // Charge
            const text = if (scan.charge_state > 0)
                std.fmt.bufPrintZ(&buf, "{d}", .{scan.charge_state}) catch "?"
            else
                "-";
            const len = @min(text.len, max_write);
            for (0..len) |i| pszText[i] = text[i];
            pszText[len] = 0;
        },
        4 => { // Precursor m/z
            const text = if (scan.precursor_mz > 0)
                std.fmt.bufPrintZ(&buf, "{d:.2}", .{scan.precursor_mz}) catch "?"
            else
                "-";
            const len = @min(text.len, max_write);
            for (0..len) |i| pszText[i] = text[i];
            pszText[len] = 0;
        },
        5 => { // Peaks
            const text = if (scan.peak_count > 0)
                std.fmt.bufPrintZ(&buf, "{d}", .{scan.peak_count}) catch "0"
            else
                "-";
            const len = @min(text.len, max_write);
            for (0..len) |i| pszText[i] = text[i];
            pszText[len] = 0;
        },
        6 => { // Size
            const text = std.fmt.bufPrintZ(&buf, "{d}", .{scan.data_size}) catch "0";
            const len = @min(text.len, max_write);
            for (0..len) |i| pszText[i] = text[i];
            pszText[len] = 0;
        },
        else => {},
    }
}

pub fn handle_notify(pnmh: *w32.NMHDR, state: *app.AppState) void {
    switch (pnmh.code) {
        w32.LVN_ITEMCHANGED => {
            if (g_selecting_programmatically) return;
            if (get_selected_scan_index(pnmh.hwndFrom)) |sel_idx| {
                state.load_scan(sel_idx) catch {};
                state.current_scan_index = sel_idx;
                updateScanEdit(state);
                // Notify canvas to redraw
                const parent = w32.GetParent(pnmh.hwndFrom) orelse return;
                const canvas = w32.GetDlgItem(parent, 101) orelse return;
                _ = w32.InvalidateRect(canvas, null, 0);
            }
        },
        w32.LVN_GETDISPINFO => {
            handle_get_disp_info(pnmh);
        },
        else => {},
    }
}

pub fn resize(hwnd: w32.HWND, width: c_int, height: c_int) void {
    // Position nav buttons and edit field
    var x: c_int = 0;
    if (g_nav_prev_btn) |btn| {
        _ = w32.MoveWindow(btn, x, 0, NAV_BUTTON_WIDTH, BUTTON_HEIGHT, 1);
    }
    x += NAV_BUTTON_WIDTH + CONTROL_GAP;

    if (g_scan_edit) |edit| {
        _ = w32.MoveWindow(edit, x, 0, SCAN_EDIT_WIDTH, BUTTON_HEIGHT, 1);
    }
    x += SCAN_EDIT_WIDTH + CONTROL_GAP;

    if (g_nav_next_btn) |btn| {
        _ = w32.MoveWindow(btn, x, 0, NAV_BUTTON_WIDTH, BUTTON_HEIGHT, 1);
    }
    x += NAV_BUTTON_WIDTH + CONTROL_GAP * 3;

    // Position filter buttons
    inline for (0..3) |i| {
        if (g_filter_buttons[i]) |btn| {
            _ = w32.MoveWindow(btn, x + @as(c_int, @intCast(i * FILTER_BUTTON_SPACING)), 0, FILTER_BUTTON_WIDTH, BUTTON_HEIGHT, 1);
        }
    }

    // Listview below buttons
    _ = w32.MoveWindow(hwnd, 0, BUTTON_HEIGHT, width, height - BUTTON_HEIGHT, 1);
}

pub fn handle_filter_command(state: *app.AppState, cmd_id: u16, parent: w32.HWND) void {
    const level: ?u8 = switch (cmd_id) {
        IDB_FILTER_ALL => null,
        IDB_FILTER_MS1 => 1,
        IDB_FILTER_MS2 => 2,
        else => return,
    };
    state.set_ms_level_filter(level);
    // Also update chromatogram filter to match scan filter
    state.set_chromatogram_ms_level_filter(level);
    // Update button states
    syncFilterButtons(level);
    // Repopulate list
    if (g_list_hwnd) |list| {
        populate(list, state);
        // Select first visible scan under the new filter
        if (state.filtered_indices) |fi| {
            if (fi.len > 0) {
                const first_visible = fi[0];
                select_scan(list, first_visible);
                state.load_scan(first_visible) catch {};
                state.current_scan_index = first_visible;
            }
        } else if (state.file.scans.len > 0) {
            select_scan(list, 0);
            state.load_scan(0) catch {};
            state.current_scan_index = 0;
        }
        // Invalidate spectrum canvas
        const canvas = w32.GetDlgItem(parent, 101) orelse return;
        _ = w32.InvalidateRect(canvas, null, 0);
        // Also invalidate chromatogram canvas
        const chroma = w32.GetDlgItem(parent, 102) orelse return;
        _ = w32.InvalidateRect(chroma, null, 0);
    }
}

/// Find the next/previous visible scan index under the current filter.
fn findNextVisibleScan(state: *app.AppState, direction: i32) ?usize {
    if (state.filtered_indices) |fi| {
        // Find current position in filtered list
        var current_filtered_pos: ?usize = null;
        for (fi, 0..) |idx, i| {
            if (idx == state.current_scan_index) {
                current_filtered_pos = i;
                break;
            }
        }
        const pos = current_filtered_pos orelse return null;
        const new_pos = if (direction > 0)
            pos + 1
        else if (pos > 0)
            pos - 1
        else
            return null;
        if (new_pos >= fi.len) return null;
        return fi[new_pos];
    } else {
        // No filter - navigate through full list
        if (direction > 0) {
            if (state.current_scan_index + 1 < state.file.scans.len) {
                return state.current_scan_index + 1;
            }
        } else {
            if (state.current_scan_index > 0) {
                return state.current_scan_index - 1;
            }
        }
        return null;
    }
}

pub fn handle_nav_command(state: *app.AppState, cmd_id: u16) void {
    switch (cmd_id) {
        IDB_NAV_PREV => {
            if (findNextVisibleScan(state, -1)) |idx| {
                navigateToScanIndex(state, idx);
            }
        },
        IDB_NAV_NEXT => {
            if (findNextVisibleScan(state, 1)) |idx| {
                navigateToScanIndex(state, idx);
            }
        },
        else => {},
    }
}

/// Get the scan edit control HWND (for focus checking in main_window)
pub fn get_scan_edit_hwnd() w32.HWND {
    return g_scan_edit;
}
