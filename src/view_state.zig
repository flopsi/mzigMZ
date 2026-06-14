/// ViewState — pure logic for zoom, pan, filters, and view mode.
///
/// Extracted from AppState (Opportunity 1). Before this module, view logic
/// was mixed with file I/O and spectrum decode in a single 800-line struct.
///
/// ViewState is a deep module: no I/O, no allocations, no file dependencies.
/// All methods are pure functions or simple mutators on the struct fields.
/// This makes it trivially unit-testable without mocking.
const std = @import("std");
const advanced = @import("advanced_packet");

pub const ViewMode = enum {
    stick,
    line,
};

/// Zoom state — visible m/z range.
pub const ZoomState = struct {
    mz_min: f64,
    mz_max: f64,
    inten_min: f32,
    inten_max: f32,

    pub fn init(spectrum: *const advanced.Spectrum) ZoomState {
        return .{
            .mz_min = spectrum.get_mz_min(),
            .mz_max = spectrum.get_mz_max(),
            .inten_min = 0,
            .inten_max = spectrum.get_intensity_max(),
        };
    }

    pub fn reset(self: *ZoomState, spectrum: *const advanced.Spectrum) void {
        self.mz_min = spectrum.get_mz_min();
        self.mz_max = spectrum.get_mz_max();
        self.inten_min = 0;
        self.inten_max = spectrum.get_intensity_max();
    }

    pub fn mz_span(self: ZoomState) f64 {
        const span = self.mz_max - self.mz_min;
        return if (span > 0) span else 1.0;
    }

    pub fn inten_span(self: ZoomState) f32 {
        const span = self.inten_max - self.inten_min;
        return if (span > 0) span else 1.0;
    }

    pub fn zoom_around(self: *ZoomState, center_mz: f64, factor: f64) void {
        const span = self.mz_span();
        const new_span = span * factor;
        const half = new_span / 2.0;
        self.mz_min = center_mz - half;
        self.mz_max = center_mz + half;
    }

    pub fn pan_by(self: *ZoomState, delta_mz: f64) void {
        self.mz_min += delta_mz;
        self.mz_max += delta_mz;
    }
};

pub const PanState = struct {
    is_panning: bool,
    start_x: i32,
    start_mz: f64,
};

pub const ViewState = struct {
    zoom: ZoomState,
    view_mode: ViewMode,
    show_peak_labels: bool,
    parse_peak_metadata: bool,
    pan: PanState,
    filter_ms_level: ?u8,

    pub fn init() ViewState {
        return .{
            .zoom = .{
                .mz_min = 0,
                .mz_max = 1,
                .inten_min = 0,
                .inten_max = 1,
            },
            .view_mode = .stick,
            .show_peak_labels = false,
            .parse_peak_metadata = true,
            .pan = .{
                .is_panning = false,
                .start_x = 0,
                .start_mz = 0,
            },
            .filter_ms_level = null,
        };
    }

    pub fn reset_zoom(self: *ViewState, spectrum: *const advanced.Spectrum) void {
        self.zoom.reset(spectrum);
    }

    pub fn set_ms_level_filter(self: *ViewState, level: ?u8) void {
        self.filter_ms_level = level;
    }

    pub fn is_panning(self: ViewState) bool {
        return self.pan.is_panning;
    }

    pub fn start_pan(self: *ViewState, screen_x: i32, mz: f64) void {
        self.pan.is_panning = true;
        self.pan.start_x = screen_x;
        self.pan.start_mz = mz;
    }

    pub fn end_pan(self: *ViewState) void {
        self.pan.is_panning = false;
    }
};

test "ViewState init has sane defaults" {
    var vs = ViewState.init();
    try std.testing.expect(!vs.is_panning());
    try std.testing.expectEqual(ViewMode.stick, vs.view_mode);
    try std.testing.expect(!vs.show_peak_labels);
    try std.testing.expect(vs.parse_peak_metadata);
    try std.testing.expect(vs.filter_ms_level == null);
}

test "ZoomState zoomAround preserves center" {
    var zs = ZoomState{ .mz_min = 100, .mz_max = 200, .inten_min = 0, .inten_max = 100 };
    zs.zoom_around(150, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 150.0), (zs.mz_min + zs.mz_max) / 2.0, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), zs.mz_span(), 1e-10);
}

test "PanState start/end cycle" {
    var vs = ViewState.init();
    vs.start_pan(100, 500.0);
    try std.testing.expect(vs.is_panning());
    try std.testing.expectEqual(@as(i32, 100), vs.pan.start_x);
    vs.end_pan();
    try std.testing.expect(!vs.is_panning());
}
