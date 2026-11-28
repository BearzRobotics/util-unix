// SPDX-License-Identifier: GPL-2.0-or-later
//! Helpers the builtin families share. Part of builtins.zig.

const std = @import("std");
const num = @import("../../num.zig");
const jobs = @import("../jobs.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");

/// A special-builtin error: the non-interactive shell exits.
pub fn optText(a: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch "";
}

pub fn die(sh: *Shell, st: u8) u8 {
    if (sh.no_die > 0 or sh.flags.interactive) return st;
    sh.status = st;
    sh.flow = .exit_shell;
    return st;
}

/// `exit` itself: always leaves the shell.
pub fn leave(sh: *Shell, st: u8) u8 {
    if (sh.flags.interactive and sh.jc and jobs.anyStopped(sh) and (sh.exit_warned == 0 or sh.exit_warned + 1 != sh.cmd_seq)) {
        sh.exit_warned = sh.cmd_seq;
        sh.diagBareK(.stopped_jobs, "", "You have stopped jobs.");
        sh.status = 1;
        return 1;
    }
    sh.explicit_exit = true;
    sh.status = st;
    sh.flow = .exit_shell;
    return st;
}

pub fn parseNum(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    return num.parseInt(i64, s, 10) catch null;
}

pub fn quoteSingle(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(a, "'\"'\"'") else try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.items;
}

pub fn sortedKeys(a: Allocator, map: anytype) Allocator.Error![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    var it = map.iterator();
    while (it.next()) |e| try keys.append(a, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lt);
    return keys.items;
}
