// SPDX-License-Identifier: GPL-2.0-or-later
//! chcon: thin wrapper over `util_unix.chcon`.
//!
//! References: GNU coreutils 9.7 "chcon invocation". Exit status 0 on success,
//! 1 on any failure (usage errors included).

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const chcon = uu.chcon;
const cli = @import("../cli.zig");

const long_names = [_][]const u8{
    "dereference", "no-dereference", "no-preserve-root", "preserve-root", "recursive",
    "reference",   "verbose",        "user",             "role",          "type",
    "range",       "help",           "version",
};

const Opt = enum { dereference, no_dereference, no_preserve_root, preserve_root, recursive, reference, verbose, user, role, type, range, help, version };

pub fn main(ctx: cli.Context) u8 {
    var recurse = false;
    var verbose = false;
    var dereference: ?bool = null;
    var traversal: chcon.Traversal = .physical;
    var preserve_root = false;
    var reference: ?[]const u8 = null;
    var comps: uu.selinux.Components = .{};
    var operands = std.ArrayList([]const u8).empty;
    defer operands.deinit(ctx.gpa);

    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return 1;
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
            const opt: Opt = @fromBackingInt(@intCast(k));
            const takes = opt == .reference or opt == .user or opt == .role or opt == .type or opt == .range;
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (!takes and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            if (takes and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                    return 1;
                }
                value = ctx.args[i];
            }
            switch (opt) {
                .dereference => dereference = true,
                .no_dereference => dereference = false,
                .no_preserve_root => preserve_root = false,
                .preserve_root => preserve_root = true,
                .reference => reference = value,
                .recursive => recurse = true,
                .verbose => verbose = true,
                .user => comps.user = value,
                .role => comps.role = value,
                .type => comps.type = value,
                .range => comps.range = value,
                .help => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
                .version => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            switch (c) {
                'R' => recurse = true,
                'h' => dereference = false,
                'v' => verbose = true,
                'H' => traversal = .command_line,
                'L' => traversal = .logical,
                'P' => traversal = .physical,
                'u', 'r', 't', 'l' => {
                    const value: []const u8 = if (j + 1 < a.len) a[j + 1 ..] else blk: {
                        i += 1;
                        if (i >= ctx.args.len) {
                            cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
                            return 1;
                        }
                        break :blk ctx.args[i];
                    };
                    switch (c) {
                        'u' => comps.user = value,
                        'r' => comps.role = value,
                        't' => comps.type = value,
                        else => comps.range = value,
                    }
                    j = a.len;
                },
                else => {
                    cli.invalidShort(ctx, c);
                    return 1;
                },
            }
        }
    }

    if (recurse) {
        if (traversal == .physical) {
            if (dereference == true) {
                cli.warn(ctx, "-R --dereference requires either -H or -L", .{});
                return 1;
            }
            dereference = false;
        }
    } else traversal = .physical;
    const follow = dereference != false;

    var rest: []const []const u8 = operands.items;
    var full: ?[]u8 = null;
    defer if (full) |f| ctx.gpa.free(f);
    var target: chcon.Target = undefined;

    if (reference) |ref| {
        if (rest.len == 0) return missing(ctx, null);
        full = uu.selinux.getFileContext(ctx.gpa, ref, true) catch |e| {
            cli.warn(ctx, "failed to get security context of {f}: {s}", .{ cli.quoteaf(ref), contextErrText(e) });
            return 1;
        };
        target = .{ .full = full.? };
    } else if (comps.any()) {
        if (rest.len == 0) return missing(ctx, null);
        target = .{ .partial = comps };
    } else {
        if (rest.len == 0) return missing(ctx, null);
        const context = rest[0];
        rest = rest[1..];
        if (rest.len == 0) return missing(ctx, context);
        target = .{ .full = context };
    }

    var opts: chcon.Options = .{
        .target = target,
        .recurse = recurse,
        .traversal = traversal,
        .dereference = follow,
        .verbose = verbose,
        .reporter = undefined,
    };
    if (recurse and preserve_root) {
        opts.preserve_root = uu.fsown.statAt(Io.Dir.cwd(), "/", true) catch |e| {
            cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteaf("/"), cli.errText(e) });
            return 1;
        };
    }
    var rep: Reporter = .{ .ctx = ctx };
    opts.reporter = .{ .context = &rep, .on_event = Reporter.onEvent };
    const ok = chcon.run(ctx.io, ctx.gpa, opts, rest) catch {
        cli.warn(ctx, "memory exhausted", .{});
        return 1;
    };
    rep.flush();
    return if (ok) 0 else 1;
}

fn missing(ctx: cli.Context, after: ?[]const u8) u8 {
    if (after) |a| {
        cli.warn(ctx, "missing operand after {f}\nTry '{s} --help' for more information.", .{ cli.quoteaf(a), ctx.name });
    } else {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
    }
    return 1;
}

fn contextErrText(e: anyerror) []const u8 {
    return switch (e) {
        error.OutOfMemory => "Cannot allocate memory",
        else => uu.selinux.describe(@errorCast(e)),
    };
}

/// Formats engine events as GNU's messages.
const Reporter = struct {
    ctx: cli.Context,
    out_buf: [512]u8 = undefined,
    out_len: usize = 0,

    fn flush(r: *Reporter) void {
        if (r.out_len > 0) _ = cli.writeStdout(r.ctx.io, r.out_buf[0..r.out_len]);
        r.out_len = 0;
    }

    fn onEvent(context: ?*anyopaque, ev: chcon.Event) void {
        const r: *Reporter = @ptrCast(@alignCast(context.?));
        const ctx = r.ctx;
        switch (ev) {
            .changing => |path| {
                var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "changing security context of {f}\n", .{cli.quoteaf(path)}) catch return;
                _ = cli.writeStdout(ctx.io, line);
            },
            .problem => |p| {
                const cause: []const u8 = if (p.cause) |c| causeText(c) else "";
                switch (p.kind) {
                    .cannot_access => cli.warn(ctx, "cannot access {f}: {s}", .{ cli.quoteaf(p.path), cause }),
                    .cannot_read_directory => cli.warn(ctx, "cannot read directory {f}: {s}", .{ cli.quoteaf(p.path), cause }),
                    .read_failed => cli.warn(ctx, "fts_read failed: {s}", .{cause}),
                    .dangerous_root => {
                        cli.warn(ctx, "it is dangerous to operate recursively on {f}", .{cli.quoteaf(p.path)});
                        cli.warn(ctx, "use --no-preserve-root to override this failsafe", .{});
                    },
                    .unlabeled => cli.warn(ctx, "can't apply partial context to unlabeled file {f}", .{cli.quoteaf(p.path)}),
                    .get_failed => cli.warn(ctx, "failed to get security context of {f}: {s}", .{ cli.quoteaf(p.path), cause }),
                    .create_failed => cli.warn(ctx, "failed to create security context: {f}: {s}", .{ cli.quoteC(p.detail), cause }),
                    .set_component_failed => cli.warn(ctx, "failed to set {s} security context component to {f}: {s}", .{ @tagName(p.component.?), cli.quoteC(p.detail), cause }),
                    .change_failed => cli.warn(ctx, "failed to change context of {f} to {f}: {s}", .{ cli.quoteaf(p.path), cli.quoteC(p.detail), cause }),
                }
            },
        }
    }
};

fn causeText(c: anyerror) []const u8 {
    if (std.mem.eql(u8, @errorName(c), "NoContext")) return "No data available";
    return switch (c) {
        error.InvalidArgument => "Invalid argument",
        error.NotSupported => "Operation not supported",
        error.NoSpaceLeft => "No space left on device",
        else => cli.errText(c),
    };
}

const help_text = @embedFile("chcon_help.txt");
