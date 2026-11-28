// SPDX-License-Identifier: GPL-2.0-or-later
//! export, readonly, local, unset, shift and getopts. Part of builtins.zig.

const std = @import("std");
const lexer = @import("../lexer.zig");
const exec = @import("../exec.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");
const die = @import("common.zig").die;
const optText = @import("common.zig").optText;
const parseNum = @import("common.zig").parseNum;
const quoteSingle = @import("common.zig").quoteSingle;
const sortedKeys = @import("common.zig").sortedKeys;

pub fn printVars(sh: *Shell, a: Allocator, prefix: []const u8, want_export: bool, want_ro: bool) u8 {
    const keys = sortedKeys(a, sh.vars) catch |oe| return sh.oom(oe);
    var out: std.ArrayList(u8) = .empty;
    for (keys) |k| {
        const v = sh.vars.get(k).?;
        if (want_export and !v.exported) continue;
        if (want_ro and !v.readonly) continue;
        const val = v.value orelse {
            out.print(a, "{s}{s}\n", .{ prefix, k }) catch |oe| return sh.oom(oe);
            continue;
        };
        const q = quoteSingle(a, val) catch |oe| return sh.oom(oe);
        out.print(a, "{s}{s}={s}\n", .{ prefix, k, q }) catch |oe| return sh.oom(oe);
    }
    _ = sh.out(out.items);
    return 0;
}

fn declare(sh: *Shell, a: Allocator, args: []const []const u8, comptime cmd: []const u8, ro: bool) u8 {
    var i: usize = 1;

    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |c| if (c != 'p') {
            sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), cmd, "Illegal option -{c}", .{c});
            return die(sh, 2);
        };
    }
    if (i >= args.len) return printVars(sh, a, cmd ++ " ", !ro, ro);
    var st: u8 = 0;
    for (args[i..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        if (!lexer.isName(name)) {
            sh.diagCmdK(.bad_variable_name, name, cmd, "{s}: bad variable name", .{name});
            return die(sh, 2);
        }
        if (eq) |e| {
            sh.setVar(name, arg[e + 1 ..]) catch |err| switch (err) {
                error.ReadOnly => {
                    sh.diagCmdK(.readonly_assignment, name, cmd, "{s}: is read only", .{name});
                    return die(sh, 2);
                },
                error.OutOfMemory => return sh.oom(error.OutOfMemory),
            };
        }
        if (ro) sh.setReadonly(name) catch |oe| return sh.oom(oe) else sh.setExported(name, true) catch |oe| return sh.oom(oe);
    }
    st = 0;
    return st;
}

pub fn exportCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    return declare(sh, a, args, "export", false);
}

pub fn readonlyCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    return declare(sh, a, args, "readonly", true);
}

pub fn localCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    if (sh.func_depth == 0) {
        sh.diagCmdK(.not_in_function, "", "local", "not in a function", .{});
        return 2;
    }
    for (args[1..]) |arg| {
        // `local -` restores the shell options when the function returns
        // (dash, FreeBSD sh)
        if (std.mem.eql(u8, arg, "-")) {
            sh.locals.ensureUnusedCapacity(sh.gpa, 1) catch |oe| return sh.oom(oe);
            sh.locals.appendAssumeCapacity(.{ .name = sh.gpa.dupe(u8, "-") catch |oe| return sh.oom(oe), .old = null, .flags = sh.flags });
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        if (!lexer.isName(name)) {
            sh.diagCmdK(.bad_variable_name, name, "local", "{s}: bad variable name", .{name});
            return 2;
        }
        // assigning to a read-only variable is an error, as for dash
        if (eq != null) if (sh.vars.get(name)) |v| if (v.readonly) {
            sh.diagCmdK(.readonly_assignment, name, "local", "{s}: is read only", .{name});
            return die(sh, 2);
        };
        // `local x` again in the same function keeps the value
        var again = false;
        for (sh.locals.items[sh.locals_base..]) |l| if (std.mem.eql(u8, l.name, name)) {
            again = true;
        };
        if (again) {
            if (eq) |e| sh.setVar(name, arg[e + 1 ..]) catch |oe| return sh.setFailed(oe);
            continue;
        }
        sh.locals.ensureUnusedCapacity(sh.gpa, 1) catch |oe| return sh.oom(oe);
        sh.locals.appendAssumeCapacity(exec.saveVar(sh, name) catch |oe| return sh.oom(oe));
        // `local x` without a value keeps the current value, as in dash and
        // FreeBSD sh (the variable is local from now on)
        if (eq) |e| sh.setVar(name, arg[e + 1 ..]) catch |oe| return sh.setFailed(oe);
    }
    return 0;
}

pub fn unsetCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var funcs = false;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |c| switch (c) {
            'f' => funcs = true,
            'v' => funcs = false,
            else => {
                sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "unset", "Illegal option -{c}", .{c});
                return die(sh, 2);
            },
        };
    }
    for (args[i..]) |name| {
        if (funcs) {
            if (sh.funcs.fetchRemove(name)) |kv| {
                if (kv.value.unit) |u| u.release();
                sh.gpa.free(kv.key);
            }
            continue;
        }
        if (!lexer.isName(name)) {
            sh.diagCmdK(.bad_variable_name, name, "unset", "{s}: bad variable name", .{name});
            return die(sh, 2);
        }
        sh.unsetVar(name) catch |e| switch (e) {
            error.ReadOnly => {
                sh.diagCmdK(.readonly_assignment, name, "unset", "{s}: is read only", .{name});
                return die(sh, 2);
            },
            error.OutOfMemory => return sh.oom(error.OutOfMemory),
        };
    }
    return 0;
}

pub fn shiftCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    var n: usize = 1;
    if (args.len > 1) {
        const v = parseNum(args[1]) orelse {
            sh.diagCmdK(.illegal_number, args[1], "shift", "Illegal number: {s}", .{args[1]});
            return die(sh, 2);
        };
        if (v < 0) {
            sh.diagCmdK(.illegal_number, args[1], "shift", "Illegal number: {s}", .{args[1]});
            return die(sh, 2);
        }
        n = @intCast(v);
    }
    if (n > sh.params.items.len) {
        sh.diagCmdK(.cannot_shift, "", "shift", "can't shift that many", .{});
        return die(sh, 2);
    }
    for (sh.params.items[0..n]) |p| sh.gpa.free(p);
    const rest = sh.params.items.len - n;
    std.mem.copyForwards([]u8, sh.params.items[0..rest], sh.params.items[n..]);
    sh.params.shrinkRetainingCapacity(rest);
    return 0;
}

pub fn getoptsCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    if (args.len < 3) {
        sh.diagCmdK(.usage, null, "getopts", "usage: getopts optstring var [arg]", .{});
        return 2;
    }
    for ([_][]const u8{ "OPTIND", "OPTARG" }) |v| {
        if (sh.vars.get(v)) |ov| if (ov.readonly) {
            sh.diagCmdK(.readonly_assignment, v, "getopts", "{s}: is read only", .{v});
            return 2;
        };
    }
    const optstr = args[1];
    const name = args[2];
    // an invalid variable name is reported, but the option is still parsed
    // (OPTIND and OPTARG are set) and the status is 2 (dash, FreeBSD sh)
    if (!lexer.isName(name)) sh.diagCmdK(.bad_variable_name, name, "getopts", "{s}: bad variable name", .{name});
    // a loop must not go on with the option it read last time
    if (sh.vars.get(name)) |v| if (v.readonly) {
        sh.diagCmdK(.readonly_assignment, name, "getopts", "{s}: is read only", .{name});
        return 2;
    };
    const list: []const []const u8 = if (args.len > 3) args[3..] else @as([]const []const u8, @ptrCast(sh.params.items));
    const silent = optstr.len > 0 and optstr[0] == ':';
    const os = if (silent) optstr[1..] else optstr;
    const optind: usize = if (sh.getVar("OPTIND")) |v| @as(usize, @intCast(@max(1, parseNum(v) orelse 1))) else 1;
    // Mid-group: dash has already advanced OPTIND past the argument.
    if (optind != sh.getopts_last_optind) sh.getopts_sub = 0;
    var sub = sh.getopts_sub;
    var idx = if (sub > 0) optind - 1 else optind;
    // The arguments may not be the ones `sub` counts in: a function call,
    // `shift` or other operands change them without touching OPTIND. A place
    // that is not inside a group of options starts that argument afresh.
    if (sub > 0 and idx >= 1 and idx <= list.len) {
        const there = list[idx - 1];
        if (sub >= there.len or there[0] != '-' or std.mem.eql(u8, there, "--")) sub = 0;
    }
    const finish = struct {
        fn f(s: *Shell, n: []const u8, val: []const u8, oi: usize, sub_: usize, st: u8) u8 {
            const ok = lexer.isName(n);
            if (ok) s.setVar(n, val) catch |se| return s.setFailed(se);
            var buf: [24]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d}", .{oi}) catch "1";
            s.setVarRaw("OPTIND", t) catch |oe| return s.oom(oe);
            s.getopts_last_optind = oi;
            s.getopts_sub = sub_;
            return if (ok) st else 2;
        }
    }.f;
    if (idx > list.len) return finish(sh, name, "?", idx, 0, 1);
    const arg = list[idx - 1];
    if (sub == 0) {
        if (std.mem.eql(u8, arg, "--")) return finish(sh, name, "?", idx + 1, 0, 1);
        if (arg.len < 2 or arg[0] != '-') return finish(sh, name, "?", idx, 0, 1);
        sub = 1;
    }
    const c = arg[sub];
    sub += 1;
    const pos = if (c == ':') null else std.mem.indexOfScalar(u8, os, c);
    var cbuf: [1]u8 = .{c};
    const more = sub < arg.len;
    if (pos == null) {
        if (silent) {
            sh.setVar("OPTARG", &cbuf) catch |se| return sh.setFailed(se);
        } else {
            sh.unsetVar("OPTARG") catch {};
            sh.diagBareK(.illegal_option, optText(a, "-{c}", .{c}), std.fmt.allocPrint(a, "Illegal option -{c}", .{c}) catch "");
        }
        return finish(sh, name, "?", idx + 1, if (more) sub else 0, 0);
    }
    const takes = pos.? + 1 < os.len and os[pos.? + 1] == ':';
    if (takes) {
        if (more) {
            sh.setVar("OPTARG", arg[sub..]) catch |se| return sh.setFailed(se);
            return finish(sh, name, &cbuf, idx + 1, 0, 0);
        }
        if (idx + 1 > list.len) {
            if (silent) {
                sh.setVar("OPTARG", &cbuf) catch |se| return sh.setFailed(se);
                return finish(sh, name, ":", idx + 1, 0, 0);
            }
            sh.unsetVar("OPTARG") catch {};
            sh.diagBareK(.usage, null, std.fmt.allocPrint(a, "No arg for -{c} option", .{c}) catch "");
            return finish(sh, name, "?", idx + 1, 0, 0);
        }
        sh.setVar("OPTARG", list[idx]) catch |se| return sh.setFailed(se);
        return finish(sh, name, &cbuf, idx + 2, 0, 0);
    }
    sh.unsetVar("OPTARG") catch {};
    idx += 0;
    return finish(sh, name, &cbuf, idx + 1, if (more) sub else 0, 0);
}
