//! Chromatogram plot — ImPlot over app_state.Chromatogram
//! Direct port of src/gui/chromatogram_canvas.zig (which uses GDI).
//!
//! Supports:
//!   - TIC: sum of all peak intensities per scan (×10^i notation in y-axis label)
//!   - BPC: max peak intensity per scan
//!   - MS-level filtering: All / MS1 / MS2
//! Caller must provide a unique title for each panel; the title is used as the
//! ImGui window ID.
const std = @import("std");
const ig = @import("appimgui").ig;
const ip = @import("implot");
const AppState = @import("app_state").AppState;
const Chromatogram = @import("app_state").Chromatogram;

const LOCKED_PANEL_FLAGS: c_int = ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoResize |
    ig.ImGuiWindowFlags_NoCollapse | ig.ImGuiWindowFlags_NoSavedSettings |
    ig.ImGuiWindowFlags_NoDocking;

pub const Kind = enum { tic, bpc };
pub const MsFilter = enum { all, ms1, ms2 };

/// Zoom state for each chromatogram panel, keyed by (kind, filter).
/// Index = @intFromEnum(kind) * 3 + @intFromEnum(filter).
var rt_zoom_min: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };
var rt_zoom_max: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };
var rt_zoom_initialized: [6]bool = .{ false, false, false, false, false, false };

fn zoomIndex(kind: Kind, filter: MsFilter) usize {
    return @as(usize, @intFromEnum(kind)) * 3 + @as(usize, @intFromEnum(filter));
}

fn clamp(v: f64, low: f64, high: f64) f64 {
    return @max(low, @min(high, v));
}

/// Zoom/pan the x-axis window from mouse-wheel input.
fn updateZoomPan(idx: usize, abs_min: f64, abs_max: f64, wheel_y: f32, wheel_x: f32, shift_held: bool) void {
    const cur_min = rt_zoom_min[idx];
    const cur_max = rt_zoom_max[idx];
    const span = cur_max - cur_min;

    const pan_input = wheel_x + (if (shift_held) wheel_y else 0);
    if (pan_input != 0) {
        const pan_step = span * 0.15 * @as(f64, pan_input);
        var new_min = cur_min + pan_step;
        var new_max = cur_max + pan_step;
        if (new_min < abs_min) {
            new_max += abs_min - new_min;
            new_min = abs_min;
        }
        if (new_max > abs_max) {
            new_min -= new_max - abs_max;
            new_max = abs_max;
        }
        rt_zoom_min[idx] = clamp(new_min, abs_min, abs_max);
        rt_zoom_max[idx] = clamp(new_max, abs_min, abs_max);
        return;
    }

    if (wheel_y == 0) return;

    const factor: f64 = if (wheel_y > 0) 0.7 else 1.4;
    const center = (cur_min + cur_max) * 0.5;
    var new_width = span * factor;
    new_width = clamp(new_width, 0.01, abs_max - abs_min);
    var new_min = center - new_width * 0.5;
    var new_max = center + new_width * 0.5;
    if (new_min < abs_min) {
        new_max += abs_min - new_min;
        new_min = abs_min;
    }
    if (new_max > abs_max) {
        new_min -= new_max - abs_max;
        new_max = abs_max;
    }
    rt_zoom_min[idx] = clamp(new_min, abs_min, abs_max);
    rt_zoom_max[idx] = clamp(new_max, abs_min, abs_max);
}

/// Compute the order-of-magnitude exponent for displaying TIC intensity
/// (e.g. 2.3e6 → exponent=6 → "×10⁶"). Returns 0 if max <= 1.
pub fn order_of_magnitude(max_value: f64) i32 {
    if (max_value <= 1.0) return 0;
    return @intFromFloat(@floor(@log10(max_value)));
}

pub const FilterError = std.mem.Allocator.Error;

/// Filter a chromatogram's arrays by MS level. Returns a contiguous buffer of
/// (rt, intensity) pairs in the given ms_level. Caller owns the returned slice.
pub fn filter_by_ms_level(allocator: std.mem.Allocator, cg: *const Chromatogram, filter: MsFilter) FilterError![]f64 {
    if (filter == .all) {
        // Return a single contiguous buffer: [rt..., intensity..., n_intensity, n_intensity]
        const buf = try allocator.alloc(f64, cg.rt.len * 2);
        @memcpy(buf[0..cg.rt.len], cg.rt);
        @memcpy(buf[cg.rt.len..], cg.intensity);
        return buf;
    }
    const want_level: u8 = if (filter == .ms1) 1 else 2;
    var count: usize = 0;
    for (cg.ms_level) |lvl| {
        if (lvl == want_level) count += 1;
    }
    const buf = try allocator.alloc(f64, count * 2);
    var w: usize = 0;
    for (cg.rt, cg.intensity, cg.ms_level) |rt, inten, lvl| {
        if (lvl == want_level) {
            buf[w] = rt;
            buf[w + count] = inten;
            w += 1;
        }
    }
    return buf;
}

pub fn draw(
    state: *AppState,
    title: [*:0]const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    kind: Kind,
    filter: MsFilter,
    allocator: std.mem.Allocator,
) void {
    ig.ImGui_SetNextWindowPosEx(.{ .x = x, .y = y }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    ig.ImGui_SetNextWindowSize(.{ .x = w, .y = h }, ig.ImGuiCond_Always);

    if (!ig.ImGui_Begin(title, null, LOCKED_PANEL_FLAGS)) {
        ig.ImGui_End();
        return;
    }
    defer ig.ImGui_End();

    if (!state.has_file_open()) {
        ig.ImGui_TextUnformatted("No file loaded");
        return;
    }
    const cg = switch (kind) {
        .tic => state.tic_chromatogram,
        .bpc => state.bpc_chromatogram,
    } orelse {
        ig.ImGui_TextUnformatted("Chromatogram not computed");
        return;
    };
    if (cg.num_points == 0) {
        ig.ImGui_TextUnformatted("No chromatogram data");
        return;
    }

    // Filter the data. For "all" we just copy; for ms1/ms2 we filter.
    const buf = filter_by_ms_level(allocator, &cg, filter) catch |err| blk: {
        var msg: [128]u8 = undefined;
        const text = std.fmt.bufPrintZ(&msg, "Filter alloc failed: {s}", .{@errorName(err)}) catch &[_:0]u8{};
        ig.ImGui_Text("%s", @as([*c]const u8, text));
        break :blk @as(?[]f64, null);
    };
    defer if (buf) |b| allocator.free(b);
    if (buf) |b| {
        const n: c_int = @intCast(b.len / 2);
        const rt = b[0..@intCast(n)];
        const inten = b[@intCast(n)..];

        // Absolute RT bounds for this panel.
        const abs_min_rt: f64 = if (rt.len > 0) @max(0, @floor(rt[0])) else 0;
        const abs_max_rt: f64 = if (rt.len > 0) @ceil(rt[rt.len - 1]) else 1;

        const zi = zoomIndex(kind, filter);
        if (!rt_zoom_initialized[zi]) {
            rt_zoom_min[zi] = abs_min_rt;
            rt_zoom_max[zi] = abs_max_rt;
            rt_zoom_initialized[zi] = true;
        }

        // Compute y-axis label with ×10^i notation
        var max_v: f64 = 0;
        for (inten) |v| {
            if (v > max_v) max_v = v;
        }
        const exp = order_of_magnitude(max_v);
        var y_label: [64]u8 = undefined;
        const y_label_z: [:0]const u8 = if (exp == 0)
            std.fmt.bufPrintZ(&y_label, "Intensity", .{}) catch "Intensity"
        else
            std.fmt.bufPrintZ(&y_label, "Intensity (\xc3\x9710^{d})", .{exp}) catch "Intensity";

        const io_ptr = ig.ImGui_GetIO();
        updateZoomPan(zi, abs_min_rt, abs_max_rt, io_ptr.*.MouseWheel, io_ptr.*.MouseWheelH, io_ptr.*.KeyShift);

        if (ip.ImPlot_BeginPlot("##Chrom", .{ .x = -1, .y = -1 }, 0)) {
            defer ip.ImPlot_EndPlot();

            ip.ImPlot_SetupAxis(ip.ImAxis_X1, "Retention Time (min)", 0);
            ip.ImPlot_SetupAxisLimits(ip.ImAxis_X1, rt_zoom_min[zi], rt_zoom_max[zi], ip.ImPlotCond_Always);
            ip.ImPlot_SetupAxis(ip.ImAxis_Y1, @as([*c]const u8, y_label_z), 0);
            ip.ImPlot_SetupAxisLimits(ip.ImAxis_Y1, 0, max_v * 1.05, ip.ImPlotCond_Always);
            ip.ImPlot_SetupFinish();
            ip.ImPlot_SetNextLineStyle(.{ .x = 0.2, .y = 0.6, .z = 0.2, .w = 1 }, 1.5);
            ip.ImPlot_PlotLine_doublePtrdoublePtr("Chromatogram", rt.ptr, inten.ptr, n, 0, 0, @sizeOf(f64));
        }
    }
}
