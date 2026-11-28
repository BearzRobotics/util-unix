// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: chmod mode strings (lib/mode.zig) and chmod itself (lib/chmod.zig), the
//! latter with arbitrary mode text applied to a tree in std.testing.tmpDir. Invariants:
//! no crash, no leak, no hang, a mode is at most 07777, and a mode text that
//! `validMode` accepts never makes `run` fail an assertion.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const mode = uu.mode;
const chmod = uu.chmod;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

fn modeText(_: void, smith: *std.testing.Smith, _: std.mem.Allocator) anyerror!void {
    var buf: [64]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    const old = smith.value(u16) & 0o7777;
    const umask = smith.value(u16) & 0o777;
    var ms: [9]u8 = undefined;
    for ([2]bool{ false, true }) |is_dir| {
        if (mode.apply(text, old, is_dir, umask)) |m| {
            try std.testing.expect(m <= 0o7777);
            try std.testing.expectEqual(@as(usize, 9), mode.modeString(&ms, m).len);
        }
        // Valid text never depends on the file for validity (only X changes the value).
        try std.testing.expectEqual(mode.apply(text, old, is_dir, umask) != null, mode.apply(text, 0, !is_dir, 0) != null);
    }
    try std.testing.expectEqual(chmod.validMode(text), mode.apply(text, 0o644, false, 0) != null);
    _ = mode.modeString(&ms, smith.value(u16));
}

const Count = struct {
    events: usize = 0,
    fn on(ctx: ?*anyopaque, ev: chmod.Event) void {
        const c: *Count = @ptrCast(@alignCast(ctx.?));
        c.events += 1;
        switch (ev) {
            .changed => |ch| std.debug.assert(ch.old <= 0o7777 and ch.new <= 0o7777),
            else => {},
        }
    }
};

fn makeTree(dir: Io.Dir) !void {
    const io = std.testing.io;
    try dir.createDirPath(io, "d/sub");
    try dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    try dir.writeFile(io, .{ .sub_path = "d/a", .data = "x" });
    try dir.writeFile(io, .{ .sub_path = "d/sub/b", .data = "x" });
    dir.symLink(io, "f", "link", .{}) catch {};
    dir.symLink(io, "../f", "d/inner", .{}) catch {};
    dir.symLink(io, "..", "d/sub/up", .{}) catch {};
    dir.symLink(io, "nowhere", "dangling", .{}) catch {};
}

/// Put the permissions back so the next iteration (and the cleanup) can walk the tree.
fn restore(dir: Io.Dir) void {
    const io = std.testing.io;
    const dirs = [_][]const u8{ "d", "d/sub" };
    const files = [_][]const u8{ "f", "d/a", "d/sub/b" };
    for (dirs) |p| dir.setFilePermissions(io, p, .fromMode(0o755), .{}) catch {};
    for (files) |p| dir.setFilePermissions(io, p, .fromMode(0o644), .{}) catch {};
}

fn chmodRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir);
    defer restore(tmp.dir);

    var buf: [48]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    const bits = smith.value(u16);
    const operands = [_][]const u8{ "f", "d", "link", "dangling", "d/sub", "nope", "d/", "d/sub/up" };
    const operand = operands[bits & 7];

    var count: Count = .{};
    var opts: chmod.Options = .{
        .change = if (bits & 0x8000 != 0) .{ .fixed = bits & 0o7777 } else .{ .mode_text = text },
        .umask = (bits >> 3) & 0o22,
        .recurse = bits & 0x100 != 0,
        .traversal = switch ((bits >> 9) % 3) {
            0 => .physical,
            1 => .command_line,
            else => .logical,
        },
        .no_dereference = bits & 0x800 != 0,
        .verbosity = switch ((bits >> 12) % 3) {
            0 => .off,
            1 => .changes,
            else => .verbose,
        },
        .quiet = bits & 0x4000 != 0,
        .reporter = .{ .context = &count, .on_event = Count.on },
        .base = tmp.dir,
    };
    // The command only calls `run` for valid text; do the same.
    if (opts.change == .mode_text and !chmod.validMode(text)) return;
    // A walk below "d" must not be able to change what is above the tree.
    _ = try chmod.run(std.testing.io, gpa, operand, opts);
    // Also walk the whole tree, following every link (it holds a link back up: a cycle).
    opts.recurse = true;
    opts.traversal = .logical;
    opts.no_dereference = false;
    restore(tmp.dir);
    _ = try chmod.run(std.testing.io, gpa, "d", opts);
}

test "fuzz: mode strings" {
    try engine.fuzz({}, seed_mod.capped(void, modeText), .{ .name = "mode-modeText", .corpus = &.{
        seed(.{"755"}),
        seed(.{"u=rwx,go=rx"}),
        seed(.{"a+X,go-w"}),
        seed(.{"u+s,g+s,o+t"}),
        seed(.{"g=u,o=g,u=o"}),
        seed(.{"+-=,,"}),
        seed(.{"7777"}),
        seed(.{"10000"}),
        seed(.{"789"}),
        seed(.{""}),
        seed(.{"u+q"}),
        seed(.{"=rwxXst,=,+"}),
    } });
}

test "fuzz: chmod on a tree with arbitrary mode text" {
    try engine.fuzz({}, seed_mod.capped(void, chmodRun), .{ .name = "mode-chmodRun", .corpus = &.{
        seed(.{"600"}),
        seed(.{"go-rwx"}),
        seed(.{"u-x"}),
        seed(.{"0"}),
        seed(.{"a=rX"}),
        seed(.{"u+s"}),
        seed(.{"o+t,g=u"}),
        seed(.{""}),
    } });
}
