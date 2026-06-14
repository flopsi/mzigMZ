/// Unified internal representation for mass spectrometry data.
/// Format-agnostic bridge between the Thermo .raw reader and all writers.
const std = @import("std");

/// A single (m/z, intensity) pair — the fundamental unit of MS data.
/// Used only when AoS is needed; prefer SoA slices in Scan.
pub const Peak = struct {
    mz: f64,
    intensity: f64,
};

/// Controlled vocabulary parameter — typed metadata unit.
pub const CVParam = struct {
    cv_ref: []const u8 = "MS",
    accession: []const u8,
    name: []const u8,
    value: ?[]const u8 = null,
    unit: ?Unit = null,
};

pub const Unit = struct {
    cv_ref: []const u8,
    accession: []const u8,
    name: []const u8,
};

/// Scan window (m/z range) for a single scan.
pub const ScanWindow = struct {
    lower_limit: f64,
    upper_limit: f64,
};

/// Precursor information for MSn scans.
pub const Precursor = struct {
    /// Reference to precursor spectrum (e.g., "scan=42"), null for DIA
    spectrum_ref: ?[]const u8 = null,
    /// Isolation target m/z
    isolation_mz: f64,
    /// Isolation window width (full width, e.g., 2.0 for ±1.0 Th)
    isolation_width: ?f64 = null,
    /// Charge state, null if unknown
    charge: ?i32 = null,
    /// Collision energy in eV (or normalized collision energy)
    collision_energy: ?f64 = null,
    /// Activation type: "HCD", "CID", "ETD", "ECD", etc.
    activation_type: ?[]const u8 = null,
};

/// A single mass spectrum scan.
/// Uses Structure of Arrays (SoA) for peaks: mz[] and intensity[] are
/// separate slices of equal length. This is cache-friendly and matches
/// both the .raw reader output and mzML binary arrays.
pub const Scan = struct {
    /// 1-based scan number (as in the original file)
    scan_number: i32,
    /// 0-based index in the run
    index: usize,
    /// Spectrum ID string (e.g., "scan=123", "controllerType=0 controllerNumber=1 scan=123")
    id: []const u8,
    /// MS level: 1=MS1, 2=MS2, 3=MS3, etc.
    ms_level: u8,
    /// Retention time in minutes
    rt: f64,
    /// m/z values — borrowed slice, owned by MsRun
    mz: []const f64,
    /// Intensity values — borrowed slice, owned by MsRun
    intensity: []const f32,

    // Metadata
    /// Total ion current
    tic: f64,
    /// Base peak m/z (null if not available)
    base_peak_mz: ?f64,
    /// Base peak intensity (null if not available)
    base_peak_intensity: ?f64,
    /// Lowest observed m/z
    lowest_mz: f64,
    /// Highest observed m/z
    highest_mz: f64,
    /// Raw packet type (for profile vs centroid labeling)
    packet_type: u32 = 0,
    /// Thermo filter string (e.g., "FTMS + p NSI Full ms [350.00-1800.00]")
    filter_string: ?[]const u8,

    // MSn
    precursor: ?Precursor,

    // Scan event params (for mzML cvParams)
    scan_params: []const CVParam = &[_]CVParam{},
    scan_windows: []const ScanWindow = &[_]ScanWindow{},

    /// Return the number of peaks in this scan.
    pub fn peak_count(self: Scan) usize {
        return self.mz.len;
    }

    /// Compute base peak from peak data if not already set.
    pub fn compute_base_peak(self: *Scan) void {
        if (self.base_peak_mz != null and self.base_peak_intensity != null) return;
        if (self.mz.len == 0) return;
        var bp_mz: f64 = self.mz[0];
        var bp_inten: f32 = self.intensity[0];
        for (self.mz[1..], self.intensity[1..]) |m, inten| {
            if (inten > bp_inten) {
                bp_mz = m;
                bp_inten = inten;
            }
        }
        self.base_peak_mz = bp_mz;
        self.base_peak_intensity = @floatCast(bp_inten);
    }

    /// Compute lowest/highest m/z from peak data if not already set.
    pub fn compute_mz_range(self: *Scan) void {
        if (self.mz.len == 0) return;
        var lo = self.mz[0];
        var hi = self.mz[0];
        for (self.mz[1..]) |m| {
            if (m < lo) lo = m;
            if (m > hi) hi = m;
        }
        self.lowest_mz = lo;
        self.highest_mz = hi;
    }
};

/// A complete LC-MS/MS run.
/// Owns all scan data. Use arena allocator for easy cleanup.
pub const MsRun = struct {
    /// Run identifier
    id: []const u8,
    /// Instrument configuration CV params
    instrument_params: []const CVParam = &[_]CVParam{},
    /// All scans in acquisition order
    scans: []const Scan,
    /// Software list (converter tool, etc.)
    software_list: []const Software = &[_]Software{},
    /// Data processing list
    data_processing: []const DataProcessing = &[_]DataProcessing{},
    /// Source file info
    source_file: ?SourceFile = null,
};

pub const Software = struct {
    id: []const u8,
    version: []const u8,
    cv_params: []const CVParam = &[_]CVParam{},
};

pub const DataProcessing = struct {
    id: []const u8,
    processing_methods: []const ProcessingMethod = &[_]ProcessingMethod{},
};

pub const ProcessingMethod = struct {
    order: usize,
    software_ref: []const u8,
    cv_params: []const CVParam = &[_]CVParam{},
};

pub const SourceFile = struct {
    id: []const u8,
    name: []const u8,
    location: []const u8,
    cv_params: []const CVParam = &[_]CVParam{},
};

// ============================================================================
// Tests
// ============================================================================

test "Scan peakCount" {
    const mz = &[_]f64{ 100.0, 200.0, 300.0 };
    const intensity = &[_]f32{ 10.0, 20.0, 30.0 };
    const scan = Scan{
        .scan_number = 1,
        .index = 0,
        .id = "scan=1",
        .ms_level = 1,
        .rt = 0.5,
        .mz = mz,
        .intensity = intensity,
        .tic = 60.0,
        .base_peak_mz = null,
        .base_peak_intensity = null,
        .lowest_mz = 100.0,
        .highest_mz = 300.0,
        .filter_string = null,
        .precursor = null,
    };
    try std.testing.expectEqual(@as(usize, 3), scan.peak_count());
}

test "Scan computeBasePeak" {
    const mz = &[_]f64{ 100.0, 200.0, 300.0 };
    const intensity = &[_]f32{ 10.0, 50.0, 30.0 };
    var scan = Scan{
        .scan_number = 1,
        .index = 0,
        .id = "scan=1",
        .ms_level = 1,
        .rt = 0.5,
        .mz = mz,
        .intensity = intensity,
        .tic = 90.0,
        .base_peak_mz = null,
        .base_peak_intensity = null,
        .lowest_mz = 100.0,
        .highest_mz = 300.0,
        .filter_string = null,
        .precursor = null,
    };
    scan.compute_base_peak();
    try std.testing.expectApproxEqAbs(200.0, scan.base_peak_mz.?, 0.001);
    try std.testing.expectApproxEqAbs(50.0, scan.base_peak_intensity.?, 0.001);
}

test "Precursor struct" {
    const prec = Precursor{
        .isolation_mz = 712.35,
        .isolation_width = 2.0,
        .charge = 2,
        .collision_energy = 30.0,
        .activation_type = "HCD",
    };
    try std.testing.expectApproxEqAbs(712.35, prec.isolation_mz, 0.001);
    try std.testing.expectEqual(@as(i32, 2), prec.charge.?);
}
