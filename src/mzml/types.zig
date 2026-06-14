/// mzML-specific types for the streaming serializer.
/// Re-exports core types and adds mzML-specific structures (Spectrum, RunInfo, etc.).
const std = @import("std");
const core = @import("types");

pub const CVParam = core.CVParam;
pub const Unit = core.Unit;
pub const Precursor = core.Precursor;
pub const ScanWindow = core.ScanWindow;
pub const Peak = core.Peak;
pub const Software = core.Software;
pub const DataProcessing = core.DataProcessing;
pub const ProcessingMethod = core.ProcessingMethod;
pub const SourceFile = core.SourceFile;

pub const Product = struct {
    isolation_mz: f64,
    isolation_width: ?f64 = null,
};

/// A spectrum in mzML representation (AoS for peak data).
pub const Spectrum = struct {
    index: usize,
    id: []const u8,
    ms_level: u8,
    peaks: []const Peak,
    rt: ?f64,
    tic: f64,
    base_peak_mz: ?f64,
    base_peak_intensity: ?f64,
    lowest_mz: f64,
    highest_mz: f64,
    scan_params: []const CVParam,
    scan_windows: []const ScanWindow,
    filter_string: ?[]const u8 = null,
    precursor: ?Precursor,
    product: ?Product = null,
    default_array_length: usize,
    is_profile: bool = false,
    instrument_config_ref: ?[]const u8 = null,

    pub const SliceError = std.mem.Allocator.Error;

    pub fn mz_slice(self: Spectrum, allocator: std.mem.Allocator) SliceError![]f64 {
        const result = try allocator.alloc(f64, self.peaks.len);
        for (self.peaks, 0..) |peak, i| result[i] = peak.mz;
        return result;
    }

    pub fn intensity_slice(self: Spectrum, allocator: std.mem.Allocator) SliceError![]f64 {
        const result = try allocator.alloc(f64, self.peaks.len);
        for (self.peaks, 0..) |peak, i| result[i] = peak.intensity;
        return result;
    }
};

pub const InstrumentComponent = struct {
    order: u8,
    params: []const CVParam,
};

pub const InstrumentConfiguration = struct {
    id: []const u8,
    params: []const CVParam,
    components: ?[]const InstrumentComponent = null,
    ref_param_group: ?[]const u8 = null,
};

pub const ChromatogramList = struct {
    rt: []const f64,
    tic: []const f64,
    bpc: []const f64,
};

pub const RunInfo = struct {
    id: []const u8,
    start_time: ?[]const u8 = null,
    default_instrument_config_ref: ?[]const u8 = null,
    instrument_params: []const CVParam = &[_]CVParam{},
    instrument_configuration: ?InstrumentConfiguration = null,
    ref_param_group_params: ?[]const CVParam = null,
    software_list: []const Software = &[_]Software{},
    file_description: ?FileDescription = null,
    data_processing: []const DataProcessing = &[_]DataProcessing{},
};

pub const FileDescription = struct {
    file_content: []const CVParam,
    source_files: []const SourceFile = &[_]SourceFile{},
    contacts: []const Contact = &[_]Contact{},
};

pub const Contact = struct {
    cv_params: []const CVParam = &[_]CVParam{},
};

pub const Chromatogram = struct {
    index: usize,
    id: []const u8,
    chromatogram_type: ChromatogramType,
    times: []const f64,
    values: []const f64,
    cv_params: []const CVParam = &[_]CVParam{},

    pub const ChromatogramType = enum {
        tic,
        bpc,
        xic,
        sic,
        other,
    };
};

test "Spectrum mzSlice" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const peaks = &[_]Peak{
        .{ .mz = 100.0, .intensity = 10.0 },
        .{ .mz = 200.0, .intensity = 20.0 },
    };
    const spectrum = Spectrum{
        .index = 0,
        .id = "scan=1",
        .ms_level = 1,
        .peaks = peaks,
        .rt = 0.5,
        .tic = 30.0,
        .base_peak_mz = 200.0,
        .base_peak_intensity = 20.0,
        .lowest_mz = 100.0,
        .highest_mz = 200.0,
        .scan_params = &[_]CVParam{},
        .scan_windows = &[_]ScanWindow{},
        .precursor = null,
        .default_array_length = 2,
    };

    const mz = try spectrum.mz_slice(allocator);
    defer allocator.free(mz);
    try std.testing.expectEqual(@as(usize, 2), mz.len);
    try std.testing.expectEqual(@as(f64, 100.0), mz[0]);
    try std.testing.expectEqual(@as(f64, 200.0), mz[1]);
}
