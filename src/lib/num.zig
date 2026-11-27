// SPDX-License-Identifier: GPL-2.0-or-later
//! Number parsing for what users and system files say.
//! `std.fmt.parseInt` accepts `_` between digits, as in Zig source, so that
//! "7_77" would be a file mode and "1_000" a user id or a process to kill.
//! Use this instead for any text that is not Zig.

const std = @import("std");

/// `std.fmt.parseInt`, with `_` an invalid character.
pub fn parseInt(comptime T: type, text: []const u8, base: u8) std.fmt.ParseIntError!T {
    if (std.mem.indexOfScalar(u8, text, '_') != null) return error.InvalidCharacter;
    return std.fmt.parseInt(T, text, base);
}

test "underscores are not digits" {
    const t = std.testing;
    try t.expectEqual(@as(u16, 0o755), try parseInt(u16, "755", 8));
    try t.expectEqual(@as(i32, -12), try parseInt(i32, "-12", 10));
    for ([_][]const u8{ "7_55", "0_0", "1_000", "_1", "1_" }) |s| {
        try t.expectError(error.InvalidCharacter, parseInt(u32, s, 10));
    }
    try t.expectError(error.Overflow, parseInt(u8, "256", 10));
}
