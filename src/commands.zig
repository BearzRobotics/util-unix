// SPDX-License-Identifier: GPL-2.0-or-later
//! Command registry. Each command lives in src/commands/<name>.zig as a thin
//! wrapper exporting `pub fn main(ctx: cli.Context) u8`; the logic it calls
//! lives in the `util_unix` library (src/lib/).
//!
//! To add a command: create its library module and its wrapper, then add the
//! name to both `all` and `modules`.

const std = @import("std");
const cli = @import("cli.zig");

/// Every command this source tree knows about.
pub const all = [_][]const u8{ "chmod", "chown", "chgrp", "getent", "id", "groups", "tty", "uname" };

/// Command source files, keyed by command name. @import needs a string
/// literal, so each command is listed here explicitly. Importing a file only
/// parses it; a command's code is compiled into a binary only when `get`
/// references it.
pub const modules = .{
    .chmod = @import("commands/chmod.zig"),
    .chown = @import("commands/chown.zig"),
    .chgrp = @import("commands/chgrp.zig"),
    .getent = @import("commands/getent.zig"),
    .id = @import("commands/id.zig"),
    .groups = @import("commands/groups.zig"),
    .tty = @import("commands/tty.zig"),
    .uname = @import("commands/uname.zig"),
};

/// Frontend for a command known at comptime.
pub fn get(comptime name: []const u8) cli.CommandFn {
    return @field(modules, name).main;
}

/// Runtime lookup restricted to the `enabled` command names.
pub fn find(comptime enabled: []const []const u8, name: []const u8) ?cli.CommandFn {
    inline for (enabled) |e| {
        if (std.mem.eql(u8, e, name)) return get(e);
    }
    return null;
}
