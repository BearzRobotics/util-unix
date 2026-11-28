// SPDX-License-Identifier: GPL-2.0-or-later
//! Corpus helper. `Smith.slice` reads a 4-byte little-endian length and then that many
//! bytes, so a corpus entry that should decode as the text "root:x:0:0" has to carry
//! that prefix. `seed(.{ "text", "key" })` builds an entry whose first slices are the
//! given strings; fields the test reads after them default to zero.

const std = @import("std");

fn build(comptime parts: anytype) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const u8 = "";
        for (parts) |p| {
            const s: []const u8 = p;
            const len: u32 = s.len;
            out = out ++ std.mem.toBytes(std.mem.nativeToLittle(u32, len)) ++ s;
        }
        return out;
    }
}

pub fn seed(comptime parts: anytype) []const u8 {
    const S = struct {
        const bytes = build(parts);
    };
    return S.bytes;
}

/// Turn `inner(ctx, smith, gpa)` into a target: `gpa` is a `limits.Capped` allocator
/// (decision 0010) and `error.OutOfMemory` is a valid outcome, not a failure.
pub fn capped(comptime Ctx: type, comptime inner: fn (Ctx, *std.testing.Smith, std.mem.Allocator) anyerror!void) fn (Ctx, *std.testing.Smith) anyerror!void {
    return struct {
        fn run(ctx: Ctx, smith: *std.testing.Smith) anyerror!void {
            var cap: @import("limits.zig").Capped = .{};
            inner(ctx, smith, cap.allocator()) catch |e| switch (e) {
                error.OutOfMemory => return,
                else => return e,
            };
        }
    }.run;
}
