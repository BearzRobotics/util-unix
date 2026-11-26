// SPDX-License-Identifier: GPL-2.0-or-later
//! `util_unix.sh`: a POSIX shell as a library (decision 0009).
//!
//! `Shell.init(env, options)` builds an interpreter; `runString` parses and
//! runs text; `parse` gives the syntax tree without running; hosts register
//! extra builtins with `registerBuiltin` and read or write variables with
//! `getVar`/`setVar`. The library never exits the process and reports
//! diagnostics through `Options.reporter` (default: standard error in dash's
//! format).

pub const ast = @import("sh/ast.zig");
pub const lexer = @import("sh/lexer.zig");
pub const parser = @import("sh/parser.zig");
pub const arith = @import("sh/arith.zig");
pub const fmtfloat = @import("sh/fmtfloat.zig");
pub const pattern = @import("sh/pattern.zig");
pub const expand = @import("sh/expand.zig");
pub const exec = @import("sh/exec.zig");
pub const builtins = @import("sh/builtins.zig");
pub const shell = @import("sh/shell.zig");
pub const diag = @import("sh/diag.zig");
pub const lint = @import("sh/lint.zig");
pub const jobs = @import("sh/jobs.zig");
pub const jobcmd = @import("sh/jobcmd.zig");
pub const history = @import("sh/history.zig");
pub const completion = @import("sh/completion.zig");
pub const interactive = @import("sh/interactive.zig");
pub const readline = @import("sh/readline.zig");

pub const Shell = shell.Shell;
pub const Env = shell.Env;
pub const Options = shell.Options;
pub const Flags = shell.Flags;
pub const Diagnostic = shell.Diagnostic;
pub const HostBuiltin = shell.HostBuiltin;

test {
    _ = ast;
    _ = lexer;
    _ = parser;
    _ = arith;
    _ = fmtfloat;
    _ = pattern;
    _ = expand;
    _ = exec;
    _ = builtins;
    _ = shell;
    _ = diag;
    _ = lint;
    _ = jobs;
    _ = jobcmd;
    _ = history;
    _ = readline;
    _ = completion;
    _ = interactive;
}

test "a shell that runs out of memory keeps its tables sound" {
    const std = @import("std");
    const quiet = struct {
        fn report(_: ?*anyopaque, _: *const shell.Diagnostic) void {}
        fn builtin(_: ?*anyopaque, _: *shell.Shell, _: []const []const u8) u8 {
            return 0;
        }
    };
    // fail every allocation in turn; the testing allocator reports what is
    // leaked or freed twice, and a bad table entry crashes `deinit`
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
        run: {
            const s = shell.Shell.init(.{ .io = std.testing.io, .gpa = failing.allocator() }, .{ .reporter = quiet.report }) catch break :run;
            defer s.deinit();
            s.registerBuiltin("hosted", .{ .run = quiet.builtin }) catch {};
            _ = s.runString("export X1; readonly Y1; alias a1=b; alias a1=c a2=d; hash sh sh; f() { :; }; f() { :; }; X2=1; X2=2 :; PATH=/bin :; hosted") catch {};
        }
        if (!failing.has_induced_failure) break;
    }
}
