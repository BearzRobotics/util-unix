// SPDX-License-Identifier: GPL-2.0-or-later
//! uname: thin wrapper over `util_unix.uname`.
//!
//! References: POSIX.1-2024 uname; GNU coreutils 9.7 "uname invocation".

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const cli = @import("../cli.zig");

const long_names = [_][]const u8{ "all", "kernel-name", "nodename", "kernel-release", "kernel-version", "machine", "processor", "hardware-platform", "operating-system", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var want: uu.uname.Fields = .{};
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            cli.warn(ctx, "extra operand {f}\nTry '{s} --help' for more information.", .{ cli.quoteaf(a), ctx.name });
            return 1;
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
            if (eq != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => want = .all,
                1 => want.kernel_name = true,
                2 => want.nodename = true,
                3 => want.kernel_release = true,
                4 => want.kernel_version = true,
                5 => want.machine = true,
                6 => want.processor = true,
                7 => want.hardware_platform = true,
                8 => want.operating_system = true,
                9 => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'a' => want = .all,
            's' => want.kernel_name = true,
            'n' => want.nodename = true,
            'r' => want.kernel_release = true,
            'v' => want.kernel_version = true,
            'm' => want.machine = true,
            'p' => want.processor = true,
            'i' => want.hardware_platform = true,
            'o' => want.operating_system = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    const info = uu.proc.uname();
    var buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    uu.uname.write(&info, want, &stdout.interface) catch return 1;
    stdout.interface.flush() catch return 1;
    return 0;
}

const help_text = "Usage: uname [OPTION]...\n" ++
    "Print certain system information.  With no OPTION, same as -s.\n\n" ++
    "  -a, --all                print all information, in the following order,\n" ++
    "                             except omit -p and -i if unknown:\n" ++
    "  -s, --kernel-name        print the kernel name\n" ++
    "  -n, --nodename           print the network node hostname\n" ++
    "  -r, --kernel-release     print the kernel release\n" ++
    "  -v, --kernel-version     print the kernel version\n" ++
    "  -m, --machine            print the machine hardware name\n" ++
    "  -p, --processor          print the processor type (non-portable)\n" ++
    "  -i, --hardware-platform  print the hardware platform (non-portable)\n" ++
    "  -o, --operating-system   print the operating system\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n";
