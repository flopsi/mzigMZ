/// Phase 1 test: Verify TrailerScanEvents parsing produces correct MS levels.
const std = @import("std");
const raw = @import("raw_file");
const trailer_events = @import("trailer_events");
const scan_event = @import("scan_event");

const LPCWSTR = [*:0]const u16;
const LPWSTR = [*:0]u16;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPCWSTR;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, pNumArgs: *i32) callconv(.winapi) ?[*]LPWSTR;
extern "kernel32" fn LocalFree(hMem: ?[*]LPWSTR) callconv(.winapi) ?*anyopaque;

fn wideZLen(s: [*:0]const u16) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

fn getArgs(allocator: std.mem.Allocator, _io: std.Io) ![][]u8 {
    _ = _io;
    const cmd_line = GetCommandLineW();
    var num_args: i32 = 0;
    const argv_wide = CommandLineToArgvW(cmd_line, &num_args) orelse return error.Failed;
    defer _ = LocalFree(argv_wide);

    const args = try allocator.alloc([]u8, @intCast(num_args));
    for (0..@intCast(num_args)) |i| {
        const wide = argv_wide[i];
        const len = wideZLen(wide);
        const wide_slice = wide[0..len];
        const aligned = try allocator.alloc(u16, len);
        defer allocator.free(aligned);
        for (0..len) |j| aligned[j] = wide_slice[j];
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, aligned);
        args[i] = utf8;
    }
    return args;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try getArgs(allocator, io);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    if (args.len < 2) {
        std.log.err("Usage: test-trailer-phase1.exe <raw-file>", .{});
        return error.MissingArgument;
    }
    const path = args[1];

    // Open file using std.Io API (same as main codebase)
    const file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});
    defer file.close(io);

    const file_size = (try file.stat(io)).size;
    std.log.info("File: {s} ({d} bytes)", .{ path, file_size });

    // Memory map
    var mm = try std.Io.File.createMemoryMap(file, io, .{
        .len = @intCast(file_size),
        .protection = .{ .read = true },
    });
    defer mm.destroy(io);

    // Read file revision
    const file_revision = try raw.readU16At(file, io, raw.FILE_REV_OFFSET);
    std.log.info("File revision: {d}", .{file_revision});

    if (file_revision < 65) {
        std.log.err("File revision {d} < 65, unsupported", .{file_revision});
        return error.UnsupportedFileRevision;
    }

    // Find MS controller
    var pos: u64 = raw.FILE_HEADER_SIZE;
    try raw.skipSequenceRow(file, io, &pos, file_revision);
    try raw.skipAutoSamplerConfig(file, io, &pos, file_revision);

    const raw_info_offset = pos;
    const controller_count_i32 = try raw.readI32At(file, io, raw_info_offset + raw.RAW_INFO_NUM_CONTROLLERS);

    var ms_controller_index: ?usize = null;
    var controller_offset: u64 = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(controller_count_i32))) : (i += 1) {
        const entry_base = raw_info_offset + raw.RAW_INFO_CONTROLLER_TABLE_CURRENT + @as(u64, @intCast(i)) * raw.RAW_INFO_CONTROLLER_SIZE_CURRENT;
        const device_type = try raw.readI32At(file, io, entry_base + raw.RAW_INFO_CONTROLLER_TYPE);
        if (device_type == raw.VIRTUAL_DEVICE_MS) {
            const off = try raw.readI64At(file, io, entry_base + raw.RAW_INFO_CONTROLLER_OFFSET);
            ms_controller_index = i;
            controller_offset = @intCast(off);
            break;
        }
    }

    if (ms_controller_index == null) {
        std.log.err("No MS controller found", .{});
        return error.NoMsController;
    }

    // Read run header
    const first_spectrum = try raw.readI32At(file, io, controller_offset + raw.RUN_HEADER_FIRST_SPECTRUM);
    const last_spectrum = try raw.readI32At(file, io, controller_offset + raw.RUN_HEADER_LAST_SPECTRUM);
    const num_scans: usize = @intCast(last_spectrum - first_spectrum + 1);
    std.log.info("Scans: {d} to {d} ({d} total)", .{ first_spectrum, last_spectrum, num_scans });

    const spectrum_pos_i64 = try raw.readI64At(file, io, controller_offset + raw.RUN_HEADER_SPECT_POS);
    const packet_pos_i64 = try raw.readI64At(file, io, controller_offset + raw.RUN_HEADER_PACKET_POS);
    const trailer_pos_i64 = try raw.readI64At(file, io, controller_offset + raw.RUN_HEADER_TRAILER_SCAN_EVENTS_POS);
    std.log.info("spectrum_pos={d}, packet_pos={d}, trailer_pos={d}", .{ spectrum_pos_i64, packet_pos_i64, trailer_pos_i64 });

    // Parse scan index table
    const scan_index_size = raw.scanIndexSize(file_revision);
    const scan_table_size = num_scans * scan_index_size;
    const spectrum_pos: usize = @intCast(spectrum_pos_i64);
    const scan_table_buf = mm.memory[spectrum_pos..spectrum_pos + scan_table_size];

    // Parse TrailerScanEvents
    if (trailer_pos_i64 <= 0) {
        std.log.err("Invalid trailer position", .{});
        return;
    }
    const trailer_pos: usize = @intCast(trailer_pos_i64);

    std.log.info("\n--- Raw TrailerScanEvents bytes ---", .{});
    const num_events = std.mem.readInt(i32, mm.memory[trailer_pos..][0..4], .little);
    std.log.info("num_events = {d}", .{num_events});

    // Dump first few index values
    const index_start = trailer_pos + 4;
    std.log.info("First 10 scan_to_unique indices:", .{});
    for (0..@min(10, num_scans)) |idx| {
        const val = std.mem.readInt(i32, mm.memory[index_start + idx * 4 ..][0..4], .little);
        std.log.info("  scan[{d}] -> unique[{d}]", .{ idx, val });
    }

    // Find max unique index
    var max_unique: i32 = -1;
    for (0..@as(usize, @intCast(num_events))) |idx| {
        const val = std.mem.readInt(i32, mm.memory[index_start + idx * 4 ..][0..4], .little);
        if (val > max_unique) max_unique = val;
    }
    std.log.info("Max unique index: {d} (num_unique = {d})", .{ max_unique, max_unique + 1 });

    // Try parsing first ScanEvent manually to debug
    const event_pos: usize = index_start + @as(usize, @intCast(num_events)) * 4;
    std.log.info("\n--- First ScanEvent at offset {d} ---", .{event_pos});

    // Dump first 128 bytes of first event
    std.log.info("First 128 bytes (hex):", .{});
    for (0..8) |row| {
        var hex_buf: [64]u8 = undefined;
        var hex_pos: usize = 0;
        for (0..16) |col| {
            const b = mm.memory[event_pos + row * 16 + col];
            hex_pos += (std.fmt.bufPrint(hex_buf[hex_pos..], "{X:0>2} ", .{b}) catch continue).len;
        }
        std.log.info("  {s}", .{hex_buf[0..hex_pos]});
    }

    // Read ScanEventInfo fields from raw bytes
    std.log.info("\nScanEventInfo fields:", .{});
    std.log.info("  ms_order (offset 6) = {d}", .{mm.memory[event_pos + 6]});
    std.log.info("  scan_type (offset 7) = {d}", .{mm.memory[event_pos + 7]});

    // Try to read num_reactions
    const reactions_pos = event_pos + 96;
    if (reactions_pos + 4 <= mm.memory.len) {
        const num_reactions = std.mem.readInt(i32, mm.memory[reactions_pos..][0..4], .little);
        std.log.info("  num_reactions (@{d}) = {d}", .{ reactions_pos, num_reactions });

        if (num_reactions >= 0 and num_reactions <= 10) {
            const reaction_size: usize = if (file_revision >= 66) raw.REACTION_SIZE_CURRENT else raw.REACTION_SIZE_REV65;
            std.log.info("  reaction_size = {d}", .{reaction_size});

            // Dump first reaction
            if (num_reactions > 0 and reactions_pos + 4 + reaction_size <= mm.memory.len) {
                const rxn = try raw.Reaction.read(mm.memory, reactions_pos + 4);
                std.log.info("  Reaction[0]: precursor_mass={e}, isolation_width={e}, collision_energy={e}", .{
                    rxn.precursor_mass, rxn.isolation_width, rxn.collision_energy,
                });
            }

            const mass_ranges_pos = reactions_pos + 4 + @as(usize, @intCast(num_reactions)) * reaction_size;
            if (mass_ranges_pos + 4 <= mm.memory.len) {
                const num_mass_ranges = std.mem.readInt(i32, mm.memory[mass_ranges_pos..][0..4], .little);
                std.log.info("  num_mass_ranges (@{d}) = {d}", .{ mass_ranges_pos, num_mass_ranges });

                const calibrators_pos = mass_ranges_pos + 4 + @as(usize, @intCast(num_mass_ranges)) * 16;
                if (calibrators_pos + 4 <= mm.memory.len) {
                    const num_calibrators = std.mem.readInt(i32, mm.memory[calibrators_pos..][0..4], .little);
                    std.log.info("  num_calibrators (@{d}) = {d}", .{ calibrators_pos, num_calibrators });

                    const fragmentations_pos = calibrators_pos + 4 + @as(usize, @intCast(num_calibrators)) * 8;
                    if (fragmentations_pos + 4 <= mm.memory.len) {
                        const num_fragmentations = std.mem.readInt(i32, mm.memory[fragmentations_pos..][0..4], .little);
                        std.log.info("  num_fragmentations (@{d}) = {d}", .{ fragmentations_pos, num_fragmentations });

                        const name_pos = fragmentations_pos + 4 + @as(usize, @intCast(num_fragmentations)) * 8;
                        if (name_pos + 4 <= mm.memory.len) {
                            const name_len = std.mem.readInt(i32, mm.memory[name_pos..][0..4], .little);
                            std.log.info("  name_len (@{d}) = {d}", .{ name_pos, name_len });
                        }
                    }
                }
            }
        } else {
            std.log.warn("  num_reactions out of range ({d}), trying as raw bytes...", .{num_reactions});
        }
    }

    // Now try the full parser
    std.log.info("\n--- Trying full parser ---", .{});
    var trailers = trailer_events.parseTrailerScanEvents(
        allocator,
        mm,
        trailer_pos,
        num_scans,
        file_revision,
    ) catch |err| {
        std.log.err("parseTrailerScanEvents failed: {s}", .{@errorName(err)});
        return;
    };
    defer trailers.deinit(allocator);

    std.log.info("Unique events: {d}", .{trailers.unique_events.len});
    std.log.info("Scan-to-unique mapping length: {d}", .{trailers.scan_to_unique.len});

    // Compare heuristic vs authoritative for first 20 scans
    std.log.info("\n--- Comparison (heuristic vs authoritative) ---", .{});
    var mismatch_count: usize = 0;
    for (0..@min(20, num_scans)) |idx| {
        const entry = try raw.parseScanIndex(scan_table_buf, idx * scan_index_size, file_revision);
        const heuristic_ms = if (entry.packet_type == raw.PACKET_TYPE_FT_PROFILE) @as(u8, 1) else @as(u8, 2);

        if (trailers.getEvent(idx)) |evt| {
            const auth_ms = @as(u8, @intCast(evt.info.ms_order));
            const match = if (auth_ms == heuristic_ms) "OK" else "MISMATCH";
            if (auth_ms != heuristic_ms) mismatch_count += 1;
            if (evt.reactions.len > 0) {
                std.log.info("Scan {d}: heuristic={d}, auth={d} [{s}] | precursor={e}, isolation={e}, CE={e}", .{
                    entry.scan_number, heuristic_ms, auth_ms, match,
                    evt.reactions[0].precursor_mass, evt.reactions[0].isolation_width, evt.reactions[0].collision_energy,
                });
            } else {
                std.log.info("Scan {d}: heuristic={d}, auth={d} [{s}] | no reactions", .{
                    entry.scan_number, heuristic_ms, auth_ms, match,
                });
            }
        } else {
            std.log.info("Scan {d}: heuristic={d}, auth=UNKNOWN", .{ entry.scan_number, heuristic_ms });
        }
    }

    // Full summary
    var ms1_count: usize = 0;
    var ms2_count: usize = 0;
    var ms3_count: usize = 0;
    var unknown_count: usize = 0;
    for (0..num_scans) |idx| {
        if (trailers.getEvent(idx)) |evt| {
            const ms = @as(u8, @intCast(evt.info.ms_order));
            switch (ms) {
                1 => ms1_count += 1,
                2 => ms2_count += 1,
                3 => ms3_count += 1,
                else => unknown_count += 1,
            }
        } else {
            unknown_count += 1;
        }
    }

    std.log.info("\n--- Summary ---", .{});
    std.log.info("MS1: {d}, MS2: {d}, MS3: {d}, Unknown: {d}", .{ ms1_count, ms2_count, ms3_count, unknown_count });
    std.log.info("Mismatches in first 20: {d}", .{mismatch_count});

    // DIA pattern analysis
    std.log.info("\n--- DIA window analysis ---", .{});
    var all_same_iw = true;
    var all_same_ce = true;
    var first_iw: f64 = 0;
    var first_ce: f64 = 0;
    var ms2_idx: usize = 0;
    for (0..num_scans) |idx| {
        if (trailers.getEvent(idx)) |evt| {
            if (evt.info.ms_order == 2 and evt.reactions.len > 0) {
                if (ms2_idx == 0) {
                    first_iw = evt.reactions[0].isolation_width;
                    first_ce = evt.reactions[0].collision_energy;
                } else {
                    if (@abs(evt.reactions[0].isolation_width - first_iw) > 0.1) all_same_iw = false;
                    if (@abs(evt.reactions[0].collision_energy - first_ce) > 0.1) all_same_ce = false;
                }
                ms2_idx += 1;
            }
        }
    }
    std.log.info("All MS2 same isolation width ({d:.2} Th): {s}", .{ first_iw, if (all_same_iw) "YES (DIA signature)" else "NO" });
    std.log.info("All MS2 same CE ({d:.1}): {s}", .{ first_ce, if (all_same_ce) "YES (DIA signature)" else "NO" });
}
