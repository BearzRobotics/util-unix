// SPDX-License-Identifier: GPL-2.0-or-later
//! The interactive shell: prompts, the read-eval loop, line editing on a
//! terminal, history, the ENV startup file and the signal rules of POSIX.1-2024
//! sh ("INTERACTIVE USE", XCU 2.5.3 PS1/PS2/ENV, "Signals and Error Handling").
//!
//! The loop reads one complete command at a time (continuing with PS2 while
//! the text is incomplete), runs it, enters it in the history, and before each
//! prompt reports finished jobs. On a terminal the line is edited by
//! `readline.zig` (emacs mode by default, `set -o vi` for vi mode); otherwise
//! it is read byte by byte so that commands which read standard input see the
//! rest of it. Prompts go to standard error.

const std = @import("std");
const numparse = @import("../num.zig");
const sys = @import("../../sys.zig");
const shell = @import("shell.zig");
const exec = @import("exec.zig");
const expand = @import("expand.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const jobs = @import("jobs.zig");
const history = @import("history.zig");
const readline = @import("readline.zig");
const completion = @import("completion.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

// --- prompts -----------------------------------------------------------------------

fn findHeredoc(n: *const ast.Node) ?ast.Word {
    switch (n.kind) {
        .simple => |s| {
            for (s.redirs) |r| if (r.op == .heredoc) return r.body;
            return null;
        },
        .list => |items| {
            for (items) |it| if (findHeredoc(it.node)) |w| return w;
            return null;
        },
        .pipeline => |p| {
            for (p.commands) |c| if (findHeredoc(c)) |w| return w;
            return null;
        },
        else => return null,
    }
}

/// Expand `text` as parameter expansion, command substitution and arithmetic
/// (as a here-document body would be), then replace `!` by the history
/// number and `!!` by a literal `!` (POSIX XCU 2.5.3 PS1).
pub fn expandPrompt(sh: *Shell, a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "$`\\!") == null) return text;
    const src = try std.fmt.allocPrint(a, "cat <<__PS_END__\n{s}\n__PS_END__\n", .{text});
    var d: parser.Diag = .{};
    var p = parser.Parser.init(a, src, &d);
    const node = (p.nextCommand() catch return text) orelse return text;
    const body = findHeredoc(node) orelse return text;
    const saved_status = sh.status;
    const expanded = expand.string(sh, a, body) catch return text;
    sh.status = saved_status;
    const s0 = std.mem.trimEnd(u8, expanded, "\n");
    var s = s0;
    if (std.mem.indexOfScalar(u8, s, '!') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    const num: u64 = if (sh.history) |h| h.nextNumber() else 1;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '!') {
            if (i + 1 < s.len and s[i + 1] == '!') {
                try out.append(a, '!');
                i += 1;
            } else try out.print(a, "{d}", .{num});
        } else try out.append(a, s[i]);
    }
    s = out.items;
    return s;
}

// --- completeness ---------------------------------------------------------------------

/// True when `text` is a complete command (or has a syntax error that more
/// input cannot fix); false when the parser ran out of input inside a
/// construct, a quote or a here-document.
pub fn isComplete(sh: *Shell, text: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    var d: parser.Diag = .{};
    var p = parser.Parser.init(arena.allocator(), text, &d);
    p.aliases = .{ .ctx = sh, .get = struct {
        fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
            const s: *Shell = @ptrCast(@alignCast(ctx));
            return s.aliases.get(name);
        }
    }.get };
    while (true) {
        const r = p.nextCommand() catch |e| switch (e) {
            error.Syntax => {
                if (d.kind == .unterminated_quote or d.kind == .unterminated_command_substitution or d.kind == .unterminated_arithmetic) return false;
                return d.token.len != 0;
            },
            error.OutOfMemory => return true,
        };
        if (p.warn_heredoc != null) return false;
        if (r == null) break;
    }
    // a trailing backslash-newline asks for more
    var n: usize = 0;
    const t = std.mem.trimEnd(u8, text, "\n");
    if (text.len > t.len) {
        while (t.len > n and t[t.len - 1 - n] == '\\') n += 1;
        if (n % 2 == 1) return false;
    }
    return true;
}

// --- terminal binding ---------------------------------------------------------------------

const TermCtx = struct {
    saved: ?sys.Termios = null,
    in_fd: i32 = 0,
    out_fd: i32 = 2,
};

fn tRead(ctx: ?*anyopaque, buf: []u8, timeout_ms: i32) readline.ReadResult {
    const t: *TermCtx = @ptrCast(@alignCast(ctx.?));
    if (timeout_ms >= 0) {
        if (!sys.pollIn(t.in_fd, timeout_ms)) {
            if (sys.errno() == sys.E_INTR and sys.peekPending(sys.SIGWINCH)) {
                _ = sys.takePending(sys.SIGWINCH);
                return .interrupted;
            }
            return .timeout;
        }
    }
    const n = sys.read(t.in_fd, buf) catch {
        if (sys.errno() == sys.E_INTR) {
            _ = sys.takePending(sys.SIGWINCH);
            _ = sys.takePending(2);
            return .interrupted;
        }
        return .eof;
    };
    if (n == 0) return .eof;
    return .{ .bytes = n };
}

fn tWrite(ctx: ?*anyopaque, bytes: []const u8) void {
    const t: *TermCtx = @ptrCast(@alignCast(ctx.?));
    sys.writeAll(t.out_fd, bytes) catch {};
}

fn tSize(ctx: ?*anyopaque) readline.Size {
    const t: *TermCtx = @ptrCast(@alignCast(ctx.?));
    if (sys.winsize(t.out_fd)) |w| return .{ .cols = w.cols, .rows = w.rows };
    return .{};
}

fn tRaw(ctx: ?*anyopaque, on: bool) void {
    const t: *TermCtx = @ptrCast(@alignCast(ctx.?));
    if (on) {
        const cur = sys.tcgetattr(t.in_fd) catch return;
        t.saved = cur;
        const raw = sys.termiosRaw(cur);
        sys.tcsetattr(t.in_fd, &raw) catch {};
    } else if (t.saved) |s| {
        sys.tcsetattr(t.in_fd, &s) catch {};
        t.saved = null;
    }
}

fn aliasLetter(ctx: ?*anyopaque, letter: u8) ?[]const u8 {
    const sh: *Shell = @ptrCast(@alignCast(ctx.?));
    const name = [1]u8{letter};
    return sh.aliases.get(&name);
}

// --- the loop ---------------------------------------------------------------------------------

pub const Session = struct {
    sh: *Shell,
    hist: history.History,
    term: TermCtx = .{},
    editor: readline.Editor,
    use_editor: bool,
    ignoreeof_count: u8 = 0,

    pub fn deinit(self: *Session) void {
        self.editor.deinit();
        self.hist.deinit();
        self.sh.history = null;
    }
};

fn varNum(sh: *Shell, name: []const u8) ?usize {
    const v = sh.getVar(name) orelse return null;
    return numparse.parseInt(usize, v, 10) catch null;
}

/// Enter interactive mode: job control, signals, history. Call after
/// `Shell.init`, before the first command.
pub fn setup(sh: *Shell, s: *Session, gpa: Allocator) void {
    sh.flags.interactive = true;
    s.* = .{ .sh = sh, .hist = history.History.init(gpa), .editor = undefined, .use_editor = false };
    sh.history = &s.hist;
    // POSIX: an interactive shell ignores SIGTERM, catches SIGINT (so that
    // `wait` and `read` are interrupted) and ignores SIGQUIT.
    // A signal that was ignored on entry stays ignored (and is what commands inherit).
    if (!sh.inherited_ignore[2]) _ = sys.setSignal(2, .catch_flag);
    if (!sh.inherited_ignore[3]) _ = sys.setSignal(3, .ignore);
    if (!sh.inherited_ignore[15]) _ = sys.setSignal(15, .ignore);
    _ = sys.setSignal(sys.SIGWINCH, .catch_flag);
    sh.flags.monitor = true;
    // before the job signals are ignored: a shell started in the background
    // has to be stoppable until it is brought to the foreground
    if (!jobs.enable(sh, true)) {
        sh.diagBareK(.no_job_control, null, "can't access tty; job control turned off");
        sh.flags.monitor = false;
    }
    sh.ignoreJobSignals();
    if (!sh.flags.vi and !sh.flags.emacs) sh.flags.emacs = true;
    const term_env = sh.getVar("TERM") orelse "";
    s.use_editor = sys.isatty(0) and sys.isatty(2) and !std.mem.eql(u8, term_env, "dumb");
    var ed = readline.Editor.init(gpa, .{ .ctx = &s.term, .read = tRead, .write = tWrite, .size = tSize, .setRaw = tRaw });
    ed.complete_fn = completion.complete;
    ed.cb_ctx = sh;
    ed.alias_fn = aliasLetter;
    if (s.use_editor) if (sys.tcgetattr(0)) |t| {
        const c = sys.termiosChars(t);
        if (c.erase != 0) ed.erase_char = c.erase;
        if (c.kill != 0) ed.kill_char = c.kill;
        if (c.eof != 0) ed.eof_char = c.eof;
    } else |_| {};
    s.editor = ed;
    if (sys.geteuid() == 0 and sh.getVar("PS1") != null and std.mem.eql(u8, sh.getVar("PS1").?, "$ ")) sh.setVarRaw("PS1", "# ") catch {};
}

/// Source the file named by ENV (after parameter expansion) as POSIX
/// requires for interactive shells.
pub fn runEnvFile(sh: *Shell) void {
    // POSIX: ignored when the real and effective ids differ
    if (sys.idsDiffer()) return;
    const raw = sh.getVar("ENV") orelse return;
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = expandPrompt(sh, a, raw) catch return;
    if (path.len == 0 or path[0] != '/') return;
    const text = exec.readFile(a, path) orelse return;
    const saved = sh.label;
    _ = exec.runSource(sh, text, .{}) catch |oe| sh.oom(oe);
    sh.label = saved;
    if (sh.flow == .interrupt or (sh.flow == .exit_shell and !sh.explicit_exit)) sh.flow = .none;
}

fn readPlainLine(sh: *Shell, a: Allocator, prompt: []const u8) ?[]const u8 {
    sh.errRaw(prompt);
    var line: std.ArrayList(u8) = .empty;
    var b: [1]u8 = undefined;
    while (true) {
        const n = sys.read(0, &b) catch {
            if (sys.errno() == sys.E_INTR) {
                if (sys.takePending(2)) {
                    sh.errRaw("\n");
                    return "\n";
                }
                continue;
            }
            return null;
        };
        if (n == 0) {
            if (line.items.len == 0) return null;
            line.append(a, '\n') catch return null;
            return line.items;
        }
        line.append(a, b[0]) catch return null;
        if (b[0] == '\n') return line.items;
    }
}

const Read = union(enum) { text: []const u8, eof, interrupted, edit: []const u8 };

fn readOne(s: *Session, a: Allocator, prompt: []const u8) Read {
    const sh = s.sh;
    if (s.use_editor and (sh.flags.vi or sh.flags.emacs)) {
        s.editor.mode = if (sh.flags.vi) .vi else .emacs;
        s.editor.history_first = s.hist.first;
        const r = s.editor.readLine(prompt, s.hist.lines()) catch return .eof;
        return switch (r) {
            .line => |l| .{ .text = a.dupe(u8, l) catch return .eof },
            .eof => .eof,
            .interrupted => .interrupted,
            .external_edit => |t| .{ .edit = a.dupe(u8, t) catch return .eof },
        };
    }
    const l = readPlainLine(sh, a, prompt) orelse return .eof;
    return .{ .text = l };
}

/// Edit `text` with $VISUAL/$EDITOR/vi (vi-mode `v`) and return what the user
/// left in the file.
fn externalEdit(sh: *Shell, a: Allocator, text: []const u8) ?[]const u8 {
    const tmpdir = sh.getVar("TMPDIR") orelse "/tmp";
    const path = std.fmt.allocPrint(a, "{s}/sh-edit.{d}", .{ tmpdir, sys.getpid() }) catch return null;
    const fd = sys.open(path, .{ .read = false, .write = true, .create = true, .trunc = true, .cloexec = true }, 0o600) catch return null;
    sys.writeAll(fd, text) catch {};
    sys.writeAll(fd, "\n") catch {};
    sys.close(fd);
    const ed = sh.getVar("VISUAL") orelse sh.getVar("EDITOR") orelse "vi";
    const cmd = std.fmt.allocPrint(a, "{s} '{s}'", .{ ed, path }) catch return null;
    // only what a successful editor leaves is run (POSIX fc and vi `v`)
    const st = exec.runSource(sh, cmd, .{}) catch 2;
    const out = if (st == 0) exec.readFile(a, path) else null;
    var buf: [4097]u8 = undefined;
    if (path.len < 4096) {
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        _ = std.os.linux.unlink(@ptrCast(&buf));
    }
    return out;
}

/// Run the interactive loop until `exit` or end of input; returns the exit
/// status.
pub fn loop(s: *Session) u8 {
    const sh = s.sh;
    // Loaded here, after the ENV file: it may set HISTFILE and HISTSIZE, and
    // the file is rewritten at exit from what was loaded.
    s.hist.setMax(varNum(sh, "HISTSIZE") orelse history.default_size);
    if (historyFile(sh)) |hf| s.hist.load(hf);
    while (true) {
        var arena = std.heap.ArenaAllocator.init(sh.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        sh.cmd_seq += 1;
        _ = sys.takePending(2);
        exec.checkTraps(sh);
        jobs.notify(sh);
        s.hist.setMax(varNum(sh, "HISTSIZE") orelse history.default_size);
        var text: std.ArrayList(u8) = .empty;
        var first = true;
        while (true) {
            const ps = if (first) (sh.getVar("PS1") orelse "$ ") else (sh.getVar("PS2") orelse "> ");
            const prompt = expandPrompt(sh, a, ps) catch ps;
            switch (readOne(s, a, prompt)) {
                .text => |l| {
                    // only input starts the count of ^D again
                    s.ignoreeof_count = 0;
                    text.appendSlice(a, l) catch |oe| return sh.oom(oe);
                },
                .interrupted => {
                    text.clearRetainingCapacity();
                    first = true;
                    break;
                },
                .edit => |t| {
                    if (externalEdit(sh, a, t)) |e| {
                        text.clearRetainingCapacity();
                        text.appendSlice(a, e) catch |oe| return sh.oom(oe);
                        sh.errRaw(e);
                    } else {
                        // nothing runs, not even earlier lines of the command
                        text.clearRetainingCapacity();
                        first = true;
                    }
                    break;
                },
                .eof => {
                    if (text.items.len > 0 and !first) {
                        // end of input inside a command: let the parser report it
                        break;
                    }
                    if (sh.flags.ignoreeof and s.ignoreeof_count < 10) {
                        s.ignoreeof_count += 1;
                        sh.errRaw("Use \"exit\" to leave shell.\n");
                        text.clearRetainingCapacity();
                        break;
                    }
                    if (sh.jc and jobs.anyStopped(sh) and sh.exit_warned + 1 != sh.cmd_seq) {
                        sh.exit_warned = sh.cmd_seq;
                        sh.diagBareK(.stopped_jobs, "", "You have stopped jobs.");
                        text.clearRetainingCapacity();
                        break;
                    }
                    return finish(s);
                },
            }
            first = false;
            if (isComplete(sh, text.items)) break;
        }
        const src = text.items;
        if (std.mem.trim(u8, src, " \t\n").len == 0) continue;
        sh.line = 0;
        s.hist.add(src) catch {};
        sh.hist_pending = true;
        _ = exec.runSource(sh, src, .{}) catch |oe| return sh.oom(oe);
        sh.hist_pending = false;
        if (sh.flow == .exit_shell and sh.explicit_exit) return finish(s);
        // start the prompt on a line of its own, after the terminal's "^C"
        if (sh.flow == .interrupt) sh.errRaw("\n");
        sh.flow = .none;
        sh.explicit_exit = false;
    }
}

/// HISTFILE, which like ENV is not used when the real and effective ids differ.
fn historyFile(sh: *Shell) ?[]const u8 {
    if (sys.idsDiffer()) return null;
    const path = sh.getVar("HISTFILE") orelse return null;
    return if (path.len > 0) path else null;
}

fn finish(s: *Session) u8 {
    const sh = s.sh;
    if (historyFile(sh)) |hf| s.hist.save(hf) catch |e| {
        sh.diagK(.history_error, null, "cannot save the history to {s}: {s}", .{ hf, switch (e) {
            error.Sys => sys.strerror(sys.errno()),
            error.OutOfMemory => "out of memory",
            error.NotRegularFile => "not a regular file",
            error.TooLarge => "the file is too large",
            error.FileChanging => "the file keeps being replaced",
        } });
    };
    jobs.hangupAll(sh);
    return sh.finish();
}
