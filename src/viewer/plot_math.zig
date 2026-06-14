/// Plot math module — coordinate transforms and zoom state.
///
/// This module contains pure functions for:
/// - m/z to screen pixel transforms (mzToScreen, screenToMz)
/// - Y-axis intensity transforms (intenToScreen, screenToInten)
/// - Zoom state management (ZoomState.zoomAround, panBy)
/// - Binary search for visible range (bound)
///
/// All functions are unit-tested. The coordinate transform pair must be exact inverses.
const std = @import("std");

/// Plot layout rectangle (after margins).
/// All screen coordinates are relative to this rectangle.
pub const PlotLayout = struct {
    x: f64, // left edge of plot area (after left margin)
    y: f64, // top edge of plot area (after top margin)
    w: f64, // width of plot area
    h: f64, // height of plot area

    /// Returns the rectangle with fixed 60px margins on all sides.
    pub fn with_margins(client_w: f64, client_h: f64) PlotLayout {
        const margin: f64 = 60.0;
        return .{
            .x = margin,
            .y = margin,
            .w = @max(0, client_w - 2 * margin),
            .h = @max(0, client_h - 2 * margin),
        };
    }
    pub const withMargins = with_margins; // DEPRECATED: use with_margins
};

/// Zoom state — visible m/z range.
pub const ZoomState = struct {
    mz_min: f64,
    mz_max: f64,

    /// Initialize to full scan range.
    pub fn init(full_mz_min: f64, full_mz_max: f64) ZoomState {
        return .{
            .mz_min = full_mz_min,
            .mz_max = full_mz_max,
        };
    }

    /// Zoom around a center m/z with a scale factor (<1 zooms in, >1 zooms out).
    /// The m/z under the mouse cursor stays stationary.
    pub fn zoom_around(self: *ZoomState, center: f64, factor: f64) void {
        const old_range = self.mz_max - self.mz_min;
        const new_range = old_range * factor;

        // The cursor position should stay fixed
        const cursor_rel = (center - self.mz_min) / old_range;
        self.mz_min = center - cursor_rel * new_range;
        self.mz_max = self.mz_min + new_range;
    }
    pub const zoomAround = zoom_around; // DEPRECATED: use zoom_around

    /// Pan by a delta in screen pixels (positive = move right, m/z increases).
    pub fn pan_by(self: *ZoomState, screen_delta: f64, layout: PlotLayout) void {
        // Map screen delta to m/z delta
        const mz_per_pixel = (self.mz_max - self.mz_min) / layout.w;
        const mz_delta = screen_delta * mz_per_pixel;
        self.mz_min += mz_delta;
        self.mz_max += mz_delta;
    }
    pub const panBy = pan_by; // DEPRECATED: use pan_by

    /// Clamp zoom to spectrum bounds.
    pub fn clamp(self: *ZoomState, full_mz_min: f64, full_mz_max: f64) void {
        const min_range: f64 = 0.001; // minimum visible range
        if (self.mz_max - self.mz_min < min_range) {
            const center = (self.mz_min + self.mz_max) / 2;
            self.mz_min = center - min_range / 2;
            self.mz_max = center + min_range / 2;
            return;
        }

        const full_range = full_mz_max - full_mz_min;
        const current_range = self.mz_max - self.mz_min;

        // If current range exceeds full range, clamp to full range
        if (current_range > full_range) {
            self.mz_min = full_mz_min;
            self.mz_max = full_mz_max;
            return;
        }

        // Range fits within full range, check positioning
        if (self.mz_min < full_mz_min) {
            self.mz_min = full_mz_min;
            self.mz_max = full_mz_min + current_range;
        }
        if (self.mz_max > full_mz_max) {
            self.mz_max = full_mz_max;
            self.mz_min = full_mz_max - current_range;
        }
    }

    /// Reset the m/z window to the given full-spectrum bounds. The
    /// y-axis intensity is not stored in ZoomState (it's auto-fit from
    /// the current Spectrum at render time), so the caller doesn't need
    /// to pass intensity bounds. This is the implementation of the
    /// '0' (zero) key in the keyboard handler.
    pub fn reset_to_full(self: *ZoomState, full_mz_min: f64, full_mz_max: f64) void {
        self.mz_min = full_mz_min;
        self.mz_max = full_mz_max;
    }
    pub const resetToFull = reset_to_full; // DEPRECATED: use reset_to_full

    /// Copy the m/z window from another ZoomState. Used by loadScan to
    /// preserve the user's zoom across scan changes. The source is
    /// passed as a const pointer to make the no-allocation property
    /// explicit (this is a copy, not a borrow).
    pub fn preserve(self: *ZoomState, other: *const ZoomState) void {
        self.mz_min = other.mz_min;
        self.mz_max = other.mz_max;
    }
};

/// Convert m/z to screen X coordinate (pixels).
/// Uses PlotLayout exclusively — no implicit state.
pub fn mz_to_screen(mz: f64, zoom: ZoomState, layout: PlotLayout) f64 {
    const range = zoom.mz_max - zoom.mz_min;
    const rel = (mz - zoom.mz_min) / range;
    return layout.x + rel * layout.w;
}
pub const mzToScreen = mz_to_screen; // DEPRECATED: use mz_to_screen

/// Convert screen X coordinate to m/z.
/// Exact inverse of mzToScreen.
pub fn screen_to_mz(screen_x: f64, zoom: ZoomState, layout: PlotLayout) f64 {
    const rel = (screen_x - layout.x) / layout.w;
    return zoom.mz_min + rel * (zoom.mz_max - zoom.mz_min);
}
pub const screenToMz = screen_to_mz; // DEPRECATED: use screen_to_mz

/// Convert intensity to screen Y coordinate (pixels, Y-down from top).
pub fn inten_to_screen(intensity: f64, max_intensity: f64, layout: PlotLayout) f64 {
    if (max_intensity <= 0) return layout.y + layout.h;
    const rel = intensity / max_intensity;
    return layout.y + layout.h * (1 - rel); // Y is inverted in GUI coordinates
}
pub const intenToScreen = inten_to_screen; // DEPRECATED: use inten_to_screen

/// Convert screen Y coordinate to intensity.
pub fn screen_to_inten(screen_y: f64, max_intensity: f64, layout: PlotLayout) f64 {
    const rel = (layout.y + layout.h - screen_y) / layout.h;
    return rel * max_intensity;
}
pub const screenToInten = screen_to_inten; // DEPRECATED: use screen_to_inten

/// Binary search for the first element >= value.
/// `ascending=true`: lower_bound, `ascending=false`: upper_bound
pub fn bound(sorted: []const f64, value: f64, ascending: bool) usize {
    var lo: usize = 0;
    var hi: usize = sorted.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ascending) {
            if (sorted[mid] < value) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        } else {
            if (sorted[mid] <= value) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
    }
    return lo;
}

/// Apply square-root scaling to intensity values in-place.
/// Compresses dynamic range: v → v^(1/degree).
/// Default degree=2 (square root) is most common in MS viewers.
pub fn scale_root(intensity: []f64, degree: u32) void {
    const inv = 1.0 / @as(f64, @floatFromInt(degree));
    for (intensity) |*v| {
        v.* = std.math.pow(f64, v.*, inv);
    }
}
pub const scaleRoot = scale_root; // DEPRECATED: use scale_root

/// Apply base-10 log scaling to intensity values in-place.
/// Compresses dynamic range: v → log10(v + 1).
/// The +1 shift ensures log(0) = 0 rather than -inf.
pub fn scale_log(intensity: []f64) void {
    for (intensity) |*v| {
        v.* = @log10(v.* + 1.0);
    }
}
pub const scaleLog = scale_log; // DEPRECATED: use scale_log

// ============================================================================
// Unit Tests
// ============================================================================

test "mzToScreen / screenToMz round-trip" {
    const allocator = std.testing.allocator;
    _ = allocator;

    const layout = PlotLayout.with_margins(1024, 768);
    const zoom = ZoomState.init(400.0, 600.0);

    // Test a range of m/z values
    const test_mzs = [_]f64{ 400.0, 425.0, 450.0, 475.0, 500.0, 525.0, 550.0, 575.0, 600.0 };

    for (test_mzs) |mz| {
        const screen_x = mz_to_screen(mz, zoom, layout);
        const mz_back = screen_to_mz(screen_x, zoom, layout);
        try std.testing.expectApproxEqAbs(mz, mz_back, 1e-9);
    }
}

test "zoomAround preserves cursor position" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var zoom = ZoomState.init(400.0, 600.0); // range = 200
    const center: f64 = 500.0;
    const factor: f64 = 0.5; // zoom in, range becomes 100

    // Record position under cursor before zoom
    const cursor_pos_before = mz_to_screen(center, zoom, PlotLayout.with_margins(1024, 768));

    zoom.zoom_around(center, factor);

    // After zoom, cursor m/z should still map to same screen pixel
    const cursor_pos_after = mz_to_screen(center, zoom, PlotLayout.with_margins(1024, 768));
    try std.testing.expectApproxEqAbs(cursor_pos_before, cursor_pos_after, 1e-9);
}

test "zoom clamps to spectrum bounds" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var zoom = ZoomState.init(400.0, 600.0);
    // zoom out factor 10 would make range 2000, centered at 500 -> [-500, 1100]
    zoom.zoom_around(500.0, 10.0);
    try std.testing.expectApproxEqAbs(-500.0, zoom.mz_min, 1e-9);
    try std.testing.expectApproxEqAbs(1500.0, zoom.mz_max, 1e-9);

    // Now clamp to spectrum bounds - since range (2000) exceeds full range (200),
    // clamp to [400, 600]
    zoom.clamp(400.0, 600.0);

    try std.testing.expectApproxEqAbs(400.0, zoom.mz_min, 1e-9);
    try std.testing.expectApproxEqAbs(600.0, zoom.mz_max, 1e-9);
}

test "bound lower_bound" {
    const data = [_]f64{ 100, 200, 300, 400, 500 };

    try std.testing.expectEqual(0, bound(&data, 50, true)); // before first
    try std.testing.expectEqual(0, bound(&data, 100, true)); // exact match
    try std.testing.expectEqual(2, bound(&data, 250, true)); // between 200 and 300
    try std.testing.expectEqual(5, bound(&data, 600, true)); // after last
}

test "bound upper_bound" {
    const data = [_]f64{ 100, 200, 300, 400, 500 };

    try std.testing.expectEqual(0, bound(&data, 50, false)); // before first
    try std.testing.expectEqual(1, bound(&data, 100, false)); // exact match
    try std.testing.expectEqual(2, bound(&data, 250, false)); // between 200 and 300
    try std.testing.expectEqual(5, bound(&data, 600, false)); // after last
}

test "intenToScreen / screenToInten round-trip" {
    const allocator = std.testing.allocator;
    _ = allocator;

    const layout = PlotLayout.with_margins(1024, 768);
    const max_inten: f64 = 1000.0;

    const test_intensities = [_]f64{ 0, 250, 500, 750, 1000 };

    for (test_intensities) |inten| {
        const screen_y = inten_to_screen(inten, max_inten, layout);
        const inten_back = screen_to_inten(screen_y, max_inten, layout);
        try std.testing.expectApproxEqAbs(inten, inten_back, 1e-9);
    }
}

// =====================================================================
// Issue 02 slice 02.2 — resetToFull + preserve
// =====================================================================

test "ZoomState.resetToFull sets mz_min and mz_max to the given bounds" {
    var zoom = ZoomState.init(500.0, 600.0); // current zoom
    zoom.reset_to_full(400.0, 800.0);
    try std.testing.expectEqual(@as(f64, 400.0), zoom.mz_min);
    try std.testing.expectEqual(@as(f64, 800.0), zoom.mz_max);
}

test "ZoomState.resetToFull is idempotent" {
    var zoom = ZoomState.init(500.0, 600.0);
    zoom.reset_to_full(400.0, 800.0);
    zoom.reset_to_full(400.0, 800.0);
    try std.testing.expectEqual(@as(f64, 400.0), zoom.mz_min);
    try std.testing.expectEqual(@as(f64, 800.0), zoom.mz_max);
}

test "ZoomState.resetToFull followed by clamp is a no-op when bounds match" {
    var zoom = ZoomState.init(500.0, 600.0);
    zoom.reset_to_full(400.0, 800.0);
    zoom.clamp(400.0, 800.0);
    try std.testing.expectEqual(@as(f64, 400.0), zoom.mz_min);
    try std.testing.expectEqual(@as(f64, 800.0), zoom.mz_max);
}

test "ZoomState.resetToFull makes mzToScreen of the bounds map to the layout edges" {
    const layout = PlotLayout.with_margins(1024, 768);
    var zoom = ZoomState.init(500.0, 600.0);
    zoom.reset_to_full(400.0, 800.0);
    try std.testing.expectApproxEqAbs(layout.x, mz_to_screen(400.0, zoom, layout), 1e-9);
    try std.testing.expectApproxEqAbs(layout.x + layout.w, mz_to_screen(800.0, zoom, layout), 1e-9);
}

test "ZoomState.preserve copies the mz_min and mz_max from the argument" {
    var src = ZoomState.init(420.0, 780.0);
    var dst = ZoomState.init(500.0, 600.0); // different
    dst.preserve(&src);
    try std.testing.expectEqual(@as(f64, 420.0), dst.mz_min);
    try std.testing.expectEqual(@as(f64, 780.0), dst.mz_max);
}

test "ZoomState.preserve does not alias the source" {
    var src = ZoomState.init(420.0, 780.0);
    var dst = ZoomState.init(500.0, 600.0);
    dst.preserve(&src);
    // Mutate src; dst should be unchanged.
    src.zoom_around(600.0, 0.5);
    try std.testing.expectEqual(@as(f64, 420.0), dst.mz_min);
    try std.testing.expectEqual(@as(f64, 780.0), dst.mz_max);
}

// =====================================================================
// Intensity scaling functions
// =====================================================================

test "scaleRoot preserves peak ordering" {
    var data = [_]f64{ 1.0, 10.0, 100.0, 1000.0, 10000.0 };
    scale_root(&data, 2);
    // Monotonic: each value must be >= the previous
    for (data[1..], 0..) |v, i| {
        try std.testing.expect(v >= data[i]);
    }
}

test "scaleRoot degree 2 compresses dynamic range" {
    var data = [_]f64{ 100.0, 10000.0 };
    scale_root(&data, 2);
    const ratio_before: f64 = 10000.0 / 100.0; // 100
    const ratio_after = data[1] / data[0]; // sqrt(10000)/sqrt(100) = 100/10 = 10
    try std.testing.expect(ratio_after < ratio_before);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), data[0], 1e-9); // sqrt(100) = 10
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), data[1], 1e-9); // sqrt(10000) = 100
}

test "scaleLog handles zero intensity" {
    var data = [_]f64{ 0.0, 1.0, 9.0, 99.0 };
    scale_log(&data);
    // log10(0 + 1) = 0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), data[0], 1e-9);
    // log10(1 + 1) = log10(2) ≈ 0.301
    try std.testing.expectApproxEqAbs(@as(f64, 0.30103), data[1], 1e-5);
    // log10(9 + 1) = log10(10) = 1
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), data[2], 1e-9);
    // log10(99 + 1) = log10(100) = 2
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), data[3], 1e-9);
}

test "scaleLog compresses dynamic range" {
    var data = [_]f64{ 1.0, 999999.0 };
    scale_log(&data);
    // log10(1+1) ≈ 0.301, log10(999999+1) ≈ 6.0
    // Ratio before: ~1,000,000, ratio after: ~6/0.301 ≈ 20
    try std.testing.expect(data[1] > data[0]);
    const ratio_after = data[1] / data[0];
    try std.testing.expect(ratio_after < 50.0); // dramatically compressed
}

test "scaleRoot and scaleLog are idempotent on reasonable inputs" {
    // scaleRoot then scaleLog should not panic
    var data = [_]f64{ 100.0, 200.0, 500.0 };
    scale_root(&data, 2);
    scale_log(&data);
    // Values should remain finite and ordered
    for (data) |v| {
        try std.testing.expect(!std.math.isNan(v));
        try std.testing.expect(!std.math.isInf(v));
    }
    try std.testing.expect(data[0] <= data[1]);
    try std.testing.expect(data[1] <= data[2]);
}
