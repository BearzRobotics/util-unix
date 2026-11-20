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
        .no_current => sh.diagCmd(cmd, "No current job", .{}),
        .ambiguous => sh.diagCmd(cmd, "{s}: Ambiguous", .{spec}),
        else => sh.diagCmd(cmd, "No such job: {s}", .{spec}),
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
                sh.diagCmd("jobs", "Illegal option -{c}", .{c});
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
            picked.append(a, j) catch return 2;
        }
    } else {
        for (sh.jobs.items) |j| picked.append(a, j) catch return 2;
        std.mem.sort(*jobs.Job, picked.items, {}, struct {
            fn lt(_: void, l: *jobs.Job, r: *jobs.Job) bool {
                return l.id > r.id;
            }
        }.lt);
    }
    for (picked.items) |j| {
        jobs.format(sh, a, &out, j, mode) catch return 2;
        j.notified = true;
    }
    _ = sh.out(out.items);
    for (picked.items) |j| if (j.state() == .done) jobs.remove(sh, j);
    return st;
}

fn resumeJob(sh: *Shell, cmd: []const u8, args: []const []const u8, fg: bool) u8 {
    if (args.len > 2) {
        sh.diagCmd(cmd, "too many arguments", .{});
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
        sh.diagCmd(cmd, "job {d} already in background", .{j.id});
        return 0;
    }
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    const text = jobs.commandText(arena.allocator(), j) catch return 2;
    if (fg) {
        _ = sh.out(std.fmt.allocPrint(arena.allocator(), "{s}\n", .{text}) catch return 2);
        j.foreground = true;
        jobs.continueJob(sh, j);
        j.stamp = blk: {
            sh.job_stamp += 1;
            break :blk sh.job_stamp;
        };
        return jobs.waitFg(sh, j);
    }
    _ = sh.out(std.fmt.allocPrint(arena.allocator(), "[{d}] {s}\n", .{ j.id, text }) catch return 2);
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

pub fn waitCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    jobs.update(sh);
    if (args.len == 1) {
        for (sh.jobs.items) |j| {
            if (!jobs.waitJob(sh, j)) return interrupted(sh);
        }
        var k: usize = 0;
        while (k < sh.jobs.items.len) {
            const j = sh.jobs.items[k];
            if (j.state() == .done) jobs.remove(sh, j) else k += 1;
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
                st = 127;
                continue;
            }
            pid_found = job.?.lastPid();
        } else {
            const pid = std.fmt.parseInt(i32, arg, 10) catch {
                sh.diagCmd("wait", "Illegal number: {s}", .{arg});
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
        if (j.state() == .done) jobs.remove(sh, j);
    }
    return st;
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
            sh.diagCmd("kill", "{s}", .{sys.strerror(sys.errno())});
            return 1;
        };
    } else for (j.procs.items) |p| {
        if (p.state == .done) continue;
        sys.kill(p.pid, sig) catch {
            sh.diagCmd("kill", "{s}", .{sys.strerror(sys.errno())});
            return 1;
        };
    }
    // A stopped job needs SIGCONT to act on a terminating signal.
    if (sig != 18 and sig != 19 and sig != 20 and sig != 21 and sig != 22 and j.state() == .stopped) {
        if (j.grouped and j.pgid != 0) sys.killpg(j.pgid, 18) catch {};
    }
    return 0;
}
