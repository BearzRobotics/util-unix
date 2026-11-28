// SPDX-License-Identifier: GPL-2.0-or-later
//! The shell's options and set. Part of builtins.zig.

const std = @import("std");
const jobs = @import("../jobs.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");
const die = @import("common.zig").die;
const optText = @import("common.zig").optText;
const printVars = @import("vars.zig").printVars;

const opt_names = [_]struct { []const u8, u8 }{
    .{ "errexit", 'e' },   .{ "noglob", 'f' }, .{ "ignoreeof", 0 }, .{ "interactive", 'i' },
    .{ "monitor", 'm' },   .{ "noexec", 'n' }, .{ "stdin", 's' },   .{ "xtrace", 'x' },
    .{ "verbose", 'v' },   .{ "vi", 0 },       .{ "emacs", 0 },     .{ "noclobber", 'C' },
    .{ "allexport", 'a' }, .{ "notify", 'b' }, .{ "nounset", 'u' }, .{ "privileged", 0 },
    .{ "nolog", 0 },       .{ "pipefail", 0 }, .{ "debug", 0 },
};

fn flagPtr(sh: *Shell, letter: u8) ?*bool {
    return switch (letter) {
        'a' => &sh.flags.allexport,
        'b' => &sh.flags.notify,
        'C' => &sh.flags.noclobber,
        'e' => &sh.flags.errexit,
        'f' => &sh.flags.noglob,
        'h' => &sh.flags.hashall,
        'i' => &sh.flags.interactive,
        'm' => &sh.flags.monitor,
        'n' => &sh.flags.noexec,
        's' => &sh.flags.stdin_mode,
        'u' => &sh.flags.nounset,
        'v' => &sh.flags.verbose,
        'x' => &sh.flags.xtrace,
        else => null,
    };
}

fn namedFlag(sh: *Shell, name: []const u8) ?*bool {
    if (std.mem.eql(u8, name, "ignoreeof")) return &sh.flags.ignoreeof;
    if (std.mem.eql(u8, name, "vi")) return &sh.flags.vi;
    if (std.mem.eql(u8, name, "emacs")) return &sh.flags.emacs;
    if (std.mem.eql(u8, name, "nolog")) return &sh.flags.nolog;
    if (std.mem.eql(u8, name, "pipefail")) return &sh.flags.pipefail;
    for (opt_names) |e| if (std.mem.eql(u8, e[0], name) and e[1] != 0) return flagPtr(sh, e[1]);
    return null;
}

pub fn knownOptName(name: []const u8) bool {
    for (opt_names) |e| if (std.mem.eql(u8, e[0], name)) return true;
    return false;
}

/// Set the option named `name`; false when unknown.
/// `set -m` / `set +m`: engage or release job control.
fn monitorChanged(sh: *Shell, on: bool) void {
    if (on) _ = jobs.enable(sh, false) else jobs.disable(sh);
}

pub fn setNamedOption(sh: *Shell, name: []const u8, on: bool) bool {
    if (namedFlag(sh, name)) |p| {
        p.* = on;
        if (on and std.mem.eql(u8, name, "vi")) sh.flags.emacs = false;
        if (on and std.mem.eql(u8, name, "emacs")) sh.flags.vi = false;
        if (std.mem.eql(u8, name, "monitor")) monitorChanged(sh, on);
        return true;
    }
    return knownOptName(name);
}

pub fn setOption(sh: *Shell, letter: u8, on: bool) bool {
    const p = flagPtr(sh, letter) orelse return false;
    p.* = on;
    if (letter == 'm') monitorChanged(sh, on);
    return true;
}

fn printOptions(sh: *Shell, a: Allocator, as_commands: bool) void {
    var out: std.ArrayList(u8) = .empty;
    if (!as_commands) out.appendSlice(a, "Current option settings\n") catch return;
    for (opt_names) |e| {
        const on = if (namedFlag(sh, e[0])) |p| p.* else false;
        if (as_commands) {
            out.print(a, "set {s}o {s}\n", .{ if (on) "-" else "+", e[0] }) catch return;
        } else out.print(a, "{s: <16}{s}\n", .{ e[0], if (on) "on" else "off" }) catch return;
    }
    _ = sh.out(out.items);
}

pub fn setCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    if (args.len == 1) return printVars(sh, a, "", false, false);
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-")) {
            // `set -`: turn off -x and -v and end the options (POSIX, obsolescent)
            sh.flags.xtrace = false;
            sh.flags.verbose = false;
            i += 1;
            if (i >= args.len) return 0;
            break;
        }
        if (std.mem.eql(u8, arg, "+")) {
            // a lone `+` is an ignored option
            i += 1;
            continue;
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;
        const on = arg[0] == '-';
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const c = arg[j];
            if (c == 'o') {
                if (i + 1 >= args.len) {
                    printOptions(sh, a, !on);
                    continue;
                }
                i += 1;
                if (!setNamedOption(sh, args[i], on)) {
                    sh.diagCmdK(.illegal_option, optText(a, "{s}o {s}", .{ if (on) "-" else "+", args[i] }), "set", "Illegal option {s}o {s}", .{ if (on) "-" else "+", args[i] });
                    return die(sh, 2);
                }
                continue;
            }
            if (!setOption(sh, c, on)) {
                sh.diagCmdK(.illegal_option, optText(a, "{c}{c}", .{ arg[0], c }), "set", "Illegal option {c}{c}", .{ arg[0], c });
                return die(sh, 2);
            }
        }
        i += 1;
    }
    if (i <= args.len and (i < args.len or (i > 1 and std.mem.eql(u8, args[i - 1], "--")))) {
        sh.setParams(args[i..]) catch |oe| return sh.oom(oe);
        // new positional parameters restart option parsing (dash, bash)
        sh.setVarRaw("OPTIND", "1") catch |oe| return sh.oom(oe);
        sh.getopts_sub = 0;
    }
    return 0;
}
