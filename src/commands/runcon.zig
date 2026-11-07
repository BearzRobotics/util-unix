// SPDX-License-Identifier: GPL-2.0-or-later
//! runcon: thin wrapper over `util_unix.selinux`.
//!
//! References: GNU coreutils 9.7 "runcon invocation"; proc_pid_attr(5). Exit
//! status 125 when runcon itself fails, 126 when the command is found but cannot
//! be run, 127 when it cannot be found; otherwise the command's own status
//! (runcon replaces itself with the command).
//!
//! What was verified: the argument handling and every message up to and
//! including "may be used only on a SELinux kernel" (test/test_runcon.sh), and
//! printing the current context. The host used for development has no SELinux
//! policy, so the transition itself (writing /proc/self/attr/exec and running
//! the command) is written from proc_pid_attr(5) and has not been run against a
//! policy; its messages are not compared with GNU's. `-c/--compute` (compute
//! the transition context from the policy) is not supported.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const sel = uu.selinux;
const cli = @import("../cli.zig");

const long_names = [_][]const u8{ "compute", "type", "user", "role", "range", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var compute = false;
    var comps: sel.Components = .{};

    var i: usize = 0;
    // getopt "+": option parsing stops at the first operand.
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, &long_names, m);
                    return 125;
                },
            };
            const takes = k >= 1 and k <= 4;
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (!takes and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 125;
            }
            if (takes and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                    return 125;
                }
                value = ctx.args[i];
            }
            switch (k) {
                0 => compute = true,
                1 => comps.type = value,
                2 => comps.user = value,
                3 => comps.role = value,
                4 => comps.range = value,
                5 => return if (cli.writeStdout(ctx.io, help_text)) 0 else 125,
                else => return if (cli.printVersion(ctx)) 0 else 125,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            switch (c) {
                'c' => compute = true,
                'r', 't', 'u', 'l' => {
                    const value: []const u8 = if (j + 1 < a.len) a[j + 1 ..] else blk: {
                        i += 1;
                        if (i >= ctx.args.len) {
                            cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
                            return 125;
                        }
                        break :blk ctx.args[i];
                    };
                    switch (c) {
                        'r' => comps.role = value,
                        't' => comps.type = value,
                        'u' => comps.user = value,
                        else => comps.range = value,
                    }
                    j = a.len;
                },
                else => {
                    cli.invalidShort(ctx, c);
                    return 125;
                },
            }
        }
    }
    const operands = ctx.args[i..];

    if (operands.len == 0) {
        // Neither context nor command: show the current context.
        const cur = sel.currentContext(ctx.io, ctx.gpa) orelse {
            cli.warn(ctx, "failed to get current context: No such file or directory", .{});
            return 125;
        };
        defer ctx.gpa.free(cur);
        var buf: [4200]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}\n", .{cur}) catch return 125;
        return if (cli.writeStdout(ctx.io, line)) 0 else 125;
    }

    var rest: []const [:0]const u8 = operands;
    var given: ?[]const u8 = null;
    if (!compute and !comps.any()) {
        given = rest[0];
        rest = rest[1..];
    }
    if (rest.len == 0) {
        cli.warn(ctx, "no command specified\nTry '{s} --help' for more information.", .{ctx.name});
        return 125;
    }

    if (!sel.enabled(ctx.io, ctx.gpa)) {
        cli.warn(ctx, "{s} may be used only on a SELinux kernel", .{ctx.name});
        return 125;
    }
    if (compute) {
        cli.warn(ctx, "-c/--compute is not supported by this implementation", .{});
        return 125;
    }

    var built: ?[]u8 = null;
    defer if (built) |b| ctx.gpa.free(b);
    const context: []const u8 = given orelse blk: {
        const cur = sel.currentContext(ctx.io, ctx.gpa) orelse {
            cli.warn(ctx, "failed to get current context: No such file or directory", .{});
            return 125;
        };
        defer ctx.gpa.free(cur);
        var diag: sel.Edit = .{};
        built = sel.edit(ctx.gpa, cur, comps, &diag) catch |e| {
            switch (e) {
                error.BadContext => cli.warn(ctx, "failed to create security context: {f}", .{cli.quoteC(cur)}),
                error.BadComponent => cli.warn(ctx, "failed to set {s} security context component", .{@tagName(diag.bad.?)}),
                error.OutOfMemory => cli.warn(ctx, "memory exhausted", .{}),
            }
            return 125;
        };
        break :blk built.?;
    };

    sel.setExecContext(ctx.io, context) catch |e| {
        const why: []const u8 = switch (e) {
            error.InvalidArgument => "Invalid argument",
            error.AccessDenied => "Permission denied",
            error.Unsupported => "Operation not supported",
            error.Unexpected => "Unknown error",
        };
        cli.warn(ctx, "unable to set security context {f}: {s}", .{ cli.quoteC(context), why });
        return 125;
    };

    const argv = ctx.gpa.alloc([]const u8, rest.len) catch return 125;
    defer ctx.gpa.free(argv);
    for (rest, 0..) |r, k| argv[k] = r;
    const err = std.process.replace(ctx.io, .{ .argv = argv, .exe = .detect, .environ_map = ctx.environ });
    // replace() returns only on failure.
    cli.warn(ctx, "{f}: {s}", .{ cli.quoteC(rest[0]), cli.errText(err) });
    return if (err == error.FileNotFound) 127 else 126;
}

const help_text = @embedFile("runcon_help.txt");
