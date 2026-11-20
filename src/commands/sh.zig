// SPDX-License-Identifier: GPL-2.0-or-later
//! sh: thin wrapper over `util_unix.sh`.
//!
//! sh [-abCefhimnuvx] [-o option] [+o option] [-c command [name [arg ...]] |
//!    -s | file [arg ...]]
//! sh --check file | --explain CODE | --diagnostics-catalog
//!
//! References: POSIX.1-2024 sh; behaviour and messages follow dash 0.5.12.
//!
//! Diagnostics style (never affects stdout, exit statuses or any behaviour
//! POSIX specifies): `--diagnostics=posix|rich|json|gcc|auto` or the
//! environment variable SH_DIAGNOSTICS. `auto` (the default) is rich when
//! standard error is a terminal and posix (dash's one-line wording)
//! otherwise, so scripts that parse stderr keep working. Colour only in the
//! rich style, only on a terminal, never when NO_COLOR is set.

const std = @import("std");
const uu = @import("util_unix");
const sys = uu.sys;
const cli = @import("../cli.zig");
const sh = uu.sh;
const diag = sh.diag;

const usage_text = @embedFile("sh_help.txt");

fn readAll(gpa: std.mem.Allocator, fd: i32) ?[]u8 {
    var data: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &chunk) catch {
            if (sys.errno() == sys.E_INTR) continue;
            return null;
        };
        if (n == 0) break;
        data.appendSlice(gpa, chunk[0..n]) catch return null;
    }
    return data.toOwnedSlice(gpa) catch null;
}

/// argv[0] of this process (Linux), or null.
fn argv0(buf: *[512]u8) ?[]const u8 {
    const fd = sys.open("/proc/self/cmdline", .{ .cloexec = true }, 0) catch return null;
    defer sys.close(fd);
    const n = sys.read(fd, buf) catch return null;
    const end = std.mem.indexOfScalar(u8, buf[0..n], 0) orelse n;
    return if (end == 0) null else buf[0..end];
}

fn parseStyle(s: []const u8) ?diag.Style {
    if (std.mem.eql(u8, s, "posix")) return .posix;
    if (std.mem.eql(u8, s, "rich")) return .rich;
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "gcc")) return .gcc;
    return null;
}

fn writeOut(text: []const u8) void {
    sys.writeAll(1, text) catch {};
}

fn argError(ctx: cli.Context, style: diag.Style, comptime kind: diag.Kind, subject: []const u8, posix: []const u8) void {
    const e = diag.entryOf(kind);
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const d: diag.Diagnostic = .{ .code = e.code, .kind = kind, .subject = subject, .posix = posix };
    const text = diag.render(arena.allocator(), &d, ctx.name, style, false, false) catch return;
    sys.writeAll(2, text) catch {};
}

fn listOrExplain(ctx: cli.Context, list: bool, want: ?[]const u8, json: bool) u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (want) |w| {
        var code_text: []const u8 = w;
        if (code_text.len > 2 and (code_text[0] == 'S' or code_text[0] == 's') and (code_text[1] == 'H' or code_text[1] == 'h')) code_text = code_text[2..];
        const code = std.fmt.parseInt(u16, code_text, 10) catch 0;
        const e = diag.entryByCode(code) orelse {
            var buf: [200]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "{s}: no such diagnostic code: {s}\n", .{ ctx.name, w }) catch "";
            sys.writeAll(2, m) catch {};
            return 2;
        };
        writeOut((if (json) diag.explainJson(a, e) else diag.explain(a, e)) catch return 2);
        return 0;
    }
    if (list and json) {
        writeOut(diag.catalogJson(a) catch return 2);
        return 0;
    }
    var out: std.ArrayList(u8) = .empty;
    for (&diag.catalog) |*e| out.print(a, "SH{d} {s}\n", .{ e.code, @tagName(e.kind) }) catch return 2;
    writeOut(out.items);
    return 0;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var flags: sh.Flags = .{};
    var command: ?[]const u8 = null;
    var from_stdin = false;
    var check_mode = false;
    var login = false;
    var from_explicit_s = false;
    var style_opt: ?diag.Style = null;
    var color_mode: enum { auto, always, never } = .auto;
    var list_diag = false;
    var explain_arg: ?[]const u8 = null;
    var style_auto = true;
    if (cli.getenv(ctx, "SH_DIAGNOSTICS")) |v| {
        if (parseStyle(v)) |st| {
            style_opt = st;
            style_auto = false;
        }
    }
    var pending_opts: std.ArrayList(struct { name: []const u8, on: bool }) = .empty;
    defer pending_opts.deinit(gpa);
    var i: usize = 0;
    const args = ctx.args;
    while (i < args.len) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "-") or std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or (a[0] != '-' and a[0] != '+')) break;
        if (std.mem.startsWith(u8, a, "--")) {
            if (std.mem.startsWith(u8, a, "--diagnostics=")) {
                const v = a["--diagnostics=".len..];
                if (std.mem.eql(u8, v, "auto")) {
                    style_auto = true;
                    style_opt = null;
                } else if (parseStyle(v)) |st| {
                    style_opt = st;
                    style_auto = false;
                } else {
                    argError(ctx, .posix, .invocation_option, a, "Illegal option --diagnostics value");
                    return 2;
                }
            } else if (std.mem.eql(u8, a, "--check")) {
                check_mode = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                writeOut(usage_text);
                return 0;
            } else if (std.mem.eql(u8, a, "--version")) {
                return if (cli.printVersion(ctx)) 0 else 1;
            } else if (std.mem.eql(u8, a, "--diagnostics-catalog")) {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                writeOut(diag.catalogMarkdown(arena.allocator()) catch return 2);
                return 0;
            } else if (std.mem.eql(u8, a, "--list-diagnostics")) {
                list_diag = true;
            } else if (std.mem.startsWith(u8, a, "--color=") or std.mem.startsWith(u8, a, "--diagnostics-color=")) {
                const v = a[std.mem.indexOfScalar(u8, a, '=').? + 1 ..];
                if (std.mem.eql(u8, v, "auto")) {
                    color_mode = .auto;
                } else if (std.mem.eql(u8, v, "always")) {
                    color_mode = .always;
                } else if (std.mem.eql(u8, v, "never")) {
                    color_mode = .never;
                } else {
                    argError(ctx, .posix, .invocation_option, a, "Illegal option --color value (auto, always or never)");
                    return 2;
                }
            } else if (std.mem.eql(u8, a, "--explain")) {
                i += 1;
                if (i >= args.len) {
                    argError(ctx, .posix, .missing_argument, "--explain", "--explain requires a code such as SH1001");
                    return 2;
                }
                explain_arg = args[i];
            } else {
                var buf: [200]u8 = undefined;
                argError(ctx, style_opt orelse .posix, .invocation_option, a, std.fmt.bufPrint(&buf, "Illegal option {s}", .{a}) catch "Illegal option");
                return 2;
            }
            i += 1;
            continue;
        }
        const on = a[0] == '-';
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            switch (a[j]) {
                'l' => login = on,
                // `+c` is read like `-c` (dash and FreeBSD sh agree; POSIX does not define it)
                'c' => {
                    command = "";
                    from_stdin = false;
                },
                's' => if (on) {
                    from_stdin = true;
                    from_explicit_s = true;
                },
                'o' => {
                    i += 1;
                    if (i >= args.len) {
                        argError(ctx, style_opt orelse .posix, .missing_argument, "-o requires an argument", "-o requires an argument");
                        return 2;
                    }
                    pending_opts.append(gpa, .{ .name = args[i], .on = on }) catch return 2;
                },
                else => {
                    const ok = switch (a[j]) {
                        'a' => blk: {
                            flags.allexport = on;
                            break :blk true;
                        },
                        'b' => blk: {
                            flags.notify = on;
                            break :blk true;
                        },
                        'C' => blk: {
                            flags.noclobber = on;
                            break :blk true;
                        },
                        'e' => blk: {
                            flags.errexit = on;
                            break :blk true;
                        },
                        'f' => blk: {
                            flags.noglob = on;
                            break :blk true;
                        },
                        'h' => blk: {
                            flags.hashall = on;
                            break :blk true;
                        },
                        'i' => blk: {
                            flags.interactive = on;
                            break :blk true;
                        },
                        'm' => blk: {
                            flags.monitor = on;
                            break :blk true;
                        },
                        'n' => blk: {
                            flags.noexec = on;
                            break :blk true;
                        },
                        'u' => blk: {
                            flags.nounset = on;
                            break :blk true;
                        },
                        'v' => blk: {
                            flags.verbose = on;
                            break :blk true;
                        },
                        'x' => blk: {
                            flags.xtrace = on;
                            break :blk true;
                        },
                        else => false,
                    };
                    if (!ok) {
                        var buf: [64]u8 = undefined;
                        const opt = std.fmt.bufPrint(&buf, "{c}{c}", .{ a[0], a[j] }) catch "-?";
                        var buf2: [96]u8 = undefined;
                        argError(ctx, style_opt orelse .posix, .invocation_option, opt, std.fmt.bufPrint(&buf2, "Illegal option {s}", .{opt}) catch "Illegal option");
                        return 2;
                    }
                },
            }
        }
        i += 1;
    }
    if (list_diag or explain_arg != null) return listOrExplain(ctx, list_diag, explain_arg, style_opt == .json);
    var rest = args[i..];
    // $0 of a script read from standard input is the name the shell was invoked by
    var argv0_buf: [512]u8 = undefined;
    var name: []const u8 = ctx.name;
    var label: []const u8 = "stdin";
    var script: ?[]u8 = null;
    defer if (script) |s| gpa.free(s);
    var is_c = false;
    if (check_mode) {
        if (rest.len == 0) {
            argError(ctx, .posix, .missing_argument, "--check", "--check requires a script file");
            return 2;
        }
        from_stdin = false;
        command = null;
    }
    if (command != null) {
        is_c = true;
        label = "-c";
        if (rest.len == 0) {
            argError(ctx, style_opt orelse .posix, .missing_argument, "-c requires an argument", "-c requires an argument");
            return 2;
        }
        command = rest[0];
        rest = rest[1..];
        if (rest.len > 0) {
            name = rest[0];
            rest = rest[1..];
        }
    } else if (from_stdin or rest.len == 0) {
        from_stdin = true;
        name = argv0(&argv0_buf) orelse ctx.name;
        // Interactive: -i, or standard input and error are terminals (POSIX sh, "Interactive").
        if (!flags.interactive and !check_mode and sys.isatty(0) and sys.isatty(2) and !from_explicit_s) flags.interactive = true;
    } else {
        name = rest[0];
        label = rest[0];
        rest = rest[1..];
        const fd = sys.open(name, .{ .cloexec = true }, 0) catch {
            var buf: [512]u8 = undefined;
            argError(ctx, style_opt orelse .posix, .cannot_open_script, name, std.fmt.bufPrint(&buf, "0: Can't open {s}", .{name}) catch "Can't open script");
            return 127;
        };
        defer sys.close(fd);
        script = readAll(gpa, fd);
    }
    if (from_stdin) flags.stdin_mode = true;

    // Diagnostics style: explicit, else rich on a terminal, else posix.
    const tty = sys.isatty(2);
    const style: diag.Style = style_opt orelse if (style_auto and tty) .rich else .posix;
    const color = style == .rich and switch (color_mode) {
        .always => true,
        .never => false,
        .auto => tty and cli.getenv(ctx, "NO_COLOR") == null,
    };

    var st_io = std.Io.Threaded.init_single_threaded;
    const shell = sh.Shell.init(.{ .io = st_io.io(), .gpa = gpa }, .{
        .name = name,
        .prog = ctx.name,
        .environ = ctx.environ,
        .flags = flags,
        .diag_style = style,
        .diag_color = color,
        .label = label,
    }) catch return 2;
    defer shell.deinit();
    for (pending_opts.items) |o| {
        if (!sh.builtins.setNamedOption(shell, o.name, o.on)) {
            cli.warn(ctx, "Illegal option {s}o {s}", .{ if (o.on) "-" else "+", o.name });
            return 2;
        }
    }
    shell.setParams(rest) catch return 2;
    if (login) runProfiles(shell);
    var session: sh.interactive.Session = undefined;
    var have_session = false;
    defer if (have_session) session.deinit();
    if (shell.flags.interactive and !check_mode) {
        sh.interactive.setup(shell, &session, gpa);
        have_session = true;
        if (from_stdin) {
            sh.interactive.runEnvFile(shell);
            return sh.interactive.loop(&session);
        }
    } else if (shell.flags.monitor) {
        _ = sh.jobs.enable(shell, false);
    }
    if (from_stdin and !check_mode) {
        _ = shell.runFd(0) catch return 2;
        return shell.finish();
    }
    const text: []const u8 = if (is_c) command.? else (script orelse {
        cli.warn(ctx, "cannot read input", .{});
        return 2;
    });
    if (check_mode) return runCheck(ctx, shell, text, label, if (style == .posix) .gcc else style);
    _ = shell.runString(text) catch return 2;
    return shell.finish();
}

/// Login shell: /etc/profile, then ~/.profile (POSIX sh -l).
fn runProfiles(shell: *sh.Shell) void {
    var arena = std.heap.ArenaAllocator.init(shell.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (sh.exec.readFile(a, "/etc/profile")) |t| _ = sh.exec.runSource(shell, t, .{}) catch {};
    if (shell.getVar("HOME")) |h| {
        const p = std.fmt.allocPrint(a, "{s}/.profile", .{h}) catch return;
        if (sh.exec.readFile(a, p)) |t| _ = sh.exec.runSource(shell, t, .{}) catch {};
    }
}

/// `sh --check`: parse (reporting syntax errors), then run the lint checks.
/// Exit 0 when clean, 1 with findings, 2 on a syntax error.
fn runCheck(ctx: cli.Context, shell: *sh.Shell, text: []const u8, label: []const u8, style: diag.Style) u8 {
    shell.flags.noexec = true;
    const st = shell.runString(text) catch return 2;
    if (st != 0) return 2;
    var d: sh.parser.Diag = .{};
    var prog = shell.parse(text, &d) catch return 2;
    defer prog.deinit();
    var findings: std.ArrayList(sh.lint.Finding) = .empty;
    defer findings.deinit(ctx.gpa);
    sh.lint.check(ctx.gpa, prog.commands, &findings) catch return 2;
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    for (findings.items) |f| {
        const e = diag.entryOf(f.kind);
        const dd: diag.Diagnostic = .{
            .code = e.code,
            .kind = f.kind,
            .severity = .warning,
            .label = label,
            .line = f.line,
            .column = f.column,
            .end_column = f.end_column,
            .subject = f.subject,
            .posix = e.summary,
            .source = text,
        };
        const out = diag.render(arena.allocator(), &dd, ctx.name, style, false, false) catch return 2;
        sys.writeAll(2, out) catch {};
    }
    return if (findings.items.len > 0) 1 else 0;
}

test "usage text names the synopsis" {
    try std.testing.expect(std.mem.startsWith(u8, usage_text, "Usage: sh"));
}
