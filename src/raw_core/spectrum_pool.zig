/// SpectrumPool — owns reusable decode buffers to eliminate alloc churn.
///
/// Before this module, buffer management was split across AppState
/// (six separate `reuse_*` optional fields) and ScanDecoder (which
/// borrowed them). The duplication meant buffer sizing logic lived in
/// two places, and ownership rules were implicit.
///
/// SpectrumPool centralizes all decode buffers into one module with a
/// single growth policy. Callers:
/// - ScanDecoder.decode() — writes decoded data into pool buffers
/// - AppState.loadScan* — copies from pool (owned mode) or borrows (bulk mode)
const std = @import("std");
const advanced = @import("advanced_packet");

/// A spectrum whose arrays are borrowed from the pool.
/// Valid only until the next `ensure()` or `decode()` call.
pub const PooledSpectrum = struct {
    num_points: usize,
    mz: []f64,
    intensity: []f32,
    features: ?[]advanced.PeakFeatures,
    freq: ?[]f64,
    mz_min: f64,
    mz_max: f64,
    intensity_max: f32,
};

/// Grow-only buffer pool for decoded spectra.
/// Buffers never shrink; they only grow to accommodate the largest
/// spectrum seen so far. This amortizes allocation cost across bulk
/// iteration.
pub const SpectrumPool = struct {
    allocator: std.mem.Allocator,

    mz: std.ArrayList(f64),
    intensity: std.ArrayList(f32),
    features: std.ArrayList(advanced.PeakFeatures),
    freq: std.ArrayList(f64),

    pub fn init(allocator: std.mem.Allocator) SpectrumPool {
        return .{
            .allocator = allocator,
            .mz = .empty,
            .intensity = .empty,
            .features = .empty,
            .freq = .empty,
        };
    }

    pub fn deinit(self: *SpectrumPool) void {
        self.mz.deinit(self.allocator);
        self.intensity.deinit(self.allocator);
        self.features.deinit(self.allocator);
        self.freq.deinit(self.allocator);
    }

    /// Ensure all buffers can hold at least `len` elements.
    /// Grows only if current length is insufficient (grow-only).
    pub fn ensure(
        self: *SpectrumPool,
        len: usize,
        needs_features: bool,
        needs_freq: bool,
    ) !void {
        if (self.mz.items.len < len) {
            try self.mz.resize(self.allocator, len);
        }
        if (self.intensity.items.len < len) {
            try self.intensity.resize(self.allocator, len);
        }
        if (needs_features and self.features.items.len < len) {
            try self.features.resize(self.allocator, len);
        }
        if (needs_freq and self.freq.items.len < len) {
            try self.freq.resize(self.allocator, len);
        }
    }

    /// Return the current buffers sliced to `num_points` as a PooledSpectrum.
    /// The caller borrows the buffers; they are invalidated on the next
    /// `ensure()` or `decode()` call.
    pub fn borrow(
        self: *SpectrumPool,
        num_points: usize,
        mz_min: f64,
        mz_max: f64,
        intensity_max: f32,
        has_features: bool,
        has_freq: bool,
    ) PooledSpectrum {
        return .{
            .num_points = num_points,
            .mz = self.mz.items[0..num_points],
            .intensity = self.intensity.items[0..num_points],
            .features = if (has_features and self.features.items.len >= num_points)
                self.features.items[0..num_points]
            else
                null,
            .freq = if (has_freq and self.freq.items.len >= num_points)
                self.freq.items[0..num_points]
            else
                null,
            .mz_min = mz_min,
            .mz_max = mz_max,
            .intensity_max = intensity_max,
        };
    }

    /// Current capacity of the mz/intensity buffers.
    pub fn capacity(self: SpectrumPool) usize {
        return self.mz.capacity;
    }

    /// Buffers stolen from the pool by shrinkAndSteal.
    /// The caller owns the memory and must free it with the same allocator.
    /// freq is null if the decode was not a profile scan with freq enabled.
    ///
    /// After stealing, freqBuffer() returns null — the frequency buffer is
    /// freed alongside the stolen buffers. Decode a new profile scan to
    /// repopulate it.
    pub const StolenBuffers = struct {
        mz: []f64,
        intensity: []f32,
        features: ?[]advanced.PeakFeatures,
        freq: ?[]f64,
        mz_cap: usize,
        intensity_cap: usize,
        features_cap: usize,
        freq_cap: usize,
    };

    /// Shrink buffer lengths to `num_points` (no realloc) and steal the
    /// underlying allocations from the pool. The pool is reset to empty
    /// and will reallocate on the next `ensure()` call.
    /// freq is stolen only if the freq buffer has data (profile decode).
    pub fn shrink_and_steal(self: *SpectrumPool, num_points: usize, has_features: bool) StolenBuffers {
        self.mz.items.len = num_points;
        self.intensity.items.len = num_points;
        if (has_features) self.features.items.len = num_points;

        const mz_cap = self.mz.capacity;
        const intensity_cap = self.intensity.capacity;
        const features_cap = if (has_features) self.features.capacity else 0;

        const mz = self.mz.items;
        const intensity = self.intensity.items;
        const features = if (has_features) self.features.items else null;

        // Steal freq buffer if it has data (profile decode with freq)
        const has_freq = self.freq.items.len > 0;
        const freq: ?[]f64 = if (has_freq) self.freq.items else null;
        const freq_cap: usize = if (has_freq) self.freq.capacity else 0;

        self.mz = .empty;
        self.intensity = .empty;
        self.features = .empty;
        if (has_freq) self.freq = .empty;

        return .{
            .mz = mz,
            .intensity = intensity,
            .features = features,
            .freq = freq,
            .mz_cap = mz_cap,
            .intensity_cap = intensity_cap,
            .features_cap = features_cap,
            .freq_cap = freq_cap,
        };
    }
};

test "pool grows on first ensure" {
    var pool = SpectrumPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.ensure(100, true, true);
    try std.testing.expect(pool.capacity() >= 100);
    try std.testing.expect(pool.mz.items.len >= 100);
    try std.testing.expect(pool.intensity.items.len >= 100);
    try std.testing.expect(pool.features.items.len >= 100);
    try std.testing.expect(pool.freq.items.len >= 100);
}

test "borrow returns correct slices" {
    var pool = SpectrumPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.ensure(10, false, false);
    @memset(pool.mz.items[0..10], 1.0);
    @memset(pool.intensity.items[0..10], 2.0);

    const spec = pool.borrow(5, 0, 100, 50, false, false);
    try std.testing.expectEqual(@as(usize, 5), spec.num_points);
    try std.testing.expectEqual(@as(f64, 1.0), spec.mz[0]);
    try std.testing.expectEqual(@as(f32, 2.0), spec.intensity[0]);
    try std.testing.expect(spec.features == null);
    try std.testing.expect(spec.freq == null);
}

test "ensure does not shrink" {
    var pool = SpectrumPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.ensure(1000, false, false);
    const cap_before = pool.capacity();
    try pool.ensure(10, false, false);
    try std.testing.expectEqual(cap_before, pool.capacity());
}

test "shrinkAndSteal transfers ownership" {
    var pool = SpectrumPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.ensure(10, true, false);
    @memset(pool.mz.items[0..10], 1.0);
    @memset(pool.intensity.items[0..10], 2.0);
    @memset(pool.features.items[0..10], .{
        .charge = 0,
        .resolution = 0,
        .noise = 0,
        .baseline = 0,
        .sn_ratio = 0,
        .monoisotopic = false,
        .flags = .{},
    });

    const stolen = pool.shrink_and_steal(5, true);
    defer {
        std.testing.allocator.free(stolen.mz.ptr[0..stolen.mz_cap]);
        std.testing.allocator.free(stolen.intensity.ptr[0..stolen.intensity_cap]);
        if (stolen.features_cap > 0) {
            std.testing.allocator.free(stolen.features.?.ptr[0..stolen.features_cap]);
        }
    }

    try std.testing.expectEqual(@as(usize, 5), stolen.mz.len);
    try std.testing.expectEqual(@as(usize, 5), stolen.intensity.len);
    try std.testing.expect(stolen.features != null);
    try std.testing.expectEqual(@as(usize, 5), stolen.features.?.len);

    // Pool is empty after steal
    try std.testing.expectEqual(@as(usize, 0), pool.mz.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.intensity.items.len);
}

test "borrow with features and freq" {
    var pool = SpectrumPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.ensure(4, true, true);
    const spec = pool.borrow(4, 0, 1, 1, true, true);
    try std.testing.expect(spec.features != null);
    try std.testing.expect(spec.freq != null);
    try std.testing.expectEqual(@as(usize, 4), spec.features.?.len);
    try std.testing.expectEqual(@as(usize, 4), spec.freq.?.len);
}
