// SPDX-License-Identifier: GPL-2.0-or-later
//! : true false break continue return exit eval . and exec. Part of builtins.zig.

const std = @import("std");
const sys = @import("../../../sys.zig");
const exec = @import("../exec.zig");
const interactive = @import("../interactive.zig");
const jobs = @import("../jobs.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");
const die = @import("common.zig").die;
const leave = @import("common.zig").leave;
const parseNum = @import("common.zig").parseNum;
const shellDefault = @import("trap.zig").shellDefault;

pub fn colon(_: *Shell, _: Allocator, _: []const []const u8) u8 {
    return 0;
}

pub fn trueCmd(_: *Shell, _: Allocator, _: []const []const u8) u8 {
    return 0;
}

pub fn falseCmd(_: *Shell, _: Allocator, _: []const []const u8) u8 {
    return 1;
}

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

pub fn brk(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    const n = loopArg(sh, "break", args) orelse return 2;
    if (sh.loop_depth == 0) return 0;
    sh.flow = .break_loop;
    sh.flow_count = @min(n, sh.loop_depth);
    return 0;
}

pub fn cont(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    const n = loopArg(sh, "continue", args) orelse return 2;
    if (sh.loop_depth == 0) return 0;
    sh.flow = .continue_loop;
    sh.flow_count = @min(n, sh.loop_depth);
    return 0;
}

pub fn returnCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
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

pub fn exitCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
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

pub fn eval(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    if (args.len < 2) return 0;
    const text = std.mem.join(a, " ", args[1..]) catch |oe| return sh.oom(oe);
    const saved_line = sh.line;
    defer sh.line = saved_line;
    return exec.runSource(sh, text, .{ .prefix = "eval" }) catch 2;
}

pub fn dot(sh: *Shell, a: Allocator, args_in: []const []const u8) u8 {
    var args = args_in;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--")) args = args[1..];
    if (args.len < 2) {
        sh.diagCmdK(.usage, null, ".", "filename argument required", .{});
        return die(sh, 2);
    }
    const name = args[1];
    var path: []const u8 = name;
    if (std.mem.indexOfScalar(u8, name, '/') == null) {
        // the file only has to be readable, and `command -p` does not change
        // where it is looked for
        const found = exec.searchPath(sh, a, sh.getVar("PATH") orelse "", name, false) catch |oe| return sh.oom(oe);
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
        const e = sys.errno();
        sh.diagCmdK(.cannot_open, path, ".", "cannot open {s}: {s}", .{ path, if (e == sys.E_NOENT) "No such file" else sys.strerror(e) });
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

pub fn execCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    if (args.len < 2) return 0;
    var rest = args[1..];
    if (std.mem.eql(u8, rest[0], "--")) {
        rest = rest[1..];
        if (rest.len == 0) return 0;
    }
    const name = rest[0];
    const path = if (std.mem.indexOfScalar(u8, name, '/') != null) name else exec.findExecutable(sh, a, name) orelse {
        if (exec.foundButNotExecutable(sh, a, name)) {
            sh.diagCmdK(.not_executable, name, "exec", "{s}: Permission denied", .{name});
            return die(sh, 126);
        }
        sh.diagCmdK(.not_found, name, "exec", "{s}: not found", .{name});
        return die(sh, 127);
    };
    if (sh.flags.interactive and !sh.in_subshell) interactive.saveHistory(sh);
    const env = sh.environ(a) catch |oe| return sh.oom(oe);
    // For a host that is to live on, the program runs in a child. A subshell
    // is a child already.
    var forked = false;
    if (sh.keep_process and !sh.in_subshell) {
        const pid = jobs.forkInto(sh, null, "", true) catch {
            sh.diagK(.cannot_fork, null, "Cannot fork", .{});
            return die(sh, 2);
        };
        if (pid != 0) {
            const st = exec.waitFor(sh, pid, true);
            // a shell that had been replaced would run no EXIT trap
            if (sh.traps[0]) |t| {
                sh.gpa.free(t);
                sh.traps[0] = null;
            }
            return leave(sh, st);
        }
        sh.in_subshell = true;
        forked = true;
    }
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
    // the program does not inherit what the shell ignores for job control
    const had_ignored = !interactive_main and sh.jc;
    if (had_ignored) sh.restoreJobSignals();
    if (forked) {
        sys.clearPendingAll();
        jobs.releaseSignals(sh);
    }
    exec.execProgram(sh, a, path, rest, env);
    const e = sys.errno();
    if (had_ignored and !forked) sh.ignoreJobSignals();
    if (e == sys.E_NOEXEC) exec.execScript(sh, a, path, rest, &.{}, &.{});
    if (interactive_main) for (own) |sg| {
        // exec failed: the shell goes on as before
        if (sh.traps[sg]) |t| {
            if (t.len > 0) _ = sys.setSignal(sg, .catch_flag);
        } else if (!sh.inherited_ignore[sg]) _ = sys.setSignal(sg, shellDefault(sh, sg));
    };
    var status: u8 = 126;
    if (e == sys.E_NOENT or e == sys.E_NOTDIR) {
        sh.diagCmdK(.not_found, name, "exec", "{s}: not found", .{name});
        status = 127;
    } else sh.diagCmdK(if (e == sys.E_ACCES) .not_executable else .other, name, "exec", "{s}: {s}", .{ name, sys.strerror(e) });
    // the child made for the program must not go on with the script
    if (forked) sys.exit(status);
    // the shell may well go on ("command exec", an interactive shell): put its
    // traps back as they were
    i = 1;
    while (i < sys.nsig) : (i += 1) {
        if (sh.traps[i]) |t| if (t.len > 0 and !sh.inherited_ignore[i]) {
            _ = sys.setSignal(i, .catch_flag);
        };
    }
    return die(sh, status);
}
