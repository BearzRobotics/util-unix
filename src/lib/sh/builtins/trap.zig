// SPDX-License-Identifier: GPL-2.0-or-later
//! trap. Part of builtins.zig.

const std = @import("std");
const sys = @import("../../../sys.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");
const die = @import("common.zig").die;
const parseNum = @import("common.zig").parseNum;
const quoteSingle = @import("common.zig").quoteSingle;

/// What `trap - SIG` restores: the system default, except for the signals an interactive
/// shell handles itself (POSIX XCU sh, Signals: INT caught for line editing, QUIT and TERM
/// ignored, and the job-control stops when monitoring).
pub fn shellDefault(sh: *Shell, n: u8) sys.SignalAction {
    if (!sh.flags.interactive or sh.in_subshell) return .default;
    return switch (n) {
        2 => .catch_flag,
        3, 15 => .ignore,
        20, 21, 22 => if (sh.jc) .ignore else .default,
        else => .default,
    };
}

pub fn trapCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var had_dd = false;
    if (i < args.len and std.mem.eql(u8, args[i], "--")) {
        i += 1;
        had_dd = true;
    }
    if (i >= args.len) {
        var out: std.ArrayList(u8) = .empty;
        for (sh.traps, 0..) |own, n| {
            // a subshell reports the parent's traps until it sets its own
            const t = if (sh.in_subshell and !sh.trap_set[n]) (sh.parent_traps[n] orelse own) else own;
            const cmd = t orelse continue;
            const q = quoteSingle(a, cmd) catch |oe| return sh.oom(oe);
            var nb: [12]u8 = undefined;
            out.print(a, "trap -- {s} {s}\n", .{ q, sys.signalName(n, &nb) orelse continue }) catch |oe| return sh.oom(oe);
        }
        _ = sh.out(out.items);
        return 0;
    }
    if (!had_dd and std.mem.eql(u8, args[i], "-l")) {
        var out: std.ArrayList(u8) = .empty;
        for (sys.signal_names[1..]) |nm| out.print(a, "{s}\n", .{nm}) catch |oe| return sh.oom(oe);
        _ = sh.out(out.items);
        return 0;
    }
    // `trap -p condition...` (POSIX 2024) writes how each is set, the default too
    if (!had_dd and std.mem.eql(u8, args[i], "-p")) {
        i += 1;
        if (i < args.len and std.mem.eql(u8, args[i], "--")) i += 1;
        if (i >= args.len) return trapCmd(sh, a, args[0..1]);
        var out: std.ArrayList(u8) = .empty;
        var bad: u8 = 0;
        for (args[i..]) |s| {
            const n = sys.signalNumber(s) orelse {
                sh.diagBareK(.bad_trap, s, std.fmt.allocPrint(a, "trap: {s}: bad trap", .{s}) catch "");
                bad = 1;
                continue;
            };
            const own = sh.traps[n];
            const t = if (sh.in_subshell and !sh.trap_set[n]) (sh.parent_traps[n] orelse own) else own;
            var nb: [12]u8 = undefined;
            const q = if (t) |cmd| quoteSingle(a, cmd) catch |oe| return sh.oom(oe) else "-";
            out.print(a, "trap -- {s} {s}\n", .{ q, sys.signalName(n, &nb) orelse s }) catch |oe| return sh.oom(oe);
        }
        _ = sh.out(out.items);
        return bad;
    }
    if (!had_dd and args[i].len > 1 and args[i][0] == '-' and std.mem.indexOfAny(u8, args[i], " \t\n") == null) {
        sh.diagBareK(.illegal_option, args[i], std.fmt.allocPrint(a, "trap: Illegal option {s}", .{args[i]}) catch "");
        return die(sh, 2);
    }
    var action: ?[]const u8 = null;
    // Only an unsigned decimal integer (or `-`) as the first operand makes every
    // operand a condition (POSIX trap); a name such as `term` is an action.
    // A lone operand that names a condition resets it (dash).
    const first_is_cond = args[i].len > 0 and (std.mem.indexOfNone(u8, args[i], "0123456789") == null or (i + 1 == args.len and sys.signalNumber(args[i]) != null));
    if (!first_is_cond and !std.mem.eql(u8, args[i], "-")) {
        action = args[i];
        i += 1;
        if (i >= args.len) {
            // an action with no condition: the operand was taken for a condition
            sh.diagBareK(.bad_trap, action.?, std.fmt.allocPrint(a, "trap: {s}: bad trap", .{action.?}) catch "");
            return 1;
        }
    } else if (std.mem.eql(u8, args[i], "-")) {
        i += 1;
    } else if (parseNum(args[i]) != null) {
        // a lone number: reset those signals
    }
    if (action != null and std.mem.eql(u8, action.?, "-")) action = null;
    var st: u8 = 0;
    for (args[i..]) |s| {
        const n = sys.signalNumber(s) orelse {
            sh.diagBareK(.bad_trap, s, std.fmt.allocPrint(a, "trap: {s}: bad trap", .{s}) catch "");
            st = 1;
            continue;
        };
        // A signal that was ignored on entry to a non-interactive shell cannot be trapped or
        // reset; no error is reported (POSIX XCU 2.15 trap)
        if (n > 0 and sh.inherited_ignore[n] and !sh.flags.interactive) continue;
        // an interactive shell may change a signal it inherited as ignored
        if (n == sys.SIGCHLD) sh.inherited_ignore[n] = false;
        if (sh.traps[n]) |old| sh.gpa.free(old);
        sh.traps[n] = null;
        sh.trap_set[n] = true;
        if (action) |cmd| {
            sh.traps[n] = sh.gpa.dupe(u8, cmd) catch |oe| return sh.oom(oe);
            // `trap '' CHLD` is recorded for the programs run, not applied here
            const ignored: sys.SignalAction = if (n == sys.SIGCHLD) .default else .ignore;
            if (n > 0 and !sh.inherited_ignore[n]) _ = sys.setSignal(n, if (cmd.len == 0) ignored else .catch_flag);
        } else if (n > 0 and !sh.inherited_ignore[n]) _ = sys.setSignal(n, shellDefault(sh, n));
    }
    return st;
}
