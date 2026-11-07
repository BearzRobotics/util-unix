// SPDX-License-Identifier: GPL-2.0-or-later
//! Unit-test root for the wrapper side: pulls in every command so
//! `zig build test` covers them. Library tests run from src/root.zig.
const std = @import("std");
const commands = @import("commands.zig");

test {
    _ = @import("cli.zig");
    _ = @import("sys.zig");
    inline for (commands.all) |name| {
        _ = commands.get(name);
        std.testing.refAllDecls(@field(commands.modules, name));
    }
}
