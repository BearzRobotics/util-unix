// SPDX-License-Identifier: GPL-2.0-or-later
//! cd and pwd. Part of builtins.zig.

const std = @import("std");
const sys = @import("../../../sys.zig");
const osio = @import("../osio.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");
const optText = @import("common.zig").optText;

fn absolutePwd(sh: *Shell) ?[]const u8 {
    const p = sh.getVar("PWD") orelse return null;
    return if (p.len > 0 and p[0] == '/') p else null;
}

/// `$PWD`, if it is an absolute name of the current directory.
fn truePwd(sh: *Shell) ?[]const u8 {
    const p = absolutePwd(sh) orelse return null;
    const named = sys.stat(p, true) catch return null;
    const here = sys.stat(".", true) catch return null;
    return if (named.ino == here.ino and named.dev == here.dev) p else null;
}

fn physicalCwd(sh: *Shell, a: Allocator) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const p = osio.getcwd(sh.env.io, &buf) catch return null;
    return a.dupe(u8, p) catch null;
}

fn canonical(a: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(a, c);
    }
    var out: std.ArrayList(u8) = .empty;
    for (parts.items) |c| {
        try out.append(a, '/');
        try out.appendSlice(a, c);
    }
    if (out.items.len == 0) try out.append(a, '/');
    return out.items;
}

/// Logical `..` handling (POSIX cd step 8): every component that a `..` removes
/// must be a directory.
fn dotdotOk(a: Allocator, abs: []const u8) bool {
    if (std.mem.indexOf(u8, abs, "..") == null) return true;
    var stack: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, abs, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            // the path so far must exist as a directory
            var path: std.ArrayList(u8) = .empty;
            for (stack.items) |c| {
                path.append(a, '/') catch return true;
                path.appendSlice(a, c) catch return true;
            }
            if (path.items.len == 0) path.append(a, '/') catch return true;
            const info = sys.stat(path.items, true) catch return false;
            if (info.kind != .dir) return false;
            if (stack.items.len > 0) _ = stack.pop();
            continue;
        }
        stack.append(a, comp) catch return true;
    }
    return true;
}

pub fn cdCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var physical = false;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |c| switch (c) {
            'P' => physical = true,
            'L' => physical = false,
            // POSIX 2024: with -P, fail if the new directory cannot be named.
            // It always can be here: its path is used when getcwd cannot.
            'e' => {},
            else => {
                sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "cd", "Illegal option -{c}", .{c});
                return 2;
            },
        };
    }
    var dir: []const u8 = undefined;
    var print = false;

    if (i < args.len) {
        dir = args[i];
        if (std.mem.eql(u8, dir, "-")) {
            // POSIX leaves an unset OLDPWD unspecified; dash stays in the current directory (FreeBSD sh fails)
            // a copy: OLDPWD is assigned before this is last used
            dir = a.dupe(u8, sh.getVar("OLDPWD") orelse (sh.getVar("PWD") orelse (physicalCwd(sh, a) orelse "."))) catch |oe| return sh.oom(oe);
            print = true;
        }
    } else {
        dir = sh.getVar("HOME") orelse {
            sh.diagCmdK(.other, null, "cd", "HOME not set", .{});
            return 2;
        };
    }
    // an empty operand is not an error (dash, FreeBSD sh): the directory stays
    if (dir.len == 0) return 0;
    // PWD and OLDPWD are assigned by `cd`: a read-only one makes it fail before it moves (dash)
    for ([_][]const u8{ "PWD", "OLDPWD" }) |nm| {
        if (sh.vars.get(nm)) |v| if (v.readonly) {
            sh.diagCmdK(.readonly_assignment, nm, "cd", "{s}: is read only", .{nm});
            return 2;
        };
    }
    var target = dir;
    // CDPATH
    if (dir.len > 0 and dir[0] != '/' and !std.mem.startsWith(u8, dir, "./") and !std.mem.startsWith(u8, dir, "../") and !std.mem.eql(u8, dir, ".") and !std.mem.eql(u8, dir, "..")) {
        if (sh.getVar("CDPATH")) |cp| {
            var it = std.mem.splitScalar(u8, cp, ':');
            while (it.next()) |d| {
                const cand = std.fmt.allocPrint(a, "{s}/{s}", .{ if (d.len == 0) "." else d, dir }) catch |oe| return sh.oom(oe);
                if (sys.stat(cand, true)) |info| {
                    if (info.kind == .dir) {
                        target = cand;
                        if (d.len > 0) print = true;
                        break;
                    }
                } else |_| {}
            }
        }
    }
    // $PWD is a variable like any other: a script may have given it any value
    const old_pwd = truePwd(sh) orelse physicalCwd(sh, a) orelse absolutePwd(sh) orelse "";
    var curpath = target;
    if (!physical) {
        const abs = if (target.len > 0 and target[0] == '/') target else std.fmt.allocPrint(a, "{s}/{s}", .{ old_pwd, target }) catch |oe| return sh.oom(oe);
        if (!dotdotOk(a, abs)) {
            sh.diagCmdK(.cannot_cd, dir, "cd", "can't cd to {s}", .{dir});
            return 2;
        }
        curpath = canonical(a, abs) catch |oe| return sh.oom(oe);
    }
    if (!osio.chdir(sh.env.io, if (physical) target else curpath)) {
        sh.diagCmdK(.cannot_cd, dir, "cd", "can't cd to {s}", .{dir});
        return 2;
    }
    sh.clearRelativeHash();
    const new_pwd: []const u8 = if (physical) (physicalCwd(sh, a) orelse target) else curpath;
    sh.setVarRaw("OLDPWD", old_pwd) catch |oe| return sh.oom(oe);
    if (sh.vars.getPtr("OLDPWD")) |v| v.exported = true; // dash, bash and FreeBSD sh export it
    sh.setVarRaw("PWD", new_pwd) catch |oe| return sh.oom(oe);
    if (print) _ = sh.out(std.fmt.allocPrint(a, "{s}\n", .{new_pwd}) catch |oe| return sh.oom(oe));
    return 0;
}

pub fn pwdCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var physical = false;
    for (args[1..]) |arg| {
        if (arg.len < 2 or arg[0] != '-' or std.mem.eql(u8, arg, "--")) break;
        for (arg[1..]) |c| switch (c) {
            'P' => physical = true,
            'L' => physical = false,
            else => {
                sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "pwd", "Illegal option -{c}", .{c});
                return 2;
            },
        };
    }
    var path: []const u8 = if (physical) "" else truePwd(sh) orelse "";
    if (path.len == 0) path = physicalCwd(sh, a) orelse blk: {
        // the directory was removed under us: the logical name is all there is (dash, FreeBSD sh)
        if (!physical and sys.errno() == sys.E_NOENT) if (absolutePwd(sh)) |p| break :blk p;
        sh.diagCmdK(.other, null, "pwd", "getcwd() failed: {s}", .{sys.strerror(sys.errno())});
        return 1;
    };
    _ = sh.out(std.fmt.allocPrint(a, "{s}\n", .{path}) catch |oe| return sh.oom(oe));
    return 0;
}
