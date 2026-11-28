// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: JSON string output (lib/json.zig). Whatever bytes go in, the output must
//! parse with std.json, and a string that is valid UTF-8 must come back unchanged.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const json = uu.json;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

fn jsonRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var buf: [256]u8 = undefined;
    const s = buf[0..smith.slice(&buf)];
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try json.writeString(&out.writer, s);
    var parsed = try std.json.parseFromSlice([]const u8, gpa, out.written(), .{});
    defer parsed.deinit();
    if (std.unicode.utf8ValidateSlice(s)) try std.testing.expectEqualStrings(s, parsed.value);
    // Never longer than six bytes per input byte plus the quotes.
    try std.testing.expect(out.written().len <= 6 * s.len + 2);

    var opt: Io.Writer.Allocating = .init(gpa);
    defer opt.deinit();
    try json.writeOptString(&opt.writer, s);
    try json.writeOptString(&opt.writer, null);
    try std.testing.expect(std.mem.endsWith(u8, opt.written(), "null"));
}

test "fuzz: JSON strings are always valid JSON" {
    try engine.fuzz({}, seed_mod.capped(void, jsonRun), .{ .name = "json-jsonRun", .corpus = &.{
        seed(.{"plain"}),
        seed(.{"quote\" backslash\\ tab\t nl\n cr\r"}),
        seed(.{"\x00\x01\x1f\x7f"}),
        seed(.{"caf\xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80"}),
        seed(.{"\xff\xfe\xc3\xe2\x82\xf0\x9f\x98"}),
        seed(.{"\xed\xa0\x80\xc0\x80\xf4\x90\x80\x80"}),
        seed(.{""}),
    } });
}
