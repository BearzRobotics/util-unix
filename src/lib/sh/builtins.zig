// SPDX-License-Identifier: GPL-2.0-or-later
//! Builtin utilities of the shell: the POSIX special builtins and the regular
//! builtins that must be built in (cd, read, getopts, command, ...).
//!
//! References: POSIX.1-2024 Shell Command Language 2.15 "Special Built-In
//! Utilities", and the utilities cd, command, echo, getopts, hash, kill,
//! printf, pwd, read, test, type, ulimit, umask, unalias, wait. Behaviour and
//! messages follow dash 0.5.12 where POSIX leaves them open.
//!
//! This file is the table of builtins; each family is in builtins/.

const std = @import("std");
const shell = @import("shell.zig");
const jobcmd = @import("jobcmd.zig");
const history = @import("history.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const aliasCmd = @import("builtins/lookup.zig").aliasCmd;
const bracketCmd = @import("builtins/test.zig").bracketCmd;
const brk = @import("builtins/flow.zig").brk;
const cdCmd = @import("builtins/cd.zig").cdCmd;
const colon = @import("builtins/flow.zig").colon;
const commandCmd = @import("builtins/lookup.zig").commandCmd;
const cont = @import("builtins/flow.zig").cont;
const dot = @import("builtins/flow.zig").dot;
const echoCmd = @import("builtins/printf.zig").echoCmd;
const eval = @import("builtins/flow.zig").eval;
const execCmd = @import("builtins/flow.zig").execCmd;
const exitCmd = @import("builtins/flow.zig").exitCmd;
const exportCmd = @import("builtins/vars.zig").exportCmd;
const falseCmd = @import("builtins/flow.zig").falseCmd;
const getoptsCmd = @import("builtins/vars.zig").getoptsCmd;
const hashCmd = @import("builtins/lookup.zig").hashCmd;
const killCmd = @import("builtins/process.zig").killCmd;
const localCmd = @import("builtins/vars.zig").localCmd;
const printfCmd = @import("builtins/printf.zig").printfCmd;
const pwdCmd = @import("builtins/cd.zig").pwdCmd;
const readCmd = @import("builtins/read.zig").readCmd;
const readonlyCmd = @import("builtins/vars.zig").readonlyCmd;
const returnCmd = @import("builtins/flow.zig").returnCmd;
const setCmd = @import("builtins/options.zig").setCmd;
const shiftCmd = @import("builtins/vars.zig").shiftCmd;
const testCmd = @import("builtins/test.zig").testCmd;
const timesCmd = @import("builtins/process.zig").timesCmd;
const trapCmd = @import("builtins/trap.zig").trapCmd;
const trueCmd = @import("builtins/flow.zig").trueCmd;
const typeCmd = @import("builtins/lookup.zig").typeCmd;
const ulimitCmd = @import("builtins/process.zig").ulimitCmd;
const umaskCmd = @import("builtins/process.zig").umaskCmd;
const unaliasCmd = @import("builtins/lookup.zig").unaliasCmd;
const unsetCmd = @import("builtins/vars.zig").unsetCmd;

// used by the rest of the shell and by the sh command
pub const quoteSingle = @import("builtins/common.zig").quoteSingle;
pub const knownOptName = @import("builtins/options.zig").knownOptName;
pub const setNamedOption = @import("builtins/options.zig").setNamedOption;
pub const setOption = @import("builtins/options.zig").setOption;

pub const Fn = *const fn (sh: *Shell, a: Allocator, args: []const []const u8) u8;

pub const Builtin = struct { run: Fn, special: bool };

const table = [_]struct { []const u8, Fn, bool }{
    .{ ":", colon, true },
    .{ ".", dot, true },
    .{ "break", brk, true },
    .{ "continue", cont, true },
    .{ "eval", eval, true },
    .{ "exec", execCmd, true },
    .{ "exit", exitCmd, true },
    .{ "export", exportCmd, true },
    .{ "readonly", readonlyCmd, true },
    .{ "return", returnCmd, true },
    .{ "set", setCmd, true },
    .{ "shift", shiftCmd, true },
    .{ "times", timesCmd, true },
    .{ "trap", trapCmd, true },
    .{ "unset", unsetCmd, true },
    .{ "alias", aliasCmd, false },
    .{ "cd", cdCmd, false },
    .{ "command", commandCmd, false },
    .{ "echo", echoCmd, false },
    .{ "false", falseCmd, false },
    .{ "getopts", getoptsCmd, false },
    .{ "hash", hashCmd, false },
    .{ "kill", killCmd, false },
    .{ "local", localCmd, false },
    .{ "printf", printfCmd, false },
    .{ "pwd", pwdCmd, false },
    .{ "read", readCmd, false },
    .{ "test", testCmd, false },
    .{ "[", bracketCmd, false },
    .{ "true", trueCmd, false },
    .{ "type", typeCmd, false },
    .{ "ulimit", ulimitCmd, false },
    .{ "umask", umaskCmd, false },
    .{ "unalias", unaliasCmd, false },
    .{ "wait", jobcmd.waitCmd, false },
    .{ "jobs", jobcmd.jobsCmd, false },
    .{ "fg", jobcmd.fgCmd, false },
    .{ "bg", jobcmd.bgCmd, false },
    .{ "fc", history.fcCmd, false },
};

/// Name of the i-th builtin (for completion).
pub fn nameAt(i: usize) ?[]const u8 {
    if (i >= table.len) return null;
    return table[i][0];
}

pub fn find(name: []const u8) ?Builtin {
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return .{ .run = e[1], .special = e[2] };
    return null;
}
