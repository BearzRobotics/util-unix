// SPDX-License-Identifier: GPL-2.0-or-later
//! The shell's state: variables, functions, options, positional parameters,
//! traps and control-flow flags. Execution lives in `exec.zig`, expansion in
//! `expand.zig`, builtins in `builtins.zig`.
//!
//! The shell writes to file descriptors 0, 1 and 2 as the programs it
//! interprets do (redirections remap them, so the shell cannot hold a fixed
//! `Io.Writer`); it never prints anything on its own initiative, never calls
//! `exit`, and reports diagnostics through `reporter` when the host installs
//! one (otherwise to descriptor 2 in dash's `name: line: message` format).

const std = @import("std");
const sys = @import("../../sys.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const diagmod = @import("diag.zig");
const exec = @import("exec.zig");
const jobs_mod = @import("jobs.zig");
const Allocator = std.mem.Allocator;

pub const Env = struct {
    io: std.Io,
    gpa: Allocator,
};

pub const Var = struct {
    /// Owned; null when declared (exported/readonly) but unset.
    value: ?[]u8 = null,
    exported: bool = false,
    readonly: bool = false,
};

pub const Flags = struct {
    allexport: bool = false, // -a
    notify: bool = false, // -b
    noclobber: bool = false, // -C
    errexit: bool = false, // -e
    noglob: bool = false, // -f
    hashall: bool = false, // -h
    interactive: bool = false, // -i
    monitor: bool = false, // -m
    noexec: bool = false, // -n
    stdin_mode: bool = false, // -s
    nounset: bool = false, // -u
    verbose: bool = false, // -v
    xtrace: bool = false, // -x
    ignoreeof: bool = false,
    nolog: bool = false,
    vi: bool = false,
    emacs: bool = false,
    pipefail: bool = false,
};

pub const Flow = enum { none, break_loop, continue_loop, return_func, exit_shell };

/// A builtin supplied by the host program (DKDE, tests).
pub const HostBuiltin = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, sh: *Shell, args: []const []const u8) u8,
};

pub const Diagnostic = diagmod.Diagnostic;
pub const DiagStyle = diagmod.Style;

pub const Options = struct {
    /// `$0` and the diagnostic prefix.
    name: []const u8 = "sh",
    /// Program name in the rich diagnostic header (`sh: file:3:1: error...`).
    prog: []const u8 = "sh",
    /// Initial variables (the process environment). Not retained.
    environ: ?*const std.process.Environ.Map = null,
    flags: Flags = .{},
    /// How diagnostics are written when no `reporter` is installed.
    diag_style: DiagStyle = .posix,
    /// ANSI colour in the rich style (the host decides: terminal, NO_COLOR).
    diag_color: bool = false,
    /// Label for script name in diagnostics (`-c`, a path, `stdin`).
    label: []const u8 = "",
    /// Called instead of writing diagnostics to descriptor 2.
    reporter: ?*const fn (ctx: ?*anyopaque, d: *const Diagnostic) void = null,
    reporter_ctx: ?*anyopaque = null,
};

pub const Job = jobs_mod.Job;

pub const Saved = struct {
    name: []u8,
    old: ?Var,
};

pub const Shell = struct {
    env: Env,
    gpa: Allocator,
    name: []u8,
    prog: []u8,
    vars: std.StringHashMapUnmanaged(Var) = .empty,
    funcs: std.StringHashMapUnmanaged(*const ast.Node) = .empty,
    aliases: std.StringHashMapUnmanaged([]u8) = .empty,
    hash: std.StringHashMapUnmanaged([]u8) = .empty,
    host_builtins: std.StringHashMapUnmanaged(HostBuiltin) = .empty,
    params: std.ArrayList([]u8) = .empty,
    flags: Flags,
    status: u8 = 0,
    bg_pid: i32 = 0,
    pid: i32,
    line: u32 = 0,
    /// Line offset of the command currently being run (for `eval`).
    traps: [sys.nsig]?[]u8 = @splat(null),
    /// In a subshell: the traps the parent had when it was forked, reported
    /// by `trap` with no operands (POSIX.1-2024 2.14, trap) until the
    /// subshell sets that condition itself (`trap_set`).
    parent_traps: [sys.nsig]?[]u8 = @splat(null),
    trap_set: [sys.nsig]bool = @splat(false),
    /// Signals ignored by the shell on entry (cannot be trapped).
    inherited_ignore: [sys.nsig]bool = @splat(false),
    flow: Flow = .none,
    flow_count: u32 = 1,
    loop_depth: u32 = 0,
    func_depth: u32 = 0,
    /// Index into `locals` where the running function's `local` entries start.
    locals_base: usize = 0,
    source_depth: u32 = 0,
    /// Errexit is suppressed while this is non-zero.
    noerrexit: u32 = 0,
    in_subshell: bool = false,
    jobs: std.ArrayList(*Job) = .empty,
    job_stamp: u64 = 0,
    /// Job control is on (`set -m`): jobs get process groups.
    jc: bool = false,
    /// Controlling terminal descriptor (>= 10, close-on-exec) or -1.
    tty_fd: i32 = -1,
    shell_pgid: i32 = 0,
    tty_modes: ?sys.Termios = null,
    /// `exit` was requested explicitly (an interactive shell survives other
    /// errors that end a script).
    explicit_exit: bool = false,
    /// Number of the command being read by the interactive loop, and the one
    /// at which `exit` last warned about stopped jobs.
    cmd_seq: u64 = 0,
    exit_warned: u64 = 0,
    /// Interactive-shell services supplied by `interactive.zig`.
    history: ?*@import("history.zig").History = null,
    /// The command being run was entered in the history before it ran (it is
    /// the history's newest entry and `fc` does not see it).
    hist_pending: bool = false,
    /// Variables saved by `local`, restored when the function returns.
    locals: std.ArrayList(Saved) = .empty,
    /// Arenas of programs that defined functions; kept for the shell's life.
    pinned: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    funcs_defined: u32 = 0,
    reporter: ?*const fn (ctx: ?*anyopaque, d: *const Diagnostic) void = null,
    reporter_ctx: ?*anyopaque = null,
    /// getopts: position inside a grouped option argument.
    getopts_sub: usize = 0,
    getopts_last_optind: usize = 1,
    exit_status_override: ?u8 = null,
    in_exit_trap: bool = false,
    /// `$?` when the running trap action was entered: `exit` without an
    /// operand in a trap uses it (POSIX 2.14 exit).
    trap_status: ?u8 = null,
    /// Set while the shell is executing a trap handler.
    in_trap: u32 = 0,
    last_subst_status: ?u8 = null,
    /// Non-zero while a special builtin runs under `command` (errors do not
    /// end the shell).
    no_die: u32 = 0,
    diag_style: DiagStyle = .posix,
    diag_color: bool = false,
    label: []u8 = &.{},
    /// Source text being run and the command-word columns of the current
    /// simple command (for excerpts).
    cur_src: []const u8 = "",
    cur_col: u32 = 0,
    cur_end_col: u32 = 0,

    pub fn init(env: Env, options: Options) Allocator.Error!*Shell {
        const gpa = env.gpa;
        const self = try gpa.create(Shell);
        self.* = .{
            .env = env,
            .gpa = gpa,
            .name = try gpa.dupe(u8, options.name),
            .prog = try gpa.dupe(u8, options.prog),
            .flags = options.flags,
            .pid = sys.getpid(),
            .diag_style = options.diag_style,
            .diag_color = options.diag_color,
            .label = try gpa.dupe(u8, options.label),
            .reporter = options.reporter,
            .reporter_ctx = options.reporter_ctx,
        };
        errdefer self.deinit();
        if (options.environ) |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                if (!@import("lexer.zig").isName(e.key_ptr.*)) continue;
                try self.setVarRaw(e.key_ptr.*, e.value_ptr.*);
                self.vars.getPtr(e.key_ptr.*).?.exported = true;
            }
        }
        if (self.getVar("IFS") == null or true) try self.setVarRaw("IFS", " \t\n");
        self.vars.getPtr("IFS").?.exported = false;
        if (self.getVar("PATH") == null) try self.setVarRaw("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        try self.setVarRaw("OPTIND", "1");
        if (self.getVar("PS1") == null) try self.setVarRaw("PS1", "$ ");
        if (self.getVar("PS2") == null) try self.setVarRaw("PS2", "> ");
        if (self.getVar("PS4") == null) try self.setVarRaw("PS4", "+ ");
        var ppid_buf: [16]u8 = undefined;
        try self.setVarRaw("PPID", std.fmt.bufPrint(&ppid_buf, "{d}", .{sys.getppid()}) catch "");
        try self.initPwd();
        for ([_]u8{ 2, 3, 15 }) |s| _ = s;
        for (1..sys.nsig) |i| self.inherited_ignore[i] = sys.getSignal(@intCast(i)) == .ignore;
        return self;
    }

    /// Signals an interactive shell with job control ignores (POSIX: SIGTSTP,
    /// SIGTTIN, SIGTTOU; SIGINT/SIGQUIT/SIGTERM are handled by the loop).
    pub fn ignoreJobSignals(self: *Shell) void {
        _ = self;
        for ([_]u8{ 20, 21, 22 }) |s| _ = sys.setSignal(s, .ignore);
    }

    fn initPwd(self: *Shell) Allocator.Error!void {
        var buf: [4096]u8 = undefined;
        const phys = sys.getcwd(&buf) catch return;
        if (self.getVar("PWD")) |p| {
            if (p.len > 0 and p[0] == '/') {
                const a = sys.stat(p, true) catch null;
                const b = sys.stat(phys, true) catch null;
                if (a != null and b != null and a.?.ino == b.?.ino and a.?.dev == b.?.dev) {
                    self.vars.getPtr("PWD").?.exported = true;
                    return;
                }
            }
        }
        try self.setVarRaw("PWD", phys);
        self.vars.getPtr("PWD").?.exported = true;
    }

    pub fn deinit(self: *Shell) void {
        const gpa = self.gpa;
        var vit = self.vars.iterator();
        while (vit.next()) |e| {
            if (e.value_ptr.value) |v| gpa.free(v);
            gpa.free(e.key_ptr.*);
        }
        self.vars.deinit(gpa);
        var fit = self.funcs.iterator();
        while (fit.next()) |e| gpa.free(e.key_ptr.*);
        self.funcs.deinit(gpa);
        var ait = self.aliases.iterator();
        while (ait.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.aliases.deinit(gpa);
        var hit = self.hash.iterator();
        while (hit.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.hash.deinit(gpa);
        var bit = self.host_builtins.iterator();
        while (bit.next()) |e| gpa.free(e.key_ptr.*);
        self.host_builtins.deinit(gpa);
        for (self.params.items) |p| gpa.free(p);
        self.params.deinit(gpa);
        for (self.traps) |t| if (t) |s| gpa.free(s);
        jobs_mod.clearAll(self);
        for (self.parent_traps) |t| if (t) |s| gpa.free(s);
        self.jobs.deinit(gpa);
        for (self.locals.items) |l| {
            gpa.free(l.name);
            if (l.old) |o| if (o.value) |v| gpa.free(v);
        }
        self.locals.deinit(gpa);
        for (self.pinned.items) |*p| p.deinit();
        self.pinned.deinit(gpa);
        gpa.free(self.name);
        gpa.free(self.prog);
        gpa.free(self.label);
        gpa.destroy(self);
    }

    // --- variables ---------------------------------------------------------

    pub fn getVar(self: *const Shell, name: []const u8) ?[]const u8 {
        const v = self.vars.get(name) orelse return null;
        return v.value;
    }

    pub const SetError = error{ ReadOnly, OutOfMemory };

    /// Set a variable, honouring `readonly` and `set -a`.
    pub fn setVar(self: *Shell, name: []const u8, value: []const u8) SetError!void {
        if (self.vars.get(name)) |v| if (v.readonly) return error.ReadOnly;
        try self.setVarRaw(name, value);
        if (self.flags.allexport) self.vars.getPtr(name).?.exported = true;
    }

    /// Set a variable ignoring `readonly` (used for the shell's own
    /// variables such as PWD and OPTIND).
    pub fn setVarRaw(self: *Shell, name: []const u8, value: []const u8) Allocator.Error!void {
        const gpa = self.gpa;
        const copy = try gpa.dupe(u8, value);
        errdefer gpa.free(copy);
        const gop = try self.vars.getOrPut(gpa, name);
        if (gop.found_existing) {
            if (gop.value_ptr.value) |old| gpa.free(old);
            gop.value_ptr.value = copy;
        } else {
            errdefer _ = self.vars.remove(name);
            gop.key_ptr.* = try gpa.dupe(u8, name);
            gop.value_ptr.* = .{ .value = copy };
        }
    }

    pub fn unsetVar(self: *Shell, name: []const u8) SetError!void {
        const v = self.vars.getPtr(name) orelse return;
        if (v.readonly) return error.ReadOnly;
        if (v.value) |old| self.gpa.free(old);
        v.value = null;
        if (!v.exported and !v.readonly) {
            if (self.vars.fetchRemove(name)) |kv| self.gpa.free(kv.key);
        }
    }

    pub fn setExported(self: *Shell, name: []const u8, on: bool) Allocator.Error!void {
        const gop = try self.vars.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.exported = on;
    }

    pub fn setReadonly(self: *Shell, name: []const u8) Allocator.Error!void {
        const gop = try self.vars.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.readonly = true;
    }

    /// "NAME=value" strings of the exported variables, allocated from `a`.
    pub fn environ(self: *const Shell, a: Allocator) Allocator.Error![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var it = self.vars.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.exported) continue;
            const v = e.value_ptr.value orelse continue;
            try list.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ e.key_ptr.*, v }));
        }
        return list.toOwnedSlice(a);
    }

    /// Replace the positional parameters.
    pub fn setParams(self: *Shell, args: []const []const u8) Allocator.Error!void {
        var fresh: std.ArrayList([]u8) = .empty;
        errdefer {
            for (fresh.items) |p| self.gpa.free(p);
            fresh.deinit(self.gpa);
        }
        for (args) |a| try fresh.append(self.gpa, try self.gpa.dupe(u8, a));
        for (self.params.items) |p| self.gpa.free(p);
        self.params.deinit(self.gpa);
        self.params = fresh;
    }

    // --- output and diagnostics -------------------------------------------

    /// Write to standard output (descriptor 1). False on failure.
    pub fn out(self: *Shell, bytes: []const u8) bool {
        _ = self;
        sys.writeAll(1, bytes) catch return false;
        return true;
    }

    /// Write raw text to standard error (descriptor 2).
    pub fn errRaw(self: *Shell, bytes: []const u8) void {
        _ = self;
        sys.writeAll(2, bytes) catch {};
    }

    /// A diagnostic in dash's wording with an explicit catalog kind. `subject`
    /// is the name, path or number the rich message talks about; null means
    /// the whole formatted text.
    pub fn diagK(self: *Shell, kind: diagmod.Kind, subject: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        self.diagWith2(msg, false, .{ .kind = kind, .subject = subject orelse msg });
    }

    /// Like `diagK` for messages dash prints without any prefix (trap, getopts).
    pub fn diagBareK(self: *Shell, kind: diagmod.Kind, subject: ?[]const u8, msg: []const u8) void {
        self.diagWith2(msg, true, .{ .kind = kind, .subject = subject orelse msg });
    }

    /// `name: line: cmd: message` for builtins.
    pub fn diagCmdK(self: *Shell, kind: diagmod.Kind, subject: ?[]const u8, cmd: []const u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: " ++ fmt, .{cmd} ++ args) catch buf[0..0];
        self.diagWith2(msg, false, .{ .kind = kind, .subject = subject orelse msg });
    }

    /// Report with an explicit kind and a ready message.
    pub fn diagKind(self: *Shell, kind: diagmod.Kind, subject: []const u8, msg: []const u8) void {
        self.diagWith2(msg, false, .{ .kind = kind, .subject = subject });
    }

    fn diagWith2(self: *Shell, msg: []const u8, bare: bool, c: diagmod.Classified) void {
        const e = diagmod.entryOf(c.kind);
        var col = self.cur_col;
        var end_col = self.cur_end_col;
        if (self.line > 0 and self.cur_src.len > 0) {
            if (diagmod.sourceLine(self.cur_src, self.line)) |text| {
                if (diagmod.refine(text, self.cur_col, c.kind, c.subject)) |sp| {
                    col = sp.col;
                    end_col = sp.end;
                }
            }
        }
        var d: Diagnostic = .{
            .code = e.code,
            .kind = c.kind,
            .label = self.label,
            .line = self.line,
            .column = col,
            .end_column = end_col,
            .subject = c.subject,
            .posix = msg,
            .bare = bare,
            .source = self.cur_src,
        };
        self.emit(&d);
    }

    /// Hand a diagnostic to the host's reporter or render it to descriptor 2.
    pub fn emit(self: *Shell, d: *const Diagnostic) void {
        if (self.reporter) |r| {
            r(self.reporter_ctx, d);
            return;
        }
        if (d.severity == .warning and self.diag_style == .posix) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var dd = d.*;
        dd.prog = self.prog;
        const text = diagmod.render(arena.allocator(), &dd, self.name, self.diag_style, self.diag_color, self.flags.interactive) catch return;
        self.errRaw(text);
    }

    // --- registration for hosts -------------------------------------------

    /// Register a builtin implemented by the host. It is found before
    /// functions? No: after special builtins and functions, before `PATH`.
    pub fn registerBuiltin(self: *Shell, name: []const u8, b: HostBuiltin) Allocator.Error!void {
        const gop = try self.host_builtins.getOrPut(self.gpa, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, name);
        gop.value_ptr.* = b;
    }

    // --- running -----------------------------------------------------------

    pub const RunError = error{OutOfMemory};

    /// Parse and run `src`; returns the exit status of the last command.
    /// A syntax error is reported as a diagnostic and gives status 2.
    pub fn runString(self: *Shell, src: []const u8) RunError!u8 {
        return exec.runSource(self, src, .{});
    }

    /// Run a script read incrementally from a descriptor (standard input).
    pub fn runFd(self: *Shell, fd: i32) RunError!u8 {
        return exec.runStream(self, fd);
    }

    /// Parse without running (the library half of `sh -n`).
    pub fn parse(self: *Shell, src: []const u8, d: *parser.Diag) parser.Error!ast.Program {
        return parser.parseProgram(self.gpa, src, d);
    }

    /// True when the shell was asked to exit (`exit`, `set -e`, fatal error).
    pub fn exiting(self: *const Shell) bool {
        return self.flow == .exit_shell;
    }

    /// Run the EXIT trap and return the final exit status.
    pub fn finish(self: *Shell) u8 {
        exec.runExitTrap(self);
        return self.status;
    }
};
