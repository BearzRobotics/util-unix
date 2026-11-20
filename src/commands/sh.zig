// SPDX-License-Identifier: GPL-2.0-or-later
//! sh: thin wrapper over `util_unix.sh`.
//!
//! sh [-abCefhimnuvx] [-o option] [+o option] [-c command [name [arg ...]] |
//!    -s | file [arg ...]]
//!
//! References: POSIX.1-2024 sh; behaviour and messages follow dash 0.5.12.

const std = @import("std");
const uu = @import("util_unix");
const sys = uu.sys;
const cli = @import("../cli.zig");
const sh = uu.sh;

const usage_text = "Usage: sh [-abCefhimnuvx] [-o option] [+o option] [-c command [name [arg ...]] | -s | file [arg ...]]\n";

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

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var flags: sh.Flags = .{};
    var command: ?[]const u8 = null;
    var from_stdin = false;
    var pending_opts: std.ArrayList(struct { name: []const u8, on: bool }) = .empty;
    defer pending_opts.deinit(gpa);
    var i: usize = 0;
    const args = ctx.args;
    while (i < args.len) {
        const a: []const u8 = args[i];
        if (a.len < 2 or (a[0] != '-' and a[0] != '+')) break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-")) {
            i += 1;
            break;
        }
        const on = a[0] == '-';
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            switch (a[j]) {
                'c' => if (on) {
                    command = "";
                    from_stdin = false;
                },
                's' => if (on) {
                    from_stdin = true;
                },
                'o' => {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "{s}: option requires an argument -- o", .{"Illegal option"});
                        return 2;
                    }
                    pending_opts.append(gpa, .{ .name = args[i], .on = on }) catch return 2;
                },
                else => {
                    var tmp: sh.Flags = flags;
                    _ = &tmp;
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
                        cli.warn(ctx, "Illegal option {c}{c}", .{ a[0], a[j] });
                        return 2;
                    }
                },
            }
        }
        i += 1;
    }
    var rest = args[i..];
    var name: []const u8 = ctx.name;
    var script: ?[]u8 = null;
    defer if (script) |s| gpa.free(s);
    var is_c = false;
    // `-c` was seen: the first operand is the command string.
    if (command != null) {
        is_c = true;
        if (rest.len == 0) {
            cli.warn(ctx, "-c requires an argument", .{});
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
        script = readAll(gpa, 0);
    } else {
        name = rest[0];
        rest = rest[1..];
        const fd = sys.open(name, .{ .cloexec = true }, 0) catch {
            var buf: [512]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "{s}: 0: Can't open {s}\n", .{ ctx.name, name }) catch return 127;
            sys.writeAll(2, m) catch {};
            return 127;
        };
        defer sys.close(fd);
        script = readAll(gpa, fd);
        // a file descriptor 10 or above is how shells keep the script open;
        // we read it whole instead.
    }
    if (from_stdin) flags.stdin_mode = true;

    var st_io = std.Io.Threaded.init_single_threaded;
    const shell = sh.Shell.init(.{ .io = st_io.io(), .gpa = gpa }, .{
        .name = name,
        .environ = ctx.environ,
        .flags = flags,
    }) catch return 2;
    defer shell.deinit();
    for (pending_opts.items) |o| {
        if (!sh.builtins.setNamedOption(shell, o.name, o.on)) {
            cli.warn(ctx, "Illegal option {s}o {s}", .{ if (o.on) "-" else "+", o.name });
            return 2;
        }
    }
    shell.setParams(rest) catch return 2;
    const text: []const u8 = if (is_c) command.? else (script orelse {
        cli.warn(ctx, "cannot read input", .{});
        return 2;
    });
    const st = shell.runString(text) catch return 2;
    _ = st;
    return shell.finish();
}

test "usage text names the synopsis" {
    try std.testing.expect(std.mem.startsWith(u8, usage_text, "Usage: sh"));
}
