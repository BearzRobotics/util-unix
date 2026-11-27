// SPDX-License-Identifier: GPL-2.0-or-later
//! Builtin utilities of the shell: the POSIX special builtins and the regular
//! builtins that must be built in (cd, read, getopts, command, ...).
//!
//! References: POSIX.1-2024 Shell Command Language 2.15 "Special Built-In
//! Utilities", and the utilities cd, command, echo, getopts, hash, kill,
//! printf, pwd, read, test, type, ulimit, umask, unalias, wait. Behaviour and
//! messages follow dash 0.5.12 where POSIX leaves them open.

const std = @import("std");
const sys = @import("../../sys.zig");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const exec = @import("exec.zig");
const expand = @import("expand.zig");
const shell = @import("shell.zig");
const arith = @import("arith.zig");
const pattern = @import("pattern.zig");
const jobs = @import("jobs.zig");
const jobcmd = @import("jobcmd.zig");
const history = @import("history.zig");
const mode_mod = @import("../mode.zig");
const fmtfloat = @import("fmtfloat.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

pub const Fn = *const fn (sh: *Shell, a: Allocator, args: []const []const u8) u8;
pub const Builtin = struct { run: Fn, special: bool };

const table = [_]struct { []const u8, Fn, bool }{
    .{ ":", colon, true },
    .{ ".", dot, true },
    .{ "break", brk, true },
    .{ "continue", cont, true },
    .{ "eval", eval, true },
    .{ "exec", execCmd, true },
    .{ "exit", exitCmd, true },
    .{ "export", exportCmd, true },
    .{ "readonly", readonlyCmd, true },
    .{ "return", returnCmd, true },
    .{ "set", setCmd, true },
    .{ "shift", shiftCmd, true },
    .{ "times", timesCmd, true },
    .{ "trap", trapCmd, true },
    .{ "unset", unsetCmd, true },
    .{ "alias", aliasCmd, false },
    .{ "cd", cdCmd, false },
    .{ "command", commandCmd, false },
    .{ "echo", echoCmd, false },
    .{ "false", falseCmd, false },
    .{ "getopts", getoptsCmd, false },
    .{ "hash", hashCmd, false },
    .{ "kill", killCmd, false },
    .{ "local", localCmd, false },
    .{ "printf", printfCmd, false },
    .{ "pwd", pwdCmd, false },
    .{ "read", readCmd, false },
    .{ "test", testCmd, false },
    .{ "[", bracketCmd, false },
    .{ "true", trueCmd, false },
    .{ "type", typeCmd, false },
    .{ "ulimit", ulimitCmd, false },
    .{ "umask", umaskCmd, false },
    .{ "unalias", unaliasCmd, false },
    .{ "wait", jobcmd.waitCmd, false },
    .{ "jobs", jobcmd.jobsCmd, false },
    .{ "fg", jobcmd.fgCmd, false },
    .{ "bg", jobcmd.bgCmd, false },
    .{ "fc", history.fcCmd, false },
};

/// Name of the i-th builtin (for completion).
pub fn nameAt(i: usize) ?[]const u8 {
    if (i >= table.len) return null;
    return table[i][0];
}

pub fn find(name: []const u8) ?Builtin {
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return .{ .run = e[1], .special = e[2] };
    return null;
}

// --- helpers --------------------------------------------------------------------

/// A special-builtin error: the non-interactive shell exits.
fn optText(a: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch "";
}

fn die(sh: *Shell, st: u8) u8 {
    if (sh.no_die > 0 or sh.flags.interactive) return st;
    sh.status = st;
    sh.flow = .exit_shell;
    return st;
}

/// `exit` itself: always leaves the shell.
fn leave(sh: *Shell, st: u8) u8 {
    if (sh.flags.interactive and sh.jc and jobs.anyStopped(sh) and sh.exit_warned + 1 != sh.cmd_seq) {
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

fn parseNum(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn quoteSingle(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(a, "'\"'\"'") else try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.items;
}

fn sortedKeys(a: Allocator, map: anytype) Allocator.Error![][]const u8 {
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

// --- trivial ----------------------------------------------------------------------

fn colon(_: *Shell, _: Allocator, _: []const []const u8) u8 {
    return 0;
}
fn trueCmd(_: *Shell, _: Allocator, _: []const []const u8) u8 {
    return 0;
}
fn falseCmd(_: *Shell, _: Allocator, _: []const []const u8) u8 {
    return 1;
}

// --- flow control ---------------------------------------------------------------------

fn loopArg(sh: *Shell, name: []const u8, args: []const []const u8) ?u32 {
    var n: i64 = 1;
    if (args.len > 1) {
        n = parseNum(args[1]) orelse {
            sh.diagCmdK(.illegal_number, args[1], name, "Illegal number: {s}", .{args[1]});
            _ = die(sh, 2);
            return null;
        };
        if (n < 1) {
            sh.diagCmdK(.illegal_number, args[1], name, "Illegal number: {s}", .{args[1]});
            _ = die(sh, 2);
            return null;
        }
    }
    return @intCast(@min(n, 1 << 20));
}

fn brk(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    const n = loopArg(sh, "break", args) orelse return 2;
    if (sh.loop_depth == 0) return 0;
    sh.flow = .break_loop;
    sh.flow_count = @min(n, sh.loop_depth);
    return 0;
}

fn cont(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    const n = loopArg(sh, "continue", args) orelse return 2;
    if (sh.loop_depth == 0) return 0;
    sh.flow = .continue_loop;
    sh.flow_count = @min(n, sh.loop_depth);
    return 0;
}

fn returnCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    var st: u8 = sh.status;
    if (args.len > 1) {
        const n = parseNum(args[1]) orelse {
            sh.diagCmdK(.illegal_number, args[1], "return", "Illegal number: {s}", .{args[1]});
            return die(sh, 2);
        };
        if (n < 0 or n > std.math.maxInt(i32)) {
            sh.diagCmdK(.illegal_number, args[1], "return", "Illegal number: {s}", .{args[1]});
            return die(sh, 2);
        }
        st = @truncate(@as(u64, @bitCast(n)));
        // dash and FreeBSD sh keep the whole value in `$?` after the return
        if (n > 255) {
            sh.wide_status = @intCast(n);
            sh.wide_seq = sh.simple_seq;
        }
    }
    sh.status = st;
    sh.flow = .return_func;
    return st;
}

fn exitCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    var st: u8 = if (args.len <= 1) (sh.trap_status orelse sh.status) else sh.status;
    // a bare `exit` after `return 300` passes the whole value on to the EXIT trap
    if (args.len <= 1 and sh.trap_status == null and sh.wide_seq != 0 and sh.wide_seq + 1 == sh.simple_seq and (sh.wide_status & 255) == sh.status) sh.wide_seq = sh.simple_seq;
    if (args.len > 1) {
        const n = parseNum(args[1]) orelse {
            sh.diagCmdK(.illegal_number, args[1], "exit", "Illegal number: {s}", .{args[1]});
            return die(sh, 2);
        };
        if (n < 0 or n > std.math.maxInt(i32)) {
            sh.diagCmdK(.illegal_number, args[1], "exit", "Illegal number: {s}", .{args[1]});
            return die(sh, 2);
        }
        st = @truncate(@as(u64, @bitCast(n)));
        if (n > 255) {
            sh.wide_status = @intCast(n); // an EXIT trap sees the whole value
            sh.wide_seq = sh.simple_seq;
        }
    }
    return leave(sh, st);
}

fn eval(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    if (args.len < 2) return 0;
    const text = std.mem.join(a, " ", args[1..]) catch |oe| return sh.oom(oe);
    const saved_line = sh.line;
    defer sh.line = saved_line;
    return exec.runSource(sh, text, .{ .prefix = "eval" }) catch 2;
}

fn dot(sh: *Shell, a: Allocator, args_in: []const []const u8) u8 {
    var args = args_in;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--")) args = args[1..];
    if (args.len < 2) {
        sh.diagCmdK(.usage, null, ".", "filename argument required", .{});
        return die(sh, 2);
    }
    const name = args[1];
    var path: []const u8 = name;
    if (std.mem.indexOfScalar(u8, name, '/') == null) {
        const found = blk: {
            const pv = sh.getVar("PATH") orelse "";
            var it = std.mem.splitScalar(u8, pv, ':');
            while (it.next()) |dir| {
                const full = std.fmt.allocPrint(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch |oe| return sh.oom(oe);
                const info = sys.stat(full, true) catch continue;
                if (info.kind == .dir) continue;
                break :blk full;
            }
            break :blk null;
        };
        if (found) |f| path = f else {
            sh.diagCmdK(.not_found, name, ".", "{s}: not found", .{name});
            return die(sh, 2);
        }
    }
    // a directory reads as an empty file (dash, FreeBSD sh)
    if (sys.stat(path, true)) |info| {
        if (info.kind == .dir) return 0;
    } else |_| {}
    const text = exec.readFile(a, path) orelse {
        sh.diagCmdK(.cannot_open, path, ".", "cannot open {s}: No such file", .{path});
        return die(sh, 2);
    };
    var old: std.ArrayList([]u8) = .empty;
    const have_args = args.len > 2;
    if (have_args) {
        old = sh.params;
        sh.params = .empty;
        sh.setParams(args[2..]) catch |oe| return sh.oom(oe);
    }
    const saved_line = sh.line;
    sh.source_depth += 1;
    var st = exec.runSource(sh, text, .{}) catch 2;
    sh.source_depth -= 1;
    sh.line = saved_line;
    if (sh.flow == .return_func) {
        sh.flow = .none;
        st = sh.status;
    }
    if (have_args) {
        for (sh.params.items) |p| sh.gpa.free(p);
        sh.params.deinit(sh.gpa);
        sh.params = old;
    }
    return st;
}

fn execCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    if (args.len < 2) return 0;
    var rest = args[1..];
    if (std.mem.eql(u8, rest[0], "--")) {
        rest = rest[1..];
        if (rest.len == 0) return 0;
    }
    const name = rest[0];
    const path = if (std.mem.indexOfScalar(u8, name, '/') != null) name else exec.findExecutable(sh, a, name) orelse {
        sh.diagCmdK(.not_found, name, "exec", "{s}: not found", .{name});
        return die(sh, 127);
    };
    const env = sh.environ(a) catch |oe| return sh.oom(oe);
    var i: u8 = 1;
    while (i < sys.nsig) : (i += 1) {
        if (sh.traps[i]) |t| if (t.len > 0) {
            _ = sys.setSignal(i, .default);
        };
    }
    // an interactive shell hands over the dispositions it set up for itself as defaults
    const own = [_]u8{ 2, 3, 15, 20, 21, 22 };
    const interactive_main = sh.flags.interactive and !sh.in_subshell;
    if (interactive_main) for (own) |sg| {
        const user_ignored = if (sh.traps[sg]) |t| t.len == 0 else false;
        if (!sh.inherited_ignore[sg] and !user_ignored) _ = sys.setSignal(sg, .default);
    };
    exec.execProgram(sh, a, path, rest, env);
    const e = sys.errno();
    if (e == sys.E_NOEXEC) exec.execScript(sh, a, path, rest, &.{}, &.{});
    if (interactive_main) for (own) |sg| {
        // exec failed: the shell goes on as before
        if (sh.traps[sg]) |t| {
            if (t.len > 0) _ = sys.setSignal(sg, .catch_flag);
        } else if (!sh.inherited_ignore[sg]) _ = sys.setSignal(sg, shellDefault(sh, sg));
    };
    if (e == sys.E_NOENT or e == sys.E_NOTDIR) {
        sh.diagCmdK(.not_found, name, "exec", "{s}: not found", .{name});
        return die(sh, 127);
    }
    sh.diagCmdK(if (e == sys.E_ACCES) .not_executable else .other, name, "exec", "{s}: {s}", .{ name, sys.strerror(e) });
    return die(sh, 126);
}

// --- variables ---------------------------------------------------------------------------

fn printVars(sh: *Shell, a: Allocator, prefix: []const u8, want_export: bool, want_ro: bool) u8 {
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
        if (std.mem.eql(u8, args[i], "-p")) {
            _ = 0;
        } else {
            sh.diagCmdK(.illegal_option, args[i], cmd, "Illegal option {s}", .{args[i]});
            return die(sh, 2);
        }
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

fn exportCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    return declare(sh, a, args, "export", false);
}

fn readonlyCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    return declare(sh, a, args, "readonly", true);
}

fn localCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
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

fn unsetCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var funcs = false;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, args[i], "-f")) {
            funcs = true;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            funcs = false;
        } else {
            sh.diagCmdK(.illegal_option, args[i], "unset", "Illegal option {s}", .{args[i]});
            return die(sh, 2);
        }
    }
    for (args[i..]) |name| {
        if (funcs) {
            if (sh.funcs.fetchRemove(name)) |kv| sh.gpa.free(kv.key);
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

fn shiftCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
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

fn setCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
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

fn timesCmd(sh: *Shell, a: Allocator, _: []const []const u8) u8 {
    const t = sys.cpuTimes();
    const f = struct {
        fn fmt(al: Allocator, us: u64) []const u8 {
            const secs = us / 1_000_000;
            return std.fmt.allocPrint(al, "{d}m{d}.{d:0>6}s", .{ secs / 60, secs % 60, us % 1_000_000 }) catch "";
        }
    }.fmt;
    const text = std.fmt.allocPrint(a, "{s} {s}\n{s} {s}\n", .{ f(a, t.user), f(a, t.system), f(a, t.child_user), f(a, t.child_system) }) catch |oe| return sh.oom(oe);
    _ = sh.out(text);
    return 0;
}

// --- trap -----------------------------------------------------------------------------------

/// What `trap - SIG` restores: the system default, except for the signals an interactive
/// shell handles itself (POSIX XCU sh, Signals: INT caught for line editing, QUIT and TERM
/// ignored, and the job-control stops when monitoring).
fn shellDefault(sh: *Shell, n: u8) sys.SignalAction {
    if (!sh.flags.interactive or sh.in_subshell) return .default;
    return switch (n) {
        2 => .catch_flag,
        3, 15 => .ignore,
        20, 21, 22 => if (sh.jc) .ignore else .default,
        else => .default,
    };
}

fn trapCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
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
            out.print(a, "trap -- {s} {s}\n", .{ q, sys.signal_names[n] }) catch |oe| return sh.oom(oe);
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

// --- cd and pwd -----------------------------------------------------------------------------

fn physicalCwd(a: Allocator) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const p = sys.getcwd(&buf) catch return null;
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

fn cdCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var physical = false;
    opts: while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..]) |c| switch (c) {
            'P' => physical = true,
            'L' => physical = false,
            else => break :opts,
        };
    }
    var dir: []const u8 = undefined;
    var print = false;

    if (i < args.len) {
        dir = args[i];
        if (std.mem.eql(u8, dir, "-")) {
            // POSIX leaves an unset OLDPWD unspecified; dash stays in the current directory (FreeBSD sh fails)
            dir = sh.getVar("OLDPWD") orelse (sh.getVar("PWD") orelse (physicalCwd(a) orelse "."));
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
    const old_pwd = sh.getVar("PWD") orelse (physicalCwd(a) orelse "");
    var curpath = target;
    if (!physical) {
        const abs = if (target.len > 0 and target[0] == '/') target else std.fmt.allocPrint(a, "{s}/{s}", .{ old_pwd, target }) catch |oe| return sh.oom(oe);
        if (!dotdotOk(a, abs)) {
            sh.diagCmdK(.cannot_cd, dir, "cd", "can't cd to {s}", .{dir});
            return 2;
        }
        curpath = canonical(a, abs) catch |oe| return sh.oom(oe);
    }
    sys.chdir(if (physical) target else curpath) catch {
        const e = sys.errno();
        sh.diagCmdK(.cannot_cd, dir, "cd", "can't cd to {s}", .{dir});
        _ = e;
        return 2;
    };
    sh.clearRelativeHash();
    const new_pwd: []const u8 = if (physical) (physicalCwd(a) orelse target) else curpath;
    sh.setVarRaw("OLDPWD", old_pwd) catch |oe| return sh.oom(oe);
    if (sh.vars.getPtr("OLDPWD")) |v| v.exported = true; // dash, bash and FreeBSD sh export it
    sh.setVarRaw("PWD", new_pwd) catch |oe| return sh.oom(oe);
    if (print) _ = sh.out(std.fmt.allocPrint(a, "{s}\n", .{new_pwd}) catch |oe| return sh.oom(oe));
    return 0;
}

fn pwdCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var physical = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-P")) physical = true else if (std.mem.eql(u8, arg, "-L")) physical = false;
    }
    var path: []const u8 = "";
    if (!physical) {
        if (sh.getVar("PWD")) |p| {
            if (p.len > 0 and p[0] == '/') {
                const x = sys.stat(p, true) catch null;
                const y = sys.stat(".", true) catch null;
                if (x != null and y != null and x.?.ino == y.?.ino and x.?.dev == y.?.dev) path = p;
            }
        }
    }
    if (path.len == 0) path = physicalCwd(a) orelse blk: {
        // the directory was removed under us: the logical name is all there is (dash, FreeBSD sh)
        if (!physical and sys.errno() == sys.E_NOENT) if (sh.getVar("PWD")) |p| if (p.len > 0 and p[0] == '/') break :blk p;
        sh.diagCmdK(.other, null, "pwd", "getcwd() failed: {s}", .{sys.strerror(sys.errno())});
        return 1;
    };
    _ = sh.out(std.fmt.allocPrint(a, "{s}\n", .{path}) catch |oe| return sh.oom(oe));
    return 0;
}

// --- echo and printf ----------------------------------------------------------------------------

/// Process backslash escapes of `echo`/`%b`; returns false at `\c`.
fn escapes(a: Allocator, out: *std.ArrayList(u8), s: []const u8, is_b: bool) Allocator.Error!bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) {
            try out.append(a, c);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'a' => try out.append(a, 7),
            'b' => try out.append(a, 8),
            'c' => return false,
            'f' => try out.append(a, 12),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            't' => try out.append(a, '\t'),
            'v' => try out.append(a, 11),
            '\\' => try out.append(a, '\\'),
            '0' => {
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '7') : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                try out.append(a, @truncate(v));
            },
            '1'...'7' => |d| {
                // \ddd (also in a %b operand, as dash, bash and FreeBSD sh)
                _ = is_b;
                var v: u32 = d - '0';
                var n: usize = 0;
                while (n < 2 and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '7') : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                try out.append(a, @truncate(v));
            },
            else => |o| {
                try out.append(a, '\\');
                try out.append(a, o);
            },
        }
    }
    return true;
}

fn echoCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var newline = true;
    if (i < args.len and std.mem.eql(u8, args[i], "-n")) {
        newline = false;
        i += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var go = true;
    while (i < args.len and go) : (i += 1) {
        if (!first) out.append(a, ' ') catch |oe| return sh.oom(oe);
        first = false;
        go = escapes(a, &out, args[i], false) catch |oe| return sh.oom(oe);
    }
    if (go and newline) out.append(a, '\n') catch |oe| return sh.oom(oe);
    if (!sh.out(out.items)) {
        sh.diagCmdK(.io_error, "I/O error", "echo", "I/O error", .{});
        return 1;
    }
    return 0;
}

/// A complete integer operand with its range checked like strtoimax / strtoumax: out of
/// range clamps (INT64_MAX/MIN, UINT64_MAX) and the status becomes 1; a negative number
/// converted as unsigned wraps (dash, bash, FreeBSD sh).
fn printfRanged(sh: *Shell, s: []const u8, st: *u8, unsigned: bool) ?i64 {
    var t = std.mem.trimStart(u8, s, " \t\n\x0b\x0c\r");
    var neg = false;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    var base: u8 = 10;
    if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        base = 16;
        t = t[2..];
    } else if (t.len > 1 and t[0] == '0') {
        base = 8;
        t = t[1..];
    }
    if (t.len == 0) return null;
    var mag: u128 = 0;
    for (t) |c| {
        const d = std.fmt.charToDigit(c, base) catch return null;
        mag = mag * base + d;
        if (mag > (1 << 70)) mag = 1 << 70; // saturate: far beyond any limit
    }
    var range = false;
    var out: i64 = 0;
    if (unsigned) {
        if (mag > std.math.maxInt(u64)) {
            range = true;
            out = -1; // UINT64_MAX
        } else {
            const m: u64 = @intCast(mag);
            out = @bitCast(if (neg) 0 -% m else m);
        }
    } else if (neg) {
        if (mag > (1 << 63)) {
            range = true;
            out = std.math.minInt(i64);
        } else out = @intCast(-@as(i128, @intCast(mag)));
    } else if (mag > std.math.maxInt(i64)) {
        range = true;
        out = std.math.maxInt(i64);
    } else out = @intCast(mag);
    if (range) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: Result too large", .{s});
        st.* = 1;
    }
    return out;
}

fn printfNumber(sh: *Shell, s: []const u8, st: *u8) i64 {
    return printfNumberK(sh, s, st, false);
}

fn printfNumberK(sh: *Shell, s: []const u8, st: *u8, unsigned: bool) i64 {
    if (s.len == 0) return 0;
    if (s[0] == '\'' or s[0] == '"') return if (s.len > 1) s[1] else 0;
    if (printfRanged(sh, s, st, unsigned)) |v| return v;
    if (arith.parseNumber(s)) |v| return v;
    // partial conversion: the longest numeric prefix (leading blanks allowed)
    var end: usize = 0;
    while (end < s.len and (s[end] == ' ' or (s[end] >= '\t' and s[end] <= '\r'))) end += 1;
    const num_start = end;
    if (end < s.len and (s[end] == '-' or s[end] == '+')) end += 1;
    const digits_start = end;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    if (end > digits_start) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: not completely converted", .{s});
        st.* = 1;
        return std.fmt.parseInt(i64, s[num_start..end], 10) catch 0;
    }
    sh.diagCmdK(.printf_number, s, "printf", "{s}: expected numeric value", .{s});
    st.* = 1;
    return 0;
}

fn printfFloat(sh: *Shell, s: []const u8, st: *u8) f64 {
    if (s.len == 0) return 0;
    if (s[0] == '\'' or s[0] == '"') return if (s.len > 1) @floatFromInt(s[1]) else 0;
    const p = fmtfloat.parsePrefix(s);
    if (p.used == 0) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: expected numeric value", .{s});
        st.* = 1;
        return 0;
    }
    if (p.used < s.len) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: not completely converted", .{s});
        st.* = 1;
    } else if (p.range) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: Numerical result out of range", .{s});
        st.* = 1;
    }
    return p.value;
}

fn printfCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    if (i < args.len and std.mem.eql(u8, args[i], "--")) i += 1 else if (i < args.len and args[i].len > 1 and args[i][0] == '-') {
        // no options (POSIX utility syntax guidelines aside): `printf -v x` is an error as in dash and FreeBSD sh
        sh.diagCmdK(.illegal_option, args[i], "printf", "Illegal option {s}", .{args[i][0..2]});
        return 2;
    }
    if (i >= args.len) {
        sh.diagCmdK(.usage, null, "printf", "usage: printf format [arg ...]", .{});
        return 2;
    }
    const fmt = args[i];
    i += 1;
    const rest = args[i..];
    var out: std.ArrayList(u8) = .empty;
    var ai: usize = 0;
    var st: u8 = 0;
    while (true) {
        const start_ai = ai;
        var consumed_any = false;
        var k: usize = 0;
        var stop = false;
        while (k < fmt.len and !stop) : (k += 1) {
            const c = fmt[k];
            if (c == '\\') {
                // format-string escapes
                var j = k + 1;
                if (j >= fmt.len) {
                    out.append(a, '\\') catch |oe| return sh.oom(oe);
                    break;
                }
                var tmp: std.ArrayList(u8) = .empty;
                // \NNN octal (up to three digits) as in the format
                if (fmt[j] >= '0' and fmt[j] <= '7') {
                    var v: u32 = 0;
                    var n: usize = 0;
                    while (n < 3 and j < fmt.len and fmt[j] >= '0' and fmt[j] <= '7') : (n += 1) {
                        v = v * 8 + (fmt[j] - '0');
                        j += 1;
                    }
                    out.append(a, @truncate(v)) catch |oe| return sh.oom(oe);
                    k = j - 1;
                    continue;
                }
                const seg = fmt[k .. k + 2];
                if (fmt[j] == '"' or fmt[j] == '\'') {
                    out.append(a, fmt[j]) catch |oe| return sh.oom(oe);
                } else {
                    _ = escapes(a, &tmp, seg, true) catch |oe| return sh.oom(oe);
                    out.appendSlice(a, tmp.items) catch |oe| return sh.oom(oe);
                }
                k += 1;
                continue;
            }
            if (c != '%') {
                out.append(a, c) catch |oe| return sh.oom(oe);
                continue;
            }
            k += 1;
            if (k >= fmt.len) {
                sh.diagCmdK(.usage, null, "printf", "%: invalid directive", .{});
                _ = sh.out(out.items);
                return 1;
            }
            if (fmt[k] == '%') {
                out.append(a, '%') catch |oe| return sh.oom(oe);
                continue;
            }
            // flags, width, precision
            var left = false;
            var plus = false;
            var space = false;
            var alt = false;
            var zero = false;
            while (k < fmt.len) : (k += 1) switch (fmt[k]) {
                '-' => left = true,
                '+' => plus = true,
                ' ' => space = true,
                '#' => alt = true,
                '0' => zero = true,
                else => break,
            };
            var width: usize = 0;
            if (k < fmt.len and fmt[k] == '*') {
                const v = if (ai < rest.len) printfNumber(sh, rest[ai], &st) else 0;
                ai += 1;
                if (v < 0) {
                    left = true;
                    width = @abs(v);
                } else width = @intCast(v);
                k += 1;
            } else while (k < fmt.len and std.ascii.isDigit(fmt[k])) : (k += 1) width = width *| 10 +| (fmt[k] - '0');
            var prec: ?usize = null;
            if (k < fmt.len and fmt[k] == '.') {
                k += 1;
                var p: usize = 0;
                if (k < fmt.len and fmt[k] == '*') {
                    const v = if (ai < rest.len) printfNumber(sh, rest[ai], &st) else 0;
                    ai += 1;
                    p = if (v < 0) 0 else @intCast(v);
                    k += 1;
                } else while (k < fmt.len and std.ascii.isDigit(fmt[k])) : (k += 1) p = p *| 10 +| (fmt[k] - '0');
                prec = p;
            }
            if (k >= fmt.len) {
                sh.diagCmdK(.usage, null, "printf", "%: invalid directive", .{});
                _ = sh.out(out.items);
                return 1;
            }
            const conv = fmt[k];
            // for a string the precision only cuts, so any value will do
            const cuts = conv == 's' or conv == 'b';
            if (width > fmtfloat.max_precision or (!cuts and (prec orelse 0) > fmtfloat.max_precision)) {
                sh.diagCmdK(.usage, null, "printf", "field width or precision too large", .{});
                _ = sh.out(out.items);
                return 2;
            }
            const arg: ?[]const u8 = if (ai < rest.len) rest[ai] else null;
            if (arg != null) consumed_any = true;
            var body: std.ArrayList(u8) = .empty;
            switch (conv) {
                's' => {
                    ai += 1;
                    var s = arg orelse "";
                    if (prec) |p| s = s[0..@min(p, s.len)];
                    body.appendSlice(a, s) catch |oe| return sh.oom(oe);
                },
                'b' => {
                    ai += 1;
                    var tmp: std.ArrayList(u8) = .empty;
                    const cont_ = escapes(a, &tmp, arg orelse "", true) catch |oe| return sh.oom(oe);
                    var s: []const u8 = tmp.items;
                    if (prec) |p| s = s[0..@min(p, s.len)];
                    body.appendSlice(a, s) catch |oe| return sh.oom(oe);
                    if (!cont_) stop = true;
                },
                'c' => {
                    ai += 1;
                    if (arg) |s| if (s.len > 0) body.append(a, s[0]) catch |oe| return sh.oom(oe);
                },
                'd', 'i' => {
                    ai += 1;
                    const v = if (arg) |s| printfNumber(sh, s, &st) else 0;
                    var digits: std.ArrayList(u8) = .empty;
                    const mag: u64 = if (v < 0) @as(u64, @bitCast(-%v)) else @intCast(v);
                    digits.print(a, "{d}", .{mag}) catch |oe| return sh.oom(oe);
                    if (prec) |p| while (digits.items.len < p) digits.insert(a, 0, '0') catch |oe| return sh.oom(oe);
                    const sign: []const u8 = if (v < 0) "-" else if (plus) "+" else if (space) " " else "";
                    padNum(a, &body, sign, digits.items, width, left, zero and prec == null) catch |oe| return sh.oom(oe);
                    width = 0;
                },
                'u', 'o', 'x', 'X' => {
                    ai += 1;
                    const v: u64 = @bitCast(if (arg) |s| printfNumberK(sh, s, &st, true) else 0);
                    var digits: std.ArrayList(u8) = .empty;
                    switch (conv) {
                        'u' => digits.print(a, "{d}", .{v}) catch |oe| return sh.oom(oe),
                        'o' => digits.print(a, "{o}", .{v}) catch |oe| return sh.oom(oe),
                        'x' => digits.print(a, "{x}", .{v}) catch |oe| return sh.oom(oe),
                        else => digits.print(a, "{X}", .{v}) catch |oe| return sh.oom(oe),
                    }
                    if (prec) |p| while (digits.items.len < p) digits.insert(a, 0, '0') catch |oe| return sh.oom(oe);
                    const pre: []const u8 = if (alt and v != 0) (if (conv == 'x') "0x" else if (conv == 'X') "0X" else if (conv == 'o') "0" else "") else "";
                    padNum(a, &body, pre, digits.items, width, left, zero and prec == null) catch |oe| return sh.oom(oe);
                    width = 0;
                },
                'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A' => {
                    ai += 1;
                    const x = if (arg) |s| printfFloat(sh, s, &st) else 0.0;
                    const r = fmtfloat.format(a, x, .{ .conv = conv, .prec = prec, .alt = alt }) catch |oe| return sh.oom(oe);
                    const sign: []const u8 = if (r.neg) "-" else if (plus) "+" else if (space) " " else "";
                    const hex_prefix: usize = if (std.ascii.toLower(conv) == 'a' and r.finite) 2 else 0;
                    if (zero and !left and r.finite and width > sign.len + r.body.len) {
                        // zeros go after the sign (and the 0x of %a)
                        body.appendSlice(a, sign) catch |oe| return sh.oom(oe);
                        body.appendSlice(a, r.body[0..hex_prefix]) catch |oe| return sh.oom(oe);
                        body.appendNTimes(a, '0', width - sign.len - r.body.len) catch |oe| return sh.oom(oe);
                        body.appendSlice(a, r.body[hex_prefix..]) catch |oe| return sh.oom(oe);
                    } else {
                        body.appendSlice(a, sign) catch |oe| return sh.oom(oe);
                        body.appendSlice(a, r.body) catch |oe| return sh.oom(oe);
                    }
                },
                else => {
                    sh.diagCmdK(.usage, null, "printf", "%{c}: invalid directive", .{conv});
                    _ = sh.out(out.items);
                    return 2; // dash; FreeBSD sh and bash say 1, POSIX only wants non-zero
                },
            }
            // pad strings
            if (body.items.len < width) {
                const pad = width - body.items.len;
                if (left) {
                    out.appendSlice(a, body.items) catch |oe| return sh.oom(oe);
                    out.appendNTimes(a, ' ', pad) catch |oe| return sh.oom(oe);
                } else {
                    out.appendNTimes(a, ' ', pad) catch |oe| return sh.oom(oe);
                    out.appendSlice(a, body.items) catch |oe| return sh.oom(oe);
                }
            } else out.appendSlice(a, body.items) catch |oe| return sh.oom(oe);
        }
        if (stop) break;
        if (ai >= rest.len or ai == start_ai or !consumed_any) break;
    }
    if (!sh.out(out.items)) {
        sh.diagCmdK(.io_error, "I/O error", "printf", "I/O error", .{});
        return 1;
    }
    return st;
}

fn padNum(a: Allocator, body: *std.ArrayList(u8), sign: []const u8, digits: []const u8, width: usize, left: bool, zero: bool) Allocator.Error!void {
    const len = sign.len + digits.len;
    const pad = if (width > len) width - len else 0;
    if (left) {
        try body.appendSlice(a, sign);
        try body.appendSlice(a, digits);
        try body.appendNTimes(a, ' ', pad);
    } else if (zero) {
        try body.appendSlice(a, sign);
        try body.appendNTimes(a, '0', pad);
        try body.appendSlice(a, digits);
    } else {
        try body.appendNTimes(a, ' ', pad);
        try body.appendSlice(a, sign);
        try body.appendSlice(a, digits);
    }
}

// --- read -------------------------------------------------------------------------------------

fn readCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var raw = false;
    var i: usize = 1;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, args[i], "-r")) {
            raw = true;
        } else if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            // `read -p prompt` is not POSIX; dash and FreeBSD sh accept it and
            // write the prompt to standard error when reading a terminal
            i += 1;
            if (sys.isatty(0)) sh.errRaw(args[i]);
        } else {
            sh.diagCmdK(.illegal_option, args[i], "read", "Illegal option {s}", .{args[i]});
            return 2;
        }
    }
    const names = args[i..];
    if (names.len == 0) {
        sh.diagCmdK(.usage, null, "read", "arg count", .{});
        return 2;
    }
    var bytes: std.ArrayList(u8) = .empty;
    var esc: std.ArrayList(bool) = .empty;
    var got_eof = false;

    var escaped = false;
    while (true) {
        var ch: [1]u8 = undefined;
        const n = sys.read(0, &ch) catch {
            if (sys.errno() == sys.E_INTR) {
                exec.checkTraps(sh);
                if (sh.flow != .none) return sh.status; // the trap left the shell (exit, return)
                continue;
            }
            return 1;
        };
        if (n == 0) {
            got_eof = true;
            break;
        }

        const c = ch[0];
        if (escaped) {
            escaped = false;
            if (c == '\n') continue;
            bytes.append(a, c) catch |oe| return sh.oom(oe);
            esc.append(a, true) catch |oe| return sh.oom(oe);
            continue;
        }
        if (c == '\\' and !raw) {
            escaped = true;
            continue;
        }
        if (c == '\n') break;
        bytes.append(a, c) catch |oe| return sh.oom(oe);
        esc.append(a, false) catch |oe| return sh.oom(oe);
    }
    // a copy: IFS may be one of the names being read
    const ifs: []const u8 = a.dupe(u8, sh.getVar("IFS") orelse " \t\n") catch |oe| return sh.oom(oe);
    const isIfs = struct {
        fn f(s: []const u8, c: u8) bool {
            return std.mem.indexOfScalar(u8, s, c) != null;
        }
    }.f;
    const isWs = struct {
        fn f(s: []const u8, c: u8) bool {
            return (c == ' ' or c == '\t' or c == '\n') and std.mem.indexOfScalar(u8, s, c) != null;
        }
    }.f;
    const b = bytes.items;
    var pos: usize = 0;
    for (names, 0..) |name, idx| {
        if (!lexer.isName(name)) {
            sh.diagCmdK(.bad_variable_name, name, "read", "{s}: bad variable name", .{name});
            return 2;
        }
        while (pos < b.len and !esc.items[pos] and isWs(ifs, b[pos])) pos += 1;
        var val: std.ArrayList(u8) = .empty;
        if (idx + 1 == names.len) {
            val.appendSlice(a, b[pos..]) catch |oe| return sh.oom(oe);
            // trim trailing IFS whitespace
            while (val.items.len > 0) {
                const li = pos + val.items.len - 1;
                if (!esc.items[li] and isWs(ifs, b[li])) _ = val.pop() else break;
            }
            // a single trailing non-whitespace delimiter ends the last field too
            // (POSIX 2.6.5: "A-B-" with two names gives "B"); not when the
            // remainder holds another such delimiter ("C-D -")
            if (val.items.len > 0) {
                const li = pos + val.items.len - 1;
                if (!esc.items[li] and isIfs(ifs, b[li]) and !isWs(ifs, b[li])) {
                    var other = false;
                    for (val.items[0 .. val.items.len - 1], 0..) |ch, k| if (!esc.items[pos + k] and isIfs(ifs, ch) and !isWs(ifs, ch)) {
                        other = true;
                    };
                    if (!other) {
                        _ = val.pop();
                        while (val.items.len > 0) {
                            const lj = pos + val.items.len - 1;
                            if (!esc.items[lj] and isWs(ifs, b[lj])) _ = val.pop() else break;
                        }
                    }
                }
            }
            pos = b.len;
        } else {
            while (pos < b.len and (esc.items[pos] or !isIfs(ifs, b[pos]))) : (pos += 1) val.append(a, b[pos]) catch |oe| return sh.oom(oe);
            // consume the delimiter
            while (pos < b.len and !esc.items[pos] and isWs(ifs, b[pos])) pos += 1;
            if (pos < b.len and !esc.items[pos] and isIfs(ifs, b[pos]) and !isWs(ifs, b[pos])) {
                pos += 1;
                while (pos < b.len and !esc.items[pos] and isWs(ifs, b[pos])) pos += 1;
            }
        }
        sh.setVar(name, val.items) catch {
            sh.diagCmdK(.readonly_assignment, name, "read", "{s}: is read only", .{name});
            return 2;
        };
    }
    if (got_eof) return 1;
    return 0;
}

// --- test -------------------------------------------------------------------------------------

const TestErr = error{Syntax};

const T = struct {
    sh: *Shell,
    args: []const []const u8,
    i: usize = 0,
    name: []const u8,
    err: [160]u8 = undefined,
    err_len: usize = 0,
    st: u8 = 0,

    fn fail(self: *T, comptime fmt: []const u8, a: anytype) TestErr {
        const m = std.fmt.bufPrint(&self.err, fmt, a) catch self.err[0..0];
        self.err_len = m.len;
        return error.Syntax;
    }

    fn cur(self: *const T) ?[]const u8 {
        return if (self.i < self.args.len) self.args[self.i] else null;
    }

    fn isUnary(s: []const u8) bool {
        if (s.len != 2 or s[0] != '-') return false;
        return std.mem.indexOfScalar(u8, "rwxefdcbpugkstznhLSOG", s[1]) != null;
    }

    fn binop(s: []const u8) ?enum { seq, sne, slt, sgt, eq, ne, gt, ge, lt, le, nt, ot, ef } {
        const m = std.mem.eql;
        if (m(u8, s, "=") or m(u8, s, "==")) return .seq;
        if (m(u8, s, "!=")) return .sne;
        if (m(u8, s, "<")) return .slt;
        if (m(u8, s, ">")) return .sgt;
        if (m(u8, s, "-eq")) return .eq;
        if (m(u8, s, "-ne")) return .ne;
        if (m(u8, s, "-gt")) return .gt;
        if (m(u8, s, "-ge")) return .ge;
        if (m(u8, s, "-lt")) return .lt;
        if (m(u8, s, "-le")) return .le;
        if (m(u8, s, "-nt")) return .nt;
        if (m(u8, s, "-ot")) return .ot;
        if (m(u8, s, "-ef")) return .ef;
        return null;
    }

    fn oexpr(self: *T) TestErr!bool {
        var res = try self.aexpr();
        while (self.cur()) |c| {
            if (!std.mem.eql(u8, c, "-o")) break;
            self.i += 1;
            const r = try self.aexpr();
            res = res or r;
        }
        return res;
    }

    fn aexpr(self: *T) TestErr!bool {
        var res = try self.nexpr();
        while (self.cur()) |c| {
            if (!std.mem.eql(u8, c, "-a")) break;
            self.i += 1;
            const r = try self.nexpr();
            res = res and r;
        }
        return res;
    }

    fn nexpr(self: *T) TestErr!bool {
        if (self.cur()) |c| if (std.mem.eql(u8, c, "!")) {
            self.i += 1;
            return !(try self.nexpr());
        };
        return self.primary();
    }

    fn num(self: *T, s: []const u8) TestErr!i64 {
        // blanks around the number are allowed (strtoimax; dash, FreeBSD sh)
        return parseNum(std.mem.trim(u8, s, " \t\n")) orelse self.fail("Illegal number: {s}", .{s});
    }

    fn primary(self: *T) TestErr!bool {
        const c = self.cur() orelse return false;
        if (std.mem.eql(u8, c, "(")) {
            self.i += 1;
            if (self.cur()) |n| if (std.mem.eql(u8, n, ")")) {
                self.i += 1;
                return false;
            };
            const r = try self.oexpr();
            const cl = self.cur() orelse return self.fail("closing paren expected", .{});
            if (!std.mem.eql(u8, cl, ")")) return self.fail("closing paren expected", .{});
            self.i += 1;
            return r;
        }
        // binary operator with the next token as operator takes precedence
        if (self.i + 1 < self.args.len) {
            if (binop(self.args[self.i + 1])) |op| {
                // `-a`/`-o`-style ambiguity: a unary operator followed by a
                // binary operator word is still a binary test of strings.
                if (self.i + 2 >= self.args.len) return self.fail("{s}: argument expected", .{self.args[self.i + 1]});
                const l = c;
                const r = self.args[self.i + 2];
                self.i += 3;
                return self.evalBin(op, l, r);
            }
        }
        if (isUnary(c)) {
            if (self.i + 1 >= self.args.len) {
                // `test -n` alone: a one-word expression is a string test.
                self.i += 1;
                return true;
            }
            const operand = self.args[self.i + 1];
            self.i += 2;
            return try self.evalUnary(c[1], operand);
        }
        self.i += 1;
        // A word followed by something that is not an operator is an error
        // unless it ends the expression or is followed by -a/-o/)
        return c.len > 0;
    }

    fn evalUnary(self: *T, op: u8, s: []const u8) TestErr!bool {
        switch (op) {
            'z' => return s.len == 0,
            'n' => return s.len > 0,
            't' => {
                const fd = parseNum(s) orelse return self.fail("Illegal number: {s}", .{s});
                if (fd < 0 or fd > std.math.maxInt(i32)) return false;
                return sys.isatty(@intCast(fd));
            },
            'r' => return sys.access(s, 4),
            'w' => return sys.access(s, 2),
            'x' => return sys.access(s, 1),
            'e' => return if (sys.stat(s, true)) |_| true else |_| false,
            'h', 'L' => return if (sys.stat(s, false)) |i| i.kind == .symlink else |_| false,
            else => {},
        }
        const info = sys.stat(s, true) catch return false;
        return switch (op) {
            'f' => info.kind == .file,
            'd' => info.kind == .dir,
            'c' => info.kind == .char,
            'b' => info.kind == .block,
            'p' => info.kind == .fifo,
            'S' => info.kind == .socket,
            's' => info.size > 0,
            'u' => info.mode & 0o4000 != 0,
            'g' => info.mode & 0o2000 != 0,
            'k' => info.mode & 0o1000 != 0,
            'O' => info.uid == sys.geteuid(),
            'G' => info.gid == sys.getegid(),
            else => false,
        };
    }

    fn evalBin(self: *T, op: anytype, l: []const u8, r: []const u8) TestErr!bool {
        switch (op) {
            .seq => return std.mem.eql(u8, l, r),
            .sne => return !std.mem.eql(u8, l, r),
            .slt => return std.mem.order(u8, l, r) == .lt,
            .sgt => return std.mem.order(u8, l, r) == .gt,
            .eq, .ne, .gt, .ge, .lt, .le => {
                const a = try self.num(l);
                const b = try self.num(r);
                return switch (op) {
                    .eq => a == b,
                    .ne => a != b,
                    .gt => a > b,
                    .ge => a >= b,
                    .lt => a < b,
                    else => a <= b,
                };
            },
            .nt, .ot, .ef => {
                const x = sys.stat(l, true) catch null;
                const y = sys.stat(r, true) catch null;
                if (op == .ef) return x != null and y != null and x.?.ino == y.?.ino and x.?.dev == y.?.dev;
                if (op == .nt) {
                    if (x == null) return false;
                    if (y == null) return true;
                    return x.?.mtime_sec > y.?.mtime_sec or (x.?.mtime_sec == y.?.mtime_sec and x.?.mtime_nsec > y.?.mtime_nsec);
                }
                if (y == null) return false;
                if (x == null) return true;
                return x.?.mtime_sec < y.?.mtime_sec or (x.?.mtime_sec == y.?.mtime_sec and x.?.mtime_nsec < y.?.mtime_nsec);
            },
        }
    }
};

fn evalCounted(t: *T, args: []const []const u8) TestErr!bool {
    const eq = std.mem.eql;
    t.args = args;
    t.i = 0;
    switch (args.len) {
        0 => return false,
        1 => return args[0].len > 0,
        2 => {
            if (eq(u8, args[0], "!")) return args[1].len == 0;
            if (T.isUnary(args[0])) return t.evalUnary(args[0][1], args[1]);
            // dash and FreeBSD sh read `[ -a -a ]` as an empty AND and `[ -o -o ]`
            // as an empty OR: false and true, no error; any other `-a x` is an
            // error as above.
            if (eq(u8, args[0], "-a") and eq(u8, args[1], "-a")) return false;
            if (eq(u8, args[0], "-o") and eq(u8, args[1], "-o")) return true;
            return t.fail("{s}: unexpected operator", .{args[0]});
        },
        3 => {
            if (T.binop(args[1])) |op| return t.evalBin(op, args[0], args[2]);
            if (eq(u8, args[0], "!")) return !(try evalCounted(t, args[1..]));
            if (eq(u8, args[0], "(") and eq(u8, args[2], ")")) return args[1].len > 0;
        },
        4 => {
            if (eq(u8, args[0], "!")) return !(try evalCounted(t, args[1..]));
            if (eq(u8, args[0], "(") and eq(u8, args[3], ")")) return evalCounted(t, args[1..3]);
        },
        else => {},
    }
    t.args = args;
    t.i = 0;
    const r = try t.oexpr();
    if (t.i < args.len) return t.fail("{s}: unexpected operator", .{args[t.i]});
    return r;
}

fn runTest(sh: *Shell, name: []const u8, args: []const []const u8) u8 {
    var t: T = .{ .sh = sh, .args = args, .name = name };
    const r = evalCounted(&t, args) catch {
        sh.diagCmdK(.test_error, null, name, "{s}", .{t.err[0..t.err_len]});
        return 2;
    };
    return if (r) 0 else 1;
}

fn testCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    return runTest(sh, "test", args[1..]);
}

fn bracketCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[args.len - 1], "]")) {
        sh.diagCmdK(.test_error, null, "[", "missing ]", .{});
        return 2;
    }
    return runTest(sh, "[", args[1 .. args.len - 1]);
}

// --- command, type, hash, alias ------------------------------------------------------------------

fn describe(sh: *Shell, a: Allocator, name: []const u8, verbose: bool, out: *std.ArrayList(u8)) bool {
    if (lexer.reservedOf(&.{.{ .text = name }}) != null) {
        if (verbose) out.print(a, "{s} is a shell keyword\n", .{name}) catch {} else out.print(a, "{s}\n", .{name}) catch {};
        return true;
    }
    if (sh.aliases.get(name)) |v| {
        if (verbose) out.print(a, "{s} is an alias for {s}\n", .{ name, v }) catch {} else out.print(a, "alias {s}={s}\n", .{ name, quoteSingle(a, v) catch v }) catch {};
        return true;
    }
    if (sh.funcs.get(name) != null) {
        if (verbose) out.print(a, "{s} is a shell function\n", .{name}) catch {} else out.print(a, "{s}\n", .{name}) catch {};
        return true;
    }
    if (find(name)) |b| {
        if (verbose) out.print(a, "{s} is a {s}shell builtin\n", .{ name, if (b.special) "special " else "" }) catch {} else out.print(a, "{s}\n", .{name}) catch {};
        return true;
    }
    if (sh.host_builtins.get(name) != null) {
        if (verbose) out.print(a, "{s} is a shell builtin\n", .{name}) catch {} else out.print(a, "{s}\n", .{name}) catch {};
        return true;
    }
    const path = if (std.mem.indexOfScalar(u8, name, '/') != null) (if (sys.access(name, 1)) name else null) else exec.findExecutable(sh, a, name);
    if (path) |p| {
        if (verbose) out.print(a, "{s} is {s}\n", .{ name, p }) catch {} else out.print(a, "{s}\n", .{p}) catch {};
        return true;
    }
    return false;
}

fn typeCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var st: u8 = 0;
    var out: std.ArrayList(u8) = .empty;
    for (args[1..]) |n| {
        if (!describe(sh, a, n, true, &out)) {
            out.print(a, "{s}: not found\n", .{n}) catch {};
            st = 127;
        }
    }
    _ = sh.out(out.items);
    return st;
}

fn commandCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
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
    var saved_path: ?shell.Saved = null;
    if (use_default_path) {
        const saved = exec.saveVar(sh, "PATH") catch |oe| return sh.oom(oe);
        saved_path = saved;
        sh.setVarRaw("PATH", "/usr/bin:/bin") catch |oe| return sh.oom(oe);
    }
    defer if (saved_path) |saved| exec.restoreVar(sh, saved);
    if (mode != 0) {
        var out: std.ArrayList(u8) = .empty;
        const ok = describe(sh, a, args[i], mode == 'V', &out);
        if (!ok and mode == 'V') {
            out.print(a, "{s}: not found\n", .{args[i]}) catch {};
        }
        _ = sh.out(out.items);
        return if (ok) 0 else 127;
    }
    sh.no_die += 1;
    defer sh.no_die -= 1;
    return exec.runArgs(sh, a, args[i..], true);
}

fn hashCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    if (i < args.len and std.mem.eql(u8, args[i], "-r")) {
        sh.clearHash();
        i += 1;
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

fn aliasCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
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

fn unaliasCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    var st: u8 = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-a")) {
            var it = sh.aliases.iterator();
            while (it.next()) |e| {
                sh.gpa.free(e.key_ptr.*);
                sh.gpa.free(e.value_ptr.*);
            }
            sh.aliases.clearRetainingCapacity();
            continue;
        }
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

// --- getopts -----------------------------------------------------------------------------------

fn getoptsCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
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

// --- wait, kill, umask, ulimit -------------------------------------------------------------------

fn killCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var sig: u8 = 15;
    if (i < args.len and std.mem.eql(u8, args[i], "-l")) {
        var out: std.ArrayList(u8) = .empty;
        if (i + 1 < args.len) {
            // `kill -l N`: a signal number or the exit status of a process
            // killed by it (128+N); 0, 128 and anything else is an error
            // (dash and FreeBSD sh).
            const n = parseNum(args[i + 1]) orelse {
                sh.diagCmdK(.kill_error, null, "kill", "invalid signal number or exit status: {s}", .{args[i + 1]});
                return 2;
            };
            const s: i64 = if (n > 128) n - 128 else n;
            if (s <= 0 or s >= sys.signal_names.len) {
                sh.diagCmdK(.kill_error, null, "kill", "invalid signal number or exit status: {s}", .{args[i + 1]});
                return 2;
            }
            out.print(a, "{s}\n", .{sys.signal_names[@intCast(s)]}) catch |oe| return sh.oom(oe);
        } else for (sys.signal_names[1..]) |nm| out.print(a, "{s}\n", .{nm}) catch |oe| return sh.oom(oe);
        _ = sh.out(out.items);
        return 0;
    }
    if (i < args.len and (std.mem.eql(u8, args[i], "-s") or std.mem.eql(u8, args[i], "-n"))) {
        if (i + 1 >= args.len) {
            sh.diagCmdK(.usage, null, "kill", "usage: kill [-s sigspec | -signum | -sigspec] [pid | job]... or kill -l [exitstatus]", .{});
            return 2;
        }
        sig = sys.signalNumber(args[i + 1]) orelse {
            sh.diagCmdK(.kill_error, null, "kill", "invalid signal number or name: {s}", .{args[i + 1]});
            return 2;
        };
        i += 2;
    } else if (i < args.len and args[i].len > 1 and args[i][0] == '-' and args[i][1] != '-') {
        sig = sys.signalNumber(args[i][1..]) orelse {
            sh.diagCmdK(.kill_error, null, "kill", "invalid signal number or name: {s}", .{args[i][1..]});
            return 2;
        };
        i += 1;
    }
    if (i < args.len and std.mem.eql(u8, args[i], "--")) i += 1;
    if (i >= args.len) {
        sh.diagCmdK(.usage, null, "kill", "usage: kill [-s sigspec | -signum | -sigspec] [pid | job]... or kill -l [exitstatus]", .{});
        return 2;
    }
    var st: u8 = 0;
    for (args[i..]) |p| {
        if (jobcmd.killJob(sh, p, sig)) |r| {
            if (r != 0) st = r;
            continue;
        }
        const pid = parseNum(p) orelse {
            sh.diagCmdK(.kill_error, null, "kill", "invalid pid {s}", .{p});
            st = 2;
            continue;
        };
        // a cut-down number could name another process, or -1, all of them
        const target = std.math.cast(i32, pid) orelse {
            sh.diagCmdK(.kill_error, null, "kill", "invalid pid {s}", .{p});
            st = 2;
            continue;
        };
        sys.kill(target, sig) catch {
            sh.diagCmdK(.kill_error, null, "kill", "{s}", .{sys.strerror(sys.errno())});
            st = 1;
        };
    }
    return st;
}

fn umaskCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var symbolic = false;
    if (i < args.len and std.mem.eql(u8, args[i], "-S")) {
        symbolic = true;
        i += 1;
    }
    if (i >= args.len) {
        const m = sys.umaskGet();
        if (symbolic) {
            const f = struct {
                fn p(al: Allocator, who: u8, bits: u32) []const u8 {
                    return std.fmt.allocPrint(al, "{c}={s}{s}{s}", .{ who, if (bits & 4 == 0) "r" else "", if (bits & 2 == 0) "w" else "", if (bits & 1 == 0) "x" else "" }) catch "";
                }
            }.p;
            _ = sh.out(std.fmt.allocPrint(a, "{s},{s},{s}\n", .{ f(a, 'u', (m >> 6) & 7), f(a, 'g', (m >> 3) & 7), f(a, 'o', m & 7) }) catch |oe| return sh.oom(oe));
        } else _ = sh.out(std.fmt.allocPrint(a, "{o:0>4}\n", .{m}) catch |oe| return sh.oom(oe));
        return 0;
    }
    if (args[i].len > 1 and args[i][0] == '-' and !std.mem.eql(u8, args[i], "--")) {
        sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{args[i][1]}), "umask", "Illegal option {s}", .{args[i]});
        return 2;
    }
    if (args[i].len > 0 and !std.ascii.isDigit(args[i][0])) {
        // symbolic mode (POSIX umask): applied to the permissions the mask
        // allows, i.e. its complement
        const perm: u16 = @intCast(~sys.umaskGet() & 0o777);
        const np = mode_mod.apply(args[i], perm, false, 0) orelse {
            sh.diagCmdK(.illegal_number, args[i], "umask", "Illegal mode: {s}", .{args[i]});
            return 2;
        };
        _ = sys.umaskSet(~@as(u32, np) & 0o777);
        return 0;
    }
    const m = std.fmt.parseInt(u32, args[i], 8) catch {
        sh.diagCmdK(.illegal_number, args[i], "umask", "Illegal number: {s}", .{args[i]});
        return 2;
    };
    // a numeric mask keeps only the permission bits (dash, FreeBSD sh)
    _ = sys.umaskSet(m & 0o777);
    return 0;
}

fn ulimitCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var res: u32 = 1; // -f
    var scale: u64 = 1024;
    var hard = false;
    var soft_set = false;
    var all = false;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        for (args[i][1..]) |c| switch (c) {
            // the last of -H and -S wins (dash, FreeBSD sh)
            'H' => {
                hard = true;
                soft_set = false;
            },
            'S' => {
                soft_set = true;
                hard = false;
            },
            'a' => all = true,
            'f' => {
                res = 1;
                scale = 512;
            },
            'c' => {
                res = 4;
                scale = 512;
            },
            'd' => {
                res = 2;
                scale = 1024;
            },
            's' => {
                res = 3;
                scale = 1024;
            },
            'n' => {
                res = 7;
                scale = 1;
            },
            't' => {
                res = 0;
                scale = 1;
            },
            'v' => {
                res = 9;
                scale = 1024;
            },
            'm' => {
                res = 5;
                scale = 1024;
            },
            else => {
                sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "ulimit", "Illegal option -{c}", .{c});
                return 2;
            },
        };
    }
    if (all) {
        if (i < args.len) {
            sh.diagCmdK(.usage, null, "ulimit", "too many arguments", .{});
            return 2;
        }
        // POSIX.1-2024 `ulimit -a`: every limit this shell knows, one per line
        const Row = struct { label: []const u8, opt: u8, res: u32, scale: u64 };
        const rows = [_]Row{
            .{ .label = "time(seconds)", .opt = 't', .res = 0, .scale = 1 },
            .{ .label = "file(blocks)", .opt = 'f', .res = 1, .scale = 512 },
            .{ .label = "data(kbytes)", .opt = 'd', .res = 2, .scale = 1024 },
            .{ .label = "stack(kbytes)", .opt = 's', .res = 3, .scale = 1024 },
            .{ .label = "coredump(blocks)", .opt = 'c', .res = 4, .scale = 512 },
            .{ .label = "memory(kbytes)", .opt = 'm', .res = 5, .scale = 1024 },
            .{ .label = "nofiles(descriptors)", .opt = 'n', .res = 7, .scale = 1 },
            .{ .label = "vmemory(kbytes)", .opt = 'v', .res = 9, .scale = 1024 },
        };
        var out: std.ArrayList(u8) = .empty;
        for (rows) |row| {
            const lim = sys.getrlimit(row.res) catch continue;
            const v = if (hard) lim.hard else lim.soft;
            out.print(a, "-{c}: {s:<22}", .{ row.opt, row.label }) catch |oe| return sh.oom(oe);
            if (v == sys.infinity) out.appendSlice(a, "unlimited\n") catch |oe| return sh.oom(oe) else out.print(a, "{d}\n", .{v / row.scale}) catch |oe| return sh.oom(oe);
        }
        _ = sh.out(out.items);
        return 0;
    }
    var cur = sys.getrlimit(res) catch {
        sh.diagCmdK(.bad_limit, null, "ulimit", "error getting limit ({s})", .{sys.strerror(sys.errno())});
        return 2;
    };
    if (i >= args.len) {
        const v = if (hard) cur.hard else cur.soft;
        if (v == sys.infinity) _ = sh.out("unlimited\n") else _ = sh.out(std.fmt.allocPrint(a, "{d}\n", .{v / scale}) catch |oe| return sh.oom(oe));
        return 0;
    }
    const v: u64 = if (std.mem.eql(u8, args[i], "unlimited")) sys.infinity else blk: {
        const n = std.fmt.parseInt(u64, args[i], 10) catch {
            sh.diagCmdK(.illegal_number, args[i], "ulimit", "bad number", .{});
            return 2;
        };
        // a value that does not fit once scaled is a bad number (FreeBSD sh; dash wraps silently)
        break :blk std.math.mul(u64, n, scale) catch {
            sh.diagCmdK(.illegal_number, args[i], "ulimit", "bad number", .{});
            return 2;
        };
    };
    if (i + 1 < args.len) {
        sh.diagCmdK(.usage, null, "ulimit", "too many arguments", .{});
        return 2;
    }
    if (hard or !soft_set) cur.hard = v;
    if (!hard or soft_set) cur.soft = v;
    sys.setrlimit(res, cur) catch {
        sh.diagCmdK(.bad_limit, null, "ulimit", "error setting limit ({s})", .{sys.strerror(sys.errno())});
        return 2;
    };
    return 0;
}
