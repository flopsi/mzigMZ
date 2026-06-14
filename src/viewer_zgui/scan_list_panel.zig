//! Scan list panel — ImGui table over file_state.ScanInfo
//! Direct port of src/gui/scan_list.zig (which uses Win32 ListView).
const std = @import("std");
const ig = @import("appimgui").ig;
const AppState = @import("app_state").AppState;

const LOCKED_PANEL_FLAGS: c_int = ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoResize |
    ig.ImGuiWindowFlags_NoCollapse | ig.ImGuiWindowFlags_NoSavedSettings |
    ig.ImGuiWindowFlags_NoDocking;

pub const SelectionCallback = *const fn (context: ?*anyopaque, scan_index: usize) void;

pub const State = struct {
    current_index: i32 = 0,
};

pub fn init() State {
    return .{};
}

pub fn deinit(self: *State) void {
    _ = self;
}

pub fn draw(
    self: *State,
    state: *AppState,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    show: *bool,
    on_select: SelectionCallback,
    context: ?*anyopaque,
) void {
    ig.ImGui_SetNextWindowPosEx(.{ .x = x, .y = y }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    ig.ImGui_SetNextWindowSize(.{ .x = w, .y = h }, ig.ImGuiCond_Always);

    if (!ig.ImGui_Begin("Scan List", show, LOCKED_PANEL_FLAGS)) {
        ig.ImGui_End();
        return;
    }
    defer ig.ImGui_End();

    if (!state.has_file_open()) {
        ig.ImGui_TextUnformatted("No file open. Pass a .raw path as argv[1].");
        return;
    }

    // NOTE: ImGuiListClipper + BeginTable has known assertion bugs in
    // ImGui 1.92.7 (github.com/ocornut/imgui issues #8595, #9350). Instead
    // of iterating all rows, we hand-roll a clipper using the window scroll
    // position and a fixed row height. Invisible rows are collapsed into two
    // spacer rows (top and bottom), so we only emit ~visible row count per frame.
    if (!ig.ImGui_BeginTableEx(
        "Scans",
        4,
        ig.ImGuiTableFlags_Resizable | ig.ImGuiTableFlags_RowBg |
            ig.ImGuiTableFlags_BordersInnerV,
        .{ .x = 0, .y = -1 },
        0,
    )) {
        return;
    }
    defer ig.ImGui_EndTable();

    ig.ImGui_TableSetupColumnEx("#", ig.ImGuiTableColumnFlags_WidthFixed, 50, 0);
    ig.ImGui_TableSetupColumnEx("RT", ig.ImGuiTableColumnFlags_WidthFixed, 70, 0);
    ig.ImGui_TableSetupColumnEx("MS", ig.ImGuiTableColumnFlags_WidthFixed, 40, 0);
    ig.ImGui_TableSetupColumnEx("TIC", ig.ImGuiTableColumnFlags_WidthStretch, 0, 0);
    ig.ImGui_TableHeadersRow();

    const total_rows: i32 = @intCast(state.file.scans.len);
    if (total_rows == 0) return;

    const row_height = ig.ImGui_GetTextLineHeightWithSpacing();
    const cursor_y = ig.ImGui_GetCursorPosY();
    const scroll_y = ig.ImGui_GetScrollY();
    const win_height = ig.ImGui_GetWindowHeight();

    const content_top = scroll_y - cursor_y;
    var first_row: i32 = @intFromFloat(@floor(content_top / row_height));
    first_row = std.math.clamp(first_row, 0, total_rows - 1);
    var last_row: i32 = first_row + @as(i32, @intFromFloat(@ceil(win_height / row_height))) + 1;
    last_row = std.math.clamp(last_row, 0, total_rows - 1);

    // Spacer for the invisible rows above the visible range.
    const top_count = first_row;
    if (top_count > 0) {
        ig.ImGui_TableNextRowEx(0, @as(f32, @floatFromInt(top_count)) * row_height);
    }

    var i: i32 = first_row;
    while (i <= last_row) : (i += 1) {
        const scan = state.file.scans[@intCast(i)];
        ig.ImGui_TableNextRowEx(0, 0);
        _ = ig.ImGui_TableNextColumn();
        var buf: [32]u8 = undefined;
        const lbl = std.fmt.bufPrintSentinel(&buf, "{d}", .{scan.scan_number}, 0) catch continue;
        _ = ig.ImGui_SelectableEx(lbl, i == self.current_index, 0, .{ .x = 0, .y = 0 });
        if (ig.ImGui_IsItemClicked()) {
            self.current_index = i;
            on_select(context, @intCast(i));
        }
        _ = ig.ImGui_TableNextColumn();
        ig.ImGui_Text("%.2f", scan.rt);
        _ = ig.ImGui_TableNextColumn();
        if (scan.ms_level > 0) {
            ig.ImGui_Text("%d", scan.ms_level);
        } else {
            ig.ImGui_TextUnformatted("-");
        }
        _ = ig.ImGui_TableNextColumn();
        ig.ImGui_Text("%.0f", scan.tic);
    }

    // Spacer for the invisible rows below the visible range.
    const bottom_count = total_rows - 1 - last_row;
    if (bottom_count > 0) {
        ig.ImGui_TableNextRowEx(0, @as(f32, @floatFromInt(bottom_count)) * row_height);
    }
}
