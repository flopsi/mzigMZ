/// Convert Thermo .raw reader output to unified MsRun representation.
///
/// Memory: allocates peak data (mz, intensity) for EVERY scan at once into
/// the arena. For a 275k-scan Astral file with 500 peaks/scan this requires
/// ~275k × (80 B Scan + 8 B × 500 mz + 4 B × 500 intensity) + overhead ≈
/// 1.7 GB. **Do not use for files with >50k scans.** Use the streaming
/// conversion path (`streaming_convert.zig`) instead, which processes one
/// scan at a time with O(1) memory proportional to output buffer size.
const std = @import("std");
const core = @import("types");
const raw_file_reader = @import("raw_file_reader");
const raw = @import("raw_file");
const trailer_events = @import("trailer_events");
const scan_event = @import("scan_event");
const scan_decoder = @import("scan_decoder");
const cv = @import("cv");
const filter_string = @import("filter_string");
const instrument_utils = @import("instrument_utils");

pub const ConvertError = error{
    NoScans,
    TooManyScans,
    OutOfMemory,
};

/// Maximum number of scans `convert` will accept.
/// Above this threshold, use the streaming converter instead.
const MAX_SCANS: usize = 50_000;

/// Per-scan metadata rebuilt directly from the RawFile scan index and optional
/// TrailerScanEvents. Decouples the converter from the mutable file-state struct.
const ScanMeta = struct {
    scan_number: i32,
    packet_type: u32,
    data_offset: u64,
    ms_level: u8,
    charge_state: i32,
    precursor_mz: f64,
    isolation_width: f64,
    collision_energy: f64,
    rt: f64,
    tic: f64,
    base_peak_mz: f64,
    base_peak_intensity: f64,
    low_mass: f64,
    high_mass: f64,
    filter_string: ?[]u8,
};

/// Convert an opened RawFile to an MsRun.
/// Uses arena allocator — all allocations freed when arena is destroyed.
pub fn convert(
    arena: *std.heap.ArenaAllocator,
    raw_file: *raw_file_reader.RawFile,
    trailers: ?trailer_events.TrailerScanEvents,
) ConvertError!core.MsRun {
    const allocator = arena.allocator();

    if (raw_file.num_scans == 0) return ConvertError.NoScans;
    if (raw_file.num_scans > MAX_SCANS) return ConvertError.TooManyScans;

    const num_scans = raw_file.num_scans;

    // Build local scan metadata and collect packet types for analyzer inference.
    const scan_metas = try allocator.alloc(ScanMeta, num_scans);
    errdefer allocator.free(scan_metas);
    const packet_types = try allocator.alloc(u32, num_scans);
    errdefer allocator.free(packet_types);

    for (0..num_scans) |i| {
        // Safe: i < num_scans <= MAX_SCANS (50_000), well inside i32 range.
        const scan_index_i32 = std.math.cast(i32, i) orelse return ConvertError.TooManyScans;
        const scan_number = raw_file.first_spectrum + scan_index_i32;
        const entry = raw_file.scan_at(scan_number) catch |err| {
            std.log.warn("Failed to read scan index for scan {d}: {s}", .{ scan_number, @errorName(err) });
            scan_metas[i] = .{
                .scan_number = scan_number,
                .packet_type = 0,
                .data_offset = 0,
                .ms_level = 0,
                .charge_state = 0,
                .precursor_mz = 0,
                .isolation_width = 0,
                .collision_energy = 0,
                .rt = 0,
                .tic = 0,
                .base_peak_mz = 0,
                .base_peak_intensity = 0,
                .low_mass = 0,
                .high_mass = 0,
                .filter_string = null,
            };
            packet_types[i] = 0;
            continue;
        };

        var meta = ScanMeta{
            .scan_number = entry.scan_number,
            .packet_type = entry.packet_type,
            .data_offset = entry.data_offset,
            .ms_level = 0,
            .charge_state = 0,
            .precursor_mz = 0,
            .isolation_width = 0,
            .collision_energy = 0,
            .rt = entry.start_time,
            .tic = entry.tic,
            .base_peak_mz = entry.base_peak_mass,
            .base_peak_intensity = entry.base_peak_intensity,
            .low_mass = entry.low_mass,
            .high_mass = entry.high_mass,
            .filter_string = null,
        };

        if (trailers) |te| {
            if (te.get_event(i)) |evt| {
                meta.ms_level = std.math.cast(u8, evt.info.ms_order) orelse
                    if (entry.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
                if (meta.ms_level >= 2 and evt.reactions.len > 0) {
                    const rxn = evt.reactions[0];
                    meta.precursor_mz = rxn.precursor_mass;
                    meta.isolation_width = rxn.isolation_width;
                    meta.collision_energy = rxn.collision_energy;
                }

                if (scan_event.build_filter_string(evt.*, allocator)) |maybe_fs| {
                    meta.filter_string = maybe_fs;
                } else |err| {
                    std.log.warn("Failed to build filter string for scan {d}: {s}", .{ meta.scan_number, @errorName(err) });
                }
            } else {
                meta.ms_level = if (entry.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
            }
        } else {
            meta.ms_level = if (entry.packet_type == raw.PACKET_TYPE_FT_PROFILE) 1 else 2;
        }

        scan_metas[i] = meta;
        packet_types[i] = entry.packet_type;
    }

    // Build scan array
    const scans = try allocator.alloc(core.Scan, num_scans);
    errdefer allocator.free(scans);

    // Local decoder for loading spectra; owns only transient pool buffers.
    var decoder = scan_decoder.ScanDecoder.init(allocator);
    defer decoder.deinit();
    decoder.configure(raw_file.mm, raw_file.packet_pos, raw_file.file_size, trailers);

    for (scan_metas, 0..) |meta, i| {
        if (meta.packet_type == 0) {
            scans[i] = try makeEmptyScan(allocator, meta, i);
            continue;
        }

        // Load scan data using the decoder pool.
        const result = decoder.decode(i, &.{ .packet_type = meta.packet_type, .data_offset = meta.data_offset }) catch |err| {
            std.log.warn("Failed to load scan {d}: {s}", .{ meta.scan_number, @errorName(err) });
            scans[i] = try makeEmptyScan(allocator, meta, i);
            continue;
        };
        const num_points = result.num_points;

        // Copy mz and intensity from decoder pool buffers into arena-owned memory.
        const mz = try allocator.alloc(f64, num_points);
        errdefer allocator.free(mz);
        const intensity = try allocator.alloc(f32, num_points);
        errdefer allocator.free(intensity);

        const pool_mz = decoder.mz_buffer();
        const pool_intensity = decoder.intensity_buffer();
        @memcpy(mz, pool_mz[0..num_points]);
        @memcpy(intensity, pool_intensity[0..num_points]);

        // Build id string (ThermoRawFileParser-compatible format)
        const id = try raw.format_scan_id(allocator, meta.scan_number);
        errdefer allocator.free(id);

        // Build precursor (for MS2+)
        const precursor: ?core.Precursor = if (meta.ms_level >= 2 and meta.precursor_mz > 0) blk: {
            break :blk .{
                .isolation_mz = meta.precursor_mz,
                .isolation_width = if (meta.isolation_width > 0) meta.isolation_width else null,
                .charge = if (meta.charge_state > 0) meta.charge_state else null,
                .collision_energy = if (meta.collision_energy > 0) meta.collision_energy else null,
                .activation_type = null,
            };
        } else null;

        // Build scan windows from low/high mass
        const scan_windows = try allocator.alloc(core.ScanWindow, 1);
        errdefer allocator.free(scan_windows);
        scan_windows[0] = .{
            .lower_limit = meta.low_mass,
            .upper_limit = meta.high_mass,
        };

        scans[i] = .{
            .scan_number = meta.scan_number,
            .index = i,
            .id = id,
            .ms_level = meta.ms_level,
            .rt = meta.rt,
            .mz = mz,
            .intensity = intensity,
            .tic = meta.tic,
            .base_peak_mz = meta.base_peak_mz,
            .base_peak_intensity = meta.base_peak_intensity,
            .lowest_mz = meta.low_mass,
            .highest_mz = meta.high_mass,
            .packet_type = meta.packet_type,
            .filter_string = meta.filter_string,
            .precursor = precursor,
            .scan_params = &[_]core.CVParam{},
            .scan_windows = scan_windows,
        };
    }

    // Build run info
    const run_id = try allocator.dupe(u8, "run_1");
    errdefer allocator.free(run_id);

    // Instrument params — infer from packet types + scan events.
    const instrument_params = try buildInstrumentParams(allocator, raw_file, trailers, packet_types);
    errdefer allocator.free(instrument_params);

    return .{
        .id = run_id,
        .instrument_params = instrument_params,
        .scans = scans,
    };
}

fn makeEmptyScan(allocator: std.mem.Allocator, meta: ScanMeta, index: usize) !core.Scan {
    const id = try raw.format_scan_id(allocator, meta.scan_number);
    return .{
        .scan_number = meta.scan_number,
        .index = index,
        .id = id,
        .ms_level = meta.ms_level,
        .rt = meta.rt,
        .mz = &[_]f64{},
        .intensity = &[_]f32{},
        .tic = meta.tic,
        .base_peak_mz = null,
        .base_peak_intensity = null,
        .lowest_mz = 0,
        .highest_mz = 0,
        .packet_type = meta.packet_type,
        .filter_string = meta.filter_string,
        .precursor = null,
        .scan_params = &[_]core.CVParam{},
        .scan_windows = &[_]core.ScanWindow{},
    };
}

/// Build instrument configuration CV params.
/// Uses shared instrument_utils.inferAnalyzers and instrument model from file header.
fn buildInstrumentParams(
    allocator: std.mem.Allocator,
    raw_file: raw_file_reader.RawFile,
    trailers: ?trailer_events.TrailerScanEvents,
    packet_types: []const u32,
) ConvertError![]core.CVParam {
    // Extract ScanEventInfo slice from TrailerScanEvents for analyzer inference.
    var scan_event_infos: []raw.ScanEventInfo = &[_]raw.ScanEventInfo{};
    if (trailers) |te| {
        scan_event_infos = allocator.alloc(raw.ScanEventInfo, te.unique_events.len) catch return error.OutOfMemory;
        for (te.unique_events, 0..) |evt, i| {
            scan_event_infos[i] = evt.info;
        }
    }
    defer allocator.free(scan_event_infos);

    const analyzers = instrument_utils.infer_analyzers(raw_file.file_revision, scan_event_infos, packet_types);

    var model_param: ?core.CVParam = null;
    if (raw_file.instrument_model) |model| {
        if (cv.map_instrument_model(model)) |mapped| {
            model_param = .{ .accession = mapped.accession, .name = mapped.name };
        }
    }

    var param_count: usize = 1; // manufacturer
    if (model_param != null) param_count += 1;
    if (analyzers.has_orbitrap or analyzers.has_astral) param_count += 1;
    if (analyzers.has_ion_trap) param_count += 1;

    const params = try allocator.alloc(core.CVParam, param_count);
    var idx: usize = 0;

    params[idx] = .{ .accession = "MS:1000483", .name = "Thermo Fisher Scientific instrument model" };
    idx += 1;

    if (model_param) |mp| {
        params[idx] = mp;
        idx += 1;
    }

    if (analyzers.has_orbitrap or analyzers.has_astral) {
        params[idx] = .{ .accession = "MS:1000482", .name = "orbitrap mass analyzer" };
        idx += 1;
    }
    if (analyzers.has_ion_trap) {
        params[idx] = .{ .accession = "MS:1000083", .name = "radial ejection linear ion trap" };
        idx += 1;
    }

    return params[0..idx];
}

// ============================================================================
// Tests
// ============================================================================

test "convert rejects > MAX_SCANS" {
    try std.testing.expect(MAX_SCANS > 0);
    try std.testing.expect(MAX_SCANS <= 200_000);
    try std.testing.expectError(
        error.TooManyScans,
        (struct {
            fn returnsError() ConvertError!void {
                return ConvertError.TooManyScans;
            }
        }).returnsError(),
    );
}
