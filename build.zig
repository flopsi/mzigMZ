const std = @import("std");

pub fn build(b: *std.Build) void {
    
    
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

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

    // ---- raw_core/raw_file module -----------------------------------------
    const raw_file_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/raw_file.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- raw_core/scan_event module ---------------------------------------
    const scan_event_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/scan_event.zig"),
        .target = target,
        .optimize = optimize,
    });
    scan_event_mod.addImport("raw_file", raw_file_mod);

    // ---- raw_core/raw_file_reader module -----------------------------------
    const raw_file_reader_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/raw_file_reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    raw_file_reader_mod.addImport("raw_file", raw_file_mod);

    // ---- raw_core/trailer_events module -----------------------------------
    const trailer_events_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/trailer_events.zig"),
        .target = target,
        .optimize = optimize,
    });
    trailer_events_mod.addImport("raw_file", raw_file_mod);
    trailer_events_mod.addImport("scan_event", scan_event_mod);

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

    // ---- gui/win32_viewer module (legacy simple viewer) -------------------
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/win32_viewer.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("advanced_packet", packet_mod);
    gui_mod.addImport("win32_common", win32_common_mod);

    // ---- main executable -------------------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("advanced_packet", packet_mod);
    exe_mod.addImport("raw_file", raw_file_mod);
    exe_mod.addImport("raw_file_reader", raw_file_reader_mod);
    exe_mod.addImport("win32_viewer", gui_mod);
    exe_mod.addImport("main_window", main_window_mod);
    exe_mod.addImport("app_state", app_state_mod);
    exe_mod.addImport("scan_event", scan_event_mod);
    exe_mod.addImport("trailer_events", trailer_events_mod);

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

    const run_step = b.step("run", "Run the viewer");
    run_step.dependOn(&run_cmd.step);

    // ---- unit tests (advanced_packet) ----------------------------
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/raw_core/advanced_packet.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = tests_mod,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // ---- benchmark executable ---------------------------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("app_state", app_state_mod);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_run.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks (pass .raw file as arg)");
    bench_step.dependOn(&bench_run.step);

    // ---- Phase 1 test executable -------------------------------------------
    const test_trailer_mod = b.createModule(.{
        .root_source_file = b.path("src/test_trailer_phase1.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_trailer_mod.addImport("raw_file", raw_file_mod);
    test_trailer_mod.addImport("raw_file_reader", raw_file_reader_mod);
    test_trailer_mod.addImport("scan_event", scan_event_mod);
    test_trailer_mod.addImport("trailer_events", trailer_events_mod);

    const test_trailer_exe = b.addExecutable(.{
        .name = "test-trailer-phase1",
        .root_module = test_trailer_mod,
    });
    b.installArtifact(test_trailer_exe);

    const test_trailer_run = b.addRunArtifact(test_trailer_exe);
    test_trailer_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        test_trailer_run.addArgs(args);
    }

    // ---- C3 trailer-label sanity test -----------------------------------------
    const test_trailer_label_mod = b.createModule(.{
        .root_source_file = b.path("src/test_trailer_label.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_trailer_label_mod.addImport("app_state", app_state_mod);
    test_trailer_label_mod.addImport("raw_file_reader", raw_file_reader_mod);

    const test_trailer_label_exe = b.addExecutable(.{
        .name = "test-trailer-label",
        .root_module = test_trailer_label_mod,
    });
    b.installArtifact(test_trailer_label_exe);

    const test_trailer_label_run = b.addRunArtifact(test_trailer_label_exe);
    test_trailer_label_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        test_trailer_label_run.addArgs(args);
    }

    const test_trailer_step = b.step("test-trailer", "Run Phase 1 trailer test (pass .raw file as arg)");
    test_trailer_step.dependOn(&test_trailer_run.step);

    // ---- debug_meta executable ---------------------------------------------
    const debug_meta_mod = b.createModule(.{
        .root_source_file = b.path("src/debug_meta.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_meta_mod.addImport("app_state", app_state_mod);

    const debug_meta_exe = b.addExecutable(.{
        .name = "debug_meta",
        .root_module = debug_meta_mod,
    });
    b.installArtifact(debug_meta_exe);

    const debug_meta_run = b.addRunArtifact(debug_meta_exe);
    debug_meta_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        debug_meta_run.addArgs(args);
    }

    const debug_meta_step = b.step("debug-meta", "Debug metadata dump");
    debug_meta_step.dependOn(&debug_meta_run.step);

    // ---- debug_mass executable ---------------------------------------------
    const debug_mass_mod = b.createModule(.{
        .root_source_file = b.path("src/debug_mass.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_mass_mod.addImport("app_state", app_state_mod);

    const debug_mass_exe = b.addExecutable(.{
        .name = "debug_mass",
        .root_module = debug_mass_mod,
    });
    b.installArtifact(debug_mass_exe);

    const debug_mass_run = b.addRunArtifact(debug_mass_exe);
    debug_mass_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        debug_mass_run.addArgs(args);
    }

    const debug_mass_step = b.step("debug-mass", "Debug mass calibration");
    debug_mass_step.dependOn(&debug_mass_run.step);

    // ---- debug_profile executable ------------------------------------------
    const debug_profile_mod = b.createModule(.{
        .root_source_file = b.path("src/debug_profile.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_profile_mod.addImport("app_state", app_state_mod);
    debug_profile_mod.addImport("raw_file", raw_file_mod);
    debug_profile_mod.addImport("advanced_packet", packet_mod);
    debug_profile_mod.addImport("profile_packet", profile_mod);

    const debug_profile_exe = b.addExecutable(.{
        .name = "debug_profile",
        .root_module = debug_profile_mod,
    });
    b.installArtifact(debug_profile_exe);

    const debug_profile_run = b.addRunArtifact(debug_profile_exe);
    debug_profile_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        debug_profile_run.addArgs(args);
    }

    const debug_profile_step = b.step("debug-profile", "Debug profile packet decode");
    debug_profile_step.dependOn(&debug_profile_run.step);

    // ---- debug_scan_dump executable ----------------------------------------
    const debug_scan_dump_mod = b.createModule(.{
        .root_source_file = b.path("src/debug_scan_dump.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_scan_dump_mod.addImport("app_state", app_state_mod);
    debug_scan_dump_mod.addImport("raw_file", raw_file_mod);
    debug_scan_dump_mod.addImport("advanced_packet", packet_mod);
    debug_scan_dump_mod.addImport("scan_event", scan_event_mod);

    const debug_scan_dump_exe = b.addExecutable(.{
        .name = "debug_scan_dump",
        .root_module = debug_scan_dump_mod,
    });
    b.installArtifact(debug_scan_dump_exe);

    const debug_scan_dump_run = b.addRunArtifact(debug_scan_dump_exe);
    debug_scan_dump_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        debug_scan_dump_run.addArgs(args);
    }

    const debug_scan_dump_step = b.step("debug-scan-dump", "Dump scan metadata + peaks as JSON (pass .raw file and scan number as args)");
    debug_scan_dump_step.dependOn(&debug_scan_dump_run.step);

    // ---- test-all executable -----------------------------------------------
    const test_all_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/test_all.zig"),
        .target = target,
        .optimize = .Debug,
    });
    test_all_mod.addImport("raw_file", raw_file_mod);
    test_all_mod.addImport("advanced_packet", packet_mod);
    test_all_mod.addImport("scan_event", scan_event_mod);
    test_all_mod.addImport("trailer_events", trailer_events_mod);
    test_all_mod.addImport("app_state", app_state_mod);

    const test_all = b.addTest(.{ .root_module = test_all_mod });
    const test_all_step = b.step("test-all", "Run full test suite");
    test_all_step.dependOn(&b.addRunArtifact(test_all).step);
}
