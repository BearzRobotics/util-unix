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
pub const pattern = @import("sh/pattern.zig");
pub const expand = @import("sh/expand.zig");
pub const exec = @import("sh/exec.zig");
pub const builtins = @import("sh/builtins.zig");
pub const shell = @import("sh/shell.zig");

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
    _ = pattern;
    _ = expand;
    _ = exec;
    _ = builtins;
    _ = shell;
}
