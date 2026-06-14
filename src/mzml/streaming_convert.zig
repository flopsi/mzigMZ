/// Streaming conversion: .raw file → mzML file directly.
/// Reads one scan at a time, writes XML to a buffered file writer.
/// No intermediate MsRun, no AoS conversion, minimal memory usage.
const std = @import("std");
const app = @import("app_state");
const file_state = @import("file_state");
const mzml_writer = @import("mzml_writer");
const mzml_types = @import("mzml_types");
const b64 = @import("base64");
const raw = @import("raw_file");
const cv = @import("cv");
const filter_string = @import("filter_string");
const instrument_utils = @import("instrument_utils");

const AnalyzerType = enum { unknown, orbitrap, astral, ion_trap, triple_quad };

/// Public error set for streaming convert entry point. Per zig-quality R1,
/// public APIs declare named error sets for exhaustive switch support.
/// Note: includes MzmlWriter.WriteError variants since we wrap that writer,
/// plus std.Io File write error variants.
pub const StreamingConvertError = error{
    NoScans,
    CreateFileFailed,
    // std.Io.File write error variants not covered by MzmlWriter.WriteError
    AccessDenied,
    Canceled,
    FileBusy,
    FileTooBig,
    InputOutput,
    NonResizable,
    PermissionDenied,
    Unexpected,
} || mzml_writer.WriteError;

fn scanAnalyzerType(scan_info: file_state.ScanInfo) AnalyzerType {
    if (scan_info.filter_string) |fs| {
        if (std.mem.indexOf(u8, fs, "ASTMS") != null) return .astral;
        if (std.mem.indexOf(u8, fs, "FTMS") != null) return .orbitrap;
        if (std.mem.indexOf(u8, fs, "ITMS") != null) return .ion_trap;
        if (std.mem.indexOf(u8, fs, "TQMS") != null) return .triple_quad;
    }
    const pt = scan_info.packet_type;
    if (pt == raw.PACKET_TYPE_FT_PROFILE or pt == raw.PACKET_TYPE_FT_CENTROID or pt == raw.PACKET_TYPE_HIGH_RES_COMPRESSED_PROFILE) return .orbitrap;
    if (pt == raw.PACKET_TYPE_LINEAR_TRAP_PROFILE or pt == raw.PACKET_TYPE_LINEAR_TRAP_CENTROID or pt == raw.PACKET_TYPE_LOW_RES_SPECTRUM or pt == raw.PACKET_TYPE_LOW_RES_COMPRESSED_PROFILE) return .ion_trap;
    return .unknown;
}

fn analyzerConfigId(analyzer: AnalyzerType) ?[]const u8 {
    return switch (analyzer) {
        .orbitrap, .astral => "IC1",
        .ion_trap => "IC2",
        .triple_quad => "IC3",
        .unknown => null,
    };
}

/// Format a scan ID in the ThermoRawFileParser-compatible form:
/// `controllerType=0 controllerNumber=1 scan=N`. Every spectrum `id` and
/// every `<precursor spectrumRef="...">` must use this exact format so
/// that downstream tools (OpenMS, MSFileReader, pyteomics) can resolve
/// parent scans via string match. See GOTCHAS.md G3.
fn format_scan_id(allocator: std.mem.Allocator, scan_number: i32) ![]u8 {
    return raw.format_scan_id(allocator, scan_number);
}

/// Convert a .raw file to mzML using streaming I/O.
pub fn convert_raw_to_mzml_streaming(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *app.AppState,
    output_path: []const u8,
    source_file_name: ?[]const u8,
    source_file_location: ?[]const u8,
    options: mzml_writer.MzmlWriterOptions,
) StreamingConvertError!void {
    if (state.file.scans.len == 0) return error.NoScans;

    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch return error.CreateFileFailed;
    defer file.close(io);

    var write_buf: [65536]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);

    var writer = try mzml_writer.MzmlWriter.init(allocator, options);
    defer writer.deinit();

    var sha1_hasher: ?std.crypto.hash.Sha1 = if (options.use_indexed_mzml) std.crypto.hash.Sha1.init(.{}) else null;

    const instrument_bundle = try buildInstrumentParams(allocator, state);
    defer {
        if (instrument_bundle.ref_params) |rp| allocator.free(rp);
        for (instrument_bundle.configs) |cfg| {
            allocator.free(cfg.id);
            allocator.free(cfg.params);
            if (cfg.components) |comps| allocator.free(comps);
        }
        allocator.free(instrument_bundle.configs);
    }

    try writer.write_header();
    try writer.write_file_description(source_file_name, source_file_location);
    try writer.write_referenceable_param_group_list(instrument_bundle.ref_params);
    try writer.write_software_list();
    try writer.print("  <instrumentConfigurationList count=\"{d}\">\n", .{instrument_bundle.configs.len});
    for (instrument_bundle.configs) |cfg| {
        try writer.write_instrument_configuration(cfg);
    }
    try writer.write_str("  </instrumentConfigurationList>\n");
    try writer.write_data_processing_list();
    const run_info = if (state.file.creation_time) |ct|
        mzml_types.RunInfo{ .id = "run_1", .start_time = ct, .default_instrument_config_ref = instrument_bundle.default_id }
    else
        mzml_types.RunInfo{ .id = "run_1", .default_instrument_config_ref = instrument_bundle.default_id };
    try writer.write_run_open(run_info, state.file.scans.len);

    const header_bytes = writer.bytes();
    try file_writer.interface.writeAll(header_bytes);
    if (sha1_hasher) |*h| h.update(header_bytes);
    writer.buf.clearRetainingCapacity();

    var last_ms1_scan: ?i32 = null;
    const total_scans = state.file.scans.len;
    const progress_interval = @max(1, total_scans / 10);

    for (state.file.scans, 0..) |scan_info, i| {
        const load_result = state.load_scan_bulk(i) catch |err| {
            std.log.warn("Failed to load scan {d}: {s}", .{ scan_info.scan_number, @errorName(err) });
            try writeEmptySpectrum(&writer, scan_info, i);
            _ = try flushWithHash(&writer, &file_writer, &sha1_hasher);
            continue;
        };

        const mz = state.decoder.mz_buffer()[0..load_result.num_points];
        const intensity = state.decoder.intensity_buffer()[0..load_result.num_points];

        try writeScanFromBuffers(&writer, scan_info, i, mz, intensity, load_result.mz_min, load_result.mz_max, state, allocator, last_ms1_scan);
        _ = try flushWithHash(&writer, &file_writer, &sha1_hasher);
        if (scan_info.ms_level == 1) {
            last_ms1_scan = scan_info.scan_number;
        }

        if (i > 0 and i % progress_interval == 0) {
            const pct = @divTrunc(i * 100, total_scans);
            std.log.info("Progress: {d}/{d} scans ({d}%)", .{ i, total_scans, pct });
        }
    }

    state.compute_chromatograms();
    const chromatograms: ?mzml_types.ChromatogramList = if (state.tic_chromatogram) |tic| cg: {
        if (state.bpc_chromatogram) |bpc| {
            break :cg .{ .rt = tic.rt, .tic = tic.intensity, .bpc = bpc.intensity };
        }
        break :cg null;
    } else null;
    try writer.write_footer(chromatograms);

    if (options.use_indexed_mzml) try writer.write_index_content();

    const pre_checksum_bytes = writer.bytes();
    if (sha1_hasher) |*h| h.update(pre_checksum_bytes);

    const checksum_slice: ?[]const u8 = if (sha1_hasher) |*h| blk: {
        const digest = h.finalResult();
        break :blk &std.fmt.bytesToHex(digest, .lower);
    } else null;

    if (checksum_slice) |cs| {
        try writer.print("<fileChecksum>{s}</fileChecksum>\n", .{cs});
    } else if (options.use_indexed_mzml) {
        try writer.write_str("<fileChecksum>0</fileChecksum>\n");
    }

    try file_writer.interface.writeAll(writer.bytes());
    try file_writer.end();
}

fn flushWithHash(writer: *mzml_writer.MzmlWriter, file_writer: anytype, sha1_hasher: *?std.crypto.hash.Sha1) !u64 {
    const flush_threshold = 48 * 1024;
    if (writer.buf.items.len >= flush_threshold) {
        const bytes = writer.bytes();
        try file_writer.interface.writeAll(bytes);
        if (sha1_hasher.*) |*h| h.update(bytes);
        writer.buf.clearRetainingCapacity();
        return bytes.len;
    }
    return 0;
}

fn writeEmptySpectrum(writer: *mzml_writer.MzmlWriter, scan_info: file_state.ScanInfo, index: usize) !void {
    const id = try format_scan_id(writer.allocator, scan_info.scan_number);
    defer writer.allocator.free(id);

    const offset = writer.byte_offset;
    const id_copy = try writer.allocator.dupe(u8, id);
    errdefer writer.allocator.free(id_copy);
    try writer.spectrum_offsets.append(writer.allocator, .{ .index = index, .id = id_copy, .offset = offset });

    try writer.print("      <spectrum index=\"{d}\" id=\"{s}\" defaultArrayLength=\"0\">\n", .{ index, id });

    var buf: [32]u8 = undefined;
    const ms_level = try std.fmt.bufPrint(&buf, "{d}", .{scan_info.ms_level});
    try writer.print("        <cvParam cvRef=\"MS\" accession=\"MS:1000511\" name=\"ms level\" value=\"{s}\"/>\n", .{ms_level});

    if (scan_info.ms_level == 1) {
        try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000579\" name=\"MS1 spectrum\"/>\n");
    } else {
        try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000580\" name=\"MSn spectrum\"/>\n");
    }
    try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000127\" name=\"centroid spectrum\"/>\n");

    const analyzer = scanAnalyzerType(scan_info);
    const ic_ref = analyzerConfigId(analyzer);
    if (ic_ref) |ref| {
        try writer.print("        <scanList count=\"1\">\n          <scan instrumentConfigurationRef=\"{s}\">\n", .{ref});
    } else {
        try writer.write_str("        <scanList count=\"1\">\n          <scan>\n");
    }
    try writer.print("            <cvParam cvRef=\"MS\" accession=\"MS:1000016\" name=\"scan start time\" value=\"{d:.4}\" unitCvRef=\"UO\" unitAccession=\"UO:0000031\" unitName=\"minute\"/>\n", .{scan_info.rt});
    try writer.write_str("          </scan>\n        </scanList>\n");
    try writer.write_str("        <binaryDataArrayList count=\"0\">\n        </binaryDataArrayList>\n      </spectrum>\n");
}

fn writeScanFromBuffers(
    writer: *mzml_writer.MzmlWriter,
    scan_info: file_state.ScanInfo,
    index: usize,
    mz: []const f64,
    intensity: []const f32,
    mz_min: f64,
    mz_max: f64,
    state: *app.AppState,
    allocator: std.mem.Allocator,
    parent_scan_number: ?i32,
) !void {
    const id = try format_scan_id(writer.allocator, scan_info.scan_number);
    defer writer.allocator.free(id);

    const offset = writer.byte_offset;
    const id_copy = try writer.allocator.dupe(u8, id);
    errdefer writer.allocator.free(id_copy);
    try writer.spectrum_offsets.append(writer.allocator, .{ .index = index, .id = id_copy, .offset = offset });

    try writer.print("      <spectrum index=\"{d}\" id=\"{s}\" defaultArrayLength=\"{d}\">\n", .{ index, id, mz.len });

    {
        var buf: [32]u8 = undefined;
        const ms_level = try std.fmt.bufPrint(&buf, "{d}", .{scan_info.ms_level});
        try writer.print("        <cvParam cvRef=\"MS\" accession=\"MS:1000511\" name=\"ms level\" value=\"{s}\"/>\n", .{ms_level});
    }
    if (scan_info.ms_level == 1) {
        try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000579\" name=\"MS1 spectrum\"/>\n");
    } else {
        try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000580\" name=\"MSn spectrum\"/>\n");
    }

    if (scan_info.packet_type == raw.PACKET_TYPE_FT_PROFILE or
        scan_info.packet_type == raw.PACKET_TYPE_LINEAR_TRAP_PROFILE or
        scan_info.packet_type == raw.PACKET_TYPE_HIGH_RES_COMPRESSED_PROFILE or
        scan_info.packet_type == raw.PACKET_TYPE_LOW_RES_COMPRESSED_PROFILE or
        scan_info.packet_type == raw.PACKET_TYPE_PROFILE_SPECTRUM)
    {
        try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000128\" name=\"profile spectrum\"/>\n");
    } else {
        try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000127\" name=\"centroid spectrum\"/>\n");
    }

    if (state.file.trailer_events) |te| {
        if (te.get_event(index)) |evt| {
            if (evt.info.polarity == 1) {
                try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000130\" name=\"positive scan\"/>\n");
            } else if (evt.info.polarity == 2) {
                try writer.write_str("        <cvParam cvRef=\"MS\" accession=\"MS:1000129\" name=\"negative scan\"/>\n");
            }
        }
    }

    try writer.print("        <cvParam cvRef=\"MS\" accession=\"MS:1000285\" name=\"total ion current\" value=\"{d:.4}\"/>\n", .{scan_info.tic});
    if (scan_info.base_peak_mz > 0) {
        try writer.print("        <cvParam cvRef=\"MS\" accession=\"MS:1000504\" name=\"base peak m/z\" value=\"{d:.4}\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n", .{scan_info.base_peak_mz});
    }
    if (scan_info.base_peak_intensity > 0) {
        try writer.print("        <cvParam cvRef=\"MS\" accession=\"MS:1000505\" name=\"base peak intensity\" value=\"{d:.2}\" unitCvRef=\"MS\" unitAccession=\"MS:1000131\" unitName=\"number of detector counts\"/>\n", .{scan_info.base_peak_intensity});
    }
    try writer.print("        <cvParam cvRef=\"MS\" accession=\"MS:1000528\" name=\"lowest observed m/z\" value=\"{d:.4}\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n", .{mz_min});
    try writer.print("        <cvParam cvRef=\"MS\" accession=\"MS:1000527\" name=\"highest observed m/z\" value=\"{d:.4}\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n", .{mz_max});

    const analyzer = scanAnalyzerType(scan_info);
    const ic_ref = analyzerConfigId(analyzer);
    if (ic_ref) |ref| {
        try writer.print("        <scanList count=\"1\">\n          <scan instrumentConfigurationRef=\"{s}\">\n", .{ref});
    } else {
        try writer.write_str("        <scanList count=\"1\">\n          <scan>\n");
    }
    try writer.print("            <cvParam cvRef=\"MS\" accession=\"MS:1000016\" name=\"scan start time\" value=\"{d:.4}\" unitCvRef=\"UO\" unitAccession=\"UO:0000031\" unitName=\"minute\"/>\n", .{scan_info.rt});
    if (scan_info.filter_string) |fs| {
        try writer.print("            <cvParam cvRef=\"MS\" accession=\"MS:1000512\" name=\"filter string\" value=\"{s}\"/>\n", .{fs});
    }
    try writer.print(
        "            <scanWindowList count=\"1\">\n              <scanWindow>\n" ++ "                <cvParam cvRef=\"MS\" accession=\"MS:1000501\" name=\"scan window lower limit\" value=\"{d:.4}\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n" ++ "                <cvParam cvRef=\"MS\" accession=\"MS:1000500\" name=\"scan window upper limit\" value=\"{d:.4}\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n" ++ "              </scanWindow>\n            </scanWindowList>\n",
        .{ scan_info.low_mass, scan_info.high_mass },
    );
    try writer.write_str("          </scan>\n        </scanList>\n");

    if (scan_info.ms_level >= 2 and scan_info.precursor_mz > 0) {
        try writer.write_str("        <precursorList count=\"1\">\n");
        if (parent_scan_number) |psn| {
            // G3 fix: spectrumRef MUST match a spectrum `id` exactly so that
            // downstream tools (OpenMS, MSFileReader, ThermoRawFileParser) can
            // resolve the parent scan via string match. Use the shared helper
            // so this stays in lockstep with the spectrum id template.
            const spectrum_ref = try format_scan_id(writer.allocator, psn);
            defer writer.allocator.free(spectrum_ref);
            try writer.print("          <precursor spectrumRef=\"{s}\">\n", .{spectrum_ref});
        } else {
            try writer.write_str("          <precursor>\n");
        }
        try writer.write_str("            <isolationWindow>\n");
        try writer.print("              <cvParam cvRef=\"MS\" accession=\"MS:1000827\" name=\"isolation window target m/z\" value=\"{d:.4}\"/>\n", .{scan_info.precursor_mz});
        if (scan_info.isolation_width > 0) {
            const half = scan_info.isolation_width / 2.0;
            try writer.print("              <cvParam cvRef=\"MS\" accession=\"MS:1000828\" name=\"isolation window lower offset\" value=\"{d:.4}\"/>\n", .{half});
            try writer.print("              <cvParam cvRef=\"MS\" accession=\"MS:1000829\" name=\"isolation window upper offset\" value=\"{d:.4}\"/>\n", .{half});
        }
        try writer.write_str("            </isolationWindow>\n");
        try writer.write_str("            <selectedIonList count=\"1\">\n              <selectedIon>\n");
        try writer.print("                <cvParam cvRef=\"MS\" accession=\"MS:1000744\" name=\"selected ion m/z\" value=\"{d:.4}\"/>\n", .{scan_info.precursor_mz});
        if (scan_info.charge_state > 0) {
            var buf: [16]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{scan_info.charge_state});
            try writer.print("                <cvParam cvRef=\"MS\" accession=\"MS:1000041\" name=\"charge state\" value=\"{s}\"/>\n", .{s});
        }
        try writer.write_str("              </selectedIon>\n            </selectedIonList>\n");
        try writer.write_str("            <activation>\n");
        if (scan_info.filter_string) |fs| {
            if (filter_string.extract_activation_type(fs)) |at| {
                if (std.mem.eql(u8, at, "HCD")) {
                    try writer.write_str("              <cvParam cvRef=\"MS\" accession=\"MS:1000422\" name=\"beam-type collision-induced dissociation\"/>\n");
                } else if (std.mem.eql(u8, at, "CID")) {
                    try writer.write_str("              <cvParam cvRef=\"MS\" accession=\"MS:1000133\" name=\"collision-induced dissociation\"/>\n");
                } else if (std.mem.eql(u8, at, "ETD")) {
                    try writer.write_str("              <cvParam cvRef=\"MS\" accession=\"MS:1000598\" name=\"electron transfer dissociation\"/>\n");
                } else if (std.mem.eql(u8, at, "ECD")) {
                    try writer.write_str("              <cvParam cvRef=\"MS\" accession=\"MS:1000250\" name=\"electron capture dissociation\"/>\n");
                }
            }
        }
        if (scan_info.collision_energy > 0) {
            try writer.print("              <cvParam cvRef=\"MS\" accession=\"MS:1000045\" name=\"collision energy\" value=\"{d:.1}\"/>\n", .{scan_info.collision_energy});
        }
        try writer.write_str("            </activation>\n          </precursor>\n        </precursorList>\n");
    }

    if (scan_info.ms_level >= 2 and scan_info.isolation_width > 0) {
        try writer.write_str("        <productList count=\"1\">\n          <product>\n            <isolationWindow>\n");
        try writer.print("              <cvParam cvRef=\"MS\" accession=\"MS:1000827\" name=\"isolation window target m/z\" value=\"{d:.4}\"/>\n", .{scan_info.precursor_mz});
        const half = scan_info.isolation_width / 2.0;
        try writer.print("              <cvParam cvRef=\"MS\" accession=\"MS:1000828\" name=\"isolation window lower offset\" value=\"{d:.4}\"/>\n", .{half});
        try writer.print("              <cvParam cvRef=\"MS\" accession=\"MS:1000829\" name=\"isolation window upper offset\" value=\"{d:.4}\"/>\n", .{half});
        try writer.write_str("            </isolationWindow>\n          </product>\n        </productList>\n");
    }

    const mz_b64 = try writer.encode_mz_array(mz);
    defer allocator.free(mz_b64);
    const inten_b64 = try writer.encode_intensity_array(intensity);
    defer allocator.free(inten_b64);

    try writer.write_str("        <binaryDataArrayList count=\"2\">\n");

    try writer.print("          <binaryDataArray encodedLength=\"{d}\">\n", .{mz_b64.len});
    try writer.write_str("            <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n");
    try writer.write_str("            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n");
    try writer.write_compression_cv();
    try writer.write_str("            <binary>");
    try writer.write_str(mz_b64);
    try writer.write_str("</binary>\n          </binaryDataArray>\n");

    try writer.print("          <binaryDataArray encodedLength=\"{d}\">\n", .{inten_b64.len});
    try writer.write_str("            <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\" unitCvRef=\"MS\" unitAccession=\"MS:1000131\" unitName=\"number of detector counts\"/>\n");
    switch (writer.options.precision) {
        .f64 => try writer.write_str("            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"),
        .f32 => try writer.write_str("            <cvParam cvRef=\"MS\" accession=\"MS:1000521\" name=\"32-bit float\"/>\n"),
    }
    try writer.write_compression_cv();
    try writer.write_str("            <binary>");
    try writer.write_str(inten_b64);
    try writer.write_str("</binary>\n          </binaryDataArray>\n");

    try writer.write_str("        </binaryDataArrayList>\n      </spectrum>\n");
}

// Removed: writeCompressionCv, encodeMzArray, encodeIntensityArray are now MzmlWriter methods
// extractActivationTypeShort removed — use filter_string.extractActivationType
// inferAnalyzers removed — use instrument_utils.inferAnalyzers

const InstrumentConfigBundle = struct {
    ref_params: ?[]const mzml_types.CVParam,
    configs: []const mzml_types.InstrumentConfiguration,
    default_id: []const u8,
};

fn buildInstrumentParams(allocator: std.mem.Allocator, state: *app.AppState) !InstrumentConfigBundle {
    // Build decoupled inputs for analyzer inference.
    var scan_event_infos: []raw.ScanEventInfo = &[_]raw.ScanEventInfo{};
    if (state.file.trailer_events) |te| {
        scan_event_infos = try allocator.alloc(raw.ScanEventInfo, te.unique_events.len);
        for (te.unique_events, 0..) |evt, i| {
            scan_event_infos[i] = evt.info;
        }
    }
    defer allocator.free(scan_event_infos);

    const packet_types = try allocator.alloc(u32, state.file.scans.len);
    defer allocator.free(packet_types);
    for (state.file.scans, 0..) |scan_info, i| {
        packet_types[i] = scan_info.packet_type;
    }

    const analyzers = instrument_utils.infer_analyzers(state.file.file_revision(), scan_event_infos, packet_types);

    var model_param: ?mzml_types.CVParam = null;
    if (state.file.raw_file) |rf| {
        if (rf.instrument_model) |model| {
            if (cv.map_instrument_model(model)) |mapped| {
                model_param = .{ .accession = mapped.accession, .name = mapped.name };
            }
        }
    }

    var ref_params: std.ArrayList(mzml_types.CVParam) = .empty;
    defer ref_params.deinit(allocator);
    try ref_params.append(allocator, .{ .accession = "MS:1000483", .name = "Thermo Fisher Scientific instrument model" });
    if (model_param) |mp| try ref_params.append(allocator, mp);

    const has_nsi = blk: {
        for (state.file.scans) |scan_info| {
            if (scan_info.filter_string) |fs| {
                if (std.mem.indexOf(u8, fs, "NSI") != null) break :blk true;
            }
        }
        break :blk false;
    };
    const source_params = if (has_nsi)
        &[_]mzml_types.CVParam{.{ .accession = "MS:1000398", .name = "nanospray" }}
    else
        &[_]mzml_types.CVParam{.{ .accession = "MS:1000073", .name = "electrospray ionization" }};

    const has_serial = if (state.file.raw_file) |rf| rf.instrument_serial != null else false;
    const serial_str: ?[]const u8 = if (state.file.raw_file) |rf| rf.instrument_serial else null;

    var configs: std.ArrayList(mzml_types.InstrumentConfiguration) = .empty;
    defer configs.deinit(allocator);
    const default_id: []const u8 = "IC1";
    var config_index: u8 = 1;

    if (analyzers.has_orbitrap or analyzers.has_astral) {
        var comps: std.ArrayList(mzml_types.InstrumentComponent) = .empty;
        defer comps.deinit(allocator);
        try comps.append(allocator, .{ .order = 1, .params = source_params });
        try comps.append(allocator, .{ .order = 2, .params = &[_]mzml_types.CVParam{.{ .accession = "MS:1000482", .name = "orbitrap mass analyzer" }} });
        try comps.append(allocator, .{ .order = 3, .params = &[_]mzml_types.CVParam{.{ .accession = "MS:1000624", .name = "inductive detector" }} });

        var ic_params: std.ArrayList(mzml_types.CVParam) = .empty;
        defer ic_params.deinit(allocator);
        if (has_serial) {
            try ic_params.append(allocator, .{ .accession = "MS:1000529", .name = "instrument serial number", .value = serial_str.? });
        }
        var id_buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "IC{d}", .{config_index});
        try configs.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .params = try ic_params.toOwnedSlice(allocator),
            .components = try comps.toOwnedSlice(allocator),
            .ref_param_group = "commonInstrumentParams",
        });
        config_index += 1;
    }

    if (analyzers.has_ion_trap) {
        var comps: std.ArrayList(mzml_types.InstrumentComponent) = .empty;
        defer comps.deinit(allocator);
        try comps.append(allocator, .{ .order = 1, .params = source_params });
        try comps.append(allocator, .{ .order = 2, .params = &[_]mzml_types.CVParam{.{ .accession = "MS:1000083", .name = "radial ejection linear ion trap" }} });
        try comps.append(allocator, .{ .order = 3, .params = &[_]mzml_types.CVParam{.{ .accession = "MS:1000251", .name = "electron multiplier" }} });

        var ic_params: std.ArrayList(mzml_types.CVParam) = .empty;
        defer ic_params.deinit(allocator);
        if (has_serial) {
            try ic_params.append(allocator, .{ .accession = "MS:1000529", .name = "instrument serial number", .value = serial_str.? });
        }
        var id_buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "IC{d}", .{config_index});
        try configs.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .params = try ic_params.toOwnedSlice(allocator),
            .components = try comps.toOwnedSlice(allocator),
            .ref_param_group = "commonInstrumentParams",
        });
        config_index += 1;
    }

    if (analyzers.has_tq) {
        var comps: std.ArrayList(mzml_types.InstrumentComponent) = .empty;
        defer comps.deinit(allocator);
        try comps.append(allocator, .{ .order = 1, .params = source_params });
        try comps.append(allocator, .{ .order = 2, .params = &[_]mzml_types.CVParam{.{ .accession = "MS:1002579", .name = "triple quadrupole mass analyzer" }} });
        try comps.append(allocator, .{ .order = 3, .params = &[_]mzml_types.CVParam{.{ .accession = "MS:1000251", .name = "electron multiplier" }} });

        var ic_params: std.ArrayList(mzml_types.CVParam) = .empty;
        defer ic_params.deinit(allocator);
        if (has_serial) {
            try ic_params.append(allocator, .{ .accession = "MS:1000529", .name = "instrument serial number", .value = serial_str.? });
        }
        var id_buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "IC{d}", .{config_index});
        try configs.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .params = try ic_params.toOwnedSlice(allocator),
            .components = try comps.toOwnedSlice(allocator),
            .ref_param_group = "commonInstrumentParams",
        });
        config_index += 1;
    }

    if (configs.items.len == 0) {
        var comps: std.ArrayList(mzml_types.InstrumentComponent) = .empty;
        defer comps.deinit(allocator);
        try comps.append(allocator, .{ .order = 1, .params = source_params });
        try comps.append(allocator, .{ .order = 2, .params = &[_]mzml_types.CVParam{.{ .accession = "MS:1000482", .name = "orbitrap mass analyzer" }} });
        try comps.append(allocator, .{ .order = 3, .params = &[_]mzml_types.CVParam{.{ .accession = "MS:1000624", .name = "inductive detector" }} });

        var ic_params: std.ArrayList(mzml_types.CVParam) = .empty;
        defer ic_params.deinit(allocator);
        if (has_serial) {
            try ic_params.append(allocator, .{ .accession = "MS:1000529", .name = "instrument serial number", .value = serial_str.? });
        }
        try configs.append(allocator, .{
            .id = try allocator.dupe(u8, "IC1"),
            .params = try ic_params.toOwnedSlice(allocator),
            .components = try comps.toOwnedSlice(allocator),
            .ref_param_group = "commonInstrumentParams",
        });
    }

    return InstrumentConfigBundle{
        .ref_params = try ref_params.toOwnedSlice(allocator),
        .configs = try configs.toOwnedSlice(allocator),
        .default_id = default_id,
    };
}
