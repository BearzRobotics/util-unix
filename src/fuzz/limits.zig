// SPDX-License-Identifier: GPL-2.0-or-later
//! Resource limits for fuzz targets (decision 0010).
//!
//! A fuzzer feeds arbitrary input to code that sizes buffers from it (a printf width,
//! a seq range, a field count). Without a cap, one such input can make the test process
//! balloon until the machine runs out of memory and the kernel kills it, taking every
//! process in the same terminal session with it. That happened twice on 2026-11-19/20
//! (a fuzz `test` binary of 20 GB). Every fuzz target therefore allocates from `Capped`:
//! it forwards to `std.testing.allocator` (so leaks still fail the test) but refuses an
//! allocation that would push the live total past `cap`. Targets must treat
//! `error.OutOfMemory` as a valid outcome, not a failure: refusing a huge allocation
//! cleanly is the correct behaviour; the bug is only if it crashes or hangs.

const std = @import("std");

/// Live-byte limit for one fuzz iteration.
pub const default_cap: usize = 64 << 20;

pub const Capped = struct {
    backing: std.mem.Allocator = std.testing.allocator,
    cap: usize = default_cap,
    live: usize = 0,

    pub fn allocator(c: *Capped) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (len > c.cap or c.live > c.cap - len) return null;
        const p = c.backing.rawAlloc(len, alignment, ra) orelse return null;
        c.live += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            const extra = new_len - memory.len;
            if (extra > c.cap or c.live > c.cap - extra) return false;
        }
        if (!c.backing.rawResize(memory, alignment, new_len, ra)) return false;
        c.live = c.live - memory.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            const extra = new_len - memory.len;
            if (extra > c.cap or c.live > c.cap - extra) return null;
        }
        const p = c.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        c.live = c.live - memory.len + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const c: *Capped = @ptrCast(@alignCast(ctx));
        c.backing.rawFree(memory, alignment, ra);
        c.live -= memory.len;
    }
};

test "Capped refuses what would exceed the cap and keeps the count straight" {
    var c: Capped = .{ .cap = 1024 };
    const a = c.allocator();
    const x = try a.alloc(u8, 600);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 600));
    const y = try a.alloc(u8, 400);
    try std.testing.expectEqual(@as(usize, 1000), c.live);
    a.free(x);
    a.free(y);
    try std.testing.expectEqual(@as(usize, 0), c.live);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, std.math.maxInt(usize) / 2));
}
