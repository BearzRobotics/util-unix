// SPDX-License-Identifier: GPL-2.0-or-later
//! The job-control utilities: `jobs`, `fg`, `bg`, `wait` and the job-specifier
//! half of `kill` (POSIX.1-2024 XCU `jobs`, `fg`, `bg`, `wait`, `kill`).
//! Messages follow dash and FreeBSD sh ("No current job", "No such job: %9").

const std = @import("std");
const sys = @import("../../sys.zig");
const shell = @import("shell.zig");
const jobs = @import("jobs.zig");
const exec = @import("exec.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

/// Report a failed specification; returns false.
pub fn specError(sh: *Shell, cmd: []const u8, spec: []const u8, err: jobs.SpecError) void {
    switch (err) {
        .no_current => sh.diagCmdK(.no_such_job, "current job", cmd, "No current job", .{}),
        .ambiguous => sh.diagCmdK(.ambiguous_job, spec, cmd, "{s}: Ambiguous", .{spec}),
        else => sh.diagCmdK(.no_such_job, spec, cmd, "No such job: {s}", .{spec}),
    }
}

pub fn jobsCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var mode: jobs.ListMode = .short;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |c| switch (c) {
            'l' => mode = .long,
            'p' => mode = .pids,
            else => {
                sh.diagCmdK(.illegal_option, &[_]u8{ '-', c }, "jobs", "Illegal option -{c}", .{c});
                return 2;
            },
        };
    }
    jobs.update(sh);
    var out: std.ArrayList(u8) = .empty;
    var st: u8 = 0;
    var picked: std.ArrayList(*jobs.Job) = .empty;
    if (i < args.len) {
        for (args[i..]) |spec| {
            var err: jobs.SpecError = .none;
            const j = jobs.resolve(sh, spec, &err) orelse {
                specError(sh, "jobs", spec, err);
                st = 1;
                continue;
            };
            picked.append(a, j) catch |oe| return sh.oom(oe);
        }
    } else {
        for (sh.jobs.items) |j| picked.append(a, j) catch |oe| return sh.oom(oe);
        // current job first, then the previous one, then the rest newest first
        std.mem.sort(*jobs.Job, picked.items, {}, struct {
            fn lt(_: void, l: *jobs.Job, r: *jobs.Job) bool {
                const ls = l.state() == .stopped;
                const rs = r.state() == .stopped;
                if (ls != rs) return ls;
                return l.stamp > r.stamp;
            }
        }.lt);
    }
    for (picked.items) |j| {
        jobs.format(sh, a, &out, j, mode) catch |oe| return sh.oom(oe);
        j.notified = true;
    }
    _ = sh.out(out.items);
    for (picked.items) |j| if (j.state() == .done) jobs.remove(sh, j);
    return st;
}

fn resumeJob(sh: *Shell, cmd: []const u8, args: []const []const u8, fg: bool) u8 {
    if (args.len > 2) {
        sh.diagCmdK(.usage, null, cmd, "too many arguments", .{});
        return 2;
    }
    jobs.update(sh);
    const spec = if (args.len > 1) args[1] else "%+";
    var err: jobs.SpecError = .none;
    const j = jobs.resolve(sh, spec, &err) orelse {
        specError(sh, cmd, spec, err);
        return 1;
    };
    if (!fg and j.state() == .running) {
        sh.diagCmdK(.usage, null, cmd, "job {d} already in background", .{j.id});
        return 0;
    }
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    const text = jobs.commandText(arena.allocator(), j) catch |oe| return sh.oom(oe);
    if (fg) {
        _ = sh.out(std.fmt.allocPrint(arena.allocator(), "{s}\n", .{text}) catch |oe| return sh.oom(oe));
        j.foreground = true;
        jobs.continueJob(sh, j);
        j.stamp = blk: {
            sh.job_stamp += 1;
            break :blk sh.job_stamp;
        };
        return jobs.waitFg(sh, j);
    }
    _ = sh.out(std.fmt.allocPrint(arena.allocator(), "[{d}] {s}\n", .{ j.id, text }) catch |oe| return sh.oom(oe));
    jobs.continueJob(sh, j);
    sh.bg_pid = j.lastPid();
    return 0;
}

pub fn fgCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    return resumeJob(sh, "fg", args, true);
}

pub fn bgCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    return resumeJob(sh, "bg", args, false);
}

fn lowestPending() u8 {
    var s: u8 = 1;
    while (s < sys.nsig) : (s += 1) if (sys.peekPending(s)) return s;
    return 0;
}

pub fn waitCmd(sh: *Shell, _: Allocator, args_in: []const []const u8) u8 {
    jobs.update(sh);
    // `wait --` ends the options (POSIX 12.2 guideline 10; dash and FreeBSD sh)
    const args = if (args_in.len > 1 and std.mem.eql(u8, args_in[1], "--")) args_in[1..] else args_in;
    if (args.len == 1) {
        for (sh.jobs.items) |j| {
            if (!jobs.waitJob(sh, j)) return interrupted(sh);
        }
        var k: usize = 0;
        while (k < sh.jobs.items.len) {
            const j = sh.jobs.items[k];
            if (j.state() == .done) {
                announce(sh, j);
                jobs.remove(sh, j);
            } else k += 1;
        }
        return 0;
    }
    var st: u8 = 0;
    for (args[1..]) |arg| {
        var job: ?*jobs.Job = null;
        var pid_found: i32 = 0;
        if (arg.len > 0 and arg[0] == '%') {
            var err: jobs.SpecError = .none;
            job = jobs.resolve(sh, arg, &err);
            if (job == null) {
                specError(sh, "wait", arg, err);
                return 2;
            }
            pid_found = job.?.lastPid();
        } else {
            const pid = std.fmt.parseInt(i32, arg, 10) catch {
                sh.diagCmdK(.illegal_number, arg, "wait", "Illegal number: {s}", .{arg});
                return 2;
            };
            for (sh.jobs.items) |j| for (j.procs.items) |p| if (p.pid == pid) {
                job = j;
                pid_found = pid;
            };
            if (job == null) {
                st = 127;
                continue;
            }
        }
        const j = job.?;
        if (!jobs.waitJob(sh, j)) return interrupted(sh);
        for (j.procs.items) |p| if (p.pid == pid_found) {
            st = sys.statusCode(p.status);
        };
        // a pipeline's status (with pipefail, its rightmost failure) when its last process is meant
        if (pid_found == j.lastPid()) st = j.status(sh.flags.pipefail);
        if (j.state() == .done) {
            announce(sh, j);
            jobs.remove(sh, j);
        }
    }
    return st;
}

/// An interactive shell reports a job that finished while it was waited for,
/// as dash and FreeBSD sh do.
fn announce(sh: *Shell, j: *jobs.Job) void {
    if (!sh.flags.interactive or j.notified) return;
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    jobs.format(sh, arena.allocator(), &out, j, .short) catch return;
    sh.errRaw(out.items);
}

fn interrupted(sh: *Shell) u8 {
    const sig = lowestPending();
    if (sig == 0) {
        // An interactive shell's SIGINT handler sets the flag too; without a
        // trap it still interrupts the wait.
        return 130;
    }
    exec.checkTraps(sh);
    return 128 + sig;
}

/// `kill` operand that names a job; returns false when it was not a job
/// specification (starts without `%`).
pub fn killJob(sh: *Shell, spec: []const u8, sig: u8) ?u8 {
    if (spec.len == 0 or spec[0] != '%') return null;
    var err: jobs.SpecError = .none;
    const j = jobs.resolve(sh, spec, &err) orelse {
        specError(sh, "kill", spec, err);
        return 1;
    };
    if (j.grouped and j.pgid != 0) {
        sys.killpg(j.pgid, sig) catch {
            sh.diagCmdK(.kill_error, null, "kill", "{s}", .{sys.strerror(sys.errno())});
            return 1;
        };
    } else for (j.procs.items) |p| {
        if (p.state == .done) continue;
        sys.kill(p.pid, sig) catch {
            sh.diagCmdK(.kill_error, null, "kill", "{s}", .{sys.strerror(sys.errno())});
            return 1;
        };
    }
    return 0;
}
