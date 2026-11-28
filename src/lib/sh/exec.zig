// SPDX-License-Identifier: GPL-2.0-or-later
//! Execution of parsed commands: simple and compound commands, pipelines,
//! lists, functions, redirections, subshells, command substitution and
//! external programs.
//!
//! Subshells, background commands, pipeline stages and command substitution
//! `fork` (docs/std-io-gaps.md rows 17-27) and the child keeps interpreting;
//! external programs are `execve`d after the redirections have been applied
//! with `dup2` in the child.
//!
//! References: POSIX.1-2024 Shell Command Language 2.8 "Shell Execution
//! Environment", 2.9 "Shell Commands", 2.11 "Signals and Error Handling",
//! 2.12 "Shell Execution Environment"; exit statuses 126/127 per 2.8.2.

const std = @import("std");
const num = @import("../num.zig");
const sys = @import("../../sys.zig");
const osio = @import("osio.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const expand = @import("expand.zig");
const pattern = @import("pattern.zig");
const builtins = @import("builtins.zig");
const lexer = @import("lexer.zig");
const diagmod = @import("diag.zig");
const shell = @import("shell.zig");
const jobs = @import("jobs.zig");
const Shell = shell.Shell;
const Node = ast.Node;
const Allocator = std.mem.Allocator;

// --- running source text ----------------------------------------------------

pub const RunOpts = struct {
    /// Diagnostics for a syntax error are prefixed with this (e.g. `eval`).
    prefix: []const u8 = "",
};

fn aliasGet(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const sh: *Shell = @ptrCast(@alignCast(ctx));
    return sh.aliases.get(name);
}

/// Parse and execute `src` one complete command at a time.
pub fn runSource(sh: *Shell, src_in: []const u8, o: RunOpts) error{OutOfMemory}!u8 {
    const unit = try shell.Unit.create(sh.gpa);
    defer unit.release();
    const outer_unit = sh.cur_unit;
    sh.cur_unit = unit;
    defer sh.cur_unit = outer_unit;
    const a = unit.arena.allocator();
    // NUL bytes in a script are ignored (dash, FreeBSD sh)
    const src = if (std.mem.indexOfScalar(u8, src_in, 0) != null) blk: {
        var clean: std.ArrayList(u8) = .empty;
        for (src_in) |c| if (c != 0) try clean.append(a, c);
        break :blk clean.items;
    } else src_in;
    var d: parser.Diag = .{};
    var p = try parser.Parser.initProgram(a, src, &d);
    p.aliases = .{ .ctx = sh, .get = aliasGet };
    const saved_src = sh.cur_src;
    const saved_start = sh.cur_src_start;
    sh.cur_src = src;
    sh.cur_src_start = 1;
    defer {
        sh.cur_src = saved_src;
        sh.cur_src_start = saved_start;
    }
    var last: u8 = 0;
    var echoed: usize = 0; // how much of `src` `set -v` has been through
    while (true) {
        const maybe = p.nextCommand() catch |e| switch (e) {
            error.Syntax => {
                sh.line = d.line;
                reportSyntax(sh, &d, o.prefix, src);
                sh.status = 2;
                // `command eval 'bad'` is a regular builtin call: it fails, the shell goes on
                if (!(sh.no_die > 0 and o.prefix.len > 0)) sh.flow = .exit_shell;
                last = 2;
                break;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (p.warn_heredoc) |w| {
            p.warn_heredoc = null;
            var wd: diagmod.Diagnostic = .{ .code = 1003, .kind = .unterminated_heredoc, .severity = .warning, .label = sh.label, .line = w.line, .subject = w.delim, .posix = "here-document delimited by end-of-file", .source = src };
            sh.emit(&wd);
        }
        const node = maybe orelse break;
        // (`p.pos` is no place in `src` once an alias has been put in)
        const end = src.len - @min(p.origTailLen(), src.len);
        if (sh.flags.verbose and end > echoed) sh.errRaw(std.mem.trimStart(u8, src[echoed..end], "\n"));
        echoed = @max(echoed, end);
        if (sh.flags.noexec) continue;
        last = execNode(sh, node);
        jobs.reap(sh);
        checkTraps(sh);
        if (sh.flow != .none) break;
    }
    return last;
}

/// Run a script read from descriptor `fd` incrementally, as dash does: a
/// command is parsed and executed as soon as it is complete, so a command
/// that reads standard input (`cat`, `read`) sees whatever the shell has not
/// yet buffered. The shell reads 8192 bytes at a time, like dash.
/// True when `text` ends in a backslash-newline: the line goes on.
fn endsInContinuation(text: []const u8) bool {
    if (!std.mem.endsWith(u8, text, "\n")) return false;
    const body = text[0 .. text.len - 1];
    return (body.len - std.mem.trimEnd(u8, body, "\\").len) % 2 == 1;
}

/// How much of a script read from a descriptor is held on to after it has run.
const stream_keep = 64 * 1024;

pub fn runStream(sh: *Shell, fd: i32) error{OutOfMemory}!u8 {
    const gpa = sh.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var start: usize = 0;
    var line: u32 = 1;
    var eof = false;
    var last: u8 = 0;
    const outer_unit = sh.cur_unit;
    defer sh.cur_unit = outer_unit;
    const saved_src = sh.cur_src;
    const saved_start = sh.cur_src_start;
    defer {
        sh.cur_src = saved_src;
        sh.cur_src_start = saved_start;
    }
    // the line `buf` starts with
    var first_line: u32 = 1;
    var chunk: [8192]u8 = undefined;
    // alias text the last command's parser had not reached, and its storage
    var carry: parser.Carry = .{};
    var carry_store = std.heap.ArenaAllocator.init(gpa);
    defer carry_store.deinit();
    while (true) {
        // What has been run is let go, in whole lines, or the shell would keep
        // all it was ever fed. Enough stays for a diagnostic to quote.
        if (start > 2 * stream_keep) {
            if (std.mem.lastIndexOfScalar(u8, buf.items[0 .. start - stream_keep], '\n')) |nl| {
                const cut = nl + 1;
                first_line += @intCast(std.mem.count(u8, buf.items[0..cut], "\n"));
                buf.replaceRange(gpa, 0, cut, "") catch unreachable; // it only shrinks
                start -= cut;
            }
        }
        sh.cur_src = buf.items;
        sh.cur_src_start = first_line;
        const unit = try shell.Unit.create(gpa);
        const a = unit.arena.allocator();
        const text = a.dupe(u8, buf.items[start..]) catch {
            unit.release();
            return error.OutOfMemory;
        };
        var d: parser.Diag = .{};
        var p = parser.Parser.initProgram(a, text, &d) catch {
            unit.release();
            return error.OutOfMemory;
        };
        p.line = line;
        p.aliases = .{ .ctx = sh, .get = aliasGet };
        p.resumeAlias(carry) catch {
            unit.release();
            return error.OutOfMemory;
        };
        const maybe = p.nextCommand() catch |e| switch (e) {
            error.Syntax => {
                if (!eof and p.pos >= p.src.len) {
                    unit.release();
                    eof = readMore(gpa, &buf, fd, &chunk) catch |re| switch (re) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ReadFailed => return readFailed(sh),
                    };
                    continue;
                }
                sh.cur_src = buf.items;
                sh.line = d.line;
                sh.cur_src_start = first_line;
                reportSyntax(sh, &d, "", buf.items);
                sh.status = 2;
                sh.flow = .exit_shell;
                unit.release();
                return 2;
            },
            error.OutOfMemory => {
                unit.release();
                return error.OutOfMemory;
            },
        };
        const tail = p.origTailLen();
        const complete = eof or (p.pos < p.src.len) or (std.mem.endsWith(u8, p.src, "\n") and !endsInContinuation(p.src));
        if (!eof and (maybe == null or !complete or p.warn_heredoc != null)) {
            // An open here-document cannot end before its delimiter has been
            // read: parsing again after every chunk would be quadratic. The
            // reads themselves are the same, so no more of the input is taken.
            var delim_store: [128]u8 = undefined;
            const delim: ?[]const u8 = if (p.warn_heredoc) |w| (std.fmt.bufPrint(&delim_store, "{s}\n", .{w.delim}) catch null) else null;
            unit.release();
            while (true) {
                const had = buf.items.len;
                eof = readMore(gpa, &buf, fd, &chunk) catch |re| switch (re) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ReadFailed => return readFailed(sh),
                };
                const end = delim orelse break;
                // from a little before: the line may straddle two reads
                if (eof or mayEndHeredoc(buf.items[had -| end.len..], end)) break;
            }
            continue;
        }
        if (p.warn_heredoc) |w| {
            p.warn_heredoc = null;
            sh.cur_src = buf.items;
            var wd: diagmod.Diagnostic = .{ .code = 1003, .kind = .unterminated_heredoc, .severity = .warning, .label = sh.label, .line = w.line, .subject = w.delim, .posix = "here-document delimited by end-of-file", .source = buf.items, .source_start = first_line };
            sh.emit(&wd);
        }
        const node = maybe orelse {
            unit.release();
            break;
        };
        const consumed = text.len - @min(tail, text.len);
        // `carry` was copied into this parser's arena, so its store can be reused
        _ = carry_store.reset(.retain_capacity);
        carry = p.aliasCarry(carry_store.allocator()) catch {
            unit.release();
            return error.OutOfMemory;
        };
        sh.cur_src = buf.items;
        if (sh.flags.verbose and consumed > 0) sh.errRaw(std.mem.trimStart(u8, text[0..consumed], "\n"));
        start += consumed;
        line = p.line;
        if (!sh.flags.noexec) {
            sh.cur_unit = unit;
            defer sh.cur_unit = outer_unit;
            last = execNode(sh, node);
            checkTraps(sh);
        }
        unit.release();
        if (sh.flow != .none) break;
    }
    return last;
}

/// Whether `text` may hold the end of a here-document whose delimiter line is
/// `delim_line`. A backslash-newline can join a line into the delimiter.
fn mayEndHeredoc(text: []const u8, delim_line: []const u8) bool {
    return std.mem.indexOf(u8, text, delim_line) != null or std.mem.indexOf(u8, text, "\\\n") != null;
}

/// Append more of the script to `buf`; true at its end. A failure is never
/// taken for the end: what has been read may stop in the middle of a command.
fn readMore(gpa: Allocator, buf: *std.ArrayList(u8), fd: i32, chunk: *[8192]u8) error{ OutOfMemory, ReadFailed }!bool {
    while (true) {
        const n = sys.read(fd, chunk) catch {
            if (sys.errno() == sys.E_INTR) continue;
            // a descriptor someone left non-blocking (dash turns that off too)
            if (sys.errno() == sys.E_AGAIN and sys.setBlocking(fd)) continue;
            return error.ReadFailed;
        };
        if (n == 0) return true;
        // NUL bytes in a script are ignored (dash, FreeBSD sh; POSIX leaves them undefined)
        var kept: usize = 0;
        for (chunk[0..n]) |c| if (c != 0) {
            chunk[kept] = c;
            kept += 1;
        };
        try buf.appendSlice(gpa, chunk[0..kept]);
        return false;
    }
}

/// The script cannot be read: the shell stops with a failure.
fn readFailed(sh: *Shell) u8 {
    sh.diagK(.other, null, "error reading the script: {s}", .{sys.strerror(sys.errno())});
    sh.status = 2;
    sh.flow = .exit_shell;
    return 2;
}

fn reportSyntax(sh: *Shell, d: *const parser.Diag, prefix: []const u8, src: []const u8) void {
    var buf: [400]u8 = undefined;
    const text = if (prefix.len > 0) (std.fmt.bufPrint(&buf, "{s}: {s}", .{ prefix, d.message() }) catch d.message()) else d.message();
    const e = diagmod.entryOf(d.kind);
    var dd: diagmod.Diagnostic = .{
        .code = e.code,
        .kind = d.kind,
        .label = sh.label,
        .line = d.line,
        .column = d.col,
        .end_column = d.end_col,
        .token = d.token,
        .expected = d.expected,
        .opener = d.opener,
        .subject = d.token,
        .posix = text,
        .source = src,
        .source_start = sh.cur_src_start,
    };
    if (d.kind == .unterminated_quote or d.kind == .unterminated_arithmetic) dd.subject = if (d.opener) |o| o.name else "";
    if (d.kind == .missing_redirect_target) dd.subject = d.expected;
    if (d.kind == .bad_function_name) dd.subject = d.token;
    if (d.kind == .bad_for_variable) dd.subject = d.token;
    sh.emit(&dd);
}

// --- traps ------------------------------------------------------------------

/// Whether SIGINT without a trap abandons the commands being run.
fn abandons(sh: *const Shell) bool {
    return sh.flags.interactive and !sh.in_subshell;
}

fn interrupt(sh: *Shell) void {
    sh.flow = .interrupt;
    sh.status = 130;
}

/// ^C while a command's words were being expanded (a command substitution it
/// killed): the command must not run with what is left.
fn interruptedExpanding(sh: *Shell) bool {
    if (sh.flow == .interrupt) return true;
    if (!abandons(sh) or sh.traps[2] != null or !sys.takePending(2)) return false;
    interrupt(sh);
    return true;
}

/// Run the trap commands of signals that arrived since the last check.
pub fn checkTraps(sh: *Shell) void {
    if (!sys.signalsPending()) return;
    sys.clearPendingAny();
    var sig: u8 = 1;
    while (sig < sys.nsig) : (sig += 1) {
        if (!sys.takePending(sig)) continue;
        const cmd = sh.traps[sig] orelse {
            if (sig == 2 and abandons(sh)) interrupt(sh);
            continue;
        };
        if (cmd.len == 0) continue;
        const saved = sh.status;
        const copy = sh.gpa.dupe(u8, cmd) catch |oe| {
            _ = sh.oom(oe);
            return;
        };
        defer sh.gpa.free(copy);
        const prev_ts = sh.trap_status;
        sh.trap_status = saved;
        defer sh.trap_status = prev_ts;
        sh.in_trap += 1;
        const saved_flow = sh.flow;
        sh.flow = .none;
        _ = runSource(sh, copy, .{}) catch |oe| sh.oom(oe);
        sh.in_trap -= 1;
        if (sh.flow == .none) {
            sh.flow = saved_flow;
            sh.status = saved;
        }
    }
}

/// Run (once) the trap set for `EXIT`.
pub fn runExitTrap(sh: *Shell) void {
    const cmd = sh.traps[0] orelse return;
    sh.traps[0] = null;
    defer sh.gpa.free(cmd);
    if (cmd.len == 0) return;
    const saved = sh.status;
    sh.flow = .none;
    sh.trap_status = saved;
    _ = runSource(sh, cmd, .{}) catch |oe| sh.oom(oe);
    if (sh.flow != .exit_shell) sh.status = saved;
}

// --- helpers ----------------------------------------------------------------

fn xerr(sh: *Shell, e: expand.Error) u8 {
    switch (e) {
        error.Fatal => return sh.status,
        error.OutOfMemory => {
            sh.diagK(.other, null, "out of memory", .{});
            sh.flow = .exit_shell;
            sh.status = 2;
            return 2;
        },
    }
}

fn errexitCheck(sh: *Shell, st: u8, what: []const u8) void {
    if (st != 0 and sh.flags.errexit and sh.noerrexit == 0 and sh.flow == .none) {
        sh.flow = .exit_shell;
        sh.status = st;
        // Rich and JSON styles say which command ended the shell; the posix
        // style stays silent (POSIX prints nothing here).
        var d: diagmod.Diagnostic = .{ .code = 4005, .kind = .errexit_exit, .severity = .warning, .label = sh.label, .line = sh.line, .column = sh.cur_col, .end_column = sh.cur_end_col, .subject = what, .posix = "", .source = sh.cur_src, .source_start = sh.cur_src_start };
        sh.emit(&d);
    }
}

/// Wait for `pid`; on termination by a signal print dash's message.
pub fn waitFor(sh: *Shell, pid: i32, report: bool) u8 {
    while (true) {
        const r = sys.waitpid(pid, false) catch {
            if (sys.errno() == sys.E_INTR) continue;
            return 127;
        };
        if (report) {
            // as dash: nothing for INT, PIPE, CHLD or a real-time signal
            const sig = sys.statusSignal(r.status);
            if (sig != 0 and sig != 2 and sig != 13 and sig != sys.SIGCHLD and sig < 32) jobs.reportDeath(sh, r.status);
        }
        return sys.statusCode(r.status);
    }
}

fn childInit(sh: *Shell, bg: bool) void {
    const was_subshell = sh.in_subshell;
    sh.in_subshell = true;
    sh.trap_set = @splat(false);
    jobs.clearAll(sh);
    sys.clearPendingAll();
    if (sh.flags.interactive and !was_subshell) {
        // The interactive shell's own dispositions must not leak into
        // commands (POSIX XCU sh "Signals").
        // A child without a process group of its own shares the shell's: were
        // it stopped by ^Z, the shell, which ignores that signal, would wait
        // for it for ever. It keeps the job-control signals ignored.
        const own_group = sh.jc and sys.getpgrp() != sh.shell_pgid;
        for ([_]u8{ 2, 3, 15, 20, 21, 22 }) |sg| {
            if (sg >= 20 and !own_group) continue;
            // a `trap '' SIG` the user set stays in force for the child and what it runs
            const user_ignored = if (sh.traps[sg]) |t| t.len == 0 else false;
            if (!sh.inherited_ignore[sg] and !user_ignored) _ = sys.setSignal(sg, .default);
        }
    }
    // a script with `set -m`: what runs in a group of its own can be stopped
    // and continued, so it gets the signals back (see above for the others)
    if (!sh.flags.interactive and sh.jc and sys.getpgrp() != sh.shell_pgid) sh.restoreJobSignals();
    var i: u8 = 0;
    while (i < sys.nsig) : (i += 1) {
        if (sh.traps[i]) |t| {
            if (t.len > 0 or i == 0) {
                if (sh.parent_traps[i]) |old| sh.gpa.free(old);
                sh.parent_traps[i] = t;
                sh.traps[i] = null;
                if (i > 0 and !sh.inherited_ignore[i]) _ = sys.setSignal(i, .default);
            }
        }
    }
    // (a subshell gives what it starts no group of its own, with `set -m` or not)
    if (bg and !(sh.jc and !was_subshell)) {
        _ = sys.setSignal(2, .ignore);
        _ = sys.setSignal(3, .ignore);
    }
    jobs.releaseSignals(sh);
}

fn childExit(sh: *Shell, st: u8) noreturn {
    var status = st;
    if (sh.traps[0] != null) {
        sh.status = st;
        sh.flow = .none;
        runExitTrap(sh);
        status = sh.status;
    }
    sys.exit(status);
}

const ChildIo = struct {
    /// A command substitution is a subshell environment of its own for `set -e`
    /// (POSIX 2.14 set: the -e setting applies to each subshell environment
    /// separately), so a surrounding `if` condition does not suspend it.
    fresh_errexit: bool = false,
    stdin: ?i32 = null,
    stdout: ?i32 = null,
    close: []const i32 = &.{},
    devnull_stdin: bool = false,
    bg: bool = false,
    job: ?*jobs.Job = null,
    /// what `jobs` calls it, when that is not the node run
    named: ?*const Node = null,
};

fn useJobs(sh: *Shell) bool {
    return sh.jc and !sh.in_subshell;
}

fn nodeText(sh: *Shell, node: *const Node) []u8 {
    return jobs.unparse(sh.gpa, node) catch &.{};
}

fn forkRun(sh: *Shell, node: *const Node, cio: ChildIo) ?i32 {
    const text = if (cio.job != null) nodeText(sh, cio.named orelse node) else &[_]u8{};
    defer if (text.len > 0) sh.gpa.free(text);
    const pid = jobs.forkInto(sh, cio.job, text, !cio.bg) catch {
        sh.diagK(.cannot_fork, null, "Cannot fork", .{});
        return null;
    };
    if (pid != 0) return pid;
    childInit(sh, cio.bg);
    if (cio.fresh_errexit) sh.noerrexit = 0;
    if (cio.stdin) |fd| _ = sys.dup2(fd, 0) catch sys.exit(2);
    if (cio.stdout) |fd| _ = sys.dup2(fd, 1) catch sys.exit(2);
    for (cio.close) |fd| sys.close(fd);
    if (cio.devnull_stdin) {
        const fd = sys.open("/dev/null", .{}, 0) catch -1;
        if (fd >= 0) {
            _ = sys.dup2(fd, 0) catch {};
            if (fd != 0) sys.close(fd);
        }
    }
    const st = execReplace(sh, node);
    childExit(sh, st);
}

/// Run `node` in a child that will exit afterwards: a simple command may
/// `exec` directly instead of forking again.
fn execReplace(sh: *Shell, node: *const Node) u8 {
    switch (node.kind) {
        .simple => |s| {
            sh.line = node.line;
            const st = execSimple(sh, node, s, true);
            sh.status = st;
            return st;
        },
        // already in a child that exits afterwards (`(cmd) &`, a pipeline stage):
        // the subshell needs no second process, only its trap reset
        .subshell => |body| {
            const b = body orelse return 0;
            childInit(sh, false);
            return execReplace(sh, b);
        },
        else => return execNode(sh, node),
    }
}

// --- nodes --------------------------------------------------------------------

pub fn execNode(sh: *Shell, node: *const Node) u8 {
    var st = execInner(sh, node);
    // the statuses of the constructs unwound by ^C do not count
    if (sh.flow == .interrupt) st = 130;
    sh.status = st;
    return st;
}

fn execInner(sh: *Shell, node: *const Node) u8 {
    switch (node.kind) {
        .simple => |s| {
            sh.line = node.line;
            return execSimple(sh, node, s, false);
        },
        .pipeline => |p| return execPipeline(sh, node, p.negate, p.commands),
        .and_or => |ao| {
            sh.noerrexit += 1;
            const l = execNode(sh, ao.left);
            sh.noerrexit -= 1;
            if (sh.flow != .none) return l;
            const run_right = switch (ao.op) {
                .and_if => l == 0,
                .or_if => l != 0,
            };
            if (!run_right) return l;
            return execNode(sh, ao.right);
        },
        .list => |items| {
            var st: u8 = 0;
            for (items) |it| {
                if (it.background) {
                    st = spawnBackground(sh, it.node);
                } else {
                    st = execNode(sh, it.node);
                    jobs.reap(sh);
                }
                checkTraps(sh);
                if (sh.flow != .none) return st;
            }
            return st;
        },
        .subshell => |body| {
            const b = body orelse return 0;
            const job: ?*jobs.Job = if (useJobs(sh)) jobs.create(sh) else null;
            const pid = forkRun(sh, b, .{ .job = job, .named = node }) orelse {
                if (job) |j| jobs.remove(sh, j);
                return 1;
            };
            const st = if (job) |j| jobs.waitFg(sh, j) else waitFor(sh, pid, true);
            errexitCheck(sh, st, "subshell");
            return st;
        },
        .group => |body| return if (body) |b| execNode(sh, b) else 0,
        .redirected => |r| return execRedirected(sh, r.body, r.redirs),
        .if_clause => |c| {
            sh.noerrexit += 1;
            const cs = execNode(sh, c.cond);
            sh.noerrexit -= 1;
            if (sh.flow != .none) return cs;
            if (cs == 0) return if (c.then) |t| execNode(sh, t) else 0;
            if (c.otherwise) |o| return execNode(sh, o);
            return 0;
        },
        .loop => |l| return execLoop(sh, l.until, l.cond, l.body),
        .for_clause => |f| return execFor(sh, f.name, f.words, f.body),
        .case_clause => |c| return execCase(sh, c.word, c.items),
        .function => |f| {
            const old = shell.putOwned(shell.Func, sh.gpa, &sh.funcs, f.name, .{ .body = f.body, .unit = sh.cur_unit }) catch |oe| return sh.oom(oe);
            if (sh.cur_unit) |u| _ = u.retain();
            if (old) |o| if (o.unit) |u| u.release();
            return 0;
        },
    }
}

fn spawnBackground(sh: *Shell, node: *const Node) u8 {
    jobs.reap(sh);
    if (node.kind == .pipeline and node.kind.pipeline.commands.len > 1 and !node.kind.pipeline.negate) {
        return runStagesBg(sh, node.kind.pipeline.commands);
    }
    const job = jobs.create(sh);
    if (job != null and !useJobs(sh)) job.?.grouped = false;
    const pid = forkRun(sh, node, .{ .devnull_stdin = !useJobs(sh), .bg = true, .job = job }) orelse {
        if (job) |j| jobs.remove(sh, j);
        return 1;
    };
    sh.bg_pid = pid;
    return 0;
}

fn execPipeline(sh: *Shell, node: *const Node, negate: bool, cmds: []const *const Node) u8 {
    _ = node;
    if (negate) sh.noerrexit += 1;
    defer if (negate) {
        sh.noerrexit -= 1;
    };
    var st: u8 = 0;
    if (cmds.len == 1) {
        st = execNode(sh, cmds[0]);
    } else {
        st = runStages(sh, cmds);
    }
    // `! break` and `! return` leave the status alone: the jump happens first
    if (negate) return if (sh.flow != .none) st else @intFromBool(st == 0);
    errexitCheck(sh, st, "pipeline");
    return st;
}

fn runStagesBg(sh: *Shell, cmds: []const *const Node) u8 {
    const r = runStagesImpl(sh, cmds, true);
    return r;
}

fn runStages(sh: *Shell, cmds: []const *const Node) u8 {
    return runStagesImpl(sh, cmds, false);
}

fn runStagesImpl(sh: *Shell, cmds: []const *const Node, bg: bool) u8 {
    const gpa = sh.gpa;
    var pids = gpa.alloc(i32, cmds.len) catch |oe| return sh.oom(oe);
    defer gpa.free(pids);
    var fds: std.ArrayList(i32) = .empty;
    defer fds.deinit(gpa);
    var prev_read: ?i32 = null;
    var spawned: usize = 0;
    const job: ?*jobs.Job = if (useJobs(sh) or bg) jobs.create(sh) else null;
    for (cmds, 0..) |c, i| {
        var next_pipe: ?[2]i32 = null;
        if (i + 1 < cmds.len) {
            next_pipe = sys.pipe() catch {
                sh.diagK(.cannot_fork, null, "Pipe call failed", .{});
                if (prev_read) |r| sys.close(r);
                // a script does not go on (dash)
                if (!sh.flags.interactive) sh.flow = .exit_shell;
                break;
            };
        }
        var closes: [3]i32 = undefined;
        var nclose: usize = 0;
        if (prev_read) |r| {
            closes[nclose] = r;
            nclose += 1;
        }
        if (next_pipe) |np| for (np) |fd| {
            closes[nclose] = fd;
            nclose += 1;
        };
        const pid = forkRun(sh, c, .{
            .stdin = prev_read,
            .stdout = if (next_pipe) |np| np[1] else null,
            .close = closes[0..nclose],
            .job = job,
            .bg = bg,
            .devnull_stdin = bg and !useJobs(sh) and i == 0,
        }) orelse {
            if (prev_read) |r| sys.close(r);
            if (next_pipe) |np| {
                sys.close(np[0]);
                sys.close(np[1]);
            }
            break;
        };
        pids[i] = pid;
        spawned += 1;
        if (prev_read) |r| sys.close(r);
        if (next_pipe) |np| {
            sys.close(np[1]);
            prev_read = np[0];
        } else prev_read = null;
    }
    if (bg) {
        if (job) |j| {
            if (spawned == 0) {
                jobs.remove(sh, j);
                return 1;
            }
            sh.bg_pid = j.lastPid();
        }
        return 0;
    }
    if (job) |j| {
        if (spawned == 0) {
            jobs.remove(sh, j);
            return 2;
        }
        const jst = jobs.waitFg(sh, j);
        if (spawned < cmds.len) return 2;
        return jst;
    }
    var st: u8 = 0;
    var worst: u8 = 0;
    for (pids[0..spawned], 0..) |pid, i| {
        const s = waitFor(sh, pid, true);
        if (s != 0) worst = s;
        if (i + 1 == cmds.len) st = s;
    }
    if (spawned < cmds.len) return 2;
    if (sh.flags.pipefail and worst != 0) return worst;
    return st;
}

// --- loops and case -------------------------------------------------------------

/// After a loop body: true when the loop must stop.
fn loopStop(sh: *Shell) bool {
    switch (sh.flow) {
        .none => return false,
        .break_loop => {
            sh.flow_count -|= 1;
            if (sh.flow_count == 0) sh.flow = .none;
            return true;
        },
        .continue_loop => {
            sh.flow_count -|= 1;
            if (sh.flow_count == 0) {
                sh.flow = .none;
                return false;
            }
            return true;
        },
        else => return true,
    }
}

fn execLoop(sh: *Shell, until: bool, cond: *const Node, body: ?*const Node) u8 {
    var st: u8 = 0;
    sh.loop_depth += 1;
    defer sh.loop_depth -= 1;
    while (true) {
        sh.noerrexit += 1;
        const c = execNode(sh, cond);
        sh.noerrexit -= 1;
        if (sh.flow != .none) {
            // `break` and `continue` in the condition act on this loop
            if (sh.flow == .break_loop or sh.flow == .continue_loop) {
                if (loopStop(sh)) break;
                continue;
            }
            return c;
        }
        if ((c == 0) == until) break;
        if (body) |b| st = execNode(sh, b) else st = 0;
        checkTraps(sh);
        if (loopStop(sh)) break;
    }
    return st;
}

fn execFor(sh: *Shell, name: []const u8, words: ?[]const ast.Word, body: ?*const Node) u8 {
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    if (words) |w| {
        expand.fields(sh, a, w, &list) catch |e| return xerr(sh, e);
    } else {
        for (sh.params.items) |p| list.append(a, a.dupe(u8, p) catch |oe| return sh.oom(oe)) catch |oe| return sh.oom(oe);
    }
    if (interruptedExpanding(sh)) return 130;
    var st: u8 = 0;
    sh.loop_depth += 1;
    defer sh.loop_depth -= 1;
    for (list.items) |item| {
        sh.setVar(name, item) catch |e| switch (e) {
            error.ReadOnly => {
                sh.diagK(.readonly_assignment, name, "{s}: is read only", .{name});
                sh.status = 2;
                sh.flow = .exit_shell;
                return 2;
            },
            error.OutOfMemory => return sh.oom(error.OutOfMemory),
        };
        st = if (body) |b| execNode(sh, b) else 0;
        checkTraps(sh);
        if (loopStop(sh)) break;
    }
    return st;
}

fn execCase(sh: *Shell, word: ast.Word, items: []const ast.CaseItem) u8 {
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const w = expand.string(sh, a, word) catch |e| return xerr(sh, e);
    for (items, 0..) |it, first| {
        for (it.patterns) |pw| {
            const pat = expand.patternString(sh, a, pw) catch |e| return xerr(sh, e);
            if (!pattern.match(pat, w)) continue;
            var st: u8 = 0;
            for (items[first..]) |run| {
                if (run.body) |b| st = execNode(sh, b);
                if (!run.falls_through or sh.flow != .none) break;
            }
            return st;
        }
    }
    return 0;
}

// --- redirections ---------------------------------------------------------------

const SavedFd = struct { fd: i32, saved: i32 };

pub const Redirs = struct {
    saved: std.ArrayList(SavedFd) = .empty,

    pub fn restore(self: *Redirs, gpa: Allocator) void {
        var i = self.saved.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.saved.items[i];
            if (s.saved >= 0) {
                _ = sys.dup2(s.saved, s.fd) catch {};
                sys.close(s.saved);
            } else sys.close(s.fd);
        }
        self.saved.deinit(gpa);
        self.saved = .empty;
    }

    /// Make the redirections permanent (builtin `exec`).
    pub fn commit(self: *Redirs, gpa: Allocator) void {
        for (self.saved.items) |s| if (s.saved >= 0) sys.close(s.saved);
        self.saved.deinit(gpa);
        self.saved = .empty;
    }
};

fn openError(sh: *Shell, path: []const u8, create: bool) void {
    const e = sys.errno();
    const text: []const u8 = if (create)
        (if (e == sys.E_NOENT or e == sys.E_NOTDIR) "Directory nonexistent" else sys.strerror(e))
    else
        (if (e == sys.E_NOENT) "No such file" else sys.strerror(e));
    sh.diagK(if (create) .cannot_create else .cannot_open, path, "cannot {s} {s}: {s}", .{ if (create) "create" else "open", path, text });
}

/// Apply `redirs` in the current process. When `save` is non-null the
/// previous state of each descriptor is recorded for `restore`. Returns false
/// (after a diagnostic) when one fails.
pub fn applyRedirs(sh: *Shell, a: Allocator, redirs: []const *ast.Redirect, save: ?*Redirs) bool {
    for (redirs) |r| {
        sh.line = if (r.line != 0) r.line else sh.line;
        const default_fd: i32 = switch (r.op) {
            .in, .dup_in, .read_write, .heredoc => 0,
            else => 1,
        };
        const n = r.fd orelse default_fd;
        switch (r.op) {
            .in, .out, .append, .clobber, .read_write => {
                const path = expand.string(sh, a, r.target) catch |e| {
                    _ = xerr(sh, e);
                    return false;
                };
                var flags: sys.OpenFlags = .{ .cloexec = true };
                var mode: u32 = 0;
                switch (r.op) {
                    .in => {},
                    .out, .clobber => {
                        flags = .{ .read = false, .write = true, .create = true, .trunc = true, .cloexec = true };
                        mode = 0o666;
                        if (r.op == .out and sh.flags.noclobber) {
                            if (sys.stat(path, true)) |info| {
                                if (info.kind == .file) {
                                    sh.diagK(.noclobber, path, "cannot create {s}: File exists", .{path});
                                    return false;
                                }
                                flags.trunc = false;
                            } else |_| flags.excl = true;
                        }
                    },
                    .append => {
                        flags = .{ .read = false, .write = true, .create = true, .append = true, .cloexec = true };
                        mode = 0o666;
                    },
                    .read_write => {
                        flags = .{ .read = true, .write = true, .create = true, .cloexec = true };
                        mode = 0o666;
                    },
                    else => unreachable,
                }
                const fd = while (true) {
                    break sys.open(path, flags, mode) catch {
                        // a trapped signal interrupted a blocked open (a FIFO): run the trap, retry
                        if (sys.errno() == sys.E_INTR) {
                            checkTraps(sh);
                            if (sh.flow != .none) return false;
                            continue;
                        }
                        openError(sh, path, flags.create);
                        return false;
                    };
                };
                if (!place(sh, fd, n, save)) return false;
            },
            .dup_in, .dup_out => {
                const word = expand.string(sh, a, r.target) catch |e| {
                    _ = xerr(sh, e);
                    return false;
                };
                if (std.mem.eql(u8, word, "-")) {
                    if (!saveFd(sh, n, save)) return false;
                    sys.close(n);
                    continue;
                }
                const m0 = num.parseInt(i32, word, 10) catch -1;
                // a duplicated descriptor is one digit (POSIX leaves more unspecified; dash and FreeBSD sh refuse)
                const m = if (m0 > 9 or word.len > 1 and word[0] == '0') -1 else m0;
                if (m < 0) {
                    sh.diagKind(.bad_fd_number, word, "Syntax error: Bad fd number");
                    // a non-number operand of >& or <& ends a non-interactive shell (dash, FreeBSD sh)
                    if (!sh.flags.interactive and sh.no_die == 0) {
                        sh.status = 2;
                        sh.flow = .exit_shell;
                    }
                    return false;
                }
                if (m == n) continue; // `3>&3` is a no-op even when 3 is closed (dash, FreeBSD sh)
                if (!sys.fdIsOpen(m)) {
                    {
                        var fb: [16]u8 = undefined;
                        sh.diagK(.bad_fd, std.fmt.bufPrint(&fb, "{d}", .{m}) catch "", "{d}: Bad file descriptor", .{m});
                    }
                    return false;
                }
                if (m == n) continue;
                if (!saveFd(sh, n, save)) return false;
                _ = sys.dup2(m, n) catch {
                    {
            var fb: [16]u8 = undefined;
            sh.diagK(.bad_fd, std.fmt.bufPrint(&fb, "{d}", .{n}) catch "", "{d}: Bad file descriptor", .{n});
        }
                    return false;
                };
            },
            .heredoc => {
                const body = expand.string(sh, a, r.body) catch |e| {
                    _ = xerr(sh, e);
                    return false;
                };
                const fd = sys.memfileWith(body) catch {
                    sh.diagK(.cannot_create, "temporary file", "cannot create temporary file", .{});
                    return false;
                };
                if (!place(sh, fd, n, save)) return false;
            },
        }
    }
    return true;
}

fn saveFd(sh: *Shell, n: i32, save: ?*Redirs) bool {
    const s = save orelse return true;
    s.saved.ensureUnusedCapacity(sh.gpa, 1) catch return false;
    const copy: i32 = sys.dupAbove(n, 10) catch if (sys.errno() == sys.E_BADF) -1 else {
        // -1 means "was closed": restoring would then close what is in use
        sh.diagK(.other, null, "{d}: cannot save the descriptor: {s}", .{ n, sys.strerror(sys.errno()) });
        return false;
    };
    s.saved.appendAssumeCapacity(.{ .fd = n, .saved = copy });
    return true;
}

/// Put the open descriptor `fd` at number `n` (closing `fd`).
fn place(sh: *Shell, fd: i32, n: i32, save: ?*Redirs) bool {
    if (fd == n) {
        // open() returned the very number: it was closed before, so restoring means closing
        if (save) |sv| sv.saved.append(sh.gpa, .{ .fd = n, .saved = -1 }) catch {
            sys.close(fd);
            return false;
        };
        sys.setCloexec(n, false);
        return true;
    }
    if (!saveFd(sh, n, save)) {
        sys.close(fd);
        return false;
    }
    if (fd == n) {
        sys.setCloexec(n, false);
        return true;
    }
    _ = sys.dup2(fd, n) catch {
        {
            var fb: [16]u8 = undefined;
            sh.diagK(.bad_fd, std.fmt.bufPrint(&fb, "{d}", .{n}) catch "", "{d}: Bad file descriptor", .{n});
        }
        sys.close(fd);
        return false;
    };
    sys.close(fd);
    return true;
}

fn execRedirected(sh: *Shell, body: *const Node, redirs: []const *ast.Redirect) u8 {
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    var saved: Redirs = .{};
    if (!applyRedirs(sh, arena.allocator(), redirs, &saved)) {
        saved.restore(sh.gpa);
        errexitCheck(sh, 2, "redirection"); // set -e: a failed redirection of a compound command ends the shell (dash)
        return 2;
    }
    defer saved.restore(sh.gpa);
    return execNode(sh, body);
}

// --- command substitution ---------------------------------------------------------

/// Run `node` with its standard output captured; trailing newlines removed.
pub fn substitute(sh: *Shell, a: Allocator, node: *const Node) expand.Error![]const u8 {
    const p = sys.pipe() catch {
        sh.diagK(.cannot_fork, null, "Pipe call failed", .{});
        return expand.fatal(sh, .cannot_fork, null, "Pipe call failed", .{});
    };
    const pid = forkRun(sh, node, .{ .stdout = p[1], .close = &.{ p[0], p[1] }, .fresh_errexit = true }) orelse {
        sys.close(p[0]);
        sys.close(p[1]);
        return expand.fatal(sh, .cannot_fork, null, "Cannot fork", .{});
    };
    sys.close(p[1]);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(p[0], &chunk) catch {
            if (sys.errno() == sys.E_INTR) continue;
            break;
        };
        if (n == 0) break;
        try buf.appendSlice(a, chunk[0..n]);
    }
    sys.close(p[0]);
    const st = waitFor(sh, pid, false);
    sh.last_subst_status = st;
    // NUL bytes cannot be kept in a shell string; they are dropped (dash, FreeBSD sh)
    if (std.mem.indexOfScalar(u8, buf.items, 0) != null) {
        var w: usize = 0;
        for (buf.items) |c| if (c != 0) {
            buf.items[w] = c;
            w += 1;
        };
        buf.items.len = w;
    }
    var end = buf.items.len;
    while (end > 0 and buf.items[end - 1] == '\n') end -= 1;
    return buf.items[0..end];
}

// --- simple commands -----------------------------------------------------------------

fn xtrace(sh: *Shell, a: Allocator, s: ast.Simple, vals: []const []const u8, args: []const []const u8) void {
    var line: std.ArrayList(u8) = .empty;
    // a copy: expanding it may assign PS4, and a failure leaves this as the text
    var ps4: []const u8 = a.dupe(u8, sh.getVar("PS4") orelse "+ ") catch return;
    // PS4 is subject to parameter expansion, command substitution and arithmetic
    if (std.mem.indexOfAny(u8, ps4, "$`") != null) {
        if (parser.parseText(a, ps4)) |w| {
            const saved_trace = sh.flags.xtrace;
            sh.flags.xtrace = false;
            defer sh.flags.xtrace = saved_trace;
            // an error in PS4 is ignored: the trace line keeps the raw text
            const saved_flow = sh.flow;
            const saved_status = sh.status;
            if (expand.string(sh, a, w)) |v| ps4 = v else |_| {
                sh.flow = saved_flow;
                sh.status = saved_status;
            }
        } else |_| {}
    }
    line.appendSlice(a, ps4) catch return;
    var first = true;
    for (s.assigns, vals) |asg, v| {
        if (!first) line.append(a, ' ') catch return;
        first = false;
        line.print(a, "{s}={s}", .{ asg.name, v }) catch return;
    }
    for (args) |w| {
        if (!first) line.append(a, ' ') catch return;
        first = false;
        line.appendSlice(a, w) catch return;
    }
    line.append(a, '\n') catch return;
    sh.errRaw(line.items);
}

const Resolved = union(enum) {
    special: builtins.Builtin,
    function: shell.Func,
    builtin: builtins.Builtin,
    host: shell.HostBuiltin,
    external: []const u8,
    not_found,
};

/// The first file called `name` in the directories of `path` that is not a
/// directory and, when asked for, may be executed.
pub fn searchPath(sh: *Shell, a: Allocator, path: []const u8, name: []const u8, want_exec: bool) Allocator.Error!?[]const u8 {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name });
        const info = sys.stat(full, true) catch continue;
        if (info.kind == .dir) continue;
        if (want_exec and !osio.access(sh.env.io, full, .{ .execute = true })) continue;
        return full;
    }
    return null;
}

/// `searchPath` for a command: in the PATH the lookup is to use.
fn pathFind(sh: *Shell, a: Allocator, name: []const u8, want_exec: bool) ?[]const u8 {
    return searchPath(sh, a, sh.lookup_path orelse sh.getVar("PATH") orelse "", name, want_exec) catch |oe| {
        // not the same as "not found"
        _ = sh.oom(oe);
        return null;
    };
}

pub fn resolve(sh: *Shell, a: Allocator, name: []const u8) Resolved {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return .{ .external = name };
    if (builtins.find(name)) |b| if (b.special) return .{ .special = b };
    if (sh.funcs.get(name)) |f| return .{ .function = f };
    if (builtins.find(name)) |b| return .{ .builtin = b };
    if (sh.host_builtins.get(name)) |h| return .{ .host = h };
    // a remembered location is used as it is, even if the file went away
    // (dash, FreeBSD sh: the command is then not found until `hash -r`)
    // a copy: a redirection's expansion may assign PATH, which empties the table
    if (sh.lookup_path == null) if (sh.hash.get(name)) |p| return .{ .external = a.dupe(u8, p) catch |oe| {
        _ = sh.oom(oe);
        return .not_found;
    } };
    if (pathFind(sh, a, name, true)) |p| {
        // remember the location, as dash and FreeBSD sh do (POSIX `hash`);
        // entries from a relative PATH entry are dropped again by `cd`
        if (sh.lookup_path == null) {
            const key = sh.gpa.dupe(u8, name) catch return .{ .external = p };
            const val = sh.gpa.dupe(u8, p) catch {
                sh.gpa.free(key);
                return .{ .external = p };
            };
            sh.hash.put(sh.gpa, key, val) catch {
                sh.gpa.free(key);
                sh.gpa.free(val);
            };
        }
        return .{ .external = p };
    }
    return .not_found;
}

/// True when the PATH search for `name` passed over a file that may not be run.
pub fn foundButNotExecutable(sh: *Shell, a: Allocator, name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '/') == null and pathFind(sh, a, name, false) != null;
}

/// Report a command that cannot be run; its exit status.
fn reportMissing(sh: *Shell, name: []const u8, denied: bool) u8 {
    if (denied) {
        sh.diagK(.not_executable, name, "{s}: Permission denied", .{name});
        return 126;
    }
    sh.diagK(.not_found, name, "{s}: not found", .{name});
    return 127;
}

pub fn findExecutable(sh: *Shell, a: Allocator, name: []const u8) ?[]const u8 {
    return pathFind(sh, a, name, true);
}

fn assignError(sh: *Shell, name: []const u8) u8 {
    sh.diagK(.readonly_assignment, name, "{s}: is read only", .{name});
    sh.status = 2;
    sh.flow = .exit_shell;
    return 2;
}

fn execSimple(sh: *Shell, node: *const Node, s_in: ast.Simple, replace: bool) u8 {
    sh.simple_seq += 1;
    var s = s_in;
    sh.cur_col = node.col;
    sh.cur_end_col = node.end_col;
    // `set -n` in the middle of a script: nothing more runs (dash, bash).
    if (sh.flags.noexec) return 0;
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    sh.last_subst_status = null;

    var args: std.ArrayList([]const u8) = .empty;
    // Declaration utilities (`export`, `readonly`, also behind `command`):
    // operands of the form name=word are expanded like assignments, with
    // neither field splitting nor pathname expansion (POSIX 2.14 export).
    const decl = declStart(s.words);
    for (s.words, 0..) |w, i| {
        if (decl != null and i >= decl.? and isAssignWord(w)) {
            const v = expand.assignValue(sh, a, w) catch |e| return xerr(sh, e);
            args.append(a, v) catch |oe| return sh.oom(oe);
        } else expand.fields(sh, a, &.{w}, &args) catch |e| return xerr(sh, e);
    }
    const vals = a.alloc([]const u8, s.assigns.len) catch |oe| return sh.oom(oe);
    // `export x=~` style operands expand tildes after `=` like assignments.
    for (vals) |*v| v.* = "";
    // POSIX 2.9.1: the redirections are performed before the assignments of a
    // command with a name are expanded (so `a=$(cat f) >f true` sees f). They are
    // applied here, in the shell, around the command; special builtins and `exec`
    // keep their own order (their redirections may be permanent).
    var early: Redirs = .{};
    defer early.restore(sh.gpa);
    if (args.items.len > 0 and s.assigns.len > 0 and s.redirs.len > 0 and !lexer.isSpecialBuiltin(args.items[0]) and !std.mem.eql(u8, args.items[0], "command")) {
        if (!applyRedirs(sh, a, s.redirs, &early)) {
            errexitCheck(sh, 2, "redirection");
            return 2;
        }
        s.redirs = &.{};
    }
    if (args.items.len > 0 and s.assigns.len > 0) {
        expandPrefix(sh, a, s.assigns, vals) catch |e| return xerr(sh, e);
    }
    if (args.items.len > 0) {
        const nm = args.items[0];
        if (std.mem.eql(u8, nm, "export") or std.mem.eql(u8, nm, "readonly") or std.mem.eql(u8, nm, "local")) {
            // re-expand assignment-looking operands with assignment tilde rules
            for (s.words[1..], 1..) |w, i| {
                if (i >= args.items.len) break;
                if (hasAssignTilde(w)) {
                    const v = expand.assignValue(sh, a, w) catch |e| return xerr(sh, e);
                    if (std.mem.indexOfScalar(u8, v, '=') != null) args.items[i] = v;
                }
            }
        }
    }

    if (interruptedExpanding(sh)) return 130;

    if (sh.flags.xtrace and args.items.len > 0) xtrace(sh, a, s, vals, args.items);

    if (args.items.len == 0) {
        var saved: Redirs = .{};
        const ok = applyRedirs(sh, a, s.redirs, &saved);
        defer saved.restore(sh.gpa);
        if (!ok) {
            errexitCheck(sh, 2, "redirection");
            return 2;
        }
        // POSIX 2.9.1 (Issue 8): each assignment is expanded and made in order,
        // so a later one sees an earlier one.
        for (s.assigns) |asg| {
            const v = expand.assignValue(sh, a, asg.value) catch |e| return xerr(sh, e);
            if (sh.flags.xtrace) {
                var one = [_][]const u8{v};
                const only: ast.Simple = .{ .assigns = &.{asg}, .words = &.{}, .redirs = &.{} };
                xtrace(sh, a, only, &one, &.{});
            }
            sh.setVar(asg.name, v) catch |e| switch (e) {
                error.ReadOnly => return assignError(sh, asg.name),
                error.OutOfMemory => return sh.oom(error.OutOfMemory),
            };
        }
        const ast_st = sh.last_subst_status orelse 0;
        errexitCheck(sh, ast_st, "assignment");
        return ast_st;
    }

    const name = args.items[0];
    // A PATH assignment in the command's own prefix applies to its lookup.
    var path_saved: ?shell.Saved = null;
    for (s.assigns, vals) |asg, v| if (std.mem.eql(u8, asg.name, "PATH")) {
        // saved once: restoring then brings back the value from before the line
        if (path_saved == null) {
            const saved = saveVar(sh, "PATH") catch |oe| return sh.oom(oe);
            path_saved = saved;
        }
        sh.setVarRaw("PATH", v) catch |oe| {
            restoreVar(sh, path_saved.?);
            return sh.oom(oe);
        };
    };
    const r = resolve(sh, a, name);
    // why it was not found: asked while the same PATH is in effect
    const denied = r == .not_found and foundButNotExecutable(sh, a, name);
    if (path_saved) |ps| restoreVar(sh, ps);
    // A variable assignment error ends a non-interactive shell for every kind of
    // command (POSIX 2.8.1); builtins check it themselves.
    switch (r) {
        .external, .not_found => for (s.assigns) |asg| {
            if (sh.vars.get(asg.name)) |ov| if (ov.readonly) return assignError(sh, asg.name);
        },
        else => {},
    }
    const st: u8 = switch (r) {
        .not_found => blk: {
            // Redirections still happen (to a forked child in real shells).
            if (replace) {
                if (!applyRedirs(sh, a, s.redirs, null)) break :blk 2;
                break :blk reportMissing(sh, name, denied);
            }
            const pid = jobs.forkInto(sh, null, "", true) catch {
                sh.diagK(.cannot_fork, null, "Cannot fork", .{});
                break :blk 2;
            };
            if (pid == 0) {
                childInit(sh, false);
                if (!applyRedirs(sh, a, s.redirs, null)) sys.exit(2);
                sys.exit(reportMissing(sh, name, denied));
            }
            break :blk waitFor(sh, pid, true);
        },
        .external => |path| runExternal(sh, a, path, args.items, s, vals, replace),
        else => runInShell(sh, a, r, args.items, s, vals),
    };
    errexitCheck(sh, st, name);
    // a signal that arrived while the command ran: its trap runs now (POSIX 2.11)
    if (sh.flow == .none) {
        sh.status = st; // $? and a bare `exit` in the trap see this command's status
        checkTraps(sh);
        // a trap that exits or returns decides the status
        if (sh.flow != .none) return sh.status;
    }
    return st;
}

/// Expand the assignments in front of a command name. POSIX 2.9.1 (Issue 8):
/// each is made before the next is expanded, so a later one sees an earlier
/// one. They are made in a scope that ends here; the caller then applies `vals`
/// in the way the kind of command calls for.
fn expandPrefix(sh: *Shell, a: Allocator, assigns: []const ast.Assign, vals: [][]const u8) expand.Error!void {
    var temps: std.ArrayList(shell.Saved) = .empty;
    defer {
        var i = temps.items.len;
        while (i > 0) {
            i -= 1;
            restoreVar(sh, temps.items[i]);
        }
        temps.deinit(sh.gpa);
    }
    for (assigns, vals) |asg, *v| {
        v.* = try expand.assignValue(sh, a, asg.value);
        // the caller reports an assignment to a read-only variable
        if (sh.vars.get(asg.name)) |ov| if (ov.readonly) continue;
        try temps.ensureUnusedCapacity(sh.gpa, 1);
        temps.appendAssumeCapacity(try saveVar(sh, asg.name));
        try sh.setVarRaw(asg.name, v.*);
        sh.vars.getPtr(asg.name).?.exported = true;
    }
    // an expansion may assign again to an earlier name: `a=1 b=$((a=5)) cmd`
    for (assigns, vals, 0..) |asg, *v, i| {
        const last = for (assigns[i + 1 ..]) |later| {
            if (std.mem.eql(u8, later.name, asg.name)) break false;
        } else true;
        if (!last) continue;
        const now = sh.getVar(asg.name) orelse continue;
        if (sh.vars.get(asg.name).?.readonly) continue;
        v.* = try a.dupe(u8, now);
    }
}

/// What `restoreVar` needs to put variable `name` back as it is now.
pub fn saveVar(sh: *Shell, name: []const u8) Allocator.Error!shell.Saved {
    var old: ?shell.Var = null;
    if (sh.vars.get(name)) |ov| old = .{
        .value = if (ov.value) |x| try sh.gpa.dupe(u8, x) else null,
        .exported = ov.exported,
        .readonly = ov.readonly,
    };
    errdefer if (old) |o| if (o.value) |x| sh.gpa.free(x);
    return .{ .name = try sh.gpa.dupe(u8, name), .old = old };
}

/// A word that reads `name=...` (the name literal and unquoted).
fn isAssignWord(w: ast.Word) bool {
    if (w.len == 0) return false;
    const first = switch (w[0]) {
        .text => |t| t,
        else => return false,
    };
    const eq = std.mem.indexOfScalar(u8, first, '=') orelse return false;
    return eq > 0 and lexer.isName(first[0..eq]);
}

/// True when the word is made only of literal (quoted or not) text equal to `name`.
fn wordIs(w: ast.Word, name: []const u8) bool {
    var rest = name;
    for (w) |p| {
        const t = switch (p) {
            .text => |t| t,
            .quoted => |t| t,
            else => return false,
        };
        if (!std.mem.startsWith(u8, rest, t)) return false;
        rest = rest[t.len..];
    }
    return rest.len == 0;
}

/// Index of the first operand of a declaration utility command, if it is one.
/// `command` (also quoted, as in `\command`) may precede it.
fn declStart(words: []const ast.Word) ?usize {
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        if (wordIs(words[i], "command")) continue;
        if (wordIs(words[i], "export") or wordIs(words[i], "readonly") or wordIs(words[i], "local")) return i + 1;
        return null;
    }
    return null;
}

fn hasAssignTilde(w: ast.Word) bool {
    for (w) |p| if (p == .atilde) return true;
    return false;
}

/// Builtins, host builtins and functions run in the shell process.
fn runInShell(sh: *Shell, a: Allocator, r: Resolved, args: []const []const u8, s: ast.Simple, vals: []const []const u8) u8 {
    const is_special = r == .special;
    var saved: Redirs = .{};
    const is_exec = std.mem.eql(u8, args[0], "exec") or (args.len > 1 and std.mem.eql(u8, args[0], "command") and execBehindCommand(args));
    if (!applyRedirs(sh, a, s.redirs, &saved)) {
        saved.restore(sh.gpa);
        if (is_special) {
            sh.status = 2;
            sh.flow = .exit_shell;
        }
        return 2;
    }
    // Variable assignments: permanent for special builtins, temporary
    // (exported to the command) otherwise.
    var temps: std.ArrayList(shell.Saved) = .empty;
    defer {
        var i = temps.items.len;
        while (i > 0) {
            i -= 1;
            restoreVar(sh, temps.items[i]);
        }
        temps.deinit(sh.gpa);
    }
    for (s.assigns, vals) |asg, v| {
        if (!is_special) {
            // room first, so that what is saved cannot be dropped
            temps.ensureUnusedCapacity(sh.gpa, 1) catch |oe| return sh.oom(oe);
            temps.appendAssumeCapacity(saveVar(sh, asg.name) catch |oe| return sh.oom(oe));
        }
        sh.setVar(asg.name, v) catch |e| switch (e) {
            error.ReadOnly => {
                saved.restore(sh.gpa);
                return assignError(sh, asg.name);
            },
            error.OutOfMemory => return sh.oom(error.OutOfMemory),
        };
        if (!is_special or is_exec) sh.vars.getPtr(asg.name).?.exported = true;
    }
    var st: u8 = 0;
    sh.out_failed = false;
    defer if (r == .special or r == .builtin) {
        sh.out_failed = false;
    };
    switch (r) {
        .special, .builtin => |b| {
            st = b.run(sh, a, args);
            // output that could not be written fails the builtin (dash: status 1)
            if (sh.out_failed and st == 0) {
                sh.diagCmdK(.io_error, "I/O error", args[0], "I/O error", .{});
                st = 1;
            }
        },
        .host => |h| st = h.run(h.ctx, sh, args),
        .function => |f| st = callFunction(sh, f, args[1..]),
        else => unreachable,
    }
    if (is_exec and sh.flow != .exit_shell and st == 0) {
        saved.commit(sh.gpa);
    } else saved.restore(sh.gpa);
    return st;
}

fn execBehindCommand(args: []const []const u8) bool {
    var i: usize = 1;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
    }
    return i < args.len and std.mem.eql(u8, args[i], "exec");
}

pub fn restoreVar(sh: *Shell, sv: shell.Saved) void {
    defer sh.gpa.free(sv.name);
    if (sv.flags) |f| {
        sh.flags = f;
        return;
    }
    // what was found along the temporary PATH must not outlive it
    if (std.mem.eql(u8, sv.name, "PATH")) sh.clearHash();
    if (sv.old) |o| {
        if (sh.vars.getPtr(sv.name)) |cur| {
            if (cur.value) |x| sh.gpa.free(x);
            cur.* = o;
        } else {
            _ = shell.putOwned(shell.Var, sh.gpa, &sh.vars, sv.name, o) catch {
                if (o.value) |x| sh.gpa.free(x);
            };
        }
    } else {
        if (sh.vars.getPtr(sv.name)) |cur| {
            if (cur.value) |x| sh.gpa.free(x);
            cur.value = null;
            if (sh.vars.fetchRemove(sv.name)) |kv| sh.gpa.free(kv.key);
        }
    }
}

pub fn callFunction(sh: *Shell, f: shell.Func, args: []const []const u8) u8 {
    const gpa = sh.gpa;
    // held while it runs, whatever it does to its own definition
    const unit = if (f.unit) |u| u.retain() else null;
    defer if (unit) |u| u.release();
    const outer_unit = sh.cur_unit;
    sh.cur_unit = unit;
    defer sh.cur_unit = outer_unit;
    var old_params = sh.params;
    sh.params = .empty;
    sh.setParams(args) catch |oe| {
        sh.params = old_params;
        return sh.oom(oe);
    };
    const mark = sh.locals.items.len;
    const saved_base = sh.locals_base;
    sh.locals_base = mark;
    defer sh.locals_base = saved_base;
    sh.func_depth += 1;
    const saved_loops = sh.loop_depth;
    sh.loop_depth = 0;
    var st = execNode(sh, f.body);
    sh.loop_depth = saved_loops;
    sh.func_depth -= 1;
    if (sh.flow == .return_func) {
        sh.flow = .none;
        st = sh.status;
    }
    // restore `local` variables
    while (sh.locals.items.len > mark) {
        const l = sh.locals.pop().?;
        restoreVar(sh, l);
    }
    for (sh.params.items) |p| gpa.free(p);
    sh.params.deinit(gpa);
    sh.params = old_params;
    old_params = .empty;
    return st;
}

fn runExternal(sh: *Shell, a: Allocator, path: []const u8, args: []const []const u8, s: ast.Simple, vals: []const []const u8, replace: bool) u8 {
    if (!replace) {
        const job: ?*jobs.Job = if (useJobs(sh)) jobs.create(sh) else null;
        const node: Node = .{ .line = 0, .kind = .{ .simple = s } };
        const text = if (job != null) nodeText(sh, &node) else &[_]u8{};
        defer if (text.len > 0) sh.gpa.free(text);
        const pid = jobs.forkInto(sh, job, text, true) catch {
            sh.diagK(.cannot_fork, null, "Cannot fork", .{});
            if (job) |j| jobs.remove(sh, j);
            return 2;
        };
        if (pid != 0) return if (job) |j| jobs.waitFg(sh, j) else waitFor(sh, pid, true);
        childInit(sh, false);
    }
    if (!applyRedirs(sh, a, s.redirs, null)) sys.exit(2);
    // environment: exported variables with the command's assignments on top
    var env: std.ArrayList([]const u8) = .empty;
    const base = sh.environ(a) catch sys.exit(2);
    for (base) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=').?;
        var overridden = false;
        for (s.assigns) |asg| if (std.mem.eql(u8, asg.name, e[0..eq])) {
            overridden = true;
        };
        if (!overridden) env.append(a, e) catch sys.exit(2);
    }
    for (s.assigns, vals) |asg, v| env.append(a, std.fmt.allocPrint(a, "{s}={s}", .{ asg.name, v }) catch sys.exit(2)) catch sys.exit(2);
    execProgram(sh, a, path, args, env.items);
    const e = sys.errno();
    if (e == sys.E_NOEXEC) execScript(sh, a, path, args, s.assigns, vals);
    if (e == sys.E_NOENT or e == sys.E_NOTDIR) {
        sh.diagK(.not_found, args[0], "{s}: not found", .{args[0]});
        sys.exit(127);
    }
    sh.diagK(if (e == sys.E_ACCES) .not_executable else .other, args[0], "{s}: {s}", .{ args[0], sys.strerror(e) });
    sys.exit(126);
}

/// True when programs the shell runs are to start with SIGCHLD ignored: the
/// user said `trap '' CHLD`, or the shell inherited the ignore. The shell's own
/// disposition is never "ignore".
fn childrenIgnoreChld(sh: *const Shell) bool {
    if (sh.traps[sys.SIGCHLD]) |t| return t.len == 0;
    return sh.inherited_ignore[sys.SIGCHLD];
}

/// execve with the signal dispositions the program is to start with. Returns
/// only on failure, with `sys.errno` describing it.
pub fn execProgram(sh: *Shell, a: Allocator, path: []const u8, args: []const []const u8, env: []const []const u8) void {
    const ignore_chld = childrenIgnoreChld(sh);
    const before = sys.getSignal(sys.SIGCHLD);
    if (ignore_chld) _ = sys.setSignal(sys.SIGCHLD, .ignore);
    sys.execve(a, path, args, env) catch {};
    if (ignore_chld) _ = sys.setSignal(sys.SIGCHLD, before);
}

/// execve failed with ENOEXEC: POSIX 2.9.1.1 says the shell then runs the file
/// as if a new shell had been invoked with it as the operand. This process
/// becomes that shell, built afresh from the environment, so that none of the
/// caller's state (a suppressed `set -e`, loop depth, `getopts` position, job
/// control...) reaches the script. Does not return.
pub fn execScript(sh: *Shell, a: Allocator, path: []const u8, args: []const []const u8, assigns: []const ast.Assign, vals: []const []const u8) noreturn {
    const text = readFile(a, path) orelse {
        sh.diagK(.not_executable, args[0], "{s}: {s}", .{ args[0], sys.strerror(sys.errno()) });
        sys.exit(126);
    };
    // a file with NUL bytes in its first line is a binary, not a script
    const head = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (std.mem.indexOfScalar(u8, head, 0) != null or std.mem.startsWith(u8, text, "\x7fELF")) {
        sh.diagK(.not_executable, args[0], "{s}: Exec format error", .{args[0]});
        sys.exit(126);
    }
    const fresh = newShell(sh, args[0], assigns, vals) catch {
        sh.diagK(.other, null, "out of memory", .{});
        sys.exit(2);
    };
    fresh.setParams(args[1..]) catch sys.exit(2);
    const st = runSource(fresh, text, .{}) catch 2;
    childExit(fresh, if (fresh.flow == .exit_shell) fresh.status else st);
}

/// The shell a script without `#!` starts in.
fn newShell(sh: *Shell, name: []const u8, assigns: []const ast.Assign, vals: []const []const u8) Allocator.Error!*Shell {
    var environ = std.process.Environ.Map.init(sh.gpa);
    defer environ.deinit();
    var it = sh.vars.iterator();
    while (it.next()) |e| if (e.value_ptr.exported) {
        if (e.value_ptr.value) |v| try environ.put(e.key_ptr.*, v);
    };
    for (assigns, vals) |asg, v| try environ.put(asg.name, v);

    // the dispositions a program would start with, which is what it inherits
    const ignore_chld = childrenIgnoreChld(sh);
    var i: u8 = 1;
    while (i < sys.nsig) : (i += 1) {
        if (sh.traps[i]) |t| if (t.len > 0) {
            _ = sys.setSignal(i, .default);
        };
    }
    if (ignore_chld) _ = sys.setSignal(sys.SIGCHLD, .ignore);
    sys.clearPendingAny();
    if (sh.tty_fd >= 0) sys.close(sh.tty_fd);

    const fresh = try Shell.init(sh.env, .{
        .name = name,
        .prog = sh.prog,
        .label = name,
        .environ = &environ,
        .diag_style = sh.diag_style,
        .diag_color = sh.diag_color,
        .reporter = sh.reporter,
        .reporter_ctx = sh.reporter_ctx,
    });
    var hosts = sh.host_builtins.iterator();
    while (hosts.next()) |e| try fresh.registerBuiltin(e.key_ptr.*, e.value_ptr.*);
    return fresh;
}

/// Run an already-expanded command (used by `command`); with `no_func` shell
/// functions are skipped.
/// Run `args` as a command, for `command`. `lookup` replaces PATH for finding it
/// only: the command itself, and what it runs, see PATH as it is.
pub fn runArgs(sh: *Shell, a: Allocator, args: []const []const u8, no_func: bool, lookup: ?[]const u8) u8 {
    sh.lookup_path = lookup;
    var r = resolve(sh, a, args[0]);
    if (no_func and r == .function) {
        r = if (builtins.find(args[0])) |b| .{ .builtin = b } else if (sh.host_builtins.get(args[0])) |h| .{ .host = h } else if (pathFind(sh, a, args[0], true)) |p| .{ .external = p } else .not_found;
    }
    const denied = r == .not_found and foundButNotExecutable(sh, a, args[0]);
    sh.lookup_path = null;
    const empty: ast.Simple = .{ .assigns = &.{}, .words = &.{}, .redirs = &.{} };
    switch (r) {
        .not_found => return reportMissing(sh, args[0], denied),
        .external => |p| return runExternal(sh, a, p, args, empty, &.{}, false),
        .special, .builtin => |b| return b.run(sh, a, args),
        .host => |h| return h.run(h.ctx, sh, args),
        .function => |f| return callFunction(sh, f, args[1..]),
    }
}

pub fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    const fd = sys.open(path, .{ .cloexec = true }, 0) catch return null;
    defer sys.close(fd);
    var data: std.ArrayList(u8) = .empty;
    sys.readToEnd(a, fd, &data, std.math.maxInt(usize)) catch return null;
    return data.items;
}

/// A startup file's text. One that is not there is passed over in silence; one
/// that is there and cannot be read is reported.
pub fn readStartup(sh: *Shell, a: Allocator, path: []const u8) ?[]const u8 {
    if (readFile(a, path)) |t| return t;
    const e = sys.errno();
    if (e != sys.E_NOENT and e != 20) sh.diagK(.cannot_open, path, "cannot open {s}: {s}", .{ path, sys.strerror(e) });
    return null;
}
