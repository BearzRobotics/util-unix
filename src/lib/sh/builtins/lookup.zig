// SPDX-License-Identifier: GPL-2.0-or-later
//! How names are looked up: command, type, hash, alias and unalias. Part of builtins.zig.

const std = @import("std");
const osio = @import("../osio.zig");
const lexer = @import("../lexer.zig");
const exec = @import("../exec.zig");
const shell = @import("../shell.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const find = @import("../builtins.zig").find;
const optText = @import("common.zig").optText;
const quoteSingle = @import("common.zig").quoteSingle;
const sortedKeys = @import("common.zig").sortedKeys;

fn describe(sh: *Shell, a: Allocator, name: []const u8, verbose: bool, out: *std.ArrayList(u8)) Allocator.Error!bool {
    if (lexer.reservedOf(&.{.{ .text = name }}) != null) {
        if (verbose) try out.print(a, "{s} is a shell keyword\n", .{name}) else try out.print(a, "{s}\n", .{name});
        return true;
    }
    if (sh.aliases.get(name)) |v| {
        if (verbose) try out.print(a, "{s} is an alias for {s}\n", .{ name, v }) else try out.print(a, "alias {s}={s}\n", .{ name, try quoteSingle(a, v) });
        return true;
    }
    if (sh.funcs.get(name) != null) {
        if (verbose) try out.print(a, "{s} is a shell function\n", .{name}) else try out.print(a, "{s}\n", .{name});
        return true;
    }
    if (find(name)) |b| {
        if (verbose) try out.print(a, "{s} is a {s}shell builtin\n", .{ name, if (b.special) "special " else "" }) else try out.print(a, "{s}\n", .{name});
        return true;
    }
    if (sh.host_builtins.get(name) != null) {
        if (verbose) try out.print(a, "{s} is a shell builtin\n", .{name}) else try out.print(a, "{s}\n", .{name});
        return true;
    }
    const path = if (std.mem.indexOfScalar(u8, name, '/') != null) (if (osio.access(sh.env.io, name, .{ .execute = true })) name else null) else exec.findExecutable(sh, a, name);
    if (path) |p| {
        if (verbose) try out.print(a, "{s} is {s}\n", .{ name, p }) else try out.print(a, "{s}\n", .{p});
        return true;
    }
    return false;
}

pub fn typeCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var st: u8 = 0;
    var out: std.ArrayList(u8) = .empty;
    for (args[1..]) |n| {
        if (!(describe(sh, a, n, true, &out) catch |oe| return sh.oom(oe))) {
            out.print(a, "{s}: not found\n", .{n}) catch |oe| return sh.oom(oe);
            st = 127;
        }
    }
    _ = sh.out(out.items);
    return st;
}

pub fn commandCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var mode: u8 = 0; // 'v', 'V'
    var use_default_path = false;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |c| switch (c) {
            'v', 'V' => mode = c,
            'p' => use_default_path = true,
            else => {
                sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "command", "Illegal option -{c}", .{c});
                return 2;
            },
        };
    }
    if (i >= args.len) return 0;
    const lookup: ?[]const u8 = if (use_default_path) "/usr/bin:/bin" else null;
    if (mode != 0) {
        var out: std.ArrayList(u8) = .empty;
        sh.lookup_path = lookup;
        defer sh.lookup_path = null;
        const ok = describe(sh, a, args[i], mode == 'V', &out) catch |oe| return sh.oom(oe);
        if (!ok and mode == 'V') {
            out.print(a, "{s}: not found\n", .{args[i]}) catch |oe| return sh.oom(oe);
        }
        _ = sh.out(out.items);
        return if (ok) 0 else 127;
    }
    sh.no_die += 1;
    defer sh.no_die -= 1;
    return exec.runArgs(sh, a, args[i..], true, lookup);
}

pub fn hashCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |c| if (c != 'r') {
            sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "hash", "Illegal option -{c}", .{c});
            return 2;
        };
        sh.clearHash();
    }
    if (i >= args.len and args.len == 1) {
        const keys = sortedKeys(a, sh.hash) catch |oe| return sh.oom(oe);
        var out: std.ArrayList(u8) = .empty;
        for (keys) |k| out.print(a, "{s}\n", .{sh.hash.get(k).?}) catch |oe| return sh.oom(oe);
        _ = sh.out(out.items);
        return 0;
    }
    var st: u8 = 0;
    for (args[i..]) |n| {
        const p = exec.findExecutable(sh, a, n) orelse {
            sh.diagCmdK(.not_found, n, "hash", "{s}: not found", .{n});
            st = 1;
            continue;
        };
        putString(sh.gpa, &sh.hash, n, p) catch |oe| return sh.oom(oe);
    }
    return st;
}

/// Set `key` to a copy of `value` in a map that owns both.
fn putString(gpa: Allocator, map: *std.StringHashMapUnmanaged([]u8), key: []const u8, value: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, value);
    errdefer gpa.free(copy);
    if (try shell.putOwned([]u8, gpa, map, key, copy)) |old| gpa.free(old);
}

pub fn aliasCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    if (args.len == 1) {
        const keys = sortedKeys(a, sh.aliases) catch |oe| return sh.oom(oe);
        var out: std.ArrayList(u8) = .empty;
        for (keys) |k| out.print(a, "{s}={s}\n", .{ k, quoteSingle(a, sh.aliases.get(k).?) catch |oe| return sh.oom(oe) }) catch |oe| return sh.oom(oe);
        _ = sh.out(out.items);
        return 0;
    }
    var st: u8 = 0;
    for (args[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |e| {
            const name = arg[0..e];
            putString(sh.gpa, &sh.aliases, name, arg[e + 1 ..]) catch |oe| return sh.oom(oe);
        } else if (sh.aliases.get(arg)) |v| {
            _ = sh.out(std.fmt.allocPrint(a, "{s}={s}\n", .{ arg, quoteSingle(a, v) catch |oe| return sh.oom(oe) }) catch |oe| return sh.oom(oe));
        } else {
            sh.diagCmdK(.alias_not_found, arg, "alias", "{s} not found", .{arg});
            st = 1;
        }
    }
    return st;
}

pub fn unaliasCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var st: u8 = 0;
    var i: usize = 1;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |c| if (c != 'a') {
            sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "unalias", "Illegal option -{c}", .{c});
            return 2;
        };
        var it = sh.aliases.iterator();
        while (it.next()) |e| {
            sh.gpa.free(e.key_ptr.*);
            sh.gpa.free(e.value_ptr.*);
        }
        sh.aliases.clearRetainingCapacity();
    }
    for (args[i..]) |arg| {
        if (sh.aliases.fetchRemove(arg)) |kv| {
            sh.gpa.free(kv.key);
            sh.gpa.free(kv.value);
        } else {
            sh.diagCmdK(.alias_not_found, arg, "unalias", "{s}: not found", .{arg});
            st = 1;
        }
    }
    return st;
}
