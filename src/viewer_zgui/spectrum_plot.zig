//! Spectrum plot — ImPlot over advanced.Spectrum
//! Direct port of src/gui/spectrum_canvas.zig (which uses GDI MoveTo/LineTo).
//!
//! Plot rules:
//!   - User toggle between stems (discrete peaks) and line (continuous trace).
//!   - y-axis auto-fits to data (per-panel; MS1 and MS2 have wildly different scales)
//!   - x-axis fixed at MS1: 375-985, MS2: 145-2000 (per spec, until file metadata drives it)
//!   - Scan metadata overlay: scan number, MS level, RT, precursor m/z, charge
//!   - Top-20 peak labels (m/z) drawn above the tallest peaks.
//!
//! Cached: the f64 mirror of intensity[] is allocated once and refreshed
//! only when the source spectrum changes (detected by mz.ptr identity).
const std = @import("std");
const ig = @import("appimgui").ig;
const ip = @import("implot");
const advanced = @import("advanced_packet");
const raw = @import("raw_file");
const AppState = @import("app_state").AppState;

const LOCKED_PANEL_FLAGS: c_int = ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoResize |
    ig.ImGuiWindowFlags_NoCollapse | ig.ImGuiWindowFlags_NoSavedSettings |
    ig.ImGuiWindowFlags_NoDocking;

pub const Kind = enum { ms1, ms2 };

pub const PlotMode = enum { stems, line };

pub const DrawError = std.mem.Allocator.Error;

pub const State = struct {
    /// Plot mode defaults. Profile data is drawn as a continuous line; centroid
    /// data is always drawn as stems because connecting centroid peaks implies a
    /// false continuum. User can still override per panel.
    plot_modes: [2]PlotMode = .{ .line, .line },
    show_peak_labels: [2]bool = .{ true, true },

    /// Current x-axis zoom state for each panel. Persisted across frames so the
    /// user can zoom and pan without losing the view on every redraw.
    zoom_mz_min: [2]f64 = .{ MZRange.MS1.min, MZRange.MS2.min },
    zoom_mz_max: [2]f64 = .{ MZRange.MS1.max, MZRange.MS2.max },

    // Cached f64 mirror of spectrum.intensity[]. Allocated once, reused.
    mirror: ?[]f64 = null,
    mirror_source_ptr: ?[*]const f64 = null,
    mirror_source_len: usize = 0,
};

pub fn init() State {
    return .{};
}

pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
    if (self.mirror) |old| {
        allocator.free(old);
        self.mirror = null;
        self.mirror_source_ptr = null;
        self.mirror_source_len = 0;
    }
}

/// Best default plot mode for a given packet type.
fn defaultModeForPacketType(packet_type: u32) PlotMode {
    return if (packet_type == raw.PACKET_TYPE_FT_PROFILE) .line else .stems;
}
const MAX_PEAK_LABELS = 20;

/// Fixed m/z ranges per MS level (per spec, until file metadata drives it).
pub const MZRange = struct {
    min: f64,
    max: f64,
    pub const MS1 = MZRange{ .min = 375, .max = 985 };
    pub const MS2 = MZRange{ .min = 145, .max = 2000 };
};

/// Reset zoom to the full fixed range for a panel. Called when the scan
/// changes so the user starts from the full-range view.
pub fn reset_zoom(self: *State, kind: Kind) void {
    const range = switch (kind) {
        .ms1 => MZRange.MS1,
        .ms2 => MZRange.MS2,
    };
    const idx = @intFromEnum(kind);
    self.zoom_mz_min[idx] = range.min;
    self.zoom_mz_max[idx] = range.max;
}

/// Clamp value to [low, high].
fn clamp(v: f64, low: f64, high: f64) f64 {
    return @max(low, @min(high, v));
}

/// Zoom/pan the x-axis window from mouse-wheel input.
///   - Vertical wheel (wheel_y) zooms in/out around the view center.
///   - Shift+vertical wheel or horizontal wheel (wheel_x) pans left/right.
fn updateZoomPan(self: *State, idx: usize, range: MZRange, wheel_y: f32, wheel_x: f32, shift_held: bool) void {
    const cur_min = self.zoom_mz_min[idx];
    const cur_max = self.zoom_mz_max[idx];
    const span = cur_max - cur_min;

    // Pan takes priority when Shift is held or horizontal wheel is used.
    const pan_input = wheel_x + (if (shift_held) wheel_y else 0);
    if (pan_input != 0) {
        const pan_step = span * 0.15 * @as(f64, pan_input);
        var new_min = cur_min + pan_step;
        var new_max = cur_max + pan_step;
        // Clamp pan to absolute bounds.
        if (new_min < range.min) {
            new_max += range.min - new_min;
            new_min = range.min;
        }
        if (new_max > range.max) {
            new_min -= new_max - range.max;
            new_max = range.max;
        }
        self.zoom_mz_min[idx] = clamp(new_min, range.min, range.max);
        self.zoom_mz_max[idx] = clamp(new_max, range.min, range.max);
        return;
    }

    if (wheel_y == 0) return;

    // Zoom around the center of the current view. wheel_y > 0 -> zoom in.
    const factor: f64 = if (wheel_y > 0) 0.7 else 1.4;
    const center = (cur_min + cur_max) * 0.5;
    var new_width = span * factor;
    // Minimum span 1 Da; maximum span the full fixed range.
    new_width = clamp(new_width, 1.0, range.max - range.min);
    var new_min = center - new_width * 0.5;
    var new_max = center + new_width * 0.5;
    if (new_min < range.min) {
        new_max += range.min - new_min;
        new_min = range.min;
    }
    if (new_max > range.max) {
        new_min -= new_max - range.max;
        new_max = range.max;
    }
    self.zoom_mz_min[idx] = clamp(new_min, range.min, range.max);
    self.zoom_mz_max[idx] = clamp(new_max, range.min, range.max);
}

fn ensureMirror(self: *State, allocator: std.mem.Allocator, spec: *const advanced.Spectrum) DrawError!?[]f64 {
    const key_ptr: [*]const f64 = spec.mz.ptr;
    if (self.mirror_source_ptr != null and self.mirror_source_ptr.? == key_ptr and self.mirror_source_len == spec.mz.len and self.mirror != null) {
        return self.mirror;
    }
    if (self.mirror) |old| allocator.free(old);
    const buf = try allocator.alloc(f64, spec.intensity.len);
    for (spec.intensity, 0..) |v, i| buf[i] = @floatCast(v);
    self.mirror = buf;
    self.mirror_source_ptr = key_ptr;
    self.mirror_source_len = spec.mz.len;
    return buf;
}

fn drawPeakLabels(mz: []const f64, intensity: []const f64) void {
    if (mz.len == 0) return;

    const PeakEntry = struct { idx: usize, inten: f64 };
    var top: [MAX_PEAK_LABELS]PeakEntry = undefined;
    const count = @min(MAX_PEAK_LABELS, mz.len);
    var min_idx: usize = 0;
    for (0..count) |i| {
        top[i] = .{ .idx = i, .inten = intensity[i] };
        if (top[i].inten < top[min_idx].inten) min_idx = i;
    }
    for (count..mz.len) |i| {
        if (intensity[i] > top[min_idx].inten) {
            top[min_idx] = .{ .idx = i, .inten = intensity[i] };
            var new_min: usize = 0;
            for (top[0..count], 0..) |p, k| {
                if (p.inten < top[new_min].inten) new_min = k;
            }
            min_idx = new_min;
        }
    }

    var label_buf: [32]u8 = undefined;
    for (top[0..count]) |p| {
        if (p.inten <= 0) continue;
        const label = std.fmt.bufPrintSentinel(&label_buf, "{d:.2}", .{mz[p.idx]}, 0) catch continue;
        ip.ImPlot_PlotText(label, mz[p.idx], intensity[p.idx], .{ .x = 0, .y = -15 }, 0);
    }
}

pub fn draw(
    self: *State,
    state: *AppState,
    kind: Kind,
    title: [*:0]const u8,
    scan_index: i32, // -1 = no scan, show placeholder
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    allocator: std.mem.Allocator,
) DrawError!void {
    ig.ImGui_SetNextWindowPosEx(.{ .x = x, .y = y }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    ig.ImGui_SetNextWindowSize(.{ .x = w, .y = h }, ig.ImGuiCond_Always);

    if (!ig.ImGui_Begin(title, null, LOCKED_PANEL_FLAGS)) {
        ig.ImGui_End();
        return;
    }
    defer ig.ImGui_End();

    // Header line: scan metadata
    var info_buf: [256]u8 = undefined;
    const info_text = if (scan_index >= 0 and scan_index < state.file.scans.len) blk: {
        const scan = state.file.scans[@intCast(scan_index)];
        if (scan.ms_level >= 2) {
            break :blk std.fmt.bufPrintSentinel(&info_buf, "Scan {d}  MS{d}  RT {d:.2}  prec {d:.4}  z={d}", .{
                scan.scan_number, scan.ms_level, scan.rt, scan.precursor_mz, scan.charge_state,
            }, 0) catch "(no scan)";
        }
        break :blk std.fmt.bufPrintSentinel(&info_buf, "Scan {d}  MS{d}  RT {d:.2}", .{
            scan.scan_number, scan.ms_level, scan.rt,
        }, 0) catch "(no scan)";
    } else std.fmt.bufPrintSentinel(&info_buf, "(no scan)", .{}, 0) catch "(no scan)";
    ig.ImGui_Text("%s", @as([*c]const u8, info_text.ptr));

    // Load the spectrum for the given scan index. We have to manipulate
    // current_scan_index temporarily to use currentSpectrum() since it reads
    // from state. (Alternative: bypass and read from the scan's mmap directly,
    // but that loses the cache. For now, mutate-and-restore is fine since
    // the only reader is us on the main thread.)
    if (scan_index < 0 or scan_index >= state.file.scans.len) {
        ig.ImGui_TextUnformatted("No scan selected");
        return;
    }

    // Plot controls (per panel)
    const mode_idx = @intFromEnum(kind);
    const scan = state.file.scans[@intCast(scan_index)];
    const default_mode = defaultModeForPacketType(scan.packet_type);
    if (ig.ImGui_RadioButton("Stems", self.plot_modes[mode_idx] == .stems)) self.plot_modes[mode_idx] = .stems;
    ig.ImGui_SameLine();
    if (ig.ImGui_RadioButton("Line", self.plot_modes[mode_idx] == .line)) self.plot_modes[mode_idx] = .line;
    ig.ImGui_SameLine();
    _ = ig.ImGui_Checkbox("Peak labels", &self.show_peak_labels[mode_idx]);
    if (state.current_scan_index != scan_index) {
        reset_zoom(self, kind);
        state.load_scan(@intCast(scan_index)) catch |err| {
            var msg: [128]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&msg, "loadScan({d}) failed: {s}", .{ scan_index, @errorName(err) }, 0) catch "loadScan failed";
            ig.ImGui_Text("%s", @as([*c]const u8, text.ptr));
            return;
        };
    }

    const spec_opt = state.get_current_spectrum();
    if (spec_opt == null) {
        ig.ImGui_TextUnformatted("Spectrum not loaded");
        return;
    }
    const spec = spec_opt.?;
    if (spec.point_count() == 0) {
        ig.ImGui_TextUnformatted("Spectrum is empty (profile or unsupported packet)");
        return;
    }

    const buf = try ensureMirror(self, allocator, &spec);
    if (buf) |b| {
        const range = switch (kind) {
            .ms1 => MZRange.MS1,
            .ms2 => MZRange.MS2,
        };

        const idx = @intFromEnum(kind);
        if (ip.ImPlot_BeginPlot("##Spectrum", .{ .x = -1, .y = -1 }, 0)) {
            defer ip.ImPlot_EndPlot();

            const io_ptr = ig.ImGui_GetIO();
            const wheel_y = io_ptr.*.MouseWheel;
            const wheel_x = io_ptr.*.MouseWheelH;
            const shift_held = io_ptr.*.KeyShift;
            updateZoomPan(self, idx, range, wheel_y, wheel_x, shift_held);

            ip.ImPlot_SetupAxis(ip.ImAxis_X1, "m/z", 0);
            ip.ImPlot_SetupAxisLimits(ip.ImAxis_X1, self.zoom_mz_min[idx], self.zoom_mz_max[idx], ip.ImPlotCond_Always);
            ip.ImPlot_SetupAxis(ip.ImAxis_Y1, "Intensity", 0);
            // Auto-fit y-axis: 0 to max*1.05. Per-panel, so MS1 and MS2 have
            // independent scales (MS2 peaks can be much taller than MS1).
            ip.ImPlot_SetupAxisLimits(ip.ImAxis_Y1, 0, @as(f64, spec.get_intensity_max()) * 1.05, ip.ImPlotCond_Always);
            ip.ImPlot_SetupFinish();

            const user_mode = self.plot_modes[@intFromEnum(kind)];
            const mode = if (user_mode == .line) default_mode else user_mode;
            switch (mode) {
                .line => {
                    ip.ImPlot_SetNextLineStyle(.{ .x = 0.3, .y = 0.5, .z = 1.0, .w = 1 }, 1.0);
                    ip.ImPlot_PlotLine_doublePtrdoublePtr("Spectrum", spec.mz.ptr, b.ptr, @intCast(spec.point_count()), 0, 0, @sizeOf(f64));
                },
                .stems => {
                    ip.ImPlot_SetNextLineStyle(.{ .x = 0.3, .y = 0.5, .z = 1.0, .w = 1 }, 1.0);
                    ip.ImPlot_PlotStems_doublePtrdoublePtr("Spectrum", spec.mz.ptr, b.ptr, @intCast(spec.point_count()), 0, 0, 0, @sizeOf(f64));
                },
            }

            if (self.show_peak_labels[@intFromEnum(kind)]) {
                drawPeakLabels(spec.mz, b);
            }
        }
    }
}
