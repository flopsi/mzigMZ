const std = @import("std");

/// Lightweight, type-erased progress reporter. Long-running operations accept
/// an optional Reporter and call `report(current, total)` periodically.
pub const Reporter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        report: *const fn (ptr: *anyopaque, current: usize, total: usize) void,
    };

    pub fn report(self: Reporter, current: usize, total: usize) void {
        self.vtable.report(self.ptr, current, total);
    }
};
