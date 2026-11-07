// SPDX-License-Identifier: GPL-2.0-or-later
//! Wrapper-side helper shared by id and groups: the warning for an id that has
//! no name. The library only reports the id (`identity.Unnamed`); the wording
//! and the stream belong to the executables.

const uu = @import("util_unix");
const cli = @import("cli.zig");

/// A `Unnamed` callback that prints GNU's "cannot find name for ... ID N"
/// warning. `ctx` must outlive the returned value's use.
pub fn unnamedWarning(ctx: *const cli.Context) uu.identity.Unnamed {
    return .{ .context = @constCast(ctx), .on_unnamed = unnamedCallback };
}

fn unnamedCallback(context: ?*anyopaque, kind: uu.identity.Kind, id: u32) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.warn(ctx.*, "cannot find name for {s} ID {d}", .{ if (kind == .user) "user" else "group", id });
}
