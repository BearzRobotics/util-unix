// SPDX-License-Identifier: GPL-2.0-or-later
//! Job control (POSIX.1-2024 sh "Job Control" and the utilities `jobs`, `fg`,
//! `bg`, `wait`, `kill`): the job table, process groups, the foreground
//! terminal hand-off, stopped/continued states, job specifications
//! (`%%`, `%+`, `%-`, `%n`, `%string`, `%?string`) and the notification of
//! finished jobs before the next prompt.
//!
//! With `set -m` (automatic in an interactive shell) every pipeline runs in its
//! own process group; the shell gives the terminal to a foreground group and
//! takes it back when the group ends or stops. Without it, background commands
//! are still entered in the table so that `wait` and `$!` work, but no process
//! group is created. The OS calls go through `sys.zig` (docs/std-io-gaps.md
//! rows 25-28).
//!
//! Output formats follow dash and FreeBSD sh, which agree except for the
//! column of the command (dash's is used) and the order of `jobs` (newest
//! first, as dash).

const std = @import("std");
const num = @import("../num.zig");
const sys = @import("../../sys.zig");
const ast = @import("ast.zig");
const shell = @import("shell.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

pub const State = enum { running, stopped, done };

pub const Proc = struct {
    pid: i32,
    /// Raw wait status once the process ended (or stopped).
    status: u32 = 0,
    state: State = .running,
    /// Command text of this stage.
    text: []u8,
};

pub const Job = struct {
    id: u32,
    pgid: i32,
    procs: std.ArrayList(Proc) = .empty,
    /// Recency: bigger is newer (set at creation and at each stop).
    stamp: u64,
    /// The state change has been reported to the user.
    notified: bool = false,
    foreground: bool = false,
    /// Process-group job (created with job control on).
    grouped: bool = false,

    pub fn state(self: *const Job) State {
        var stopped = false;
        for (self.procs.items) |p| switch (p.state) {
            .running => return .running,
            .stopped => stopped = true,
            .done => {},
        };
        return if (stopped) .stopped else .done;
    }

    pub fn lastPid(self: *const Job) i32 {
        return self.procs.items[self.procs.items.len - 1].pid;
    }

    /// Status of the job as `$?` sees it: the last process (or, with
    /// `pipefail`, the rightmost failure).
    pub fn status(self: *const Job, pipefail: bool) u8 {
        if (self.procs.items.len == 0) return 0;
        const code = struct {
            fn of(p: Proc) u8 {
                if (p.state == .stopped) return 128 + sys.statusStopSignal(p.status);
                return sys.statusCode(p.status);
            }
        }.of;
        if (pipefail) {
            var i = self.procs.items.len;
            while (i > 0) {
                i -= 1;
                const c = code(self.procs.items[i]);
                if (c != 0) return c;
            }
            return 0;
        }
        return code(self.procs.items[self.procs.items.len - 1]);
    }
};

// --- table -----------------------------------------------------------------

pub fn create(sh: *Shell) ?*Job {
    const gpa = sh.gpa;
    const id = freeId(sh);
    const j = gpa.create(Job) catch |oe| {
        _ = sh.oom(oe);
        return null;
    };
    sh.job_stamp += 1;
    j.* = .{ .id = id, .pgid = 0, .stamp = sh.job_stamp };
    sh.jobs.append(gpa, j) catch |oe| {
        _ = sh.oom(oe);
        gpa.destroy(j);
        return null;
    };
    return j;
}

/// The smallest job number not in use.
fn freeId(sh: *const Shell) u32 {
    // one pass over the table, marking the low numbers that are taken
    var used: [max_finished * 2]bool = @splat(false);
    for (sh.jobs.items) |j| if (j.id <= used.len) {
        used[j.id - 1] = true;
    };
    var id: u32 = 1;
    while (id <= used.len and used[id - 1]) id += 1;
    while (id > used.len and find(sh, id) != null) id += 1;
    return id;
}

/// How many finished background jobs a script's shell remembers for a later
/// `wait`. POSIX asks for at least CHILD_MAX, which is 25 or more.
const max_finished = 1024;

/// Collect the background processes that have ended, without waiting, so that
/// they do not stay behind as zombies in a script that never asks about them.
/// Only processes in the job table are collected: any other child belongs to
/// whoever is about to wait for it.
pub fn reap(sh: *Shell) void {
    if (sh.jobs.items.len == 0) return;
    var flags: u32 = sys.WNOHANG;
    if (sh.jc) flags |= sys.WUNTRACED | sys.WCONTINUED;
    // one look and one wait for each that has ended
    while (true) {
        const pid = sys.peekChild(sh.jc) catch break;
        if (pid == 0) break;
        const found = findProc(sh, pid);
        if (found == null or found.?.j.foreground) {
            // not ours to take, and it hides the ones behind it
            reapEach(sh, flags);
            break;
        }
        const r = sys.waitpidFlags(pid, flags) catch break;
        if (r.pid != pid) break;
        apply(sh, r);
    }
    if (!sh.flags.interactive) forgetOld(sh); // it reports each job first
}

fn reapEach(sh: *Shell, flags: u32) void {
    for (sh.jobs.items) |j| if (!j.foreground) for (j.procs.items) |*p| {
        if (p.state == .done) continue;
        const r = sys.waitpidFlags(p.pid, flags) catch continue;
        if (r.pid == p.pid) apply(sh, r);
    };
}

/// Forget the oldest finished jobs beyond `max_finished`, but never the one
/// "$!" names.
fn forgetOld(sh: *Shell) void {
    if (sh.jobs.items.len <= max_finished) return;
    var finished: usize = 0;
    for (sh.jobs.items) |j| if (!j.foreground and j.state() == .done) {
        finished += 1;
    };
    var k: usize = 0;
    while (finished > max_finished and k < sh.jobs.items.len) {
        const j = sh.jobs.items[k];
        if (!j.foreground and j.state() == .done and j.lastPid() != sh.bg_pid) {
            remove(sh, j);
            finished -= 1;
        } else k += 1;
    }
}

pub fn find(sh: *const Shell, id: u32) ?*Job {
    for (sh.jobs.items) |j| if (j.id == id) return j;
    return null;
}

pub fn remove(sh: *Shell, j: *Job) void {
    for (sh.jobs.items, 0..) |x, i| if (x == j) {
        _ = sh.jobs.orderedRemove(i);
        break;
    };
    for (j.procs.items) |p| sh.gpa.free(p.text);
    j.procs.deinit(sh.gpa);
    sh.gpa.destroy(j);
}

pub fn clearAll(sh: *Shell) void {
    while (sh.jobs.items.len > 0) remove(sh, sh.jobs.items[sh.jobs.items.len - 1]);
}

fn marker(sh: *const Shell, j: *const Job) u8 {
    var buf: [64]*Job = undefined;
    var n: usize = 0;
    for (sh.jobs.items) |x| {
        if (n < buf.len) {
            buf[n] = x;
            n += 1;
        }
    }
    std.mem.sort(*Job, buf[0..n], {}, struct {
        fn lt(_: void, l: *Job, r: *Job) bool {
            const ls = l.state() == .stopped;
            const rs = r.state() == .stopped;
            if (ls != rs) return ls;
            return l.stamp > r.stamp;
        }
    }.lt);
    if (n > 0 and buf[0] == j) return '+';
    if (n > 1 and buf[1] == j) return '-';
    return ' ';
}

pub fn current(sh: *const Shell) ?*Job {
    var best: ?*Job = null;
    for (sh.jobs.items) |j| {
        if (best == null) {
            best = j;
            continue;
        }
        const bs = best.?.state() == .stopped;
        const js = j.state() == .stopped;
        if ((js and !bs) or (js == bs and j.stamp > best.?.stamp)) best = j;
    }
    return best;
}

pub fn previous(sh: *const Shell) ?*Job {
    const cur = current(sh) orelse return null;
    var best: ?*Job = null;
    for (sh.jobs.items) |j| {
        if (j == cur) continue;
        if (best == null) {
            best = j;
            continue;
        }
        const bs = best.?.state() == .stopped;
        const js = j.state() == .stopped;
        if ((js and !bs) or (js == bs and j.stamp > best.?.stamp)) best = j;
    }
    return best;
}

pub const SpecError = enum { none, no_current, no_such, ambiguous };

/// Resolve a job specification (with or without the leading `%`).
pub fn resolve(sh: *Shell, spec: []const u8, err: *SpecError) ?*Job {
    err.* = .none;
    var s = spec;
    if (s.len > 0 and s[0] == '%') s = s[1..];
    if (s.len == 0 or std.mem.eql(u8, s, "%") or std.mem.eql(u8, s, "+")) {
        return current(sh) orelse {
            err.* = .no_current;
            return null;
        };
    }
    if (std.mem.eql(u8, s, "-")) {
        return previous(sh) orelse {
            err.* = .no_current;
            return null;
        };
    }
    if (num.parseInt(u32, s, 10)) |n| {
        return find(sh, n) orelse {
            err.* = .no_such;
            return null;
        };
    } else |_| {}
    const sub = s[0] == '?';
    const needle = if (sub) s[1..] else s;
    var found: ?*Job = null;
    for (sh.jobs.items) |j| {
        var buf: [1024]u8 = undefined;
        const t = jobText(j, &buf);
        const hit = if (sub) std.mem.indexOf(u8, t, needle) != null else std.mem.startsWith(u8, t, needle);
        if (hit) {
            if (found != null) {
                err.* = .ambiguous;
                return null;
            }
            found = j;
        }
    }
    if (found == null) err.* = .no_such;
    return found;
}

fn jobText(j: *const Job, buf: []u8) []const u8 {
    var n: usize = 0;
    for (j.procs.items, 0..) |p, i| {
        if (i > 0 and n < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        const k = @min(p.text.len, buf.len - n);
        @memcpy(buf[n .. n + k], p.text[0..k]);
        n += k;
        if (i + 1 < j.procs.items.len and n < buf.len) {
            buf[n] = ' ';
            n += 1;
            if (n < buf.len) {
                buf[n] = '|';
                n += 1;
            }
        }
    }
    return buf[0..n];
}

/// The job's command as `jobs` prints it ("a | b").
pub fn commandText(a: Allocator, j: *const Job) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (j.procs.items, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, " | ");
        try out.appendSlice(a, p.text);
    }
    return out.items;
}

// --- starting processes ------------------------------------------------------

/// Fork; with `job` the child joins the job's process group (the first
/// process leads it) and, for a foreground job on a terminal, takes the
/// terminal. Both sides do it so there is no race. Returns the child pid in
/// the parent and 0 in the child.
pub fn forkInto(sh: *Shell, job: ?*Job, text: []const u8, foreground: bool) sys.Error!i32 {
    const pid = try sys.fork();
    if (job) |j| {
        if (!(sh.jc and !sh.in_subshell)) {
            if (pid != 0) addPlain(sh, j, pid, text);
            return pid;
        }
        const pgid = if (j.pgid == 0) (if (pid == 0) sys.getpid() else pid) else j.pgid;
        if (pid == 0) {
            sys.setpgid(0, pgid) catch {};
            if (foreground and sh.tty_fd >= 0) sys.tcsetpgrp(sh.tty_fd, pgid) catch {};
            return 0;
        }
        sys.setpgid(pid, pgid) catch {};
        if (j.pgid == 0) j.pgid = pgid;
        j.grouped = true;
        const copy = sh.gpa.dupe(u8, text) catch return pid;
        j.procs.append(sh.gpa, .{ .pid = pid, .text = copy }) catch sh.gpa.free(copy);
    }
    return pid;
}

/// Add an already-forked process to a job (no process group).
pub fn addPlain(sh: *Shell, j: *Job, pid: i32, text: []const u8) void {
    const copy = sh.gpa.dupe(u8, text) catch return;
    j.procs.append(sh.gpa, .{ .pid = pid, .text = copy }) catch sh.gpa.free(copy);
}

// --- reaping and waiting ---------------------------------------------------------

fn findProc(sh: *Shell, pid: i32) ?struct { j: *Job, p: *Proc } {
    // Newest first, and not one already collected: the system gives a pid out
    // again once its process is gone.
    var k = sh.jobs.items.len;
    while (k > 0) {
        k -= 1;
        const j = sh.jobs.items[k];
        for (j.procs.items) |*p| if (p.pid == pid and p.state != .done) return .{ .j = j, .p = p };
    }
    return null;
}

fn apply(sh: *Shell, r: sys.WaitResult) void {
    const f = findProc(sh, r.pid) orelse return;
    if (sys.statusStopSignal(r.status) != 0) {
        f.p.state = .stopped;
        f.p.status = r.status;
        sh.job_stamp += 1;
        f.j.stamp = sh.job_stamp;
        f.j.notified = false;
    } else if (sys.statusContinued(r.status)) {
        f.p.state = .running;
    } else {
        f.p.state = .done;
        f.p.status = r.status;
    }
}

/// Collect state changes of children without blocking.
pub fn update(sh: *Shell) void {
    var flags: u32 = sys.WNOHANG;
    if (sh.jc) flags |= sys.WUNTRACED | sys.WCONTINUED;
    while (true) {
        const r = sys.waitpidFlags(-1, flags) catch {
            if (sys.errno() == sys.E_INTR) continue;
            return;
        };
        if (r.pid <= 0) return;
        apply(sh, r);
    }
}

/// `waitOne` for the `wait` builtin, which ^C and trapped signals end. One that
/// is already pending counts, and one cannot arrive unnoticed between looking
/// and sleeping: signals are held back until the sleep lets them in.
fn waitUnlessSignalled(sh: *Shell, interrupted: *bool) bool {
    var flags: u32 = sys.WNOHANG;
    if (sh.jc) flags |= sys.WUNTRACED | sys.WCONTINUED;
    const before = sys.blockSignals();
    defer sys.restoreMask(before);
    const added = sys.wakeOnChild();
    defer if (added) sys.restoreChild();
    while (true) {
        if (interrupting(sh) != null) {
            interrupted.* = true;
            return false;
        }
        const r = sys.waitpidFlags(-1, flags) catch {
            if (sys.errno() == sys.E_INTR) continue;
            return false;
        };
        if (r.pid > 0) {
            apply(sh, r);
            return true;
        }
        sys.suspendUntilSignal(&before);
    }
}

/// The pending signal that is to interrupt a `wait`: SIGINT, or one the user
/// has a trap for.
pub fn interrupting(sh: *const Shell) ?u8 {
    var s: u8 = 1;
    while (s < sys.nsig) : (s += 1) {
        if (!sys.peekPending(s)) continue;
        if (s == 2) return s;
        if (sh.traps[s]) |t| if (t.len > 0) return s;
    }
    return null;
}

/// Block until some child changes state and record it; false when there is
/// no child left or the wait was interrupted by a signal (reported through
/// `interrupted`).
fn waitOne(sh: *Shell, interrupted: *bool, interruptible: bool) bool {
    if (interruptible) return waitUnlessSignalled(sh, interrupted);
    var flags: u32 = 0;
    if (sh.jc) flags |= sys.WUNTRACED | sys.WCONTINUED;
    while (true) {
        const r = sys.waitpidFlags(-1, flags) catch {
            if (sys.errno() == sys.E_INTR) continue;
            return false;
        };
        if (r.pid <= 0) return false;
        apply(sh, r);
        return true;
    }
}

const signal_text = [_][]const u8{
    "", "Hangup", "Interrupt", "Quit", "Illegal instruction", "Trace/breakpoint trap", "Aborted", "Bus error", "Floating point exception", "Killed", "User defined signal 1", "Segmentation fault", "User defined signal 2", "Broken pipe", "Alarm clock", "Terminated", "Stack fault", "Child exited", "Continued", "Stopped (signal)", "Stopped", "Stopped (tty input)", "Stopped (tty output)", "Urgent I/O condition", "CPU time limit exceeded", "File size limit exceeded", "Virtual timer expired", "Profiling timer expired", "Window changed", "I/O possible", "Power failure", "Bad system call",
};

pub fn signalText(sig: u8) []const u8 {
    if (sig < signal_text.len and signal_text[sig].len > 0) return signal_text[sig];
    return "Unknown signal";
}

fn stateText(a: Allocator, p: Proc) []const u8 {
    switch (p.state) {
        .running => return "Running",
        .stopped => {
            const sig = sys.statusStopSignal(p.status);
            if (sig == 20) return "Stopped";
            if (sig < sys.signal_names.len) return std.fmt.allocPrint(a, "Stopped(SIG{s})", .{sys.signal_names[sig]}) catch "Stopped";
            return "Stopped";
        },
        .done => {
            const sig = sys.statusSignal(p.status);
            if (sig != 0) return std.fmt.allocPrint(a, "{s}{s}", .{ signalText(sig), if (sys.statusCoreDumped(p.status)) " (core dumped)" else "" }) catch "Killed";
            const c = sys.statusCode(p.status);
            if (c == 0) return "Done";
            return std.fmt.allocPrint(a, "Done({d})", .{c}) catch "Done";
        },
    }
}

/// Aggregate state text of a whole job: the first process that is not done
/// decides, else the first abnormal one.
fn jobStateText(a: Allocator, j: *const Job) []const u8 {
    for (j.procs.items) |p| if (p.state == .stopped) return stateText(a, p);
    for (j.procs.items) |p| if (p.state == .running) return "Running";
    var last: ?Proc = null;
    for (j.procs.items) |p| last = p;
    if (last) |p| return stateText(a, p);
    return "Done";
}

pub const ListMode = enum { short, long, pids };

/// Append the report of one job in the format of `jobs`.
pub fn format(sh: *const Shell, a: Allocator, out: *std.ArrayList(u8), j: *const Job, mode: ListMode) Allocator.Error!void {
    if (mode == .pids) {
        // the process group leader of each job: its first process (POSIX jobs -p)
        if (j.procs.items.len > 0) try out.print(a, "{d}\n", .{j.procs.items[0].pid});
        return;
    }
    const mk = marker(sh, j);
    try out.append(a, '\n');
    out.items.len -= 1;
    if (mode == .short or j.procs.items.len == 0) {
        const head = try std.fmt.allocPrint(a, "[{d}] {c} {s}", .{ j.id, mk, jobStateText(a, j) });
        try out.appendSlice(a, head);
        try padLine(out, a, head.len, 33);
        for (j.procs.items, 0..) |p, i| {
            if (i > 0) try out.appendSlice(a, " | ");
            try out.appendSlice(a, p.text);
        }
        try out.append(a, '\n');
        return;
    }
    for (j.procs.items, 0..) |p, i| {
        const head = if (i == 0)
            try std.fmt.allocPrint(a, "[{d}] {c} {d} {s}", .{ j.id, mk, p.pid, stateText(a, p) })
        else
            try std.fmt.allocPrint(a, "      {d}{s}{s}", .{ p.pid, if (std.mem.eql(u8, stateText(a, p), stateText(a, j.procs.items[0]))) "" else " ", if (std.mem.eql(u8, stateText(a, p), stateText(a, j.procs.items[0]))) "" else stateText(a, p) });
        try out.appendSlice(a, head);
        try padLine(out, a, head.len, 33);
        try out.appendSlice(a, p.text);
        if (i + 1 < j.procs.items.len) try out.appendSlice(a, " |");
        try out.append(a, '\n');
    }
}

fn padLine(out: *std.ArrayList(u8), a: Allocator, have: usize, to: usize) !void {
    var n = have;
    if (n >= to) {
        try out.append(a, ' ');
        return;
    }
    while (n < to) : (n += 1) try out.append(a, ' ');
}

/// Report finished and stopped jobs that the user has not been told about
/// (before a prompt) and forget the finished ones. Output goes to standard
/// error like dash's.
pub fn notify(sh: *Shell) void {
    update(sh);
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    // Oldest first, like the order the user started them.
    var tmp: std.ArrayList(*Job) = .empty;
    for (sh.jobs.items) |j| tmp.append(a, j) catch return;
    std.mem.sort(*Job, tmp.items, {}, struct {
        fn lt(_: void, l: *Job, r: *Job) bool {
            return l.id < r.id;
        }
    }.lt);
    for (tmp.items) |j| {
        if (j.foreground) continue;
        const st = j.state();
        if (st == .running) continue;
        if (!j.notified) {
            format(sh, a, &out, j, .short) catch return;
            j.notified = true;
        }
        if (st == .done) remove(sh, j);
    }
    if (out.items.len > 0) sh.errRaw(out.items);
}

fn handBack(sh: *Shell) void {
    if (sh.tty_fd < 0) return;
    sys.tcsetpgrp(sh.tty_fd, sh.shell_pgid) catch {};
    if (sh.tty_modes) |*m| sys.tcsetattr(sh.tty_fd, m) catch {};
}

/// Finish a job whose processes can no longer be waited for. Their statuses are
/// unknown, which must not look like success.
fn lostChildren(j: *Job) void {
    for (j.procs.items) |*p| if (p.state == .running) {
        p.state = .done;
        p.status = 127 << 8; // wait(2) form of exit status 127
    };
}

/// Wait for a foreground job. Returns its status; a stopped job reports
/// 128+signal and is kept in the table.
pub fn waitFg(sh: *Shell, j: *Job) u8 {
    j.foreground = true;
    if (sh.tty_fd >= 0 and j.pgid != 0) sys.tcsetpgrp(sh.tty_fd, j.pgid) catch {};
    var intr = false;
    while (j.state() == .running) {
        if (!waitOne(sh, &intr, false)) {
            if (intr) {
                intr = false;
                continue;
            }
            // No such child (someone else reaped it).
            lostChildren(j);
        }
    }
    j.foreground = false;
    handBack(sh);
    const st = j.state();
    const code = j.status(sh.flags.pipefail);
    if (st == .stopped) {
        j.notified = true;
        var arena = std.heap.ArenaAllocator.init(sh.gpa);
        defer arena.deinit();
        var out: std.ArrayList(u8) = .empty;
        format(sh, arena.allocator(), &out, j, .short) catch {};
        sh.errRaw(out.items);
        return code;
    }
    // Report death by signal the way dash does (not for INT and PIPE).
    const last = j.procs.items[j.procs.items.len - 1];
    const sig = sys.statusSignal(last.status);
    if (sig != 0 and sig != 2 and sig != 13) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ signalText(sig), if (sys.statusCoreDumped(last.status)) " (core dumped)" else "" }) catch "";
        sh.errRaw(msg);
    } else if (sig == 2 and sh.tty_fd >= 0 and !(sh.flags.interactive and sh.traps[2] == null)) sh.errRaw("\n");
    // With job control the terminal's SIGINT reaches only the job. It was meant
    // for the commands around it too, so the shell sends it to itself: its trap
    // runs, a script ends, an interactive shell goes back to its prompt.
    const interrupted = sig == 2 and j.grouped;
    remove(sh, j);
    if (interrupted) {
        // With nothing here to catch it, the signal would be the host's.
        if (sh.keep_process and !sh.in_subshell and !sh.flags.interactive and sh.traps[2] == null) {
            sh.status = code;
            sh.flow = .exit_shell;
        } else sys.kill(sys.getpid(), 2) catch {};
    }
    return code;
}

/// Wait (for `wait` and `fg`) until `j` is no longer running. Returns false
/// when interrupted by a signal.
pub fn waitJob(sh: *Shell, j: *Job) bool {
    var intr = false;
    while (j.state() == .running) {
        if (!waitOne(sh, &intr, true)) {
            if (intr) return false;
            lostChildren(j);
        }
    }
    return true;
}

pub fn anyRunning(sh: *const Shell) bool {
    for (sh.jobs.items) |j| if (j.state() == .running) return true;
    return false;
}

pub fn anyStopped(sh: *const Shell) bool {
    for (sh.jobs.items) |j| if (j.state() == .stopped) return true;
    return false;
}

pub fn continueJob(sh: *Shell, j: *Job) void {
    for (j.procs.items) |*p| if (p.state == .stopped) {
        p.state = .running;
    };
    j.notified = false;
    if (j.pgid != 0 and j.grouped) sys.killpg(j.pgid, 18) catch {} else for (j.procs.items) |p| sys.kill(p.pid, 18) catch {};
    _ = sh;
}

// --- enabling job control ---------------------------------------------------------

/// Turn job control on (`set -m`). Finds the terminal, takes a process group
/// of its own and the terminal's foreground. Returns false (no group changes)
/// when there is no controlling terminal and `need_tty`.
pub fn enable(sh: *Shell, need_tty: bool) bool {
    if (sh.jc) return true;
    var tty: i32 = -1;
    for ([_]i32{ 2, 0, 1 }) |fd| if (sys.isatty(fd)) {
        tty = sys.dupAbove(fd, 10) catch -1;
        break;
    };
    const orig_pgrp = sys.getpgrp();
    if (tty >= 0 and !awaitForeground(sh, tty)) {
        sys.close(tty);
        tty = -1;
    }
    if (tty < 0 and need_tty) return false;
    if (tty >= 0) {
        sys.setCloexec(tty, true);
        sh.orig_pgrp = orig_pgrp;
        sh.ignoreJobSignals();
        sys.setpgid(0, 0) catch {};
        sh.shell_pgid = sys.getpgrp();
        sys.tcsetpgrp(tty, sh.shell_pgid) catch {};
        sh.tty_modes = sys.tcgetattr(tty) catch null;
    } else {
        sh.shell_pgid = sys.getpgrp();
    }
    sh.tty_fd = tty;
    sh.jc = true;
    return true;
}

/// Whether this shell may take the terminal: only from the foreground. An
/// interactive shell in the background stops itself until it is brought there; a
/// script does without the terminal.
fn awaitForeground(sh: *Shell, tty: i32) bool {
    var tries: u32 = 0;
    while (true) {
        const fg = sys.tcgetpgrp(tty) catch return false;
        if (fg == sys.getpgrp()) return true;
        // `tries`: the system does not stop an orphaned process group
        if (!sh.flags.interactive or tries == 100) return false;
        tries += 1;
        // the signal must be able to stop us, whatever was inherited
        const before = sys.getSignal(21);
        _ = sys.setSignal(21, .default);
        sys.kill(0, 21) catch {};
        _ = sys.setSignal(21, before);
    }
}

/// Turn job control off (`set +m`, or the shell is leaving), giving the
/// terminal back to whoever had it.
pub fn disable(sh: *Shell) void {
    if (!sh.jc) return;
    sh.jc = false;
    if (sh.tty_fd < 0) return;
    // a subshell only forgets: the terminal is its parent's business
    if (!sh.in_subshell) {
        // the shell may have taken it from another group, which waits for it
        if (sh.orig_pgrp != sh.shell_pgid) {
            if (sys.setpgid(0, sh.orig_pgrp)) |_| {
                const fg = sys.tcgetpgrp(sh.tty_fd) catch 0;
                if (fg == sh.shell_pgid) sys.tcsetpgrp(sh.tty_fd, sh.orig_pgrp) catch {};
                sh.shell_pgid = sh.orig_pgrp;
            } else |_| {}
        }
        // an interactive shell goes on ignoring them after `set +m`: what it
        // then runs shares its group, and ^Z must not stop that for good
        if (!sh.flags.interactive) sh.restoreJobSignals();
    }
    sys.close(sh.tty_fd);
    sh.tty_fd = -1;
}

/// At exit: tell stopped jobs to hang up (they would never see the terminal
/// again).
pub fn hangupAll(sh: *Shell) void {
    for (sh.jobs.items) |j| {
        if (j.state() == .stopped and j.pgid != 0) {
            sys.killpg(j.pgid, 1) catch {};
            sys.killpg(j.pgid, 18) catch {};
        }
    }
}

// --- command text ----------------------------------------------------------------

/// Reconstruct shell text for a command (job descriptions).
pub fn unparse(a: Allocator, node: *const ast.Node) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeNode(a, &out, node);
    return out.toOwnedSlice(a);
}

fn writeWord(a: Allocator, out: *std.ArrayList(u8), w: ast.Word) Allocator.Error!void {
    for (w) |part| switch (part) {
        .text => |t| try out.appendSlice(a, t),
        .quoted => |t| {
            var plain = t.len > 0;
            for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/' or c == ',' or c == ':' or c == '=' or c == '+' or c == '@')) {
                plain = false;
            };
            if (plain) {
                try out.appendSlice(a, t);
            } else if (std.mem.indexOfScalar(u8, t, '\'') == null) {
                try out.append(a, '\'');
                try out.appendSlice(a, t);
                try out.append(a, '\'');
            } else {
                try out.append(a, '"');
                try out.appendSlice(a, t);
                try out.append(a, '"');
            }
        },
        .tilde, .atilde => |t| {
            try out.append(a, '~');
            try out.appendSlice(a, t);
        },
        .param => |p| {
            if (p.op == .length) {
                try out.print(a, "${{#{s}}}", .{p.name});
            } else if (p.op == .plain) {
                if (p.name.len == 1 and !std.ascii.isAlphanumeric(p.name[0]) or p.name.len > 1 and !std.ascii.isDigit(p.name[0]) or p.name.len == 1) {
                    try out.print(a, "${s}", .{p.name});
                } else try out.print(a, "${{{s}}}", .{p.name});
            } else {
                const op: []const u8 = switch (p.op) {
                    .use_default => "-",
                    .assign_default => "=",
                    .error_if_unset => "?",
                    .use_alternate => "+",
                    .trim_prefix_small => "#",
                    .trim_prefix_large => "##",
                    .trim_suffix_small => "%",
                    .trim_suffix_large => "%%",
                    else => "",
                };
                try out.print(a, "${{{s}{s}{s}", .{ p.name, if (p.colon) ":" else "", op });
                try writeWord(a, out, p.arg);
                try out.append(a, '}');
            }
        },
        .cmdsub => |c| {
            try out.appendSlice(a, "$(");
            if (c.body) |b| try writeNode(a, out, b);
            try out.append(a, ')');
        },
        .arith => |ar| {
            try out.appendSlice(a, "$((");
            try writeWord(a, out, ar.expr);
            try out.appendSlice(a, "))");
        },
    };
}

fn writeBody(a: Allocator, out: *std.ArrayList(u8), n: ?*const ast.Node) Allocator.Error!void {
    if (n) |b| try writeNode(a, out, b);
}

fn writeRedir(a: Allocator, out: *std.ArrayList(u8), r: *const ast.Redirect) Allocator.Error!void {
    if (r.fd) |fd| try out.print(a, "{d}", .{fd});
    try out.appendSlice(a, switch (r.op) {
        .in => "<",
        .out => ">",
        .append => ">>",
        .clobber => ">|",
        .dup_in => "<&",
        .dup_out => ">&",
        .read_write => "<>",
        .heredoc => "<<",
    });
    try writeWord(a, out, r.target);
}

fn writeNode(a: Allocator, out: *std.ArrayList(u8), node: *const ast.Node) Allocator.Error!void {
    switch (node.kind) {
        .simple => |s| {
            var first = true;
            for (s.assigns) |asg| {
                if (!first) try out.append(a, ' ');
                first = false;
                try out.print(a, "{s}=", .{asg.name});
                try writeWord(a, out, asg.value);
            }
            for (s.words) |w| {
                if (!first) try out.append(a, ' ');
                first = false;
                try writeWord(a, out, w);
            }
            for (s.redirs) |r| {
                if (!first) try out.append(a, ' ');
                first = false;
                try writeRedir(a, out, r);
            }
        },
        .pipeline => |p| {
            if (p.negate) try out.appendSlice(a, "! ");
            for (p.commands, 0..) |c, i| {
                if (i > 0) try out.appendSlice(a, " | ");
                try writeNode(a, out, c);
            }
        },
        .and_or => |ao| {
            try writeNode(a, out, ao.left);
            try out.appendSlice(a, if (ao.op == .and_if) " && " else " || ");
            try writeNode(a, out, ao.right);
        },
        .list => |items| for (items, 0..) |it, i| {
            if (i > 0) try out.appendSlice(a, if (items[i - 1].background) " " else "; ");
            try writeNode(a, out, it.node);
            if (it.background) try out.appendSlice(a, " &");
        },
        .subshell => |b| {
            try out.append(a, '(');
            try writeBody(a, out, b);
            try out.append(a, ')');
        },
        .group => |b| {
            try out.appendSlice(a, "{ ");
            try writeBody(a, out, b);
            try out.appendSlice(a, "; }");
        },
        .redirected => |r| {
            try writeNode(a, out, r.body);
            for (r.redirs) |rd| {
                try out.append(a, ' ');
                try writeRedir(a, out, rd);
            }
        },
        .if_clause => |c| {
            try out.appendSlice(a, "if ");
            try writeNode(a, out, c.cond);
            try out.appendSlice(a, "; then ");
            try writeBody(a, out, c.then);
            if (c.otherwise) |o| {
                try out.appendSlice(a, "; else ");
                try writeNode(a, out, o);
            }
            try out.appendSlice(a, "; fi");
        },
        .loop => |l| {
            try out.appendSlice(a, if (l.until) "until " else "while ");
            try writeNode(a, out, l.cond);
            try out.appendSlice(a, "; do ");
            try writeBody(a, out, l.body);
            try out.appendSlice(a, "; done");
        },
        .for_clause => |f| {
            try out.print(a, "for {s}", .{f.name});
            if (f.words) |ws| {
                try out.appendSlice(a, " in");
                for (ws) |w| {
                    try out.append(a, ' ');
                    try writeWord(a, out, w);
                }
            }
            try out.appendSlice(a, "; do ");
            try writeBody(a, out, f.body);
            try out.appendSlice(a, "; done");
        },
        .case_clause => |c| {
            try out.appendSlice(a, "case ");
            try writeWord(a, out, c.word);
            try out.appendSlice(a, " in ");
            for (c.items) |it| {
                for (it.patterns, 0..) |p, i| {
                    if (i > 0) try out.append(a, '|');
                    try writeWord(a, out, p);
                }
                try out.appendSlice(a, ") ");
                try writeBody(a, out, it.body);
                try out.appendSlice(a, ";; ");
            }
            try out.appendSlice(a, "esac");
        },
        .function => |f| try out.print(a, "{s}() {{ ... }}", .{f.name}),
    }
}

test "unparse of a pipeline text" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: parser.Diag = .{};
    var p = parser.Parser.init(arena.allocator(), "sleep 5 | cat 'a b' $x", &d);
    const n = (try p.nextCommand()).?;
    const t = try unparse(arena.allocator(), n);
    try std.testing.expectEqualStrings("sleep 5 | cat 'a b' $x", t);
}
