const std = @import("std");

/// Chromatogram data extracted from scan indices (no packet decode needed).
/// Contains all scans; filtering by MS level happens at render time.
pub const Chromatogram = struct {
    rt: []f64,              // retention time in minutes
    intensity: []f64,       // TIC or base peak intensity
    ms_level: []u8,         // 1=MS1, 2=MS2, etc.
    num_points: usize,

    pub fn deinit(self: Chromatogram, allocator: std.mem.Allocator) void {
        allocator.free(self.rt);
        allocator.free(self.intensity);
        allocator.free(self.ms_level);
    }
};

/// Scan metadata needed for chromatogram extraction.
pub const ScanMeta = struct {
    rt: f64,
    tic: f64,
    base_peak_intensity: f64,
    ms_level: u8,
};

/// Extract TIC chromatogram from scan metadata.
pub fn extractTIC(allocator: std.mem.Allocator, scans: []const ScanMeta) !Chromatogram {
    const n = scans.len;
    const rt = try allocator.alloc(f64, n);
    errdefer allocator.free(rt);
    const intensity = try allocator.alloc(f64, n);
    errdefer allocator.free(intensity);
    const ms_level = try allocator.alloc(u8, n);
    errdefer allocator.free(ms_level);

    for (scans, 0..) |scan, i| {
        rt[i] = scan.rt;
        intensity[i] = scan.tic;
        ms_level[i] = scan.ms_level;
    }

    return .{
        .rt = rt,
        .intensity = intensity,
        .ms_level = ms_level,
        .num_points = n,
    };
}

/// Extract Base Peak chromatogram from scan metadata.
pub fn extractBPC(allocator: std.mem.Allocator, scans: []const ScanMeta) !Chromatogram {
    const n = scans.len;
    const rt = try allocator.alloc(f64, n);
    errdefer allocator.free(rt);
    const intensity = try allocator.alloc(f64, n);
    errdefer allocator.free(intensity);
    const ms_level = try allocator.alloc(u8, n);
    errdefer allocator.free(ms_level);

    for (scans, 0..) |scan, i| {
        rt[i] = scan.rt;
        intensity[i] = scan.base_peak_intensity;
        ms_level[i] = scan.ms_level;
    }

    return .{
        .rt = rt,
        .intensity = intensity,
        .ms_level = ms_level,
        .num_points = n,
    };
}

/// Build a slice of ScanMeta from the app's scan info (caller must free).
/// This is a zero-copy view — the returned slice references the scan array.
pub fn buildScanMeta(allocator: std.mem.Allocator, scans: []const ScanMeta) ![]ScanMeta {
    // Already in the right format, just return a copy or the same slice
    // In practice, the caller already has []ScanMeta from their ScanInfo array
    const result = try allocator.alloc(ScanMeta, scans.len);
    @memcpy(result, scans);
    return result;
}
