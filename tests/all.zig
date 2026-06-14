// Central test harness — collects inline tests from critical decode modules.
// `zig build test` runs every `test "..."` block from every imported module.
//
// Per zig-quality testing-patterns: tests live inline next to the code
// they test. This harness collects a core subset under one build step.
// Additional modules with inline tests are wired via `b.addTest` entries
// in `build.zig`.
//
// Integration tests (real .raw file needed) are separate: `zig build test-integration -- file.raw`

// In Zig 0.16, tests from imported modules are discovered when the module
// is referenced by a top-level declaration in the root file.
pub const _advanced_packet = @import("advanced_packet");
pub const _profile_packet = @import("profile_packet");
pub const _plot_math = @import("plot_math");
pub const _schema = @import("schema");

// peak_labels and scan_navigation are test-only modules (zero production
// callers). They are tested via their own b.addTest entries in build.zig.

test "harness alive" {
    try @import("std").testing.expect(true);
}
