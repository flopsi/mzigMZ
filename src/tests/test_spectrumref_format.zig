/// Integration test for GOTCHAS.md G3:
///   `<precursor spectrumRef="...">` MUST match a sibling spectrum's
///   `id="..."` exactly, so that downstream tools (OpenMS, MSFileReader,
///   ThermoRawFileParser, pyteomics) can resolve the parent scan via
///   string match. mzML 1.1.0 spec requires this.
///
/// Usage: test-spectrumref-format <input.raw> [<output.mzml>]
///   - <input.raw>  : a real Thermo .raw file (use 12k-scan LC-MS/MS for speed)
///   - <output.mzml>: optional. Default: a temp file under D:/tmp/ that is
///                    deleted on success. Pass an explicit path to inspect.
///
/// Exit codes:
///   0 = pass (at least one MS2 spectrum found and every spectrumRef matches an id)
///   1 = fail (format mismatch, no MS2 spectra, or IO error)
///
/// This test complements the existing ground-truth workflow
/// (verify-ground-truth) by checking the *mzML format* itself, not just
/// the decoded m/z + intensity values.
const std = @import("std");
const app = @import("app_state");
const streaming = @import("streaming_convert");
const mzml_writer = @import("mzml_writer");
const cli = @import("cli_args");

const EXPECTED_ID_PREFIX = "controllerType=0 controllerNumber=1 scan=";

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    const args = try cli.get_args(allocator);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len < 2) {
        std.debug.print("Usage: test-spectrumref-format <input.raw> [<output.mzml>]\n", .{});
        return 1;
    }

    const input_path = args[1];

    // If the user didn't pass an output path, write to a fixed temp file in
    // the current working directory that we delete on success. We don't have a
    // portable getpid in 0.16 without reaching into std.os.linux; a fixed name
    // is fine for a single-developer test runner.
    const owned_temp: ?[]u8 = if (args.len < 3) blk: {
        const name = try allocator.dupeZ(u8, "test_spectrumref_format.mzML");
        break :blk name;
    } else null;
    const output_path = if (args.len >= 3) args[2] else owned_temp.?;
    defer if (owned_temp) |t| allocator.free(t);

    var state = app.AppState.init(allocator, io);
    defer state.deinit();

    std.debug.print("Opening {s}...\n", .{input_path});
    state.open_file(input_path) catch |err| {
        std.debug.print("FAIL: openFile returned {s}\n", .{@errorName(err)});
        return 1;
    };

    const source_name = std.fs.path.basename(input_path);
    const options = mzml_writer.MzmlWriterOptions{
        .compression = .none,
        .precision = .f64,
        .use_indexed_mzml = false,
    };

    std.debug.print("Streaming to {s}...\n", .{output_path});
    streaming.convert_raw_to_mzml_streaming(
        io,
        allocator,
        &state,
        output_path,
        source_name,
        null,
        options,
    ) catch |err| {
        std.debug.print("FAIL: convertRawToMzmlStreaming returned {s}\n", .{@errorName(err)});
        return 1;
    };

    std.debug.print("Verifying spectrumRef format...\n", .{});
    const result = try verifySpectrumRefFormat(allocator, io, output_path);

    // Clean up the temp file unless the user asked for a specific path.
    if (owned_temp != null) {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteFile(io, output_path) catch {};
    }

    return result;
}

/// Scan the mzML output and assert that for every `<precursor spectrumRef="X">`,
/// there exists a sibling `<spectrum ... id="X" ...>`. Returns 0 on pass, 1 on
/// fail. Reads the file in a single pass; a 12k-scan file is ~340 MB.
fn verifySpectrumRefFormat(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    const size = try file.length(io);
    const content = try allocator.alloc(u8, @as(usize, @intCast(size)));
    defer allocator.free(content);
    const bytes_read = try file.readPositionalAll(io, content, 0);
    if (bytes_read != size) {
        std.debug.print("FAIL: short read ({d} of {d} bytes)\n", .{ bytes_read, size });
        return 1;
    }

    // First pass: collect every spectrum id. mzML writes the id attribute as
    //   <spectrum index="N" id="controllerType=0 controllerNumber=1 scan=M" defaultArrayLength="K">
    // We just store the id value as a borrowed slice into `content`.
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);

    {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, content, cursor, "<spectrum ")) |spectrum_start| {
            const id_attr = std.mem.indexOfPos(u8, content, spectrum_start, "id=\"") orelse {
                cursor = spectrum_start + 1;
                continue;
            };
            const id_value_start = id_attr + 4; // skip past `id="`
            const id_value_end = std.mem.indexOfScalarPos(u8, content, id_value_start, '"') orelse {
                cursor = spectrum_start + 1;
                continue;
            };
            try ids.append(allocator, content[id_value_start..id_value_end]);
            cursor = id_value_end + 1;
        }
    }

    std.debug.print("  Found {d} spectrum ids\n", .{ids.items.len});
    if (ids.items.len == 0) {
        std.debug.print("FAIL: no spectrum ids found in mzML output\n", .{});
        return 1;
    }

    // Sanity-check the id format: every id should start with the canonical
    // ThermoRawFileParser prefix. Catches "I forgot to use formatScanId" type
    // regressions even before we get to the spectrumRef check.
    for (ids.items) |id| {
        if (!std.mem.startsWith(u8, id, EXPECTED_ID_PREFIX)) {
            std.debug.print(
                "FAIL: spectrum id \"{s}\" missing expected prefix \"{s}\"\n",
                .{ id, EXPECTED_ID_PREFIX },
            );
            return 1;
        }
    }

    // Sort ids for binary search. Use a Zig-0.16-compatible sort. Since the
    // ids are short prefix-differing strings, qsort from std.sort is fine.
    std.sort.heap([]const u8, ids.items, {}, lessThanSlice);

    // Second pass: every `<precursor spectrumRef="X">` must match a sibling id.
    // Track first 5 mismatches for diagnostics, then bail.
    var precursors_seen: usize = 0;
    var mismatches: usize = 0;
    {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, content, cursor, "spectrumRef=\"")) |attr_start| {
            const ref_value_start = attr_start + 13; // skip past `spectrumRef="`
            const ref_value_end = std.mem.indexOfScalarPos(u8, content, ref_value_start, '"') orelse {
                cursor = ref_value_start;
                continue;
            };
            const ref_value = content[ref_value_start..ref_value_end];
            precursors_seen += 1;

            if (!containsSlice(ids.items, ref_value)) {
                std.debug.print(
                    "FAIL: precursor spectrumRef=\"{s}\" matches no spectrum id.\n",
                    .{ref_value},
                );
                mismatches += 1;
                if (mismatches > 5) {
                    std.debug.print("  (more mismatches suppressed)\n", .{});
                    return 1;
                }
            }

            cursor = ref_value_end + 1;
        }
    }

    std.debug.print("  Checked {d} precursor references\n", .{precursors_seen});

    if (precursors_seen == 0) {
        std.debug.print(
            "FAIL: no precursor references found. Test file must contain MS2 spectra.\n",
            .{},
        );
        return 1;
    }

    if (mismatches > 0) {
        std.debug.print("FAIL: {d} precursor refs did not match any spectrum id.\n", .{mismatches});
        return 1;
    }

    std.debug.print("PASS: all {d} precursor refs match a spectrum id.\n", .{precursors_seen});
    return 0;
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn containsSlice(ids: []const []const u8, target: []const u8) bool {
    return std.sort.binarySearch([]const u8, ids, target, compareTarget) != null;
}

fn compareTarget(target: []const u8, id: []const u8) std.math.Order {
    return std.mem.order(u8, target, id);
}
