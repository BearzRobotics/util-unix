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
const sys = @import("../../sys.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const expand = @import("expand.zig");
const pattern = @import("pattern.zig");
const builtins = @import("builtins.zig");
const lexer = @import("lexer.zig");
const diagmod = @import("diag.zig");
const shell = @import("shell.zig");
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
pub fn runSource(sh: *Shell, src: []const u8, o: RunOpts) error{OutOfMemory}!u8 {
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    const a = arena.allocator();
    var d: parser.Diag = .{};
    var p = try parser.Parser.initProgram(a, src, &d);
    p.aliases = .{ .ctx = sh, .get = aliasGet };
    const defined_before = sh.funcs_defined;
    const saved_src = sh.cur_src;
    sh.cur_src = src;
    defer sh.cur_src = saved_src;
    var last: u8 = 0;
    while (true) {
        const start = p.pos;
        const maybe = p.nextCommand() catch |e| switch (e) {
            error.Syntax => {
                sh.line = d.line;
                reportSyntax(sh, &d, o.prefix, src);
                sh.status = 2;
                sh.flow = .exit_shell;
                last = 2;
                break;
            },
            error.OutOfMemory => {
                arena.deinit();
                return error.OutOfMemory;
            },
        };
        if (p.warn_heredoc) |w| {
            p.warn_heredoc = null;
            var wd: diagmod.Diagnostic = .{ .code = 1003, .kind = .unterminated_heredoc, .severity = .warning, .label = sh.label, .line = w.line, .subject = w.delim, .posix = "here-document delimited by end-of-file", .source = src };
            sh.emit(&wd);
        }
        const node = maybe orelse break;
        if (sh.flags.verbose) {
            const end = @min(p.pos, src.len);
            if (end > start) sh.errRaw(std.mem.trimStart(u8, src[start..end], "\n"));
        }
        if (sh.flags.noexec) continue;
        last = execNode(sh, node);
        checkTraps(sh);
        if (sh.flow != .none) break;
    }
    if (sh.funcs_defined != defined_before) {
        sh.pinned.append(sh.gpa, arena) catch {};
    } else arena.deinit();
    return last;
}

/// Run a script read from descriptor `fd` incrementally, as dash does: a
/// command is parsed and executed as soon as it is complete, so a command
/// that reads standard input (`cat`, `read`) sees whatever the shell has not
/// yet buffered. The shell reads 8192 bytes at a time, like dash.
pub fn runStream(sh: *Shell, fd: i32) error{OutOfMemory}!u8 {
    const gpa = sh.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var start: usize = 0;
    var line: u32 = 1;
    var eof = false;
    var last: u8 = 0;
    const saved_src = sh.cur_src;
    defer sh.cur_src = saved_src;
    var chunk: [8192]u8 = undefined;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const a = arena.allocator();
        const defined_before = sh.funcs_defined;
        const text = a.dupe(u8, buf.items[start..]) catch {
            arena.deinit();
            return error.OutOfMemory;
        };
        var d: parser.Diag = .{};
        var p = parser.Parser.initProgram(a, text, &d) catch {
            arena.deinit();
            return error.OutOfMemory;
        };
        p.line = line;
        p.aliases = .{ .ctx = sh, .get = aliasGet };
        const maybe = p.nextCommand() catch |e| switch (e) {
            error.Syntax => {
                if (!eof and p.pos >= p.src.len) {
                    arena.deinit();
                    eof = readMore(gpa, &buf, fd, &chunk);
                    continue;
                }
                sh.cur_src = buf.items;
                sh.line = d.line;
                reportSyntax(sh, &d, "", buf.items);
                sh.status = 2;
                sh.flow = .exit_shell;
                arena.deinit();
                return 2;
            },
            error.OutOfMemory => {
                arena.deinit();
                return error.OutOfMemory;
            },
        };
        const tail = p.origTailLen();
        const complete = eof or (p.pos < p.src.len) or (p.src.len > 0 and p.src[p.src.len - 1] == '\n');
        if (!eof and (maybe == null or !complete or p.warn_heredoc != null)) {
            arena.deinit();
            eof = readMore(gpa, &buf, fd, &chunk);
            continue;
        }
        if (p.warn_heredoc) |w| {
            p.warn_heredoc = null;
            sh.cur_src = buf.items;
            var wd: diagmod.Diagnostic = .{ .code = 1003, .kind = .unterminated_heredoc, .severity = .warning, .label = sh.label, .line = w.line, .subject = w.delim, .posix = "here-document delimited by end-of-file", .source = buf.items };
            sh.emit(&wd);
        }
        const node = maybe orelse {
            arena.deinit();
            break;
        };
        const consumed = text.len - @min(tail, text.len);
        sh.cur_src = buf.items;
        if (sh.flags.verbose and consumed > 0) sh.errRaw(std.mem.trimStart(u8, text[0..consumed], "\n"));
        start += consumed;
        line = p.line;
        if (!sh.flags.noexec) {
            last = execNode(sh, node);
            checkTraps(sh);
        }
        if (sh.funcs_defined != defined_before) {
            sh.pinned.append(gpa, arena) catch {};
        } else arena.deinit();
        if (sh.flow != .none) break;
    }
    return last;
}

/// Append the next chunk of `fd` to `buf`; true at end of input.
fn readMore(gpa: Allocator, buf: *std.ArrayList(u8), fd: i32, chunk: *[8192]u8) bool {
    while (true) {
        const n = sys.read(fd, chunk) catch {
            if (sys.errno() == sys.E_INTR) continue;
            return true;
        };
        if (n == 0) return true;
        buf.appendSlice(gpa, chunk[0..n]) catch return true;
        return false;
    }
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
    };
    if (d.kind == .unterminated_quote or d.kind == .unterminated_arithmetic) dd.subject = if (d.opener) |o| o.name else "";
    if (d.kind == .missing_redirect_target) dd.subject = d.expected;
    if (d.kind == .bad_function_name) dd.subject = d.token;
    if (d.kind == .bad_for_variable) dd.subject = d.token;
    sh.emit(&dd);
}

// --- traps ------------------------------------------------------------------

/// Run the trap commands of signals that arrived since the last check.
pub fn checkTraps(sh: *Shell) void {
    if (!sys.signalsPending()) return;
    sys.clearPendingAny();
    var sig: u8 = 1;
    while (sig < sys.nsig) : (sig += 1) {
        if (!sys.takePending(sig)) continue;
        const cmd = sh.traps[sig] orelse continue;
        if (cmd.len == 0) continue;
        const saved = sh.status;
        const copy = sh.gpa.dupe(u8, cmd) catch continue;
        defer sh.gpa.free(copy);
        const prev_ts = sh.trap_status;
        sh.trap_status = saved;
        defer sh.trap_status = prev_ts;
        sh.in_trap += 1;
        const saved_flow = sh.flow;
        sh.flow = .none;
        _ = runSource(sh, copy, .{}) catch {};
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
    _ = runSource(sh, cmd, .{}) catch {};
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
        var d: diagmod.Diagnostic = .{ .code = 4005, .kind = .errexit_exit, .severity = .warning, .label = sh.label, .line = sh.line, .column = sh.cur_col, .end_column = sh.cur_end_col, .subject = what, .posix = "", .source = sh.cur_src };
        sh.emit(&d);
    }
}

const signal_text = [_][]const u8{
    "", "Hangup", "", "Quit", "Illegal instruction", "Trace/breakpoint trap", "Aborted", "Bus error", "Floating point exception", "Killed", "User defined signal 1", "Segmentation fault", "User defined signal 2", "", "Alarm clock", "Terminated", "Stack fault", "", "Continued", "Stopped (signal)", "Stopped", "Stopped (tty input)", "Stopped (tty output)", "Urgent I/O condition", "CPU time limit exceeded", "File size limit exceeded", "Virtual timer expired", "Profiling timer expired", "Window changed", "I/O possible", "Power failure", "Bad system call",
};

/// Wait for `pid`; on termination by a signal print dash's message.
pub fn waitFor(sh: *Shell, pid: i32, report: bool) u8 {
    while (true) {
        const r = sys.waitpid(pid, false) catch {
            if (sys.errno() == sys.E_INTR) continue;
            return 127;
        };
        if (report) {
            const sig = sys.statusSignal(r.status);
            if (sig != 0 and sig != 2 and sig != 13 and sig < signal_text.len and signal_text[sig].len > 0) {
                var buf: [96]u8 = undefined;
                const core = if (r.status & 0x80 != 0) " (core dumped)" else "";
                const msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ signal_text[sig], core }) catch "";
                sh.errRaw(msg);
            }
        }
        return sys.statusCode(r.status);
    }
}

fn childInit(sh: *Shell, bg: bool) void {
    sh.in_subshell = true;
    sh.trap_set = @splat(false);
    sh.jobs.clearRetainingCapacity();
    sys.clearPendingAny();
    var i: u8 = 0;
    while (i < sys.nsig) : (i += 1) {
        if (sh.traps[i]) |t| {
            if (t.len > 0 or i == 0) {
                if (sh.parent_traps[i]) |old| sh.gpa.free(old);
                sh.parent_traps[i] = t;
                sh.traps[i] = null;
                if (i > 0) _ = sys.setSignal(i, .default);
            }
        }
    }
    if (bg) {
        _ = sys.setSignal(2, .ignore);
        _ = sys.setSignal(3, .ignore);
    }
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
    stdin: ?i32 = null,
    stdout: ?i32 = null,
    close: []const i32 = &.{},
    devnull_stdin: bool = false,
    bg: bool = false,
};

fn forkRun(sh: *Shell, node: *const Node, cio: ChildIo) ?i32 {
    const pid = sys.fork() catch {
        sh.diagK(.cannot_fork, null, "Cannot fork", .{});
        return null;
    };
    if (pid != 0) return pid;
    childInit(sh, cio.bg);
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
        else => return execNode(sh, node),
    }
}

// --- nodes --------------------------------------------------------------------

pub fn execNode(sh: *Shell, node: *const Node) u8 {
    const st = execInner(sh, node);
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
                }
                checkTraps(sh);
                if (sh.flow != .none) return st;
            }
            return st;
        },
        .subshell => |body| {
            const b = body orelse return 0;
            const pid = forkRun(sh, b, .{}) orelse return 1;
            const st = waitFor(sh, pid, true);
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
            const gop = sh.funcs.getOrPut(sh.gpa, f.name) catch return 2;
            if (!gop.found_existing) gop.key_ptr.* = sh.gpa.dupe(u8, f.name) catch return 2;
            gop.value_ptr.* = f.body;
            sh.funcs_defined += 1;
            return 0;
        },
    }
}

fn spawnBackground(sh: *Shell, node: *const Node) u8 {
    const pid = forkRun(sh, node, .{ .devnull_stdin = !sh.flags.monitor, .bg = true }) orelse return 1;
    sh.bg_pid = pid;
    sh.jobs.append(sh.gpa, .{ .pid = pid }) catch {};
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
    if (negate) return @intFromBool(st == 0);
    errexitCheck(sh, st, "pipeline");
    return st;
}

fn runStages(sh: *Shell, cmds: []const *const Node) u8 {
    const gpa = sh.gpa;
    var pids = gpa.alloc(i32, cmds.len) catch return 2;
    defer gpa.free(pids);
    var fds: std.ArrayList(i32) = .empty;
    defer fds.deinit(gpa);
    var prev_read: ?i32 = null;
    var spawned: usize = 0;
    for (cmds, 0..) |c, i| {
        var next_pipe: ?[2]i32 = null;
        if (i + 1 < cmds.len) {
            next_pipe = sys.pipe() catch {
                sh.diagK(.cannot_fork, null, "Pipe call failed", .{});
                break;
            };
        }
        var closes: std.ArrayList(i32) = .empty;
        defer closes.deinit(gpa);
        if (prev_read) |r| closes.append(gpa, r) catch {};
        if (next_pipe) |np| {
            closes.append(gpa, np[0]) catch {};
            closes.append(gpa, np[1]) catch {};
        }
        const pid = forkRun(sh, c, .{
            .stdin = prev_read,
            .stdout = if (next_pipe) |np| np[1] else null,
            .close = closes.items,
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
        if (sh.flow != .none) return c;
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
        for (sh.params.items) |p| list.append(a, a.dupe(u8, p) catch return 2) catch return 2;
    }
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
            error.OutOfMemory => return 2,
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
    for (items) |it| {
        for (it.patterns) |pw| {
            const pat = expand.patternString(sh, a, pw) catch |e| return xerr(sh, e);
            if (pattern.match(pat, w)) return if (it.body) |b| execNode(sh, b) else 0;
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
                const fd = sys.open(path, flags, mode) catch {
                    openError(sh, path, flags.create);
                    return false;
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
                const m = std.fmt.parseInt(i32, word, 10) catch {
                    sh.diagKind(.bad_fd_number, word, "Syntax error: Bad fd number");
                    return false;
                };
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
    const copy: i32 = sys.dupAbove(n, 10) catch -1;
    s.saved.append(sh.gpa, .{ .fd = n, .saved = copy }) catch return false;
    return true;
}

/// Put the open descriptor `fd` at number `n` (closing `fd`).
fn place(sh: *Shell, fd: i32, n: i32, save: ?*Redirs) bool {
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
    const pid = forkRun(sh, node, .{ .stdout = p[1], .close = &.{ p[0], p[1] } }) orelse {
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
    var end = buf.items.len;
    while (end > 0 and buf.items[end - 1] == '\n') end -= 1;
    return buf.items[0..end];
}

// --- simple commands -----------------------------------------------------------------

fn xtrace(sh: *Shell, a: Allocator, s: ast.Simple, vals: []const []const u8, args: []const []const u8) void {
    var line: std.ArrayList(u8) = .empty;
    const ps4 = sh.getVar("PS4") orelse "+ ";
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
    function: *const Node,
    builtin: builtins.Builtin,
    host: shell.HostBuiltin,
    external: []const u8,
    not_found,
};

fn pathFind(sh: *Shell, a: Allocator, name: []const u8, want_exec: bool) ?[]const u8 {
    const path = sh.getVar("PATH") orelse "";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = if (dir.len == 0)
            std.fmt.allocPrint(a, "./{s}", .{name}) catch return null
        else
            std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch return null;
        const info = sys.stat(full, true) catch continue;
        if (info.kind == .dir) continue;
        if (want_exec and !sys.access(full, 1)) continue;
        return full;
    }
    return null;
}

pub fn resolve(sh: *Shell, a: Allocator, name: []const u8) Resolved {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return .{ .external = name };
    if (builtins.find(name)) |b| if (b.special) return .{ .special = b };
    if (sh.funcs.get(name)) |f| return .{ .function = f };
    if (builtins.find(name)) |b| return .{ .builtin = b };
    if (sh.host_builtins.get(name)) |h| return .{ .host = h };
    if (sh.hash.get(name)) |p| return .{ .external = p };
    if (pathFind(sh, a, name, true)) |p| return .{ .external = p };
    return .not_found;
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

fn execSimple(sh: *Shell, node: *const Node, s: ast.Simple, replace: bool) u8 {
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
            args.append(a, v) catch return 2;
        } else expand.fields(sh, a, &.{w}, &args) catch |e| return xerr(sh, e);
    }
    const vals = a.alloc([]const u8, s.assigns.len) catch return 2;
    // `export x=~` style operands expand tildes after `=` like assignments.
    for (vals) |*v| v.* = "";
    if (args.items.len > 0) {
        for (s.assigns, vals) |asg, *v| v.* = expand.assignValue(sh, a, asg.value) catch |e| return xerr(sh, e);
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
                error.OutOfMemory => return 2,
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
        const old: ?shell.Var = if (sh.vars.get("PATH")) |ov| .{ .value = if (ov.value) |x| sh.gpa.dupe(u8, x) catch null else null, .exported = ov.exported, .readonly = ov.readonly } else null;
        path_saved = .{ .name = sh.gpa.dupe(u8, "PATH") catch break, .old = old };
        sh.setVarRaw("PATH", v) catch {};
    };
    const r = resolve(sh, a, name);
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
                sh.diagK(.not_found, name, "{s}: not found", .{name});
                break :blk 127;
            }
            const pid = sys.fork() catch {
                sh.diagK(.cannot_fork, null, "Cannot fork", .{});
                break :blk 2;
            };
            if (pid == 0) {
                childInit(sh, false);
                if (!applyRedirs(sh, a, s.redirs, null)) sys.exit(2);
                sh.diagK(.not_found, name, "{s}: not found", .{name});
                sys.exit(127);
            }
            break :blk waitFor(sh, pid, true);
        },
        .external => |path| runExternal(sh, a, path, args.items, s, vals, replace),
        else => runInShell(sh, a, r, args.items, s, vals),
    };
    errexitCheck(sh, st, name);
    return st;
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

fn literalWord(w: ast.Word) ?[]const u8 {
    if (w.len != 1) return null;
    return switch (w[0]) {
        .text => |t| t,
        else => null,
    };
}

/// Index of the first operand of a declaration utility command, if it is one.
fn declStart(words: []const ast.Word) ?usize {
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const t = literalWord(words[i]) orelse return null;
        if (std.mem.eql(u8, t, "command")) continue;
        if (std.mem.eql(u8, t, "export") or std.mem.eql(u8, t, "readonly")) return i + 1;
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
    const is_exec = std.mem.eql(u8, args[0], "exec") or (args.len > 1 and std.mem.eql(u8, args[0], "command") and execBehindCommand(args);
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
            const old: ?shell.Var = if (sh.vars.get(asg.name)) |ov| .{
                .value = if (ov.value) |x| sh.gpa.dupe(u8, x) catch null else null,
                .exported = ov.exported,
                .readonly = ov.readonly,
            } else null;
            temps.append(sh.gpa, .{ .name = sh.gpa.dupe(u8, asg.name) catch return 2, .old = old }) catch return 2;
        }
        sh.setVar(asg.name, v) catch |e| switch (e) {
            error.ReadOnly => {
                saved.restore(sh.gpa);
                return assignError(sh, asg.name);
            },
            error.OutOfMemory => return 2,
        };
        if (!is_special or is_exec) sh.vars.getPtr(asg.name).?.exported = true;
    }
    var st: u8 = 0;
    switch (r) {
        .special, .builtin => |b| st = b.run(sh, a, args),
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

fn restoreVar(sh: *Shell, sv: shell.Saved) void {
    defer sh.gpa.free(sv.name);
    if (sv.old) |o| {
        if (sh.vars.getPtr(sv.name)) |cur| {
            if (cur.value) |x| sh.gpa.free(x);
            cur.* = o;
        } else {
            const key = sh.gpa.dupe(u8, sv.name) catch return;
            sh.vars.put(sh.gpa, key, o) catch {};
        }
    } else {
        if (sh.vars.getPtr(sv.name)) |cur| {
            if (cur.value) |x| sh.gpa.free(x);
            cur.value = null;
            cur.exported = false;
            if (!cur.readonly) if (sh.vars.fetchRemove(sv.name)) |kv| sh.gpa.free(kv.key);
        }
    }
}

pub fn callFunction(sh: *Shell, body: *const Node, args: []const []const u8) u8 {
    const gpa = sh.gpa;
    var old_params = sh.params;
    sh.params = .empty;
    sh.setParams(args) catch {
        sh.params = old_params;
        return 2;
    };
    const mark = sh.locals.items.len;
    sh.func_depth += 1;
    const saved_loops = sh.loop_depth;
    sh.loop_depth = 0;
    var st = execNode(sh, body);
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
        const pid = sys.fork() catch {
            sh.diagK(.cannot_fork, null, "Cannot fork", .{});
            return 2;
        };
        if (pid != 0) return waitFor(sh, pid, true);
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
    sys.execve(a, path, args, env.items) catch {};
    const e = sys.errno();
    if (e == sys.E_NOEXEC) {
        // A text file without #!: interpret it with this shell.
        const text = readFile(a, path) orelse {
            sh.diagK(.not_executable, args[0], "{s}: Permission denied", .{args[0]});
            sys.exit(126);
        };
        sh.setParams(args[1..]) catch {};
        sh.name = sh.gpa.dupe(u8, args[0]) catch sh.name;
        const st = runSource(sh, text, .{}) catch 2;
        childExit(sh, if (sh.flow == .exit_shell) sh.status else st);
    }
    if (e == sys.E_NOENT or e == sys.E_NOTDIR) {
        sh.diagK(.not_found, args[0], "{s}: not found", .{args[0]});
        sys.exit(127);
    }
    sh.diagK(if (e == sys.E_ACCES) .not_executable else .other, args[0], "{s}: {s}", .{ args[0], sys.strerror(e) });
    sys.exit(126);
}

/// Run an already-expanded command (used by `command`); with `no_func` shell
/// functions are skipped.
pub fn runArgs(sh: *Shell, a: Allocator, args: []const []const u8, no_func: bool) u8 {
    var r = resolve(sh, a, args[0]);
    if (no_func and r == .function) {
        r = if (builtins.find(args[0])) |b| .{ .builtin = b } else if (sh.host_builtins.get(args[0])) |h| .{ .host = h } else if (pathFind(sh, a, args[0], true)) |p| .{ .external = p } else .not_found;
    }
    const empty: ast.Simple = .{ .assigns = &.{}, .words = &.{}, .redirs = &.{} };
    switch (r) {
        .not_found => {
            sh.diagK(.not_found, args[0], "{s}: not found", .{args[0]});
            return 127;
        },
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
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &chunk) catch return null;
        if (n == 0) break;
        data.appendSlice(a, chunk[0..n]) catch return null;
    }
    return data.items;
}
