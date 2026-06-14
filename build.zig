const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    // ---- tools/cli_args module --------------------------------------------
    const cli_args_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/cli_args.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- raw_core/advanced_packet module ----------------------------------
    const packet_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/advanced_packet.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- raw_core/profile_packet module -----------------------------------
    const profile_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/profile_packet.zig"),
        .target = target,
        .optimize = optimize,
    });
    profile_mod.addImport("advanced_packet", packet_mod);

    // ---- raw_core/spectrum_pool module ------------------------------------
    const spectrum_pool_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/spectrum_pool.zig"),
        .target = target,
        .optimize = optimize,
    });
    spectrum_pool_mod.addImport("advanced_packet", packet_mod);

    // ---- raw_core/raw_file module -----------------------------------------
    // PUBLISHED MODULE — consumed by the sibling `msViewer` repo via a
    // build.zig.zon path dependency: dep.module("raw_file").
    // DO NOT downgrade to b.createModule: that would silently break the
    // msViewer link (path deps can only see modules published via addModule).
    // See AGENTS.md § "Published modules (msViewer link)".
    const raw_file_mod = b.addModule("raw_file", .{
        .root_source_file = b.path("src/raw_core/raw_file.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- raw_core/scan_event module ---------------------------------------

    // ---- raw_core/scan_event module ---------------------------------------
    const scan_event_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/scan_event.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- raw_core/unicode_utils module (shared UTF-16LE → UTF-8) ----
    const unicode_utils_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/unicode_utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    scan_event_mod.addImport("raw_file", raw_file_mod);
    scan_event_mod.addImport("unicode_utils", unicode_utils_mod);

    // ---- raw_core/trailer_extra module (generic per-scan metadata) --------
    const trailer_extra_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/trailer_extra.zig"),
        .target = target,
        .optimize = optimize,
    });
    trailer_extra_mod.addImport("raw_file", raw_file_mod);
    trailer_extra_mod.addImport("scan_event", scan_event_mod);
    trailer_extra_mod.addImport("unicode_utils", unicode_utils_mod);

    // ---- raw_core/raw_file_reader module -----------------------------------
    const raw_file_reader_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/raw_file_reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    raw_file_reader_mod.addImport("raw_file", raw_file_mod);
    raw_file_reader_mod.addImport("unicode_utils", unicode_utils_mod);

    // ---- raw_core/filter_string module (filter string parsing) ------------
    // These spec modules must be defined first (no dependencies, used by raw_core)
    const spec_scan_event_info_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/scan_event_info.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spec_packet_header_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/packet_header.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spec_scan_index_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/scan_index.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_packet_header_mod.addImport("scan_index", spec_scan_index_mod);

    const spec_filter_string_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/filter_string.zig"),
        .target = target,
        .optimize = optimize,
    });

    const filter_string_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/filter_string.zig"),
        .target = target,
        .optimize = optimize,
    });
    filter_string_mod.addImport("spec/filter_string", spec_filter_string_mod);
    filter_string_mod.addImport("spec/scan_event_info", spec_scan_event_info_mod);

    // ---- raw_core/trailer_events module -----------------------------------
    const trailer_events_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/trailer_events.zig"),
        .target = target,
        .optimize = optimize,
    });
    trailer_events_mod.addImport("raw_file", raw_file_mod);
    trailer_events_mod.addImport("scan_event", scan_event_mod);
    trailer_events_mod.addImport("unicode_utils", unicode_utils_mod);
    trailer_events_mod.addImport("filter_string", filter_string_mod);

    // ---- raw_core/checksum module -------------------------------------------
    const checksum_mod_ = b.createModule(.{
        .root_source_file = b.path("src/raw_core/checksum.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    checksum_mod_.addImport("raw_file", raw_file_mod);

    // ---- raw_core/writer_primitives module -------------------------------
    const writer_primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/writer_primitives.zig"),
        .target = target,
        .optimize = optimize,
    });
    writer_primitives_mod.addImport("raw_file", raw_file_mod);
    writer_primitives_mod.addImport("checksum", checksum_mod_);
    writer_primitives_mod.addImport("scan_event", scan_event_mod);

    // ---- raw_writer module (de-novo .raw creation) --------------------
    const raw_writer_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_writer/writer.zig"),
        .target = target,
        .optimize = optimize,
    });
    raw_writer_mod.addImport("raw_file", raw_file_mod);
    raw_writer_mod.addImport("writer_primitives", writer_primitives_mod);
    raw_writer_mod.addImport("scan_event", scan_event_mod);
    raw_writer_mod.addImport("advanced_packet", packet_mod);

    // ---- raw_core/schema module ---------------------------------------------
    const schema_mod_ = b.createModule(.{
        .root_source_file = b.path("src/raw_core/schema.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    schema_mod_.addImport("raw_file", raw_file_mod);
    schema_mod_.addImport("advanced_packet", packet_mod);

    // ---- export/raw_file_writer module --------------------------------------
    const raw_file_writer_mod = b.createModule(.{
        .root_source_file = b.path("src/export/raw_file_writer.zig"),
        .target = target,
        .optimize = optimize,
    });
    raw_file_writer_mod.addImport("raw_file", raw_file_mod);
    raw_file_writer_mod.addImport("raw_file_reader", raw_file_reader_mod);
    raw_file_writer_mod.addImport("advanced_packet", packet_mod);
    raw_file_writer_mod.addImport("profile_packet", profile_mod);
    raw_file_writer_mod.addImport("trailer_events", trailer_events_mod);
    raw_file_writer_mod.addImport("writer_primitives", writer_primitives_mod);
    raw_file_writer_mod.addImport("schema", schema_mod_);

    // ---- file_state module ------------------------------------------------
    const file_state_mod = b.createModule(.{
        .root_source_file = b.path("src/file_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_state_mod.addImport("raw_file", raw_file_mod);
    file_state_mod.addImport("raw_file_reader", raw_file_reader_mod);
    file_state_mod.addImport("trailer_events", trailer_events_mod);
    file_state_mod.addImport("trailer_extra", trailer_extra_mod);
    file_state_mod.addImport("scan_event", scan_event_mod);

    // ---- view_state module ------------------------------------------------
    const view_state_mod = b.createModule(.{
        .root_source_file = b.path("src/view_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    view_state_mod.addImport("advanced_packet", packet_mod);

    // ---- scan_decoder module -----------------------------------------
    // PUBLISHED MODULE — DO NOT downgrade to b.createModule: that would
    // silently break the msViewer link (path deps can only see modules
    // published via addModule). See AGENTS.md § "Published modules (msViewer
    // link)". Added for Issue 17: msViewer needs the spectrum packet decoder.
    const scan_decoder_mod = b.addModule("scan_decoder", .{
        .root_source_file = b.path("src/scan_decoder.zig"),
        .target = target,
        .optimize = optimize,
    });
    scan_decoder_mod.addImport("advanced_packet", packet_mod);
    scan_decoder_mod.addImport("raw_file", raw_file_mod);
    scan_decoder_mod.addImport("profile_packet", profile_mod);
    scan_decoder_mod.addImport("trailer_events", trailer_events_mod);
    scan_decoder_mod.addImport("spectrum_pool", spectrum_pool_mod);

    // ---- core modules (unified IR for format export) ------------------
    const core_types_mod = b.createModule(.{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- spec modules -----------------------------------------------------
    // Declarative structural specifications — single source of truth for
    // all binary offsets and sizes (ADR-0003).
    const spec_file_header_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/file_header.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spec_run_header_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/run_header.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spec_raw_info_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/raw_info.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spec_reaction_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/reaction.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spec_instrument_id_mod = b.createModule(.{
        .root_source_file = b.path("src/spec/instrument_id.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Wire spec modules into raw_file
    raw_file_mod.addImport("spec/file_header", spec_file_header_mod);
    raw_file_mod.addImport("spec/run_header", spec_run_header_mod);
    raw_file_mod.addImport("spec/raw_info", spec_raw_info_mod);
    raw_file_mod.addImport("spec/scan_event_info", spec_scan_event_info_mod);
    raw_file_mod.addImport("spec/reaction", spec_reaction_mod);
    raw_file_mod.addImport("spec/instrument_id", spec_instrument_id_mod);
    raw_file_mod.addImport("spec/packet_header", spec_packet_header_mod);
    raw_file_mod.addImport("spec/scan_index", spec_scan_index_mod);

    // Wire spec modules into raw_writer
    raw_writer_mod.addImport("spec/file_header", spec_file_header_mod);
    raw_writer_mod.addImport("spec/raw_info", spec_raw_info_mod);
    raw_writer_mod.addImport("spec/run_header", spec_run_header_mod);

    // Wire spec modules into writer_primitives
    writer_primitives_mod.addImport("spec/scan_index", spec_scan_index_mod);
    writer_primitives_mod.addImport("spec/scan_event_info", spec_scan_event_info_mod);
    writer_primitives_mod.addImport("spec/reaction", spec_reaction_mod);

    // Wire spec modules into raw_file_reader
    raw_file_reader_mod.addImport("spec/file_header", spec_file_header_mod);
    raw_file_reader_mod.addImport("spec/instrument_id", spec_instrument_id_mod);

    // Wire spec/packet_header into scan_decoder
    scan_decoder_mod.addImport("spec/packet_header", spec_packet_header_mod);

    // ---- app_state module -------------------------------------------------
    const app_state_mod = b.createModule(.{
        .root_source_file = b.path("src/app_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_state_mod.addImport("advanced_packet", packet_mod);
    app_state_mod.addImport("raw_file", raw_file_mod);
    app_state_mod.addImport("raw_file_reader", raw_file_reader_mod);
    app_state_mod.addImport("scan_event", scan_event_mod);
    app_state_mod.addImport("trailer_events", trailer_events_mod);
    app_state_mod.addImport("profile_packet", profile_mod);
    app_state_mod.addImport("scan_decoder", scan_decoder_mod);
    app_state_mod.addImport("file_state", file_state_mod);
    app_state_mod.addImport("view_state", view_state_mod);

    // ---- core/instrument_utils module (analyzer inference) --------------
    const core_instrument_utils_mod = b.createModule(.{
        .root_source_file = b.path("src/core/instrument_utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_instrument_utils_mod.addImport("spec/scan_event_info", spec_scan_event_info_mod);
    core_instrument_utils_mod.addImport("spec/packet_header", spec_packet_header_mod);
    core_instrument_utils_mod.addImport("raw_file", raw_file_mod);

    // ---- mzml/cv module (PSI-MS controlled vocabulary) ----------
    const mzml_cv_mod = b.createModule(.{
        .root_source_file = b.path("src/mzml/cv.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- core/converter module (RawFile → MsRun) --------------------
    const core_converter_mod = b.createModule(.{
        .root_source_file = b.path("src/core/converter.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_converter_mod.addImport("raw_file_reader", raw_file_reader_mod);
    core_converter_mod.addImport("raw_file", raw_file_mod);
    core_converter_mod.addImport("trailer_events", trailer_events_mod);
    core_converter_mod.addImport("scan_event", scan_event_mod);
    core_converter_mod.addImport("scan_decoder", scan_decoder_mod);
    core_converter_mod.addImport("types", core_types_mod);
    core_converter_mod.addImport("cv", mzml_cv_mod);
    core_converter_mod.addImport("filter_string", filter_string_mod);
    core_converter_mod.addImport("instrument_utils", core_instrument_utils_mod);

    // ---- mzml modules (mzML format export) ----------------------------

    const mzml_base64_mod = b.createModule(.{
        .root_source_file = b.path("src/mzml/base64.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mzml_numpress_mod = b.createModule(.{
        .root_source_file = b.path("src/mzml/numpress.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mzml_types_mod = b.createModule(.{
        .root_source_file = b.path("src/mzml/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    mzml_types_mod.addImport("types", core_types_mod);

    const mzml_writer_mod = b.createModule(.{
        .root_source_file = b.path("src/mzml/writer.zig"),
        .target = target,
        .optimize = optimize,
    });
    mzml_writer_mod.addImport("mzml_types", mzml_types_mod);
    mzml_writer_mod.addImport("cv", mzml_cv_mod);
    mzml_writer_mod.addImport("base64", mzml_base64_mod);
    mzml_writer_mod.addImport("numpress", mzml_numpress_mod);

    const mzml_streaming_convert_mod = b.createModule(.{
        .root_source_file = b.path("src/mzml/streaming_convert.zig"),
        .target = target,
        .optimize = optimize,
    });
    mzml_streaming_convert_mod.addImport("app_state", app_state_mod);
    mzml_streaming_convert_mod.addImport("file_state", file_state_mod);
    mzml_streaming_convert_mod.addImport("mzml_writer", mzml_writer_mod);
    mzml_streaming_convert_mod.addImport("mzml_types", mzml_types_mod);
    mzml_streaming_convert_mod.addImport("base64", mzml_base64_mod);
    mzml_streaming_convert_mod.addImport("raw_file", raw_file_mod);
    mzml_streaming_convert_mod.addImport("cv", mzml_cv_mod);
    mzml_streaming_convert_mod.addImport("filter_string", filter_string_mod);
    mzml_streaming_convert_mod.addImport("instrument_utils", core_instrument_utils_mod);

    // ---- cli modules -------------------------------------------------------
    const cli_args_internal_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/args.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_output_sink_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/output/sink.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_output_json_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/output/json.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_output_csv_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/output/csv.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mzig_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mzig_mod.addImport("cli_args", cli_args_mod);
    mzig_mod.addImport("args", cli_args_internal_mod);
    mzig_mod.addImport("app_state", app_state_mod);
    mzig_mod.addImport("streaming_convert", mzml_streaming_convert_mod);
    mzig_mod.addImport("mzml_writer", mzml_writer_mod);
    mzig_mod.addImport("sink", cli_output_sink_mod);
    mzig_mod.addImport("json", cli_output_json_mod);
    mzig_mod.addImport("csv", cli_output_csv_mod);

    const mzig_exe = b.addExecutable(.{ .name = "mzig", .root_module = mzig_mod });
    b.installArtifact(mzig_exe);
    const mzig_run = b.addRunArtifact(mzig_exe);
    mzig_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| mzig_run.addArgs(args);
    const mzig_step = b.step("mzig", "Run the mzig CLI (pass command args)");
    mzig_step.dependOn(&mzig_run.step);

    // ---- tools/convert_to_mzml executable ----------------------------------
    const convert_to_mzml_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/convert_to_mzml.zig"),
        .target = target,
        .optimize = optimize,
    });
    convert_to_mzml_mod.addImport("app_state", app_state_mod);
    convert_to_mzml_mod.addImport("streaming_convert", mzml_streaming_convert_mod);
    convert_to_mzml_mod.addImport("mzml_writer", mzml_writer_mod);
    convert_to_mzml_mod.addImport("cli_args", cli_args_mod);

    const convert_to_mzml_exe = b.addExecutable(.{ .name = "convert-to-mzml", .root_module = convert_to_mzml_mod });
    b.installArtifact(convert_to_mzml_exe);
    const convert_to_mzml_run = b.addRunArtifact(convert_to_mzml_exe);
    convert_to_mzml_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| convert_to_mzml_run.addArgs(args);
    const convert_to_mzml_step = b.step("convert-to-mzml", "Convert .raw to mzML (pass input.raw output.mzML as args)");
    convert_to_mzml_step.dependOn(&convert_to_mzml_run.step);

    // ---- gui/win32_common module ------------------------------------------
    const win32_common_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/win32_common.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- gui/spectrum_canvas module ---------------------------------------
    const spectrum_canvas_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/spectrum_canvas.zig"),
        .target = target,
        .optimize = optimize,
    });
    spectrum_canvas_mod.addImport("win32_common", win32_common_mod);
    spectrum_canvas_mod.addImport("app_state", app_state_mod);
    spectrum_canvas_mod.addImport("advanced_packet", packet_mod);

    // ---- gui/chromatogram_canvas module -----------------------------------
    const chromatogram_canvas_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/chromatogram_canvas.zig"),
        .target = target,
        .optimize = optimize,
    });
    chromatogram_canvas_mod.addImport("win32_common", win32_common_mod);
    chromatogram_canvas_mod.addImport("app_state", app_state_mod);

    // ---- gui/scan_list module ---------------------------------------------
    const scan_list_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/scan_list.zig"),
        .target = target,
        .optimize = optimize,
    });
    scan_list_mod.addImport("win32_common", win32_common_mod);
    scan_list_mod.addImport("app_state", app_state_mod);

    // ---- gui/file_dialog module -------------------------------------------
    const file_dialog_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/file_dialog.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_dialog_mod.addImport("win32_common", win32_common_mod);

    // ---- gui/main_window module -------------------------------------------
    const main_window_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/main_window.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_window_mod.addImport("win32_common", win32_common_mod);
    main_window_mod.addImport("app_state", app_state_mod);
    main_window_mod.addImport("spectrum_canvas", spectrum_canvas_mod);
    main_window_mod.addImport("chromatogram_canvas", chromatogram_canvas_mod);
    main_window_mod.addImport("scan_list", scan_list_mod);
    main_window_mod.addImport("file_dialog", file_dialog_mod);

    // ---- main executable (Win32 viewer) ------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("advanced_packet", packet_mod);
    exe_mod.addImport("raw_file", raw_file_mod);
    exe_mod.addImport("raw_file_reader", raw_file_reader_mod);
    exe_mod.addImport("main_window", main_window_mod);
    exe_mod.addImport("app_state", app_state_mod);
    exe_mod.addImport("scan_event", scan_event_mod);
    exe_mod.addImport("trailer_events", trailer_events_mod);
    exe_mod.addImport("cli_args", cli_args_mod);

    const exe = b.addExecutable(.{
        .name = "raw-orbitrap-viewer",
        .root_module = exe_mod,
    });

    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("kernel32", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    exe.root_module.linkSystemLibrary("comdlg32", .{});
    exe.root_module.linkSystemLibrary("comctl32", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Win32 viewer");
    run_step.dependOn(&run_cmd.step);

    // PUBLISHED MODULE — consumed by the sibling `msViewer` repo via a
    // build.zig.zon path dependency: dep.module("plot_math").
    // DO NOT downgrade to b.createModule (see note on raw_file_mod above and
    // AGENTS.md § "Published modules (msViewer link)").
    const plot_math_mod = b.addModule("plot_math", .{
        .root_source_file = b.path("src/viewer/plot_math.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- imguinz2 viewer (GLFW + OpenGL3 + docking) -------------------
    const imguinz2_dep = b.dependency("imguinz2", .{});

    const appimgui_dep = imguinz2_dep.builder.dependency("appimgui", .{
        .target = target,
        .optimize = optimize,
    });
    const implot_dep = imguinz2_dep.builder.dependency("implot", .{
        .target = target,
        .optimize = optimize,
    });

    const zgui_viewer_mod = b.createModule(.{
        .root_source_file = b.path("src/viewer_zgui/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zgui_viewer_mod.addImport("appimgui", appimgui_dep.module("appimgui"));
    zgui_viewer_mod.addImport("implot", implot_dep.module("implot"));
    zgui_viewer_mod.addImport("raw_file", raw_file_mod);
    zgui_viewer_mod.addImport("raw_file_reader", raw_file_reader_mod);
    zgui_viewer_mod.addImport("scan_decoder", scan_decoder_mod);
    zgui_viewer_mod.addImport("app_state", app_state_mod);
    zgui_viewer_mod.addImport("file_state", file_state_mod);
    zgui_viewer_mod.addImport("view_state", view_state_mod);
    zgui_viewer_mod.addImport("cli_args", cli_args_mod);
    zgui_viewer_mod.addImport("advanced_packet", packet_mod);
    zgui_viewer_mod.addImport("raw_file_writer", raw_file_writer_mod);
    zgui_viewer_mod.addImport("streaming_convert", mzml_streaming_convert_mod);
    zgui_viewer_mod.addImport("mzml_writer", mzml_writer_mod);

    const zgui_exe = b.addExecutable(.{
        .name = "raw-zgui-viewer",
        .root_module = zgui_viewer_mod,
    });
    zgui_exe.subsystem = .Windows;
    zgui_exe.root_module.linkSystemLibrary("comdlg32", .{});

    b.installArtifact(zgui_exe);

    const zgui_run_cmd = b.addRunArtifact(zgui_exe);
    zgui_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        zgui_run_cmd.addArgs(args);
    }

    const zgui_run_step = b.step("run-zgui", "Run the imguinz2 viewer");
    zgui_run_step.dependOn(&zgui_run_cmd.step);

    // ---- unit tests (all inline tests from all modules) --------------

    // tests/all.zig imports every source module with inline `test "..."`
    // blocks. zig build test runs everything in one pass.
    const all_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    all_tests_mod.addImport("advanced_packet", packet_mod);
    all_tests_mod.addImport("profile_packet", profile_mod);
    all_tests_mod.addImport("plot_math", plot_math_mod);
    all_tests_mod.addImport("schema", schema_mod_);

    const all_tests = b.addTest(.{
        .root_module = all_tests_mod,
    });

    const writer_primitives_tests = b.addTest(.{ .root_module = writer_primitives_mod });
    const raw_writer_tests = b.addTest(.{ .root_module = raw_writer_mod });
    const raw_file_tests = b.addTest(.{ .root_module = raw_file_mod });
    const spec_file_header_tests = b.addTest(.{ .root_module = spec_file_header_mod });
    const spec_run_header_tests = b.addTest(.{ .root_module = spec_run_header_mod });
    const spec_raw_info_tests = b.addTest(.{ .root_module = spec_raw_info_mod });
    const spec_scan_event_info_tests = b.addTest(.{ .root_module = spec_scan_event_info_mod });
    const spec_reaction_tests = b.addTest(.{ .root_module = spec_reaction_mod });
    const spec_instrument_id_tests = b.addTest(.{ .root_module = spec_instrument_id_mod });
    const spectrum_pool_tests = b.addTest(.{ .root_module = spectrum_pool_mod });
    const file_state_tests = b.addTest(.{ .root_module = file_state_mod });
    const view_state_tests = b.addTest(.{ .root_module = view_state_mod });
    const core_types_tests = b.addTest(.{ .root_module = core_types_mod });
    const mzml_cv_tests = b.addTest(.{ .root_module = mzml_cv_mod });
    const mzml_base64_tests = b.addTest(.{ .root_module = mzml_base64_mod });
    const mzml_numpress_tests = b.addTest(.{ .root_module = mzml_numpress_mod });
    const mzml_types_tests = b.addTest(.{ .root_module = mzml_types_mod });
    const mzml_writer_tests = b.addTest(.{ .root_module = mzml_writer_mod });
    const filter_string_tests = b.addTest(.{ .root_module = filter_string_mod });
    const unicode_utils_tests = b.addTest(.{ .root_module = unicode_utils_mod });
    const core_converter_tests = b.addTest(.{ .root_module = core_converter_mod });
    const core_instrument_utils_tests = b.addTest(.{ .root_module = core_instrument_utils_mod });
    const spec_filter_string_tests = b.addTest(.{ .root_module = spec_filter_string_mod });
    const scan_decoder_tests = b.addTest(.{ .root_module = scan_decoder_mod });
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(writer_primitives_tests).step);
    test_step.dependOn(&b.addRunArtifact(raw_writer_tests).step);
    test_step.dependOn(&b.addRunArtifact(raw_file_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_file_header_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_run_header_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_raw_info_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_scan_event_info_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_reaction_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_instrument_id_tests).step);
    test_step.dependOn(&b.addRunArtifact(spectrum_pool_tests).step);
    test_step.dependOn(&b.addRunArtifact(file_state_tests).step);
    test_step.dependOn(&b.addRunArtifact(view_state_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_types_tests).step);
    test_step.dependOn(&b.addRunArtifact(mzml_cv_tests).step);
    test_step.dependOn(&b.addRunArtifact(mzml_base64_tests).step);
    test_step.dependOn(&b.addRunArtifact(mzml_numpress_tests).step);
    test_step.dependOn(&b.addRunArtifact(mzml_types_tests).step);
    test_step.dependOn(&b.addRunArtifact(mzml_writer_tests).step);
    test_step.dependOn(&b.addRunArtifact(filter_string_tests).step);
    test_step.dependOn(&b.addRunArtifact(unicode_utils_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_converter_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_instrument_utils_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_filter_string_tests).step);
    test_step.dependOn(&b.addRunArtifact(scan_decoder_tests).step);
    test_step.dependOn(&b.addRunArtifact(all_tests).step);

    // ---- integration tests (real .raw file required) ------------------
    // All integration tests take a .raw file path as CLI argument.
    // Usage: zig build test-integration -- <path-to-file.raw>

    // Phase 1 trailer test
    const test_trailer_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/test_trailer_phase1.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_trailer_mod.addImport("raw_file", raw_file_mod);
    test_trailer_mod.addImport("raw_file_reader", raw_file_reader_mod);
    test_trailer_mod.addImport("scan_event", scan_event_mod);
    test_trailer_mod.addImport("trailer_events", trailer_events_mod);
    test_trailer_mod.addImport("cli_args", cli_args_mod);

    const test_trailer_exe = b.addExecutable(.{
        .name = "test-trailer-phase1",
        .root_module = test_trailer_mod,
    });

    const test_trailer_run = b.addRunArtifact(test_trailer_exe);
    if (b.args) |args| test_trailer_run.addArgs(args);

    // Schema detection integration test (needs real .raw file)
    const test_schema_int_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/test_schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_schema_int_mod.addImport("schema", schema_mod_);
    test_schema_int_mod.addImport("raw_file", raw_file_mod);
    test_schema_int_mod.addImport("raw_file_reader", raw_file_reader_mod);
    test_schema_int_mod.addImport("cli_args", cli_args_mod);

    const test_schema_int_exe = b.addExecutable(.{
        .name = "test-schema",
        .root_module = test_schema_int_mod,
    });

    const test_schema_int_run = b.addRunArtifact(test_schema_int_exe);
    if (b.args) |args| test_schema_int_run.addArgs(args);

    // GOTCHAS.md G3 regression test: assert that <precursor spectrumRef="...">
    // matches a sibling spectrum `id="..."` exactly. mzML 1.1.0 spec requires
    // this for downstream cross-tool parent-scan resolution.
    const test_spectrumref_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/test_spectrumref_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_spectrumref_mod.addImport("app_state", app_state_mod);
    test_spectrumref_mod.addImport("streaming_convert", mzml_streaming_convert_mod);
    test_spectrumref_mod.addImport("mzml_writer", mzml_writer_mod);
    test_spectrumref_mod.addImport("cli_args", cli_args_mod);

    const test_spectrumref_exe = b.addExecutable(.{
        .name = "test-spectrumref-format",
        .root_module = test_spectrumref_mod,
    });

    const test_spectrumref_run = b.addRunArtifact(test_spectrumref_exe);
    if (b.args) |args| test_spectrumref_run.addArgs(args);

    // Unified integration test step — runs all four with same file arg
    const test_integration_step = b.step("test-integration", "Run integration tests (pass .raw file as arg)");
    test_integration_step.dependOn(&test_trailer_run.step);
    test_integration_step.dependOn(&test_schema_int_run.step);
    test_integration_step.dependOn(&test_spectrumref_run.step);

    const test_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/test_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_cli_mod.addImport("cli_args", cli_args_mod);
    test_cli_mod.addImport("args", cli_args_internal_mod);
    test_cli_mod.addImport("app_state", app_state_mod);
    test_cli_mod.addImport("streaming_convert", mzml_streaming_convert_mod);
    test_cli_mod.addImport("mzml_writer", mzml_writer_mod);
    test_cli_mod.addImport("sink", cli_output_sink_mod);
    test_cli_mod.addImport("json", cli_output_json_mod);
    test_cli_mod.addImport("csv", cli_output_csv_mod);

    const test_cli_exe = b.addExecutable(.{
        .name = "test-cli",
        .root_module = test_cli_mod,
    });
    const test_cli_run = b.addRunArtifact(test_cli_exe);
    test_cli_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| test_cli_run.addArgs(args);
    const test_cli_step = b.step("test-cli", "Run CLI integration tests (pass .raw file as arg)");
    test_cli_step.dependOn(&test_cli_run.step);

    // ---- benchmark executable ---------------------------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("app_state", app_state_mod);
    bench_mod.addImport("cli_args", cli_args_mod);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });

    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);

    const bench_step = b.step("bench", "Run benchmarks (pass .raw file as arg)");
    bench_step.dependOn(&bench_run.step);

    // ---- ground truth generation (Phase 1) --------------------------------
    const gen_gt_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/generate_ground_truth.zig"),
        .target = target,
        .optimize = .Debug,
    });
    gen_gt_mod.addImport("cli_args", cli_args_mod);

    const gen_gt_exe = b.addExecutable(.{ .name = "generate-ground-truth", .root_module = gen_gt_mod });
    const gen_gt_run = b.addRunArtifact(gen_gt_exe);
    gen_gt_run.cwd = b.path(".");
    if (b.args) |args| gen_gt_run.addArgs(args);
    const gen_gt_step = b.step("generate-ground-truth", "Generate ground truth from ThermoRawFileParser");
    gen_gt_step.dependOn(&gen_gt_run.step);

    // ---- sampled ground truth generation (for large files) ---------------
    const sample_gt_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/sample_ground_truth.zig"),
        .target = target,
        .optimize = .Debug,
    });
    sample_gt_mod.addImport("cli_args", cli_args_mod);
    sample_gt_mod.addImport("raw_file_reader", raw_file_reader_mod);

    const sample_gt_exe = b.addExecutable(.{ .name = "sample-ground-truth", .root_module = sample_gt_mod });
    const sample_gt_run = b.addRunArtifact(sample_gt_exe);
    sample_gt_run.cwd = b.path(".");
    if (b.args) |args| sample_gt_run.addArgs(args);
    const sample_gt_step = b.step("sample-ground-truth", "Generate sampled ground truth (N random scans; pass .raw file and optionally N)");
    sample_gt_step.dependOn(&sample_gt_run.step);

    // ---- ground truth verification (Phase 2) ------------------------------
    const ver_gt_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/verify_ground_truth.zig"),
        .target = target,
        .optimize = .Debug,
    });
    ver_gt_mod.addImport("app_state", app_state_mod);
    ver_gt_mod.addImport("cli_args", cli_args_mod);
    ver_gt_mod.addImport("raw_file_reader", raw_file_reader_mod);

    const ver_gt_exe = b.addExecutable(.{ .name = "verify-ground-truth", .root_module = ver_gt_mod });
    const ver_gt_run = b.addRunArtifact(ver_gt_exe);
    ver_gt_run.cwd = b.path(".");
    if (b.args) |args| ver_gt_run.addArgs(args);
    const ver_gt_step = b.step("verify-ground-truth", "Verify mzigRead against ground truth");
    ver_gt_step.dependOn(&ver_gt_run.step);

    // ---- debug_meta executable ---------------------------------------------
    const debug_meta_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/debug/debug_meta.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_meta_mod.addImport("app_state", app_state_mod);
    debug_meta_mod.addImport("cli_args", cli_args_mod);

    const debug_meta_exe = b.addExecutable(.{
        .name = "debug_meta",
        .root_module = debug_meta_mod,
    });

    const debug_meta_run = b.addRunArtifact(debug_meta_exe);
    if (b.args) |args| {
        debug_meta_run.addArgs(args);
    }

    const debug_meta_step = b.step("debug-meta", "Debug metadata dump");
    debug_meta_step.dependOn(&debug_meta_run.step);

    // ---- debug_mass executable ---------------------------------------------
    const debug_mass_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/debug/debug_mass.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_mass_mod.addImport("app_state", app_state_mod);
    debug_mass_mod.addImport("cli_args", cli_args_mod);

    const debug_mass_exe = b.addExecutable(.{
        .name = "debug_mass",
        .root_module = debug_mass_mod,
    });

    const debug_mass_run = b.addRunArtifact(debug_mass_exe);
    if (b.args) |args| {
        debug_mass_run.addArgs(args);
    }

    const debug_mass_step = b.step("debug-mass", "Debug mass calibration");
    debug_mass_step.dependOn(&debug_mass_run.step);

    // ---- debug_profile executable ------------------------------------------
    const debug_profile_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/debug/debug_profile.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_profile_mod.addImport("app_state", app_state_mod);
    debug_profile_mod.addImport("raw_file", raw_file_mod);
    debug_profile_mod.addImport("advanced_packet", packet_mod);
    debug_profile_mod.addImport("profile_packet", profile_mod);
    debug_profile_mod.addImport("cli_args", cli_args_mod);

    const debug_profile_exe = b.addExecutable(.{
        .name = "debug_profile",
        .root_module = debug_profile_mod,
    });

    const debug_profile_run = b.addRunArtifact(debug_profile_exe);
    if (b.args) |args| {
        debug_profile_run.addArgs(args);
    }

    const debug_profile_step = b.step("debug-profile", "Debug profile packet decode");
    debug_profile_step.dependOn(&debug_profile_run.step);

    // ---- debug_scan_dump executable ----------------------------------------
    const debug_scan_dump_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/debug/debug_scan_dump.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_scan_dump_mod.addImport("app_state", app_state_mod);
    debug_scan_dump_mod.addImport("raw_file", raw_file_mod);
    debug_scan_dump_mod.addImport("advanced_packet", packet_mod);
    debug_scan_dump_mod.addImport("scan_event", scan_event_mod);
    debug_scan_dump_mod.addImport("trailer_extra", trailer_extra_mod);
    debug_scan_dump_mod.addImport("cli_args", cli_args_mod);

    const debug_scan_dump_exe = b.addExecutable(.{
        .name = "debug_scan_dump",
        .root_module = debug_scan_dump_mod,
    });

    const debug_scan_dump_run = b.addRunArtifact(debug_scan_dump_exe);
    if (b.args) |args| {
        debug_scan_dump_run.addArgs(args);
    }

    const debug_scan_dump_step = b.step("debug-scan-dump", "Dump scan metadata + peaks as JSON (pass .raw file and scan number as args)");
    debug_scan_dump_step.dependOn(&debug_scan_dump_run.step);

    // ---- verify_passthrough executable ------------------------------------
    const verify_passthrough_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/verify_passthrough.zig"),
        .target = target,
        .optimize = optimize,
    });
    verify_passthrough_mod.addImport("app_state", app_state_mod);
    verify_passthrough_mod.addImport("raw_file_writer", raw_file_writer_mod);
    verify_passthrough_mod.addImport("cli_args", cli_args_mod);

    const verify_passthrough_exe = b.addExecutable(.{
        .name = "verify_passthrough",
        .root_module = verify_passthrough_mod,
    });

    const verify_passthrough_run = b.addRunArtifact(verify_passthrough_exe);
    if (b.args) |args| {
        verify_passthrough_run.addArgs(args);
    }

    const verify_passthrough_step = b.step("verify-passthrough", "Verify .raw passthrough (pass input.raw output.raw as args)");
    verify_passthrough_step.dependOn(&verify_passthrough_run.step);

    // ---- verify_encode executable ------------------------------------------
    const verify_encode_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/verify_encode.zig"),
        .target = target,
        .optimize = optimize,
    });
    verify_encode_mod.addImport("app_state", app_state_mod);
    verify_encode_mod.addImport("advanced_packet", packet_mod);
    verify_encode_mod.addImport("raw_file", raw_file_mod);
    verify_encode_mod.addImport("cli_args", cli_args_mod);

    const verify_encode_exe = b.addExecutable(.{
        .name = "verify_encode",
        .root_module = verify_encode_mod,
    });

    const verify_encode_run = b.addRunArtifact(verify_encode_exe);
    if (b.args) |args| {
        verify_encode_run.addArgs(args);
    }

    const verify_encode_step = b.step("verify-encode", "Verify centroid encoder round-trip (pass .raw file as arg)");
    verify_encode_step.dependOn(&verify_encode_run.step);

    // ---- verify_profile executable -----------------------------------------
    const verify_profile_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/verify_profile.zig"),
        .target = target,
        .optimize = optimize,
    });
    verify_profile_mod.addImport("app_state", app_state_mod);
    verify_profile_mod.addImport("profile_packet", profile_mod);
    verify_profile_mod.addImport("raw_file", raw_file_mod);
    verify_profile_mod.addImport("cli_args", cli_args_mod);

    const verify_profile_exe = b.addExecutable(.{
        .name = "verify_profile",
        .root_module = verify_profile_mod,
    });

    const verify_profile_run = b.addRunArtifact(verify_profile_exe);
    if (b.args) |args| {
        verify_profile_run.addArgs(args);
    }

    const verify_profile_step = b.step("verify-profile", "Verify profile encoder round-trip (pass .raw file as arg)");
    verify_profile_step.dependOn(&verify_profile_run.step);

    // ---- passthrough executable (write-only, no verification) --------------
    const passthrough_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/passthrough.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    passthrough_mod.addImport("app_state", app_state_mod);
    passthrough_mod.addImport("raw_file_writer", raw_file_writer_mod);
    passthrough_mod.addImport("cli_args", cli_args_mod);

    const passthrough_exe = b.addExecutable(.{
        .name = "passthrough",
        .root_module = passthrough_mod,
    });
    b.installArtifact(passthrough_exe);

    const passthrough_run = b.addRunArtifact(passthrough_exe);
    passthrough_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        passthrough_run.addArgs(args);
    }

    const passthrough_step = b.step("passthrough", "Write re-encoded .raw (pass input.raw output.raw as args)");
    passthrough_step.dependOn(&passthrough_run.step);

    // ---- check_checksum executable (diagnostic) -----------------------------
    const check_checksum_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/check_checksum.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    check_checksum_mod.addImport("raw_file", raw_file_mod);
    check_checksum_mod.addImport("checksum", checksum_mod_);
    check_checksum_mod.addImport("cli_args", cli_args_mod);
    check_checksum_mod.addImport("spec/file_header", spec_file_header_mod);

    const check_checksum_exe = b.addExecutable(.{
        .name = "check_checksum",
        .root_module = check_checksum_mod,
    });

    const check_checksum_run = b.addRunArtifact(check_checksum_exe);
    if (b.args) |args| {
        check_checksum_run.addArgs(args);
    }

    const check_checksum_step = b.step("check-checksum", "Verify RAW file checksum (pass .raw file as arg)");
    check_checksum_step.dependOn(&check_checksum_run.step);

    // ---- dump_packet_header executable (diagnostic) ------------------------
    const dump_packet_header_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/dump_packet_header.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    dump_packet_header_mod.addImport("app_state", app_state_mod);
    dump_packet_header_mod.addImport("raw_file", raw_file_mod);
    dump_packet_header_mod.addImport("advanced_packet", packet_mod);
    dump_packet_header_mod.addImport("cli_args", cli_args_mod);

    const dump_packet_header_exe = b.addExecutable(.{
        .name = "dump_packet_header",
        .root_module = dump_packet_header_mod,
    });

    const dump_packet_header_run = b.addRunArtifact(dump_packet_header_exe);
    if (b.args) |args| {
        dump_packet_header_run.addArgs(args);
    }

    const dump_packet_header_step = b.step("dump-packet-header", "Dump packet header for a scan (pass .raw file and scan number)");
    dump_packet_header_step.dependOn(&dump_packet_header_run.step);

    // ---- tools step (build all dev/diagnostic tools, no install) --------
    const tools_step = b.step("tools", "Build all development tools (bench, verify, debug, ground-truth)");
    tools_step.dependOn(&bench_exe.step);
    tools_step.dependOn(&verify_passthrough_exe.step);
    tools_step.dependOn(&verify_encode_exe.step);
    tools_step.dependOn(&verify_profile_exe.step);
    tools_step.dependOn(&check_checksum_exe.step);
    tools_step.dependOn(&gen_gt_exe.step);
    tools_step.dependOn(&sample_gt_exe.step);
    tools_step.dependOn(&ver_gt_exe.step);
    tools_step.dependOn(&debug_meta_exe.step);
    tools_step.dependOn(&debug_mass_exe.step);
    tools_step.dependOn(&debug_profile_exe.step);
    tools_step.dependOn(&debug_scan_dump_exe.step);
    tools_step.dependOn(&dump_packet_header_exe.step);
}
