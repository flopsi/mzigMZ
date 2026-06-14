/// Raw Orbitrap Viewer — Win32 GUI application.
///
/// Usage:
///   raw-orbitrap-viewer.exe                     (opens GUI with no file)
///   raw-orbitrap-viewer.exe <raw-file>           (opens GUI with file loaded)
const std = @import("std");
const main_window = @import("main_window");
const app = @import("app_state");
const cli_args = @import("cli_args");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var state = app.AppState.init(gpa, io);
    defer state.deinit();

    // Parse CLI args using the project convention (cli_args module).
    const args = cli_args.get_args(gpa) catch {
        // If arg parsing fails, just open the viewer with no file.
        main_window.run(&state) catch |err| {
            std.log.err("viewer exited with error: {}", .{err});
            return 1;
        };
        return 0;
    };
    defer {
        for (args) |a| gpa.free(a);
        gpa.free(args);
    }
    if (args.len > 1) {
        const raw_path = args[1];
        state.open_file(raw_path) catch |err| {
            std.log.err("failed to open '{s}': {}", .{ raw_path, err });
        };
    }

    main_window.run(&state) catch |err| {
        std.log.err("viewer exited with error: {}", .{err});
        return 1;
    };

    return 0;
}
