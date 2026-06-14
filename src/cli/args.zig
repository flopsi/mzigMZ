const std = @import("std");

pub const Format = enum {
    json,
    csv,
};

pub const ConvertArgs = struct {
    input_path: []const u8,
    output_path: []const u8,
};

pub const ConvertBatchArgs = struct {
    input_dir: []const u8,
    output_dir: []const u8,
    pattern: []const u8 = "*.raw",
    skip_existing: bool = false,
    fail_fast: bool = false,
};

pub const DumpScanArgs = struct {
    input_path: []const u8,
    scan: usize,
    format: Format = .json,
};

pub const DumpScansArgs = struct {
    input_path: []const u8,
    range_start: ?usize = null,
    range_end: ?usize = null,
    format: Format = .json,
};

pub const DumpChromatogramArgs = struct {
    input_path: []const u8,
    chrom_type: []const u8,
    mz: ?f64 = null,
    tol_ppm: ?f64 = null,
    format: Format = .json,
};

pub const DumpMetadataArgs = struct {
    input_path: []const u8,
    format: Format = .json,
};

pub const DumpCalibrationArgs = struct {
    input_path: []const u8,
    scan: ?usize = null,
    format: Format = .json,
};

pub const DumpInstrumentArgs = struct {
    input_path: []const u8,
    format: Format = .json,
};

pub const DumpPacketArgs = struct {
    input_path: []const u8,
    scan: usize,
    format: Format = .json,
};

pub const VerifyArgs = struct {
    input_path: []const u8,
};

pub const CommandKind = enum {
    convert,
    convert_batch,
    dump_scan,
    dump_scans,
    dump_chromatogram,
    dump_metadata,
    dump_calibration,
    dump_instrument,
    dump_packet,
    verify,
    help,
};

pub const Command = union(CommandKind) {
    convert: ConvertArgs,
    convert_batch: ConvertBatchArgs,
    dump_scan: DumpScanArgs,
    dump_scans: DumpScansArgs,
    dump_chromatogram: DumpChromatogramArgs,
    dump_metadata: DumpMetadataArgs,
    dump_calibration: DumpCalibrationArgs,
    dump_instrument: DumpInstrumentArgs,
    dump_packet: DumpPacketArgs,
    verify: VerifyArgs,
    help,
};

pub const ParseError = error{
    MissingArgument,
    InvalidValue,
    InvalidFloat,
    InvalidRange,
    UnknownCommand,
    UnknownFlag,
    InvalidFormat,
    MissingMzForXic,
};

fn parseFormat(value: []const u8) ParseError!Format {
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "csv")) return .csv;
    return ParseError.InvalidFormat;
}

fn parseUsize(value: []const u8) ParseError!usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch return ParseError.InvalidValue;
}

fn parseF64(value: []const u8) ParseError!f64 {
    return std.fmt.parseFloat(f64, value) catch return ParseError.InvalidFloat;
}

fn parseRange(value: []const u8) ParseError!struct { start: ?usize, end: ?usize } {
    const colon = std.mem.indexOfScalar(u8, value, ':');
    if (colon == null) return ParseError.InvalidRange;

    const start_s = value[0..colon.?];
    const end_s = value[colon.? + 1 ..];

    const start: ?usize = if (start_s.len == 0) null else try parseUsize(start_s);
    const end: ?usize = if (end_s.len == 0) null else try parseUsize(end_s);

    if (start != null and end != null and start.? > end.?) {
        return ParseError.InvalidRange;
    }
    if (start == null and end == null) {
        return ParseError.InvalidRange;
    }

    return .{ .start = start, .end = end };
}

/// Returns the next argument after `i` and advances `i`.
fn take_next(argv: []const []const u8, i: *usize) ParseError![]const u8 {
    if (i.* + 1 >= argv.len) return ParseError.MissingArgument;
    i.* += 1;
    return argv[i.*];
}

/// Parses a `--format <value>` flag by consuming the next argument.
fn parseFormatFlag(argv: []const []const u8, i: *usize) ParseError!Format {
    const value = try take_next(argv, i);
    return parseFormat(value);
}

/// Parses the CLI arguments in `argv`. The `allocator` parameter is reserved for
/// future use (e.g., allocating copies of argument strings) and is currently unused.
pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Command {
    _ = allocator;

    if (argv.len <= 1 or
        std.mem.eql(u8, argv[1], "help") or
        std.mem.eql(u8, argv[1], "--help") or
        std.mem.eql(u8, argv[1], "-h"))
    {
        return .help;
    }

    const command = argv[1];

    if (std.mem.eql(u8, command, "convert")) {
        if (argv.len < 4) return ParseError.MissingArgument;
        return .{
            .convert = .{
                .input_path = argv[2],
                .output_path = argv[3],
            },
        };
    }

    if (std.mem.eql(u8, command, "convert-batch")) {
        if (argv.len < 4) return ParseError.MissingArgument;
        var args = ConvertBatchArgs{
            .input_dir = argv[2],
            .output_dir = argv[3],
        };

        var i: usize = 4;
        while (i < argv.len) : (i += 1) {
            const flag = argv[i];
            if (std.mem.eql(u8, flag, "--pattern")) {
                args.pattern = try take_next(argv, &i);
            } else if (std.mem.eql(u8, flag, "--skip-existing")) {
                args.skip_existing = true;
            } else if (std.mem.eql(u8, flag, "--fail-fast")) {
                args.fail_fast = true;
            } else {
                return ParseError.UnknownFlag;
            }
        }
        return .{ .convert_batch = args };
    }

    if (std.mem.eql(u8, command, "dump")) {
        if (argv.len < 4) return ParseError.MissingArgument;
        const sub = argv[2];
        const input_path = argv[3];

        if (std.mem.eql(u8, sub, "scan")) {
            var args = DumpScanArgs{
                .input_path = input_path,
                .scan = 0,
            };
            var has_scan = false;
            var i: usize = 4;
            while (i < argv.len) : (i += 1) {
                const flag = argv[i];
                if (std.mem.eql(u8, flag, "--scan")) {
                    args.scan = try parseUsize(try take_next(argv, &i));
                    has_scan = true;
                } else if (std.mem.eql(u8, flag, "--format")) {
                    args.format = try parseFormatFlag(argv, &i);
                } else {
                    return ParseError.UnknownFlag;
                }
            }
            if (!has_scan) return ParseError.MissingArgument;
            return .{ .dump_scan = args };
        }

        if (std.mem.eql(u8, sub, "scans")) {
            var args = DumpScansArgs{
                .input_path = input_path,
            };
            var i: usize = 4;
            while (i < argv.len) : (i += 1) {
                const flag = argv[i];
                if (std.mem.eql(u8, flag, "--range")) {
                    const range = try parseRange(try take_next(argv, &i));
                    args.range_start = range.start;
                    args.range_end = range.end;
                } else if (std.mem.eql(u8, flag, "--format")) {
                    args.format = try parseFormatFlag(argv, &i);
                } else {
                    return ParseError.UnknownFlag;
                }
            }
            return .{ .dump_scans = args };
        }

        if (std.mem.eql(u8, sub, "chromatogram")) {
            var args = DumpChromatogramArgs{
                .input_path = input_path,
                .chrom_type = "",
            };
            var has_type = false;
            var i: usize = 4;
            while (i < argv.len) : (i += 1) {
                const flag = argv[i];
                if (std.mem.eql(u8, flag, "--type")) {
                    args.chrom_type = try take_next(argv, &i);
                    has_type = true;
                } else if (std.mem.eql(u8, flag, "--mz")) {
                    args.mz = try parseF64(try take_next(argv, &i));
                } else if (std.mem.eql(u8, flag, "--tol")) {
                    args.tol_ppm = try parseF64(try take_next(argv, &i));
                } else if (std.mem.eql(u8, flag, "--format")) {
                    args.format = try parseFormatFlag(argv, &i);
                } else {
                    return ParseError.UnknownFlag;
                }
            }
            if (!has_type) return ParseError.MissingArgument;
            if (std.mem.eql(u8, args.chrom_type, "xic")) {
                if (args.mz == null or args.tol_ppm == null) return ParseError.MissingMzForXic;
            }
            return .{ .dump_chromatogram = args };
        }

        if (std.mem.eql(u8, sub, "metadata")) {
            var args = DumpMetadataArgs{
                .input_path = input_path,
            };
            var i: usize = 4;
            while (i < argv.len) : (i += 1) {
                const flag = argv[i];
                if (std.mem.eql(u8, flag, "--format")) {
                    args.format = try parseFormatFlag(argv, &i);
                } else {
                    return ParseError.UnknownFlag;
                }
            }
            return .{ .dump_metadata = args };
        }

        if (std.mem.eql(u8, sub, "calibration")) {
            var args = DumpCalibrationArgs{
                .input_path = input_path,
            };
            var i: usize = 4;
            while (i < argv.len) : (i += 1) {
                const flag = argv[i];
                if (std.mem.eql(u8, flag, "--scan")) {
                    args.scan = try parseUsize(try take_next(argv, &i));
                } else if (std.mem.eql(u8, flag, "--format")) {
                    args.format = try parseFormatFlag(argv, &i);
                } else {
                    return ParseError.UnknownFlag;
                }
            }
            return .{ .dump_calibration = args };
        }

        if (std.mem.eql(u8, sub, "instrument")) {
            var args = DumpInstrumentArgs{
                .input_path = input_path,
            };
            var i: usize = 4;
            while (i < argv.len) : (i += 1) {
                const flag = argv[i];
                if (std.mem.eql(u8, flag, "--format")) {
                    args.format = try parseFormatFlag(argv, &i);
                } else {
                    return ParseError.UnknownFlag;
                }
            }
            return .{ .dump_instrument = args };
        }

        if (std.mem.eql(u8, sub, "packet")) {
            var args = DumpPacketArgs{
                .input_path = input_path,
                .scan = 0,
            };
            var has_scan = false;
            var i: usize = 4;
            while (i < argv.len) : (i += 1) {
                const flag = argv[i];
                if (std.mem.eql(u8, flag, "--scan")) {
                    args.scan = try parseUsize(try take_next(argv, &i));
                    has_scan = true;
                } else if (std.mem.eql(u8, flag, "--format")) {
                    args.format = try parseFormatFlag(argv, &i);
                } else {
                    return ParseError.UnknownFlag;
                }
            }
            if (!has_scan) return ParseError.MissingArgument;
            return .{ .dump_packet = args };
        }

        return ParseError.UnknownCommand;
    }

    if (std.mem.eql(u8, command, "verify")) {
        if (argv.len < 3) return ParseError.MissingArgument;
        return .{
            .verify = .{
                .input_path = argv[2],
            },
        };
    }

    return ParseError.UnknownCommand;
}

test "parse convert command" {
    const argv = &[_][]const u8{ "mzig", "convert", "in.raw", "out.mzML" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.convert, std.meta.activeTag(cmd));
    try std.testing.expectEqualStrings("in.raw", cmd.convert.input_path);
    try std.testing.expectEqualStrings("out.mzML", cmd.convert.output_path);
}

test "parse convert missing positional args" {
    const argv = &[_][]const u8{ "mzig", "convert", "in.raw" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parse convert-batch with flags" {
    const argv = &[_][]const u8{
        "mzig",
        "convert-batch",
        "/data/raw",
        "/data/mzml",
        "--pattern",
        "*.raw",
        "--skip-existing",
        "--fail-fast",
    };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.convert_batch, std.meta.activeTag(cmd));
    try std.testing.expectEqualStrings("/data/raw", cmd.convert_batch.input_dir);
    try std.testing.expectEqualStrings("/data/mzml", cmd.convert_batch.output_dir);
    try std.testing.expectEqualStrings("*.raw", cmd.convert_batch.pattern);
    try std.testing.expect(cmd.convert_batch.skip_existing);
    try std.testing.expect(cmd.convert_batch.fail_fast);
}

test "parse convert-batch unknown flag" {
    const argv = &[_][]const u8{ "mzig", "convert-batch", "in", "out", "--unknown" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.UnknownFlag, result);
}

test "parse dump scan with format" {
    const argv = &[_][]const u8{ "mzig", "dump", "scan", "test.raw", "--scan", "42", "--format", "csv" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.dump_scan, std.meta.activeTag(cmd));
    try std.testing.expectEqualStrings("test.raw", cmd.dump_scan.input_path);
    try std.testing.expectEqual(@as(usize, 42), cmd.dump_scan.scan);
    try std.testing.expectEqual(Format.csv, cmd.dump_scan.format);
}

test "parse dump scan missing scan" {
    const argv = &[_][]const u8{ "mzig", "dump", "scan", "test.raw" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parse dump scan invalid scan number" {
    const argv = &[_][]const u8{ "mzig", "dump", "scan", "test.raw", "--scan", "abc" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.InvalidValue, result);
}

test "parse dump scans range parsing" {
    const argv = &[_][]const u8{ "mzig", "dump", "scans", "test.raw", "--range", "5:10", "--format", "csv" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.dump_scans, std.meta.activeTag(cmd));
    try std.testing.expectEqual(@as(?usize, 5), cmd.dump_scans.range_start);
    try std.testing.expectEqual(@as(?usize, 10), cmd.dump_scans.range_end);
    try std.testing.expectEqual(Format.csv, cmd.dump_scans.format);
}

test "parse dump scans open range" {
    const argv = &[_][]const u8{ "mzig", "dump", "scans", "test.raw", "--range", "10:" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.dump_scans, std.meta.activeTag(cmd));
    try std.testing.expectEqual(@as(?usize, 10), cmd.dump_scans.range_start);
    try std.testing.expectEqual(@as(?usize, null), cmd.dump_scans.range_end);
}

test "parse dump scans invalid range" {
    const argv = &[_][]const u8{ "mzig", "dump", "scans", "test.raw", "--range", "10:5" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.InvalidRange, result);
}

test "parse dump scans malformed range" {
    const argv = &[_][]const u8{ "mzig", "dump", "scans", "test.raw", "--range", "no-colon" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.InvalidRange, result);
}

test "parse dump chromatogram xic requires mz and tol" {
    const argv = &[_][]const u8{ "mzig", "dump", "chromatogram", "test.raw", "--type", "xic" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.MissingMzForXic, result);
}

test "parse dump chromatogram xic only mz" {
    const argv = &[_][]const u8{ "mzig", "dump", "chromatogram", "test.raw", "--type", "xic", "--mz", "500.0" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.MissingMzForXic, result);
}

test "parse dump chromatogram xic only tol" {
    const argv = &[_][]const u8{ "mzig", "dump", "chromatogram", "test.raw", "--type", "xic", "--tol", "10.0" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.MissingMzForXic, result);
}

test "parse dump chromatogram invalid float" {
    const argv = &[_][]const u8{ "mzig", "dump", "chromatogram", "test.raw", "--type", "xic", "--mz", "bad", "--tol", "10.0" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.InvalidFloat, result);
}

test "parse dump chromatogram invalid format" {
    const argv = &[_][]const u8{ "mzig", "dump", "chromatogram", "test.raw", "--type", "tic", "--format", "xml" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.InvalidFormat, result);
}

test "parse dump metadata happy path" {
    const argv = &[_][]const u8{ "mzig", "dump", "metadata", "test.raw", "--format", "csv" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.dump_metadata, std.meta.activeTag(cmd));
    try std.testing.expectEqualStrings("test.raw", cmd.dump_metadata.input_path);
    try std.testing.expectEqual(Format.csv, cmd.dump_metadata.format);
}

test "parse dump calibration happy path" {
    const argv = &[_][]const u8{ "mzig", "dump", "calibration", "test.raw", "--scan", "7", "--format", "csv" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.dump_calibration, std.meta.activeTag(cmd));
    try std.testing.expectEqualStrings("test.raw", cmd.dump_calibration.input_path);
    try std.testing.expectEqual(@as(?usize, 7), cmd.dump_calibration.scan);
    try std.testing.expectEqual(Format.csv, cmd.dump_calibration.format);
}

test "parse dump instrument happy path" {
    const argv = &[_][]const u8{ "mzig", "dump", "instrument", "test.raw" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.dump_instrument, std.meta.activeTag(cmd));
    try std.testing.expectEqualStrings("test.raw", cmd.dump_instrument.input_path);
    try std.testing.expectEqual(Format.json, cmd.dump_instrument.format);
}

test "parse dump packet happy path" {
    const argv = &[_][]const u8{ "mzig", "dump", "packet", "test.raw", "--scan", "99", "--format", "csv" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.dump_packet, std.meta.activeTag(cmd));
    try std.testing.expectEqualStrings("test.raw", cmd.dump_packet.input_path);
    try std.testing.expectEqual(@as(usize, 99), cmd.dump_packet.scan);
    try std.testing.expectEqual(Format.csv, cmd.dump_packet.format);
}

test "parse verify happy path" {
    const argv = &[_][]const u8{ "mzig", "verify", "test.raw" };
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.verify, std.meta.activeTag(cmd));
    try std.testing.expectEqualStrings("test.raw", cmd.verify.input_path);
}

test "parse help variants" {
    const argv_help = &[_][]const u8{ "mzig", "help" };
    const cmd_help = try parse(std.testing.allocator, argv_help);
    try std.testing.expectEqual(CommandKind.help, std.meta.activeTag(cmd_help));

    const argv_dash = &[_][]const u8{ "mzig", "--help" };
    const cmd_dash = try parse(std.testing.allocator, argv_dash);
    try std.testing.expectEqual(CommandKind.help, std.meta.activeTag(cmd_dash));
}

test "parse no arguments returns help" {
    const argv = &[_][]const u8{"mzig"};
    const cmd = try parse(std.testing.allocator, argv);
    try std.testing.expectEqual(CommandKind.help, std.meta.activeTag(cmd));
}

test "parse unknown command" {
    const argv = &[_][]const u8{ "mzig", "frobnicate", "test.raw" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.UnknownCommand, result);
}

test "parse dump unknown subcommand" {
    const argv = &[_][]const u8{ "mzig", "dump", "unknown", "test.raw" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.UnknownCommand, result);
}

test "parse unknown flag in dump scan" {
    const argv = &[_][]const u8{ "mzig", "dump", "scan", "test.raw", "--scan", "1", "--unknown" };
    const result = parse(std.testing.allocator, argv);
    try std.testing.expectError(ParseError.UnknownFlag, result);
}
