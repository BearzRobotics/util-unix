// SPDX-License-Identifier: GPL-2.0-or-later
//! chmod: thin wrapper over `util_unix.chmod` (src/lib/chmod.zig).
//!
//! Parses GNU chmod's options, validates in GNU's order, runs the engine on
//! each operand and formats its events as GNU's messages.
//!
//! References: POSIX.1-2024 chmod; GNU coreutils 9.7 manual "chmod invocation".

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const cm = uu.chmod;
const cli = @import("../cli.zig");

const long_names = [_][]const u8{ "changes", "silent", "quiet", "verbose", "dereference", "no-dereference", "no-preserve-root", "preserve-root", "reference", "recursive", "help", "version" };

const Parsed = struct {
    verbosity: cm.Verbosity = .off,
    quiet: bool = false,
    recurse: bool = false,
    preserve_root: bool = false,
    traversal: cm.Traversal = .command_line,
    no_deref: bool = false,
};

pub fn main(ctx: cli.Context) u8 {
    var p: Parsed = .{};
    var ref_file: ?[]const u8 = null;
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, &long_names, m);
                    return 1;
                },
            };
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (k == 8 and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--reference' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                    return 1;
                }
                value = ctx.args[i];
            } else if (k != 8 and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => p.verbosity = .changes,
                1, 2 => p.quiet = true,
                3 => p.verbosity = .verbose,
                4 => p.no_deref = false,
                5 => p.no_deref = true,
                6 => p.preserve_root = false,
                7 => p.preserve_root = true,
                8 => ref_file = value,
                9 => p.recurse = true,
                10 => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        // Short options; a letter that can only be part of a mode ("-w",
        // "-x", "-rwx") ends option parsing and is the MODE operand.
        var as_mode = false;
        for (a[1..]) |c| switch (c) {
            'c' => p.verbosity = .changes,
            'f' => p.quiet = true,
            'v' => p.verbosity = .verbose,
            'h' => p.no_deref = true,
            'R' => p.recurse = true,
            'H' => p.traversal = .command_line,
            'L' => p.traversal = .logical,
            'P' => p.traversal = .physical,
            'r', 'w', 'x', 'X', 's', 't', 'u', 'g', 'o', 'a' => as_mode = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
        if (as_mode) operands.append(ctx.gpa, a) catch return oom(ctx);
    }

    var change: cm.Change = undefined;
    if (ref_file == null) {
        if (operands.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
            return 1;
        }
        const text = operands.orderedRemove(0);
        if (operands.items.len == 0) {
            cli.warn(ctx, "missing operand after {f}\nTry '{s} --help' for more information.", .{ cli.quoteaf(text), ctx.name });
            return 1;
        }
        if (!cm.validMode(text)) {
            cli.warn(ctx, "invalid mode: {f}\nTry '{s} --help' for more information.", .{ cli.quoteaf(text), ctx.name });
            return 1;
        }
        change = .{ .mode_text = text };
    } else {
        if (operands.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
            return 1;
        }
        const st = Io.Dir.cwd().statFile(ctx.io, ref_file.?, .{}) catch |e| {
            cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteaf(ref_file.?), cli.errText(e) });
            return 1;
        };
        change = .{ .fixed = @intCast(st.permissions.toMode() & 0o7777) };
    }

    var rep: Reporter = .{ .ctx = ctx };
    const opts: cm.Options = .{
        .change = change,
        .umask = uu.proc.umask(),
        .recurse = p.recurse,
        .traversal = p.traversal,
        .no_dereference = p.no_deref,
        .verbosity = p.verbosity,
        .quiet = p.quiet,
        .reporter = .{ .context = &rep, .on_event = Reporter.on },
    };

    var status: u8 = 0;
    for (operands.items) |f| {
        if (p.recurse and p.preserve_root and cm.isRoot(ctx.io, f)) {
            const literal = std.mem.indexOfNone(u8, f, "/") == null;
            cli.warn(ctx, "it is dangerous to operate recursively on {f}{s}\nchmod: use --no-preserve-root to override this failsafe", .{ cli.quoteaf(f), if (literal) "" else " (same as '/')" });
            status = 1;
            continue;
        }
        const ok = cm.run(ctx.io, ctx.gpa, f, opts) catch return oom(ctx);
        if (!ok) status = 1;
    }
    return status;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

/// Formats engine events as GNU chmod's messages: diagnostics on standard
/// error, -c/-v reports on standard output.
const Reporter = struct {
    ctx: cli.Context,

    fn on(context: ?*anyopaque, ev: cm.Event) void {
        const r: *Reporter = @ptrCast(@alignCast(context.?));
        const ctx = r.ctx;
        switch (ev) {
            .changed => |c| {
                var buf: [8192]u8 = undefined;
                var os: [9]u8 = undefined;
                var ns: [9]u8 = undefined;
                const line = if (c.old == c.new)
                    std.fmt.bufPrint(&buf, "mode of {f} retained as {o:0>4} ({s})\n", .{ cli.quoteaf(c.path), c.new, uu.mode.modeString(&ns, c.new) })
                else
                    std.fmt.bufPrint(&buf, "mode of {f} changed from {o:0>4} ({s}) to {o:0>4} ({s})\n", .{ cli.quoteaf(c.path), c.old, uu.mode.modeString(&os, c.old), c.new, uu.mode.modeString(&ns, c.new) });
                _ = cli.writeStdout(ctx.io, line catch return);
            },
            .could_not_access => |path| {
                var buf: [8200]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{f} could not be accessed\n", .{cli.quoteaf(path)}) catch return;
                _ = cli.writeStdout(ctx.io, line);
            },
            .problem => |p| {
                const cause = if (p.cause) |c| cli.errText(c) else "";
                switch (p.kind) {
                    .cannot_access => cli.warn(ctx, "cannot access {f}: {s}", .{ cli.quoteaf(p.path), cause }),
                    .dangling_symlink => cli.warn(ctx, "cannot operate on dangling symlink {f}", .{cli.quoteaf(p.path)}),
                    .changing_permissions => cli.warn(ctx, "changing permissions of {f}: {s}", .{ cli.quoteaf(p.path), cause }),
                    .cannot_read_directory => cli.warn(ctx, "cannot read directory {f}: {s}", .{ cli.quoteaf(p.path), cause }),
                    .read_failed => cli.warn(ctx, "fts_read failed: {s}", .{cause}),
                }
            },
            .umask_kept => |u| {
                var b1: [9]u8 = undefined;
                var b2: [9]u8 = undefined;
                cli.warn(ctx, "{f}: new permissions are {s}, not {s}", .{ cli.quotef(u.path), uu.mode.modeString(&b1, u.got), uu.mode.modeString(&b2, u.wanted) });
            },
        }
    }
};

const help_text = "Usage: chmod [OPTION]... MODE[,MODE]... FILE...\n" ++
    "  or:  chmod [OPTION]... OCTAL-MODE FILE...\n" ++
    "  or:  chmod [OPTION]... --reference=RFILE FILE...\n" ++
    "Change the mode of each FILE to MODE.\n" ++
    "With --reference, change the mode of each FILE to that of RFILE.\n\n" ++
    "  -c, --changes          like verbose but report only when a change is made\n" ++
    "  -f, --silent, --quiet  suppress most error messages\n" ++
    "  -v, --verbose          output a diagnostic for every file processed\n" ++
    "      --dereference      affect the referent of each symbolic link,\n" ++
    "                           rather than the symbolic link itself\n" ++
    "  -h, --no-dereference   affect each symbolic link, rather than the referent\n" ++
    "      --no-preserve-root  do not treat '/' specially (the default)\n" ++
    "      --preserve-root    fail to operate recursively on '/'\n" ++
    "      --reference=RFILE  use RFILE's mode instead of specifying MODE values.\n" ++
    "                         RFILE is always dereferenced if a symbolic link.\n" ++
    "  -R, --recursive        change files and directories recursively\n\n" ++
    "The following options modify how a hierarchy is traversed when the -R\n" ++
    "option is also specified.  If more than one is specified, only the final\n" ++
    "one takes effect. -H is the default.\n\n" ++
    "  -H                     if a command line argument is a symbolic link\n" ++
    "                         to a directory, traverse it\n" ++
    "  -L                     traverse every symbolic link to a directory\n" ++
    "                         encountered\n" ++
    "  -P                     do not traverse any symbolic links\n\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n";
