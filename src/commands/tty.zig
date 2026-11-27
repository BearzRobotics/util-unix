// SPDX-License-Identifier: GPL-2.0-or-later
//! tty: thin wrapper over `util_unix.tty`.
//!
//! References: POSIX.1-2024 tty; GNU coreutils 9.7 "tty invocation".
//! Exit status 0 on a terminal, 1 when not, 2 for bad usage, 3 on a write
//! error (the GNU values).

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix").tty;
const cli = @import("../cli.zig");

const long_names = [_][]const u8{ "silent", "quiet", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var silent = false;
    var options = true;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (options and std.mem.eql(u8, a, "--")) {
            options = false;
            continue;
        }
        if (!options or a.len < 2 or a[0] != '-') {
            cli.warn(ctx, "extra operand {f}\nTry '{s} --help' for more information.", .{ cli.quoteaf(a), ctx.name });
            return 2;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0, 1 => silent = true,
                    2 => return if (cli.writeStdout(ctx, help_text)) 0 else 3,
                    else => return if (cli.printVersion(ctx)) 0 else 3,
                },
                else => {
                    cli.badLong(ctx, a, &long_names, m);
                    return 2;
                },
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            's' => silent = true,
            else => {
                cli.invalidShort(ctx, c);
                return 2;
            },
        };
    }

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const name = uu.name(ctx.io, Io.File.stdin(), &buf);
    if (name == null) {
        if (!silent and !cli.writeStdout(ctx, "not a tty\n")) return 3;
        return 1;
    }
    if (silent) return 0;
    var line: [Io.Dir.max_path_bytes + 1]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{s}\n", .{name.?}) catch return 3;
    return if (cli.writeStdout(ctx, text)) 0 else 3;
}

const help_text = "Usage: tty [OPTION]...\n" ++
    "Print the file name of the terminal connected to standard input.\n\n" ++
    "  -s, --silent, --quiet   print nothing, only return an exit status\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n";
