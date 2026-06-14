/// Integration test: exercises the built `mzig` CLI binary.
///
/// Usage: test-cli <input.raw>
const std = @import("std");
const cli = @import("cli_args");

const MZIG_EXE = "zig-out/bin/mzig.exe";
const CONVERT_OUTPUT = "zig-out/test_cli_output.mzML";

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    const args = cli.get_args(allocator) catch {
        std.debug.print("usage: test-cli <raw-file>\n", .{});
        return 1;
    };
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len < 2) {
        std.debug.print("usage: test-cli <raw-file>\n", .{});
        return 1;
    }

    const input_path = args[1];

    // Clean up any leftover output from a previous run.
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, CONVERT_OUTPUT) catch {};

    // 1. verify
    if (!try runCommand(allocator, io, &[_][]const u8{ MZIG_EXE, "verify", input_path }, null)) {
        std.debug.print("FAIL: mzig verify exited non-zero\n", .{});
        return 1;
    }

    // 2. dump scan --scan 1 (expect valid JSON)
    const dump_result = try runCommandWithOutput(allocator, io, &[_][]const u8{ MZIG_EXE, "dump", "scan", input_path, "--scan", "1" });
    if (dump_result.term != .exited or dump_result.term.exited != 0) {
        std.debug.print("FAIL: mzig dump scan exited non-zero\n", .{});
        allocator.free(dump_result.stdout);
        allocator.free(dump_result.stderr);
        return 1;
    }
    if (!isValidJson(dump_result.stdout)) {
        std.debug.print("FAIL: mzig dump scan output is not valid JSON\n", .{});
        allocator.free(dump_result.stdout);
        allocator.free(dump_result.stderr);
        return 1;
    }
    allocator.free(dump_result.stdout);
    allocator.free(dump_result.stderr);

    // 3. convert
    if (!try runCommand(allocator, io, &[_][]const u8{ MZIG_EXE, "convert", input_path, CONVERT_OUTPUT }, null)) {
        std.debug.print("FAIL: mzig convert exited non-zero\n", .{});
        return 1;
    }

    // Clean up the generated mzML file on success.
    cwd.deleteFile(io, CONVERT_OUTPUT) catch {};

    std.debug.print("All CLI integration tests passed.\n", .{});
    return 0;
}

fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, expected_output: ?[]const u8) !bool {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        const command_line = try std.mem.join(allocator, " ", argv);
        defer allocator.free(command_line);
        std.debug.print("  command failed: {s}\n", .{command_line});
        if (result.stderr.len > 0) {
            std.debug.print("  stderr: {s}\n", .{result.stderr});
        }
        if (result.stdout.len > 0) {
            std.debug.print("  stdout: {s}\n", .{result.stdout});
        }
        return false;
    }

    if (expected_output) |expected| {
        if (!std.mem.eql(u8, result.stdout, expected)) {
            std.debug.print("  unexpected output: expected '{s}', got '{s}'\n", .{ expected, result.stdout });
            return false;
        }
    }

    return true;
}

const CommandOutput = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runCommandWithOutput(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !CommandOutput {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn isValidJson(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    const starts_ok = trimmed[0] == '{' or trimmed[0] == '[';
    const ends_ok = trimmed[trimmed.len - 1] == '}' or trimmed[trimmed.len - 1] == ']';
    return starts_ok and ends_ok;
}
