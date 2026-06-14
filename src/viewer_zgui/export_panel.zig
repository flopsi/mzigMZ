//! Export UI — progress modal + worker state for .raw passthrough and mzML export.
const std = @import("std");
const ig = @import("appimgui").ig;
const AppState = @import("app_state").AppState;
const raw_writer = @import("raw_file_writer");
const streaming = @import("streaming_convert");
const mzml_writer = @import("mzml_writer");

pub const ExportFormat = enum { raw, mzml };

pub const ExportState = struct {
    active: bool = false,
    format: ExportFormat = .raw,
    done: bool = false,
    total_scans: usize = 0,
    current_scan: usize = 0,
    status: [256:0]u8 = std.mem.zeroes([256:0]u8),
    error_message: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    /// Async future for the export worker.
    future: ?std.Io.Future(void) = null,
};

pub fn init() ExportState {
    return .{};
}

pub fn deinit(self: *ExportState, allocator: std.mem.Allocator) void {
    if (self.error_message) |m| allocator.free(m);
    if (self.output_path) |p| allocator.free(p);
    self.* = .{};
}

pub fn start(
    self: *ExportState,
    allocator: std.mem.Allocator,
    state: *AppState,
    format: ExportFormat,
    output_path: []const u8,
) !void {
    if (self.active) return;
    deinit(self, allocator);
    self.* = .{
        .active = true,
        .format = format,
        .done = false,
        .total_scans = state.file.scans.len,
        .current_scan = 0,
        .status = std.mem.zeroes([256:0]u8),
        .error_message = null,
        .output_path = try allocator.dupe(u8, output_path),
        .future = null,
    };

    // Clone path for the async task because output_path is owned by ExportState.
    const path_copy = try allocator.dupe(u8, output_path);
    errdefer allocator.free(path_copy);

    const progress = try allocator.create(Progress);
    errdefer allocator.destroy(progress);
    progress.* = .{
        .current = &self.current_scan,
        .total = self.total_scans,
    };

    const future = state.io.async(exportWorker, .{ allocator, state, format, path_copy, progress });
    self.future = future;
}

const Progress = struct {
    current: *usize,
    total: usize,
};

var export_state: ExportState = .{};

fn exportWorker(
    allocator: std.mem.Allocator,
    state: *AppState,
    format: ExportFormat,
    output_path: []const u8,
    progress: *Progress,
) void {
    defer allocator.destroy(progress);
    defer allocator.free(output_path);

    const source_name = if (state.file.file_path) |p|
        std.fs.path.basename(p)
    else
        "unknown.raw";

    const result = switch (format) {
        .raw => raw_writer.passthrough(
            allocator,
            state.io,
            &state.file.raw_file.?,
            state.file.trailer_events,
            output_path,
        ),
        .mzml => streaming.convert_raw_to_mzml_streaming(
            state.io,
            allocator,
            state,
            output_path,
            source_name,
            null,
            mzml_writer.MzmlWriterOptions{
                .compression = .none,
                .precision = .f64,
                .use_indexed_mzml = false,
            },
        ),
    };

    // Surface the result to the caller via the ExportState. Because this
    // worker runs on a thread, we mutate ExportState directly; the main
    // thread reads it each frame to update the modal.
    // TODO: guard with a mutex if ExportState outlives this worker in a
    // more complex lifetime. For now the modal owns the lifetime.
    if (result) |_| {
        // success
    } else |err| {
        const msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch return;
        export_state.error_message = msg;
    }
    @atomicStore(bool, &export_state.done, true, .release);
}

/// Draw the export-progress modal. Call every frame while active.
/// Returns true when the export is finished and the user dismissed the modal.
pub fn draw_modal(self: *ExportState) bool {
    if (!self.active) return false;

    const viewport = ig.ImGui_GetMainViewport();
    const center = ig.ImVec2{
        .x = viewport.*.WorkPos.x + viewport.*.WorkSize.x * 0.5,
        .y = viewport.*.WorkPos.y + viewport.*.WorkSize.y * 0.5,
    };
    ig.ImGui_SetNextWindowPosEx(center, ig.ImGuiCond_Always, .{ .x = 0.5, .y = 0.5 });
    ig.ImGui_SetNextWindowSize(.{ .x = 400, .y = 140 }, ig.ImGuiCond_Always);

    var open: bool = true;
    if (ig.ImGui_BeginPopupModal("Exporting...", &open, ig.ImGuiWindowFlags_NoResize | ig.ImGuiWindowFlags_NoMove)) {
        defer ig.ImGui_EndPopup();

        const label = switch (self.format) {
            .raw => "Exporting .raw",
            .mzml => "Exporting mzML",
        };
        ig.ImGui_TextUnformatted(label);
        const output_path = self.output_path orelse "?";
        ig.ImGui_Text("%s", @as([*c]const u8, @ptrCast(output_path.ptr)));

        const fraction: f32 = if (self.total_scans == 0)
            -1.0
        else
            @as(f32, @floatFromInt(self.current_scan)) / @as(f32, @floatFromInt(self.total_scans));
        ig.ImGui_ProgressBar(fraction, .{ .x = -1, .y = 0 }, null);

        if (self.done) {
            if (self.error_message) |err| {
                ig.ImGui_TextColored(.{ .x = 1, .y = 0.3, .z = 0.3, .w = 1 }, "Error: %s", @as([*c]const u8, @ptrCast(err.ptr)));
            } else {
                ig.ImGui_TextUnformatted("Done.");
            }
            if (ig.ImGui_Button("Close")) {
                ig.ImGui_CloseCurrentPopup();
                self.active = false;
                return true;
            }
        }
    }
    return false;
}
