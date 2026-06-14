/// Streaming mzML serializer — builds XML in a growable buffer.
/// The buffer can be written to a file or used in-memory.
const std = @import("std");
const types = @import("mzml_types");
const cv = @import("cv");
const b64 = @import("base64");
const numpress_mod = @import("numpress");

pub const CompressionMode = enum {
    none,
    zlib,
    numpress_linear,
    numpress_pic,
    numpress_slof,
    zlib_numpress_linear,
};

pub const MzmlWriterOptions = struct {
    compression: CompressionMode = .none,
    precision: enum { f32, f64 } = .f32,
    use_indexed_mzml: bool = true,
    /// Numpress linear codec fixed-point precision (1/fixed_point Da per
    /// integer step). Default 1000.0 = 0.001 Da, matching MS-Numpress 1.0
    /// reference. For sub-ppm Astral data, use 10_000_000 (ppb precision).
    /// Only affects Numpress linear compression; PIC and SLOF use their
    /// own fixed points.
    linear_fixed_point: f64 = 1000.0,
};

/// Public error set for MzmlWriter methods. Per zig-quality R1, public
/// APIs declare named error sets for exhaustive switch support.
pub const WriteError = error{
    OutOfMemory,
    EndOfStream,
    WriteFailed,
    HeaderNotWritten,
    RunNotOpened,
    InvalidFormat,
    NoSpaceLeft,
    BufferTooSmall,
    InvalidData,
    Overflow,
} || b64.Error || numpress_mod.NumpressError;

/// mzML writer that accumulates XML into an ArrayList buffer.
/// Call `writeMzML()` to generate the full document, then access `buf.items`.
pub const MzmlWriter = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    options: MzmlWriterOptions,

    byte_offset: u64 = 0,
    spectrum_offsets: std.ArrayList(SpectrumOffset),
    header_written: bool = false,
    run_opened: bool = false,

    const SpectrumOffset = struct {
        index: usize,
        id: []const u8,
        offset: u64,
    };

    pub fn init(allocator: std.mem.Allocator, options: MzmlWriterOptions) WriteError!MzmlWriter {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        // Start with 64KB; caller should pre-size with ensureTotalCapacity if known
        try buf.ensureTotalCapacity(allocator, 65536);

        var spectrum_offsets: std.ArrayList(SpectrumOffset) = .empty;
        errdefer spectrum_offsets.deinit(allocator);

        return .{
            .buf = buf,
            .allocator = allocator,
            .options = options,
            .spectrum_offsets = spectrum_offsets,
        };
    }

    pub fn deinit(self: *MzmlWriter) void {
        for (self.spectrum_offsets.items) |o| self.allocator.free(o.id);
        self.spectrum_offsets.deinit(self.allocator);
        self.buf.deinit(self.allocator);
    }

    /// Get the accumulated XML bytes.
    pub fn bytes(self: MzmlWriter) []const u8 {
        return self.buf.items;
    }

    /// Transfer ownership of the internal buffer to the caller.
    /// The writer is left with an empty buffer and can still be deinit'd safely.
    pub fn to_owned_buffer(self: *MzmlWriter) std.ArrayList(u8) {
        const result = self.buf;
        self.buf = .empty;
        return result;
    }

    // --- Low-level write helpers ---

    /// Fast path: resize buffer once, then memcpy directly.
    pub fn write_str(self: *MzmlWriter, str: []const u8) WriteError!void {
        const old_len = self.buf.items.len;
        try self.buf.resize(self.allocator, old_len + str.len);
        @memcpy(self.buf.items[old_len..], str);
        self.byte_offset += str.len;
    }

    pub fn print(self: *MzmlWriter, comptime fmt: []const u8, args: anytype) WriteError!void {
        // Use a temporary buffer for formatting
        var temp: [4096]u8 = undefined;
        const written = try std.fmt.bufPrint(&temp, fmt, args);
        const old_len = self.buf.items.len;
        try self.buf.resize(self.allocator, old_len + written.len);
        @memcpy(self.buf.items[old_len..], written);
        self.byte_offset += written.len;
    }

    /// Write a string with XML attribute escaping.
    fn writeEscapedAttr(self: *MzmlWriter, s: []const u8) WriteError!void {
        var start: usize = 0;
        for (s, 0..) |c, i| {
            const esc = switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                else => continue,
            };
            if (i > start) try self.write_str(s[start..i]);
            try self.write_str(esc);
            start = i + 1;
        }
        if (start < s.len) try self.write_str(s[start..]);
    }

    fn printCvParam(self: *MzmlWriter, param: types.CVParam) WriteError!void {
        try self.print("<cvParam cvRef=\"{s}\" accession=\"{s}\" name=\"", .{
            param.cv_ref, param.accession,
        });
        try self.writeEscapedAttr(param.name);
        try self.write_str("\"");
        if (param.value) |v| {
            try self.write_str(" value=\"");
            try self.writeEscapedAttr(v);
            try self.write_str("\"");
        }
        if (param.unit) |u| {
            try self.print(" unitCvRef=\"{s}\" unitAccession=\"{s}\" unitName=\"{s}\"", .{
                u.cv_ref, u.accession, u.name,
            });
        }
        try self.write_str("/>");
    }

    // --- Document structure ---

    pub fn write_header(self: *MzmlWriter) WriteError!void {
        try self.write_str(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++ "<mzML xmlns=\"http://psi.hupo.org/ms/mzml\"\n" ++ "      xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n" ++ "      xsi:schemaLocation=\"http://psi.hupo.org/ms/mzml\n" ++ "        http://psidev.info/files/ms/mzML/xsd/mzML1.1.0.xsd\"\n" ++ "      version=\"1.1.0\" id=\"mzML\">\n" ++ "  <cvList count=\"2\">\n" ++ "    <cv id=\"MS\"\n" ++ "      fullName=\"Proteomics Standards Initiative Mass Spectrometry Ontology\"\n" ++ "      URI=\"https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo\"\n" ++ "      version=\"4.1.12\"/>\n" ++ "    <cv id=\"UO\" fullName=\"Unit Ontology\"\n" ++ "      URI=\"https://raw.githubusercontent.com/bio-ontology-research-group/unit-ontology/master/unit.obo\"\n" ++ "      version=\"09:04:2014\"/>\n" ++ "  </cvList>\n",
        );
        self.header_written = true;
    }

    pub fn write_file_description(self: *MzmlWriter, source_file_name: ?[]const u8, source_file_location: ?[]const u8) WriteError!void {
        try self.write_str("  <fileDescription>\n    <fileContent>\n");
        try self.write_str("      ");
        try self.printCvParam(.{
            .accession = cv.MS_1_SPECTRUM,
            .name = cv.cv_name(cv.MS_1_SPECTRUM),
        });
        try self.write_str("\n      ");
        try self.printCvParam(.{
            .accession = cv.MS_MSN_SPECTRUM,
            .name = cv.cv_name(cv.MS_MSN_SPECTRUM),
        });
        try self.write_str("\n      ");
        try self.printCvParam(.{
            .accession = cv.MS_ION_CURRENT_CHROMATOGRAM,
            .name = cv.cv_name(cv.MS_ION_CURRENT_CHROMATOGRAM),
        });
        try self.write_str("\n    </fileContent>\n");
        if (source_file_name) |name| {
            const loc = source_file_location orelse "file:///";
            try self.write_str(
                "    <sourceFileList count=\"1\">\n" ++ "      <sourceFile id=\"SF1\" name=\"",
            );
            try self.writeEscapedAttr(name);
            try self.write_str("\" location=\"");
            try self.writeEscapedAttr(loc);
            try self.write_str(
                "\">\n" ++ "        <cvParam cvRef=\"MS\" accession=\"MS:1000760\" name=\"native spectrum identifier format\"/>\n" ++ "        <cvParam cvRef=\"MS\" accession=\"MS:1000768\" name=\"Thermo nativeID format\"/>\n" ++ "        <cvParam cvRef=\"MS\" accession=\"MS:1000563\" name=\"Thermo RAW format\"/>\n" ++ "      </sourceFile>\n" ++ "    </sourceFileList>\n",
            );
        }
        try self.write_str("  </fileDescription>\n");
    }

    pub fn write_referenceable_param_group_list(self: *MzmlWriter, ref_params: ?[]const types.CVParam) WriteError!void {
        if (ref_params) |params| {
            try self.write_str("  <referenceableParamGroupList count=\"1\">\n");
            try self.write_str("    <referenceableParamGroup id=\"commonInstrumentParams\">\n");
            for (params) |param| {
                try self.write_str("      ");
                try self.printCvParam(param);
                try self.write_str("\n");
            }
            try self.write_str("    </referenceableParamGroup>\n");
            try self.write_str("  </referenceableParamGroupList>\n");
        } else {
            try self.write_str("  <referenceableParamGroupList count=\"0\"/>\n");
        }
    }

    pub fn write_software_list(self: *MzmlWriter) WriteError!void {
        try self.write_str(
            "  <softwareList count=\"1\">\n" ++ "    <software id=\"mzzig\" version=\"0.1.0\">\n" ++ "      <cvParam cvRef=\"MS\" accession=\"MS:1000799\"\n" ++ "        name=\"custom unreleased software tool\" value=\"mzzig\"/>\n" ++ "    </software>\n" ++ "  </softwareList>\n",
        );
    }

    pub fn write_data_processing_list(self: *MzmlWriter) WriteError!void {
        try self.write_str(
            "  <dataProcessingList count=\"1\">\n" ++ "    <dataProcessing id=\"DP\">\n" ++ "      <processingMethod order=\"1\" softwareRef=\"mzzig\">\n" ++ "        <cvParam cvRef=\"MS\" accession=\"MS:1000544\"\n" ++ "          name=\"Conversion to mzML\"/>\n" ++ "      </processingMethod>\n" ++ "      <processingMethod order=\"2\" softwareRef=\"mzzig\">\n" ++ "        <cvParam cvRef=\"MS\" accession=\"MS:1000035\"\n" ++ "          name=\"peak picking\"/>\n" ++ "      </processingMethod>\n" ++ "    </dataProcessing>\n" ++ "  </dataProcessingList>\n",
        );
    }

    pub fn write_instrument_configuration(self: *MzmlWriter, config: types.InstrumentConfiguration) WriteError!void {
        try self.print("    <instrumentConfiguration id=\"{s}\">\n", .{config.id});
        if (config.ref_param_group) |ref| {
            try self.print("      <referenceableParamGroupRef ref=\"{s}\"/>\n", .{ref});
        }
        for (config.params) |param| {
            try self.write_str("      ");
            try self.printCvParam(param);
            try self.write_str("\n");
        }
        if (config.components) |components| {
            try self.print("      <componentList count=\"{d}\">\n", .{components.len});
            for (components) |comp| {
                const tag = if (comp.order == 1) "source" else if (comp.order == 2) "analyzer" else "detector";
                try self.print("        <{s} order=\"{d}\">\n", .{ tag, comp.order });
                for (comp.params) |param| {
                    try self.write_str("          ");
                    try self.printCvParam(param);
                    try self.write_str("\n");
                }
                try self.print("        </{s}>\n", .{tag});
            }
            try self.write_str("      </componentList>\n");
        }
        try self.write_str("    </instrumentConfiguration>\n");
    }

    /// Backward-compatible instrument configuration list writer.
    pub fn write_instrument_configuration_list(self: *MzmlWriter, params: []const types.CVParam, serial_number: ?[]const u8) WriteError!void {
        try self.write_str(
            "  <instrumentConfigurationList count=\"1\">\n" ++ "    <instrumentConfiguration id=\"IC\">\n",
        );
        for (params) |param| {
            try self.write_str("      ");
            try self.printCvParam(param);
            try self.write_str("\n");
        }
        if (serial_number) |sn| {
            try self.write_str("      ");
            try self.printCvParam(.{
                .accession = "MS:1000529",
                .name = "instrument serial number",
                .value = sn,
            });
            try self.write_str("\n");
        }
        try self.write_str(
            "    </instrumentConfiguration>\n" ++ "  </instrumentConfigurationList>\n",
        );
    }

    pub fn write_run_open(self: *MzmlWriter, run_info: types.RunInfo, spectrum_count: usize) WriteError!void {
        try self.write_str("  <run id=\"");
        try self.writeEscapedAttr(run_info.id);
        const ic_ref = run_info.default_instrument_config_ref orelse "IC";
        try self.write_str("\" defaultInstrumentConfigurationRef=\"");
        try self.writeEscapedAttr(ic_ref);
        try self.write_str("\"");
        if (run_info.start_time) |st| {
            try self.write_str(" startTimeStamp=\"");
            try self.writeEscapedAttr(st);
            try self.write_str("\"");
        }
        try self.write_str(" defaultSourceFileRef=\"SF1\"");
        try self.write_str(">\n");
        try self.print(
            "    <spectrumList count=\"{d}\" defaultDataProcessingRef=\"DP\">\n",
            .{spectrum_count},
        );
        self.run_opened = true;
    }

    pub fn write_footer(self: *MzmlWriter, chromatograms: ?types.ChromatogramList) WriteError!void {
        try self.write_str("    </spectrumList>\n");
        if (chromatograms) |c| {
            try self.writeChromatogramList(c);
        }
        try self.write_str("  </run>\n</mzML>\n");
    }

    fn writeChromatogramList(self: *MzmlWriter, c: types.ChromatogramList) WriteError!void {
        const rt_b64 = try b64.encode_f64_array(self.allocator, c.rt);
        defer self.allocator.free(rt_b64);
        const tic_b64 = try b64.encode_f64_array(self.allocator, c.tic);
        defer self.allocator.free(tic_b64);
        const bpc_b64 = try b64.encode_f64_array(self.allocator, c.bpc);
        defer self.allocator.free(bpc_b64);

        try self.write_str("    <chromatogramList count=\"2\" defaultDataProcessingRef=\"DP\">\n");

        // TIC
        try self.print(
            "      <chromatogram index=\"0\" id=\"TIC\" defaultArrayLength=\"{d}\">\n",
            .{c.rt.len},
        );
        try self.write_str(
            "        <cvParam cvRef=\"MS\" accession=\"MS:1000235\"\n" ++ "          name=\"total ion current chromatogram\"/>\n",
        );
        try self.write_str("        <binaryDataArrayList count=\"2\">\n");
        // time array
        try self.print(
            "          <binaryDataArray encodedLength=\"{d}\">\n",
            .{rt_b64.len},
        );
        try self.write_str(
            "            <cvParam cvRef=\"MS\" accession=\"MS:1000595\"\n" ++ "              name=\"time array\" unitCvRef=\"UO\"\n" ++ "              unitAccession=\"UO:0000031\" unitName=\"minute\"/>\n",
        );
        try self.write_str(
            "            <cvParam cvRef=\"MS\" accession=\"MS:1000523\"\n" ++ "              name=\"64-bit float\"/>\n",
        );
        try self.write_str("            <binary>");
        try self.write_str(rt_b64);
        try self.write_str("</binary>\n          </binaryDataArray>\n");
        // intensity array
        try self.print(
            "          <binaryDataArray encodedLength=\"{d}\">\n",
            .{tic_b64.len},
        );
        try self.write_str(
            "            <cvParam cvRef=\"MS\" accession=\"MS:1000515\"\n" ++ "              name=\"intensity array\" unitCvRef=\"MS\"\n" ++ "              unitAccession=\"MS:1000131\"\n" ++ "              unitName=\"number of detector counts\"/>\n",
        );
        try self.write_str(
            "            <cvParam cvRef=\"MS\" accession=\"MS:1000523\"\n" ++ "              name=\"64-bit float\"/>\n",
        );
        try self.write_str("            <binary>");
        try self.write_str(tic_b64);
        try self.write_str("</binary>\n          </binaryDataArray>\n");
        try self.write_str("        </binaryDataArrayList>\n");
        try self.write_str("      </chromatogram>\n");

        // BPC
        try self.print(
            "      <chromatogram index=\"1\" id=\"BPC\" defaultArrayLength=\"{d}\">\n",
            .{c.rt.len},
        );
        try self.write_str(
            "        <cvParam cvRef=\"MS\" accession=\"MS:1000626\"\n" ++ "          name=\"base peak chromatogram\"/>\n",
        );
        try self.write_str("        <binaryDataArrayList count=\"2\">\n");
        // time array
        try self.print(
            "          <binaryDataArray encodedLength=\"{d}\">\n",
            .{rt_b64.len},
        );
        try self.write_str(
            "            <cvParam cvRef=\"MS\" accession=\"MS:1000595\"\n" ++ "              name=\"time array\" unitCvRef=\"UO\"\n" ++ "              unitAccession=\"UO:0000031\" unitName=\"minute\"/>\n",
        );
        try self.write_str(
            "            <cvParam cvRef=\"MS\" accession=\"MS:1000523\"\n" ++ "              name=\"64-bit float\"/>\n",
        );
        try self.write_str("            <binary>");
        try self.write_str(rt_b64);
        try self.write_str("</binary>\n          </binaryDataArray>\n");
        // intensity array
        try self.print(
            "          <binaryDataArray encodedLength=\"{d}\">\n",
            .{bpc_b64.len},
        );
        try self.write_str(
            "            <cvParam cvRef=\"MS\" accession=\"MS:1000515\"\n" ++ "              name=\"intensity array\" unitCvRef=\"MS\"\n" ++ "              unitAccession=\"MS:1000131\"\n" ++ "              unitName=\"number of detector counts\"/>\n",
        );
        try self.write_str(
            "            <cvParam cvRef=\"MS\" accession=\"MS:1000523\"\n" ++ "              name=\"64-bit float\"/>\n",
        );
        try self.write_str("            <binary>");
        try self.write_str(bpc_b64);
        try self.write_str("</binary>\n          </binaryDataArray>\n");
        try self.write_str("        </binaryDataArrayList>\n");
        try self.write_str("      </chromatogram>\n");

        try self.write_str("    </chromatogramList>\n");
    }

    // --- Spectrum (AoS via types.Spectrum) ---

    pub fn write_spectrum(self: *MzmlWriter, spectrum: types.Spectrum) WriteError!void {
        if (!self.header_written) return error.HeaderNotWritten;
        if (!self.run_opened) return error.RunNotOpened;

        // Record byte offset for indexedmzML before any writes.
        const offset = self.byte_offset;

        // Do all writes FIRST. If any write fails, we never allocate id_copy,
        // so no leak and no double-free.
        try self.print("      <spectrum index=\"{d}\" id=\"", .{spectrum.index});
        try self.writeEscapedAttr(spectrum.id);
        try self.print("\" defaultArrayLength=\"{d}\">\n", .{spectrum.default_array_length});

        try self.printSpectrumParams(spectrum);
        try self.writeScanList(spectrum);
        if (spectrum.precursor) |prec| try self.writePrecursorList(prec);
        if (spectrum.product) |prod| try self.writeProductList(prod);
        try self.writeBinaryDataArrayList(spectrum);

        try self.write_str("      </spectrum>\n");

        // Duplicate the id AFTER all writes succeed. Register the offset+id
        // together in spectrum_offsets. On success, deinit() owns id_copy and
        // will free it. On append failure, the catch frees id_copy before
        // returning the error. This is the G36 fix: no errdefer overlap
        // with the append catch.
        const id_copy = try self.allocator.dupe(u8, spectrum.id);
        self.spectrum_offsets.append(self.allocator, .{ .index = spectrum.index, .id = id_copy, .offset = offset }) catch |err| {
            self.allocator.free(id_copy);
            return err;
        };
    }

    fn printSpectrumParams(self: *MzmlWriter, sp: types.Spectrum) WriteError!void {
        var buf: [32]u8 = undefined;
        const ms_level = try std.fmt.bufPrint(&buf, "{d}", .{sp.ms_level});
        try self.print(
            "        <cvParam cvRef=\"MS\" accession=\"MS:1000511\"\n" ++ "          name=\"ms level\" value=\"{s}\"/>\n",
            .{ms_level},
        );

        if (sp.ms_level == 1) {
            try self.write_str(
                "        <cvParam cvRef=\"MS\" accession=\"MS:1000579\"\n" ++ "          name=\"MS1 spectrum\"/>\n",
            );
        } else {
            try self.write_str(
                "        <cvParam cvRef=\"MS\" accession=\"MS:1000580\"\n" ++ "          name=\"MSn spectrum\"/>\n",
            );
        }

        if (sp.is_profile) {
            try self.write_str(
                "        <cvParam cvRef=\"MS\" accession=\"MS:1000128\"\n" ++ "          name=\"profile spectrum\"/>\n",
            );
        } else {
            try self.write_str(
                "        <cvParam cvRef=\"MS\" accession=\"MS:1000127\"\n" ++ "          name=\"centroid spectrum\"/>\n",
            );
        }
        try self.print(
            "        <cvParam cvRef=\"MS\" accession=\"MS:1000285\"\n" ++ "          name=\"total ion current\" value=\"{d:.4}\"/>\n",
            .{sp.tic},
        );

        if (sp.base_peak_mz) |bp| {
            try self.print(
                "        <cvParam cvRef=\"MS\" accession=\"MS:1000504\"\n" ++ "          name=\"base peak m/z\" value=\"{d:.4}\"\n" ++ "          unitCvRef=\"MS\" unitAccession=\"MS:1000040\"\n" ++ "          unitName=\"m/z\"/>\n",
                .{bp},
            );
        }
        if (sp.base_peak_intensity) |bp| {
            try self.print(
                "        <cvParam cvRef=\"MS\" accession=\"MS:1000505\"\n" ++ "          name=\"base peak intensity\" value=\"{d:.2}\"\n" ++ "          unitCvRef=\"MS\" unitAccession=\"MS:1000131\"\n" ++ "          unitName=\"number of detector counts\"/>\n",
                .{bp},
            );
        }
        try self.print(
            "        <cvParam cvRef=\"MS\" accession=\"MS:1000528\"\n" ++ "          name=\"lowest observed m/z\" value=\"{d:.4}\"\n" ++ "          unitCvRef=\"MS\" unitAccession=\"MS:1000040\"\n" ++ "          unitName=\"m/z\"/>\n",
            .{sp.lowest_mz},
        );
        try self.print(
            "        <cvParam cvRef=\"MS\" accession=\"MS:1000527\"\n" ++ "          name=\"highest observed m/z\" value=\"{d:.4}\"\n" ++ "          unitCvRef=\"MS\" unitAccession=\"MS:1000040\"\n" ++ "          unitName=\"m/z\"/>\n",
            .{sp.highest_mz},
        );
    }

    fn writeScanList(self: *MzmlWriter, sp: types.Spectrum) WriteError!void {
        if (sp.instrument_config_ref) |ref| {
            try self.print("        <scanList count=\"1\">\n          <scan instrumentConfigurationRef=\"{s}\">\n", .{ref});
        } else {
            try self.write_str("        <scanList count=\"1\">\n          <scan>\n");
        }
        if (sp.rt) |rt| {
            try self.print(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1000016\"\n" ++ "              name=\"scan start time\" value=\"{d:.4}\"\n" ++ "              unitCvRef=\"UO\" unitAccession=\"UO:0000031\"\n" ++ "              unitName=\"minute\"/>\n",
                .{rt},
            );
        }
        if (sp.filter_string) |fs| {
            try self.print(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1000512\" name=\"filter string\" value=\"{s}\"/>\n",
                .{fs},
            );
        }
        for (sp.scan_windows) |window| {
            try self.print(
                "            <scanWindowList count=\"1\">\n" ++ "              <scanWindow>\n" ++ "                <cvParam cvRef=\"MS\" accession=\"MS:1000501\"\n" ++ "                  name=\"scan window lower limit\" value=\"{d:.4}\"\n" ++ "                  unitCvRef=\"MS\" unitAccession=\"MS:1000040\"\n" ++ "                  unitName=\"m/z\"/>\n" ++ "                <cvParam cvRef=\"MS\" accession=\"MS:1000500\"\n" ++ "                  name=\"scan window upper limit\" value=\"{d:.4}\"\n" ++ "                  unitCvRef=\"MS\" unitAccession=\"MS:1000040\"\n" ++ "                  unitName=\"m/z\"/>\n" ++ "              </scanWindow>\n" ++ "            </scanWindowList>\n",
                .{ window.lower_limit, window.upper_limit },
            );
        }
        try self.write_str("          </scan>\n        </scanList>\n");
    }

    fn writePrecursorList(self: *MzmlWriter, prec: types.Precursor) WriteError!void {
        try self.write_str("        <precursorList count=\"1\">\n");
        if (prec.spectrum_ref) |ref| {
            try self.print("          <precursor spectrumRef=\"{s}\">\n", .{ref});
        } else {
            try self.write_str("          <precursor>\n");
        }

        try self.write_str("            <isolationWindow>\n");
        try self.print(
            "              <cvParam cvRef=\"MS\" accession=\"MS:1000827\"\n" ++ "                name=\"isolation window target m/z\" value=\"{d:.4}\"/>\n",
            .{prec.isolation_mz},
        );
        if (prec.isolation_width) |w| {
            const half = w / 2.0;
            try self.print(
                "              <cvParam cvRef=\"MS\" accession=\"MS:1000828\"\n" ++ "                name=\"isolation window lower offset\" value=\"{d:.4}\"/>\n",
                .{half},
            );
            try self.print(
                "              <cvParam cvRef=\"MS\" accession=\"MS:1000829\"\n" ++ "                name=\"isolation window upper offset\" value=\"{d:.4}\"/>\n",
                .{half},
            );
        }
        try self.write_str("            </isolationWindow>\n");

        try self.write_str("            <selectedIonList count=\"1\">\n");
        try self.write_str("              <selectedIon>\n");
        try self.print(
            "                <cvParam cvRef=\"MS\" accession=\"MS:1000744\"\n" ++ "                  name=\"selected ion m/z\" value=\"{d:.4}\"/>\n",
            .{prec.isolation_mz},
        );
        if (prec.charge) |z| {
            var buf: [16]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{z});
            try self.print(
                "                <cvParam cvRef=\"MS\" accession=\"MS:1000041\"\n" ++ "                  name=\"charge state\" value=\"{s}\"/>\n",
                .{s},
            );
        }
        try self.write_str("              </selectedIon>\n            </selectedIonList>\n");

        try self.write_str("            <activation>\n");
        if (prec.activation_type) |at| {
            if (std.mem.eql(u8, at, "HCD")) {
                try self.write_str(
                    "              <cvParam cvRef=\"MS\" accession=\"MS:1000422\"\n" ++ "                name=\"beam-type collision-induced dissociation\"/>\n",
                );
            } else if (std.mem.eql(u8, at, "CID")) {
                try self.write_str(
                    "              <cvParam cvRef=\"MS\" accession=\"MS:1000133\"\n" ++ "                name=\"collision-induced dissociation\"/>\n",
                );
            } else if (std.mem.eql(u8, at, "ETD")) {
                try self.write_str(
                    "              <cvParam cvRef=\"MS\" accession=\"MS:1000598\"\n" ++ "                name=\"electron transfer dissociation\"/>\n",
                );
            } else if (std.mem.eql(u8, at, "ECD")) {
                try self.write_str(
                    "              <cvParam cvRef=\"MS\" accession=\"MS:1000250\"\n" ++ "                name=\"electron capture dissociation\"/>\n",
                );
            }
        }
        if (prec.collision_energy) |ce| {
            try self.print(
                "              <cvParam cvRef=\"MS\" accession=\"MS:1000045\"\n" ++ "                name=\"collision energy\" value=\"{d:.1}\"\n" ++ "                unitCvRef=\"UO\" unitAccession=\"UO:0000266\"\n" ++ "                unitName=\"electronvolt\"/>\n",
                .{ce},
            );
        }
        try self.write_str("            </activation>\n");

        try self.write_str("          </precursor>\n        </precursorList>\n");
    }

    fn writeProductList(self: *MzmlWriter, product: types.Product) WriteError!void {
        try self.write_str("        <productList count=\"1\">\n          <product>\n            <isolationWindow>\n");
        try self.print(
            "              <cvParam cvRef=\"MS\" accession=\"MS:1000827\"\n" ++ "                name=\"isolation window target m/z\" value=\"{d:.4}\"\n" ++ "                unitCvRef=\"MS\" unitAccession=\"MS:1000040\"\n" ++ "                unitName=\"m/z\"/>\n",
            .{product.isolation_mz},
        );
        if (product.isolation_width) |w| {
            const half = w / 2.0;
            try self.print(
                "              <cvParam cvRef=\"MS\" accession=\"MS:1000828\"\n" ++ "                name=\"isolation window lower offset\" value=\"{d:.4}\"\n" ++ "                unitCvRef=\"MS\" unitAccession=\"MS:1000040\"\n" ++ "                unitName=\"m/z\"/>\n",
                .{half},
            );
            try self.print(
                "              <cvParam cvRef=\"MS\" accession=\"MS:1000829\"\n" ++ "                name=\"isolation window upper offset\" value=\"{d:.4}\"\n" ++ "                unitCvRef=\"MS\" unitAccession=\"MS:1000040\"\n" ++ "                unitName=\"m/z\"/>\n",
                .{half},
            );
        }
        try self.write_str("            </isolationWindow>\n          </product>\n        </productList>\n");
    }

    fn writeBinaryDataArrayList(self: *MzmlWriter, sp: types.Spectrum) WriteError!void {
        const mz_data = try sp.mz_slice(self.allocator);
        defer self.allocator.free(mz_data);
        const inten_data = try sp.intensity_slice(self.allocator);
        defer self.allocator.free(inten_data);

        const mz_b64 = try self.encodeArray(mz_data);
        defer self.allocator.free(mz_b64);
        const inten_b64 = try self.encodeArray(inten_data);
        defer self.allocator.free(inten_b64);

        try self.write_str("        <binaryDataArrayList count=\"2\">\n");

        // m/z array
        try self.print(
            "          <binaryDataArray encodedLength=\"{d}\">\n",
            .{mz_b64.len},
        );
        try self.writeArrayCvParams(.mz_array);
        try self.write_str("            <binary>");
        try self.write_str(mz_b64);
        try self.write_str("</binary>\n          </binaryDataArray>\n");

        // intensity array
        try self.print(
            "          <binaryDataArray encodedLength=\"{d}\">\n",
            .{inten_b64.len},
        );
        try self.writeArrayCvParams(.intensity_array);
        try self.write_str("            <binary>");
        try self.write_str(inten_b64);
        try self.write_str("</binary>\n          </binaryDataArray>\n");

        try self.write_str("        </binaryDataArrayList>\n");
    }

    fn writeArrayCvParams(self: *MzmlWriter, at: enum { mz_array, intensity_array }) WriteError!void {
        switch (at) {
            .mz_array => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1000514\"\n" ++ "              name=\"m/z array\" unitCvRef=\"MS\"\n" ++ "              unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n",
            ),
            .intensity_array => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1000515\"\n" ++ "              name=\"intensity array\" unitCvRef=\"MS\"\n" ++ "              unitAccession=\"MS:1000131\"\n" ++ "              unitName=\"number of detector counts\"/>\n",
            ),
        }
        switch (self.options.precision) {
            .f64 => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1000523\"\n" ++ "              name=\"64-bit float\"/>\n",
            ),
            .f32 => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1000521\"\n" ++ "              name=\"32-bit float\"/>\n",
            ),
        }
        try self.write_compression_cv();
    }

    /// Write compression CV param based on writer options.
    /// Public method for use by streaming converters.
    pub fn write_compression_cv(self: *MzmlWriter) WriteError!void {
        switch (self.options.compression) {
            .none => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1000576\"\n" ++ "              name=\"no compression\"/>\n",
            ),
            .zlib => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1000574\"\n" ++ "              name=\"zlib compression\"/>\n",
            ),
            .numpress_linear => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1002746\"\n" ++ "              name=\"MS-Numpress linear prediction compression\"/>\n",
            ),
            .numpress_pic => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1002747\"\n" ++ "              name=\"MS-Numpress positive integer compression\"/>\n",
            ),
            .numpress_slof => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1002748\"\n" ++ "              name=\"MS-Numpress short logged float compression\"/>\n",
            ),
            .zlib_numpress_linear => try self.write_str(
                "            <cvParam cvRef=\"MS\" accession=\"MS:1002749\"\n" ++ "              name=\"MS-Numpress linear prediction compression followed by zlib compression\"/>\n",
            ),
        }
    }

    fn encodeArray(self: *MzmlWriter, data: []const f64) WriteError![]u8 {
        return switch (self.options.compression) {
            .none => b64.encode_f64_array(self.allocator, data),
            .zlib => encode_zlib_f64(self.allocator, data),
            .numpress_linear => encode_numpress_f64(self.allocator, data, self.options.linear_fixed_point),
            .numpress_pic => encode_numpress_pic_f64(self.allocator, data),
            .numpress_slof => encode_numpress_slof_f64(self.allocator, data),
            .zlib_numpress_linear => encode_zlib_numpress_linear(self.allocator, data, self.options.linear_fixed_point),
        };
    }

    /// Encode m/z array with current compression settings.
    /// Public method for use by streaming converters.
    pub fn encode_mz_array(self: *MzmlWriter, mz: []const f64) WriteError![]u8 {
        return switch (self.options.compression) {
            .none => b64.encode_f64_array(self.allocator, mz),
            .zlib => encode_zlib_f64(self.allocator, mz),
            .numpress_linear => encode_numpress_f64(self.allocator, mz, self.options.linear_fixed_point),
            .numpress_pic => encode_numpress_pic_f64(self.allocator, mz),
            .numpress_slof => encode_numpress_slof_f64(self.allocator, mz),
            .zlib_numpress_linear => encode_zlib_numpress_linear(self.allocator, mz, self.options.linear_fixed_point),
        };
    }

    /// Encode intensity array with current precision and compression settings.
    /// Public method for use by streaming converters.
    pub fn encode_intensity_array(self: *MzmlWriter, intensity: []const f32) WriteError![]u8 {
        switch (self.options.compression) {
            .none => return switch (self.options.precision) {
                .f64 => b64.encode_f32_as_f64_array(self.allocator, intensity),
                .f32 => b64.encode_f32_array(self.allocator, intensity),
            },
            .zlib => {
                if (self.options.precision == .f32) return encode_zlib_f32(self.allocator, intensity);
                var f64_data = try self.allocator.alloc(f64, intensity.len);
                defer self.allocator.free(f64_data);
                for (intensity, 0..) |val, i| f64_data[i] = @floatCast(val);
                return encode_zlib_f64(self.allocator, f64_data);
            },
            inline .numpress_linear, .numpress_pic, .numpress_slof, .zlib_numpress_linear => |mode| {
                var f64_data = try self.allocator.alloc(f64, intensity.len);
                defer self.allocator.free(f64_data);
                for (intensity, 0..) |val, i| f64_data[i] = @floatCast(val);
                return switch (mode) {
                    .numpress_linear => encode_numpress_f64(self.allocator, f64_data, self.options.linear_fixed_point),
                    .numpress_pic => encode_numpress_pic_f64(self.allocator, f64_data),
                    .numpress_slof => encode_numpress_slof_f64(self.allocator, f64_data),
                    .zlib_numpress_linear => encode_zlib_numpress_linear(self.allocator, f64_data, self.options.linear_fixed_point),
                    else => unreachable,
                };
            },
        }
    }

    // --- indexedmzML ---

    /// Write the index. If `file_checksum` is provided, writes it;
    /// otherwise writes "0" as placeholder.
    pub fn write_index(self: *MzmlWriter, file_checksum: ?[]const u8) WriteError!void {
        if (!self.options.use_indexed_mzml) return;
        try self.write_index_content();
        if (file_checksum) |cs| {
            try self.print("<fileChecksum>{s}</fileChecksum>\n", .{cs});
        } else {
            try self.write_str("<fileChecksum>0</fileChecksum>\n");
        }
    }

    /// Write only the index content (without the checksum tag).
    /// Useful for streaming checksum computation.
    pub fn write_index_content(self: *MzmlWriter) WriteError!void {
        if (!self.options.use_indexed_mzml) return;
        const index_offset = self.byte_offset;
        try self.write_str("<indexList count=\"1\">\n  <index name=\"spectrum\">\n");
        for (self.spectrum_offsets.items) |offset| {
            try self.write_str("    <offset idRef=\"");
            try self.writeEscapedAttr(offset.id);
            try self.print("\">{d}</offset>\n", .{offset.offset});
        }
        try self.write_str("  </index>\n</indexList>\n");
        try self.print("<indexListOffset>{d}</indexListOffset>\n", .{index_offset});
    }

    // --- Full document ---

    pub fn write_mz_ml(
        self: *MzmlWriter,
        spectra: []const types.Spectrum,
        run_info: types.RunInfo,
        source_file_name: ?[]const u8,
        file_checksum: ?[]const u8,
        source_file_location: ?[]const u8,
    ) WriteError!void {
        try self.write_header();
        try self.write_file_description(source_file_name, source_file_location);
        try self.write_referenceable_param_group_list(run_info.ref_param_group_params);
        try self.write_software_list();
        if (run_info.instrument_configuration) |ic| {
            try self.write_str("  <instrumentConfigurationList count=\"1\">\n");
            try self.write_instrument_configuration(ic);
            try self.write_str("  </instrumentConfigurationList>\n");
        } else {
            try self.write_instrument_configuration_list(run_info.instrument_params, null);
        }
        try self.write_data_processing_list();
        try self.write_run_open(run_info, spectra.len);
        for (spectra) |sp| try self.write_spectrum(sp);
        try self.write_footer(null);
        if (self.options.use_indexed_mzml) try self.write_index(file_checksum);
    }
};

// ============================================================================
// Encoding helpers
// ============================================================================

/// Compress raw bytes with zlib and return base64-encoded result.
fn compressAndBase64(allocator: std.mem.Allocator, bytes: []const u8) WriteError![]u8 {
    // Use Allocating writer so it can grow dynamically.
    // Start with an estimate; it will resize if compressed data is larger.
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    try alloc_writer.ensureUnusedCapacity(@max(64, bytes.len / 4));

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(
        &alloc_writer.writer,
        &window_buf,
        .zlib,
        .fastest,
    );
    try comp.writer.writeAll(bytes);
    try comp.finish();

    const compressed = try alloc_writer.toOwnedSlice();
    defer allocator.free(compressed);
    return b64.encode(allocator, compressed);
}

pub fn encode_zlib_f64(allocator: std.mem.Allocator, data: []const f64) WriteError![]u8 {
    const byte_len = data.len * @sizeOf(f64);
    var bytes = try allocator.alloc(u8, byte_len);
    defer allocator.free(bytes);
    for (data, 0..) |val, i| {
        std.mem.writeInt(u64, bytes[i * 8 ..][0..8], @as(u64, @bitCast(val)), .little);
    }
    return compressAndBase64(allocator, bytes);
}

pub fn encode_zlib_f32(allocator: std.mem.Allocator, data: []const f32) WriteError![]u8 {
    const byte_len = data.len * @sizeOf(f32);
    var bytes = try allocator.alloc(u8, byte_len);
    defer allocator.free(bytes);
    for (data, 0..) |val, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], @as(u32, @bitCast(val)), .little);
    }
    return compressAndBase64(allocator, bytes);
}

pub fn encode_numpress_f64(allocator: std.mem.Allocator, data: []const f64, fixed_point: f64) WriteError![]u8 {
    var buf = try allocator.alloc(u8, data.len * 10 + 16);
    defer allocator.free(buf);
    const n = try numpress_mod.encode_linear(data, buf, fixed_point);
    return b64.encode(allocator, buf[0..n]);
}

pub fn encode_numpress_pic_f64(allocator: std.mem.Allocator, data: []const f64) WriteError![]u8 {
    var buf = try allocator.alloc(u8, data.len * 10 + 16);
    defer allocator.free(buf);
    const n = try numpress_mod.encode_pic(data, buf);
    return b64.encode(allocator, buf[0..n]);
}

pub fn encode_numpress_slof_f64(allocator: std.mem.Allocator, data: []const f64) WriteError![]u8 {
    var buf = try allocator.alloc(u8, data.len * 2 + 16);
    defer allocator.free(buf);
    const n = try numpress_mod.encode_slof(data, buf);
    return b64.encode(allocator, buf[0..n]);
}

pub fn encode_zlib_numpress_linear(allocator: std.mem.Allocator, data: []const f64, fixed_point: f64) WriteError![]u8 {
    var buf = try allocator.alloc(u8, data.len * 10 + 16);
    defer allocator.free(buf);
    const n = try numpress_mod.encode_linear(data, buf, fixed_point);
    return compressAndBase64(allocator, buf[0..n]);
}

// ============================================================================
// Convenience: write MsRun directly to a file (NO intermediate copy)
// ============================================================================

/// Write a complete mzML file from a run directly to disk.
/// No intermediate buffer copy — writes XML directly from the writer buffer.
pub fn write_mzml_file(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    run: types.RunInfo,
    spectra: []const types.Spectrum,
    source_file_name: ?[]const u8,
    options: MzmlWriterOptions,
) WriteError!void {
    var writer = try MzmlWriter.init(allocator, options);
    defer writer.deinit();

    try writer.write_mz_ml(spectra, run, source_file_name, null, null);

    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    var write_buf: [65536]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);

    // Write in chunks to avoid WriteFailed on large buffers
    const chunk_size = 256 * 1024;
    const bytes = writer.bytes();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + chunk_size, bytes.len);
        try file_writer.interface.writeAll(bytes[offset..end]);
        offset = end;
    }
    try file_writer.end();
}

// ============================================================================
// Tests
// ============================================================================

test "MzmlWriter basic structure" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try MzmlWriter.init(allocator, .{});
    defer writer.deinit();

    const peaks = &[_]types.Peak{
        .{ .mz = 100.0, .intensity = 10.0 },
        .{ .mz = 200.0, .intensity = 20.0 },
    };
    const spectrum = types.Spectrum{
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
        .scan_params = &[_]types.CVParam{},
        .scan_windows = &[_]types.ScanWindow{},
        .precursor = null,
        .default_array_length = 2,
    };

    const run_info = types.RunInfo{ .id = "run_1" };

    try writer.write_mz_ml(&[_]types.Spectrum{spectrum}, run_info, null, null, null);

    const output = writer.bytes();
    try std.testing.expect(std.mem.indexOf(u8, output, "<?xml version=\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<mzML") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<spectrum index=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</mzML>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<binary>") != null);
}

test "MzmlWriter with MS2" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try MzmlWriter.init(allocator, .{});
    defer writer.deinit();

    const peaks = &[_]types.Peak{
        .{ .mz = 110.0, .intensity = 50.0 },
    };
    const spectrum = types.Spectrum{
        .index = 0,
        .id = "scan=1",
        .ms_level = 2,
        .peaks = peaks,
        .rt = 1.0,
        .tic = 50.0,
        .base_peak_mz = 110.0,
        .base_peak_intensity = 50.0,
        .lowest_mz = 110.0,
        .highest_mz = 110.0,
        .scan_params = &[_]types.CVParam{},
        .scan_windows = &[_]types.ScanWindow{},
        .precursor = .{
            .isolation_mz = 712.35,
            .isolation_width = 2.0,
            .charge = 2,
            .collision_energy = 30.0,
            .activation_type = "HCD",
        },
        .default_array_length = 1,
    };

    const run_info = types.RunInfo{ .id = "run_1" };
    try writer.write_mz_ml(&[_]types.Spectrum{spectrum}, run_info, null, null, null);

    const output = writer.bytes();
    try std.testing.expect(std.mem.indexOf(u8, output, "MSn spectrum") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<precursorList") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "712.35") != null);
}

test "MzmlWriter zlib compression" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try MzmlWriter.init(allocator, .{ .compression = .zlib });
    defer writer.deinit();

    const peaks = &[_]types.Peak{
        .{ .mz = 100.0, .intensity = 10.0 },
        .{ .mz = 200.0, .intensity = 20.0 },
    };
    const spectrum = types.Spectrum{
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
        .scan_params = &[_]types.CVParam{},
        .scan_windows = &[_]types.ScanWindow{},
        .precursor = null,
        .default_array_length = 2,
    };

    const run_info = types.RunInfo{ .id = "run_1" };
    try writer.write_mz_ml(&[_]types.Spectrum{spectrum}, run_info, null, null, null);

    const output = writer.bytes();
    try std.testing.expect(std.mem.indexOf(u8, output, "zlib compression") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<binary>") != null);
}

test "MzmlWriter zlib compression large data" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a large array that would overflow a fixed buffer
    const n = 10000;
    const data = try allocator.alloc(f64, n);
    defer allocator.free(data);
    for (data, 0..) |*d, i| d.* = @floatFromInt(i % 1000);

    const encoded = try encode_zlib_f64(allocator, data);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);
    // Compressed + base64 should be smaller than raw f64 base64
    const raw_b64_len = std.base64.standard.Encoder.calcSize(n * 8);
    try std.testing.expect(encoded.len < raw_b64_len);
}

test "MzmlWriter zlib f32 compression" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const n = 5000;
    const data = try allocator.alloc(f32, n);
    defer allocator.free(data);
    for (data, 0..) |*d, i| d.* = @floatFromInt(i % 100);

    const encoded = try encode_zlib_f32(allocator, data);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);
    const raw_b64_len = std.base64.standard.Encoder.calcSize(n * 4);
    try std.testing.expect(encoded.len < raw_b64_len);
}

test "MzmlWriter toOwnedBuffer" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try MzmlWriter.init(allocator, .{});
    defer writer.deinit();

    try writer.write_str("hello world");

    var buf = writer.to_owned_buffer();
    defer buf.deinit(allocator);

    try std.testing.expectEqualStrings("hello world", buf.items);
    try std.testing.expectEqual(@as(usize, 0), writer.buf.items.len);
}

test "MzmlWriter SHA-1 checksum" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try MzmlWriter.init(allocator, .{ .use_indexed_mzml = true });
    defer writer.deinit();

    try writer.write_str("<?xml version=\"1.0\"?>\n");
    try writer.write_str("<mzML>\n");
    try writer.write_str("  <run>\n");
    try writer.write_str("    <spectrumList>\n");
    try writer.write_str("      <spectrum id=\"scan=1\"/>\n");
    try writer.write_str("    </spectrumList>\n");
    try writer.write_str("  </run>\n");
    try writer.write_str("</mzML>\n");

    // Write index content (without checksum) and compute hash of all bytes up to checksum
    try writer.write_index_content();
    const pre_checksum = writer.bytes();
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pre_checksum);
    const digest = hasher.finalResult();
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.bytesToHex(digest, .lower)}) catch unreachable;

    // Write fileChecksum tag
    try writer.print("<fileChecksum>{s}</fileChecksum>\n", .{&hex});

    const output = writer.bytes();

    // Verify the checksum appears in output
    try std.testing.expect(std.mem.indexOf(u8, output, &hex) != null);

    // Recompute hash of all bytes before <fileChecksum> and verify match
    const idx = std.mem.indexOf(u8, output, "<fileChecksum>").?;
    var hasher2 = std.crypto.hash.Sha1.init(.{});
    hasher2.update(output[0..idx]);
    const digest2 = hasher2.finalResult();
    var hex2: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex2, "{s}", .{std.fmt.bytesToHex(digest2, .lower)}) catch unreachable;

    try std.testing.expectEqualStrings(&hex, &hex2);
}
