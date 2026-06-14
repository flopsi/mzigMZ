//! mzigRead viewer — imguinz2 (GLFW + OpenGL3) — Strategy A: locked layout
//!
//! This file does ONLY four things:
//!   1. Owns the AppState and CLI / menu wiring
//!   2. Renders the top toolbar (Load File | TIC | BPC | Scan | Export + MS filter)
//!   3. Computes the layout every frame
//!   4. Calls into the panel modules: scan_list_panel, chromatogram_plot, spectrum_plot
//!
//! Layout: two horizontal panels — upper always MS1, lower always MS2.
//! Modes switch what each panel shows:
//!   - TIC: upper = MS1 TIC, lower = MS2 TIC (RT on x-axis)
//!   - BPC: upper = MS1 BPC, lower = MS2 BPC (RT on x-axis)
//!   - Scan: upper = MS1 spectrum, lower = MS2 spectrum (m/z on x-axis)
const std = @import("std");
const app = @import("appimgui");
const ig = app.ig;
const ip = @import("implot");
const AppStateM = @import("app_state");

const scan_list_panel = @import("scan_list_panel.zig");
const spectrum_plot = @import("spectrum_plot.zig");
const chromatogram_plot = @import("chromatogram_plot.zig");
const file_dialog = @import("file_dialog.zig");
const cycle_nav = @import("cycle_navigation.zig");
const export_panel = @import("export_panel.zig");

// ── State ───────────────────────────────────────────────────────────────
const ViewMode = enum { tic, bpc, scan };
const CHROM_HEIGHT: f32 = 200; // height of the chromatogram strip at the top
var show_sidebar: bool = true;
var show_status: bool = true;
var running: bool = true;
var view_mode: ViewMode = .tic;

// Two independently-navigated spectrum panels (only used in scan mode)
var current_ms1_index: i32 = -1; // -1 = unselected
var current_ms2_index: i32 = -1; // -1 = unselected

var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
const gpa: std.mem.Allocator = dbg_alloc.allocator();
var state: *AppStateM.AppState = undefined;

var status_buf: [256]u8 = undefined;
var export_state = export_panel.init();

// ── Independent MS1 / MS2 navigation (each panel has its own ←/→) ───────
fn navPrevMs1() void {
    const from = current_ms1_index;
    if (findPrevMs1(state, from)) |i| {
        current_ms1_index = @intCast(i);
        state.load_scan(i) catch |err| std.log.warn("loadScan MS1 failed: {s}", .{@errorName(err)});
    }
}
fn navNextMs1() void {
    const from = current_ms1_index;
    if (findNextMs1(state, from)) |i| {
        current_ms1_index = @intCast(i);
        state.load_scan(i) catch |err| std.log.warn("loadScan MS1 failed: {s}", .{@errorName(err)});
    }
}
fn navPrevMs2() void {
    const from = current_ms2_index;
    if (findPrevMs2(state, from)) |i| {
        current_ms2_index = @intCast(i);
        state.load_scan(i) catch |err| std.log.warn("loadScan MS2 failed: {s}", .{@errorName(err)});
    }
}
fn navNextMs2() void {
    const from = current_ms2_index;
    if (findNextMs2(state, from)) |i| {
        current_ms2_index = @intCast(i);
        state.load_scan(i) catch |err| std.log.warn("loadScan MS2 failed: {s}", .{@errorName(err)});
    }
}

// ── Helpers: find next/prev MS1 or MS2 globally (independent nav) ───────
fn findNextMs1(s: *AppStateM.AppState, from: i32) ?usize {
    var i: usize = if (from < 0) 0 else @intCast(from + 1);
    while (i < s.file.scans.len) {
        if (s.file.scans[i].ms_level == 1) return i;
        i += 1;
    }
    return null;
}
fn findPrevMs1(s: *AppStateM.AppState, from: i32) ?usize {
    if (from <= 0) return null;
    var i: usize = @intCast(from - 1);
    while (true) {
        if (s.file.scans[i].ms_level == 1) return i;
        if (i == 0) return null;
        i -= 1;
    }
}
fn findNextMs2(s: *AppStateM.AppState, from: i32) ?usize {
    var i: usize = if (from < 0) 0 else @intCast(from + 1);
    while (i < s.file.scans.len) {
        if (s.file.scans[i].ms_level == 2) return i;
        i += 1;
    }
    return null;
}
fn findPrevMs2(s: *AppStateM.AppState, from: i32) ?usize {
    if (from <= 0) return null;
    var i: usize = @intCast(from - 1);
    while (true) {
        if (s.file.scans[i].ms_level == 2) return i;
        if (i == 0) return null;
        i -= 1;
    }
}

// ── Win32 argv parsing (Zig 0.16 has no argsAlloc) ─────────────────────
const LPCWSTR = [*:0]const u16;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPCWSTR;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, pNumArgs: *i32) callconv(.winapi) ?[*]LPCWSTR;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

fn utf16ZLen(s: [*:0]const u16) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

fn getOptionalFilePath() ?[]u8 {
    var argc: i32 = 0;
    const argv_w = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return null;
    defer _ = LocalFree(@ptrCast(argv_w));
    if (argc < 2) return null;
    const n = utf16ZLen(argv_w[1]);
    return std.unicode.utf16LeToUtf8Alloc(gpa, argv_w[1][0..n]) catch null;
}

// ── File open flow (mirrors src/gui/main_window.zig handleFileOpen) ─────
fn openRawFile(path: []const u8) void {
    state.open_file(path) catch |err| {
        std.log.warn("openFile failed: {s}", .{@errorName(err)});
        return;
    };
    state.compute_chromatograms();
    // Initial selection: first MS1, first MS2
    current_ms1_index = if (findNextMs1(state, -1)) |i| @intCast(i) else -1;
    current_ms2_index = if (findNextMs2(state, -1)) |i| @intCast(i) else -1;
}

fn promptAndOpenFile() void {
    if (file_dialog.show_open_file_dialog(gpa)) |path| {
        defer gpa.free(path);
        openRawFile(path);
    }
}

fn promptExportRaw() void {
    if (!state.has_file_open()) return;
    if (file_dialog.show_save_file_dialog(gpa, "Export .raw", "RAW Files", "*.raw", "raw")) |path| {
        defer gpa.free(path);
        export_panel.start(&export_state, gpa, state, .raw, path) catch |err| {
            std.log.warn("Export .raw failed to start: {s}", .{@errorName(err)});
        };
        ig.ImGui_OpenPopup("Exporting...", ig.ImGuiPopupFlags_None);
    }
}

fn promptExportMzml() void {
    if (!state.has_file_open()) return;
    if (file_dialog.show_save_file_dialog(gpa, "Export mzML", "mzML Files", "*.mzML", "mzML")) |path| {
        defer gpa.free(path);
        export_panel.start(&export_state, gpa, state, .mzml, path) catch |err| {
            std.log.warn("Export mzML failed to start: {s}", .{@errorName(err)});
        };
        ig.ImGui_OpenPopup("Exporting...", ig.ImGuiPopupFlags_None);
    }
}

/// Sidebar click: if user clicks an MS1, set as upper; if MS2, set as lower
/// and auto-load the parent MS1 into upper. This is the only sync point.
fn onScanSelected(scan_index: usize) void {
    if (scan_index >= state.file.scans.len) return;
    const scan = state.file.scans[scan_index];
    if (scan.ms_level == 1) {
        current_ms1_index = @intCast(scan_index);
        state.load_scan(scan_index) catch |err| std.log.warn("loadScan MS1 failed: {s}", .{@errorName(err)});
    } else {
        current_ms2_index = @intCast(scan_index);
        if (cycle_nav.parent_ms1_index(state, scan_index)) |p| {
            current_ms1_index = @intCast(p);
        }
        // Load the MS2 spectrum (current_scan_index must equal scan_index for currentSpectrum to return the right one)
        state.load_scan(scan_index) catch |err| std.log.warn("loadScan MS2 failed: {s}", .{@errorName(err)});
    }
}

// ── UI: Status bar text ────────────────────────────────────────────────
fn formatStatus() [*:0]const u8 {
    const file = state.file.file_path orelse "No file loaded";
    const n = state.file.scans.len;
    const text = std.fmt.bufPrintZ(&status_buf, "{s} | {d} scans | rev {d}", .{
        file, n, state.file.file_revision(),
    }) catch &[_:0]u8{};
    return text;
}

// ── UI: Top toolbar (segmented control) ─────────────────────────────────
const TOOLBAR_HEIGHT: f32 = 28;

fn drawToolbar() void {
    ig.ImGui_SetNextWindowPosEx(.{ .x = 0, .y = 0 }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    ig.ImGui_SetNextWindowSize(.{ .x = -1, .y = TOOLBAR_HEIGHT }, ig.ImGuiCond_Always);
    if (ig.ImGui_Begin("Toolbar", null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize |
        ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoScrollbar | ig.ImGuiWindowFlags_NoDocking))
    {
        defer ig.ImGui_End();
        if (ig.ImGui_Button("Load File")) promptAndOpenFile();
        ig.ImGui_SameLine();
        ig.ImGui_Spacing();
        ig.ImGui_SameLine();
        if (ig.ImGui_RadioButton("TIC", view_mode == .tic)) view_mode = .tic;
        ig.ImGui_SameLine();
        if (ig.ImGui_RadioButton("BPC", view_mode == .bpc)) view_mode = .bpc;
        ig.ImGui_SameLine();
        if (ig.ImGui_RadioButton("Scan", view_mode == .scan)) view_mode = .scan;
        ig.ImGui_SameLine();
        ig.ImGui_Spacing();
        ig.ImGui_SameLine();
        ig.ImGui_SameLine();
        ig.ImGui_Spacing();
        ig.ImGui_SameLine();
        if (ig.ImGui_Button("Export .raw")) promptExportRaw();
        ig.ImGui_SameLine();
        if (ig.ImGui_Button("Export mzML")) promptExportMzml();
    }
}

// ── UI: Menu bar (legacy) ──────────────────────────────────────────────
fn drawMenuBar() void {
    if (!ig.ImGui_BeginMainMenuBar()) return;
    defer ig.ImGui_EndMainMenuBar();
    if (ig.ImGui_BeginMenuEx("File", true)) {
        defer ig.ImGui_EndMenu();
        if (ig.ImGui_MenuItemEx("Open .raw file...", "Ctrl+O", false, true)) promptAndOpenFile();
        ig.ImGui_Separator();
        if (ig.ImGui_MenuItemEx("Exit", "Alt+F4", false, true)) running = false;
    }
    if (ig.ImGui_BeginMenuEx("View", true)) {
        defer ig.ImGui_EndMenu();
        _ = ig.ImGui_MenuItemBoolPtr("Sidebar", null, &show_sidebar, true);
        _ = ig.ImGui_MenuItemBoolPtr("Status Bar", null, &show_status, true);
    }
}

// ── Layout: compute regions from viewport ──────────────────────────────
fn layoutRegions(vp_pos: ig.ImVec2, vp_sz: ig.ImVec2, top_h: f32) struct {
    work_y: f32,
    work_h: f32,
    sidebar_x: f32,
    sidebar_w: f32,
    main_x: f32,
    main_w: f32,
} {
    const status_h: f32 = if (show_status) 24 else 0;
    const work_y = vp_pos.y + top_h;
    const work_h = vp_sz.y - top_h - status_h;
    const sidebar_w: f32 = if (show_sidebar) @floor(vp_sz.x * 0.20) else 0;
    const main_x = vp_pos.x + sidebar_w;
    const main_w = vp_sz.x - sidebar_w;
    return .{
        .work_y = work_y,
        .work_h = work_h,
        .sidebar_x = vp_pos.x,
        .sidebar_w = sidebar_w,
        .main_x = main_x,
        .main_w = main_w,
    };
}

// ── UI: Status bar ─────────────────────────────────────────────────────
const STATUS_BAR_FLAGS: c_int = ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize |
    ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoScrollbar |
    ig.ImGuiWindowFlags_NoCollapse | ig.ImGuiWindowFlags_NoSavedSettings |
    ig.ImGuiWindowFlags_NoDocking | ig.ImGuiWindowFlags_NoScrollWithMouse;

fn drawStatusBar(x: f32, y: f32, w: f32, h: f32) void {
    ig.ImGui_SetNextWindowPosEx(.{ .x = x, .y = y }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    ig.ImGui_SetNextWindowSize(.{ .x = w, .y = h }, ig.ImGuiCond_Always);
    if (ig.ImGui_Begin("StatusBar", null, STATUS_BAR_FLAGS)) {
        defer ig.ImGui_End();
        ig.ImGui_Text("%s", @as([*c]const u8, formatStatus()));
    }
}

// ── UI: Scan navigator bar (← scan# →) shown above each spectrum panel ──
const NAV_BAR_HEIGHT: f32 = 32;

const NavKind = enum { ms1, ms2 };

fn drawScanNavigator(id: [*:0]const u8, x: f32, y: f32, w: f32, h: f32, scan_index: i32, kind: NavKind) void {
    ig.ImGui_SetNextWindowPosEx(.{ .x = x, .y = y }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    ig.ImGui_SetNextWindowSize(.{ .x = w, .y = h }, ig.ImGuiCond_Always);
    if (ig.ImGui_Begin(id, null, ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize |
        ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoScrollbar | ig.ImGuiWindowFlags_NoDocking))
    {
        defer ig.ImGui_End();
        var label_buf: [32]u8 = undefined;
        const label: [:0]const u8 = if (scan_index >= 0 and scan_index < state.file.scans.len)
            std.fmt.bufPrintZ(&label_buf, "Scan {d}", .{state.file.scans[@intCast(scan_index)].scan_number}) catch "Scan -"
        else
            "Scan -";
        if (ig.ImGui_Button("<-")) switch (kind) {
            .ms1 => navPrevMs1(),
            .ms2 => navPrevMs2(),
        };
        ig.ImGui_SameLine();
        _ = ig.ImGui_Button(label);
        ig.ImGui_SameLine();
        if (ig.ImGui_Button("->")) switch (kind) {
            .ms1 => navNextMs1(),
            .ms2 => navNextMs2(),
        };
    }
}

// ── Frame: build the UI from layout + state ────────────────────────────
fn buildUI() void {
    const viewport = ig.ImGui_GetMainViewport();
    const vp_pos = viewport.*.Pos;
    const vp_sz = viewport.*.Size;

    ig.ImGui_PushStyleColor(ig.ImGuiCol_WindowBg, 0xFF1A1A1F);
    defer ig.ImGui_PopStyleColor();

    drawMenuBar();
    const menu_h: f32 = ig.ImGui_GetFrameHeightWithSpacing();
    const top_h: f32 = menu_h + TOOLBAR_HEIGHT;

    const r = layoutRegions(vp_pos, vp_sz, top_h);

    if (show_sidebar) {
        scan_list_panel.draw(state, r.sidebar_x, r.work_y, r.sidebar_w, r.work_h, &show_sidebar, onScanSelected);
    }

    // Two horizontal panels: upper = MS1, lower = MS2.
    const half_h: f32 = @floor((r.work_h - 4) * 0.5);
    const u_pos_y = r.work_y;
    const l_pos_y = r.work_y + half_h + 4;

    switch (view_mode) {
        .tic => {
            drawScanNavigator("MS1Nav", r.main_x, u_pos_y, 160, NAV_BAR_HEIGHT, current_ms1_index, .ms1);
            chromatogram_plot.draw(state, "MS1 Chromatogram (TIC)", r.main_x, u_pos_y + NAV_BAR_HEIGHT, r.main_w, half_h - NAV_BAR_HEIGHT, .tic, .ms1, gpa);
            drawScanNavigator("MS2Nav", r.main_x, l_pos_y, 160, NAV_BAR_HEIGHT, current_ms2_index, .ms2);
            chromatogram_plot.draw(state, "MS2 Chromatogram (TIC)", r.main_x, l_pos_y + NAV_BAR_HEIGHT, r.main_w, half_h - NAV_BAR_HEIGHT, .tic, .ms2, gpa);
        },
        .bpc => {
            drawScanNavigator("MS1Nav", r.main_x, u_pos_y, 160, NAV_BAR_HEIGHT, current_ms1_index, .ms1);
            chromatogram_plot.draw(state, "MS1 Chromatogram (BPC)", r.main_x, u_pos_y + NAV_BAR_HEIGHT, r.main_w, half_h - NAV_BAR_HEIGHT, .bpc, .ms1, gpa);
            drawScanNavigator("MS2Nav", r.main_x, l_pos_y, 160, NAV_BAR_HEIGHT, current_ms2_index, .ms2);
            chromatogram_plot.draw(state, "MS2 Chromatogram (BPC)", r.main_x, l_pos_y + NAV_BAR_HEIGHT, r.main_w, half_h - NAV_BAR_HEIGHT, .bpc, .ms2, gpa);
        },
        .scan => {
            drawScanNavigator("MS1Nav", r.main_x, u_pos_y, 160, NAV_BAR_HEIGHT, current_ms1_index, .ms1);
            spectrum_plot.draw(state, .ms1, "MS1 Spectrum", current_ms1_index, r.main_x, u_pos_y + NAV_BAR_HEIGHT, r.main_w, half_h - NAV_BAR_HEIGHT, gpa);
            drawScanNavigator("MS2Nav", r.main_x, l_pos_y, 160, NAV_BAR_HEIGHT, current_ms2_index, .ms2);
            spectrum_plot.draw(state, .ms2, "MS2 Spectrum", current_ms2_index, r.main_x, l_pos_y + NAV_BAR_HEIGHT, r.main_w, half_h - NAV_BAR_HEIGHT, gpa);
        },
    }

    if (show_status) {
        drawStatusBar(vp_pos.x, vp_pos.y + vp_sz.y - 24, vp_sz.x, 24);
    }

    drawToolbar();
    _ = export_panel.draw_modal(&export_state);
}

// ── Entry ──────────────────────────────────────────────────────────────
var window: app.Window = undefined;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    state = gpa.create(AppStateM.AppState) catch return error.OutOfMemory;
    state.* = AppStateM.AppState.init(gpa, io);
    defer {
        spectrum_plot.release_mirror(gpa);
        state.deinit();
        gpa.destroy(state);
    }

    if (getOptionalFilePath()) |path| {
        defer gpa.free(path);
        openRawFile(path);
    }

    window = app.Window.createImGui(1400, 900, "mzigRead — imguinz2 viewer") catch |err| {
        std.log.err("failed to create imguinz2 window: {}", .{err});
        return 1;
    };
    defer window.destroyImGui();

    _ = app.setTheme(.dark);

    const imPlotContext = ip.ImPlot_CreateContext();
    defer ip.ImPlot_DestroyContext(imPlotContext);

    while (running and !window.shouldClose()) {
        window.pollEvents();
        if (window.isIconified()) continue;
        window.frame();
        buildUI();
        window.render();
    }

    return 0;
}
