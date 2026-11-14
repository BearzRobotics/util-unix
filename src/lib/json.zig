// SPDX-License-Identifier: GPL-2.0-or-later
//! Minimal JSON output helpers for the `--json` modes (decision 0007).
//!
//! References: RFC 8259, sections 7 (strings) and 8.1 (encoding: UTF-8).
//!
//! Output only; there is no parser. Text that comes from the system (user
//! names, terminal names, host names) is not guaranteed to be UTF-8, but JSON
//! must be. A byte sequence that is not valid UTF-8 is written as U+FFFD
//! (one per offending byte), so the output always parses.

const std = @import("std");
const Io = std.Io;

/// Write `s` as a JSON string, quotes included.
pub fn writeString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31, 127 => try w.print("\\u{x:0>4}", .{b}),
            32...33, 35...91, 93...126 => try w.writeByte(b),
            else => {
                const n = std.unicode.utf8ByteSequenceLength(b) catch {
                    try w.writeAll("\\ufffd");
                    i += 1;
                    continue;
                };
                if (i + n <= s.len and n > 1 and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                    try w.writeAll(s[i .. i + n]);
                    i += n;
                } else {
                    try w.writeAll("\\ufffd");
                    i += 1;
                }
                continue;
            },
        }
        i += 1;
    }
    try w.writeByte('"');
}

/// Write `s` as a string, or `null` when it is absent.
pub fn writeOptString(w: *Io.Writer, s: ?[]const u8) Io.Writer.Error!void {
    if (s) |text| try writeString(w, text) else try w.writeAll("null");
}

fn expectString(input: []const u8, want: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeString(&w, input);
    try std.testing.expectEqualStrings(want, w.buffered());
}

test "escapes quotes, backslashes and control characters" {
    try expectString("a\"b\\c\n\t", "\"a\\\"b\\\\c\\n\\t\"");
    try expectString("\x01\x1f\x7f", "\"\\u0001\\u001f\\u007f\"");
}

test "valid UTF-8 passes through, invalid bytes become U+FFFD" {
    try expectString("caf\xc3\xa9", "\"caf\xc3\xa9\"");
    try expectString("a\xffb", "\"a\\ufffdb\"");
    try expectString("\xc3", "\"\\ufffd\""); // truncated sequence
    try expectString("\xc3(", "\"\\ufffd(\""); // bad continuation byte
}

test "absent text is null" {
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeOptString(&w, null);
    try std.testing.expectEqualStrings("null", w.buffered());
}
