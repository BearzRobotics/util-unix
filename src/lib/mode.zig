// SPDX-License-Identifier: GPL-2.0-or-later
//! File mode operands as understood by chmod(1).
//!
//! References: POSIX.1-2024 chmod (octal and symbolic modes, the "mode"
//! operand grammar):
//! https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html ;
//! GNU coreutils 9.7 manual, "File permissions" (umask handling when no `who`
//! is given, `X`, copy-from-class permissions, special bits).
//!
//! Grammar (symbolic):  clause[,clause]...   clause = [ugoa]*  (op perm*)+
//!   op   = + - =
//!   perm = r w x X s t   or a single u g o (copy that class's permissions)
//! GNU also takes octal digits after an operator, in a clause with no who
//! letter, to the end of the clause ("=755", "+111").
//! Octal: octal digits, value at most 07777.
//!
//! Semantics were checked against GNU 9.7 (test/test_chmod.sh): with no `who`,
//! all classes are affected but the bits in the umask are left alone for + and
//! - and are not set by =.
//! Pure functions: no I/O, no allocation.

const std = @import("std");
const num = @import("num.zig");

const all_bits: u16 = 0o7777;

/// A directory's set-user-ID and set-group-ID bits.
const set_id_bits: u16 = 0o6000;

/// Apply `text` to `old` and return the new mode, or null when the text is
/// not a valid mode. `umask` is used only for clauses without a `who`.
///
/// `is_dir` matters for `X`, and because a directory keeps its set-user-ID and
/// set-group-ID bits through each part of the mode that does not name them: a
/// symbolic clause names the bits it gives its classes (`s`), and an octal mode
/// of fewer than five digits names only those it sets (GNU).
pub fn apply(text: []const u8, old: u16, is_dir: bool, umask: u16) ?u16 {
    if (text.len == 0) return null;
    if (std.ascii.isDigit(text[0])) {
        const v = octalValue(text) orelse return null;
        const named: u16 = if (text.len < 5) (v & set_id_bits) | 0o1777 else all_bits;
        const kept = if (is_dir) set_id_bits & ~named else 0;
        return v | (old & kept);
    }
    var mode = old;
    var i: usize = 0;
    while (true) {
        // who
        var who: u16 = 0;
        var mentioned = false;
        while (i < text.len) : (i += 1) {
            switch (text[i]) {
                'u' => who |= 0o4700,
                'g' => who |= 0o2070,
                'o' => who |= 0o1007,
                'a' => who |= all_bits,
                else => break,
            }
            mentioned = true;
        }
        if (!mentioned) who = all_bits;
        // one or more (op perm*) groups
        if (i >= text.len or std.mem.indexOfScalar(u8, "+-=", text[i]) == null) return null;
        while (i < text.len and std.mem.indexOfScalar(u8, "+-=", text[i]) != null) {
            const op = text[i];
            i += 1;
            var value: u16 = 0;
            // the special bits this part speaks of
            var named: u16 = 0;
            const number = i < text.len and text[i] >= '0' and text[i] <= '7';
            if (number) {
                const end = std.mem.indexOfScalarPos(u8, text, i, ',') orelse text.len;
                if (mentioned) return null;
                value = octalValue(text[i..end]) orelse return null;
                named = all_bits;
                i = end;
            } else if (i < text.len and std.mem.indexOfScalar(u8, "ugo", text[i]) != null) {
                const cls: u16 = switch (text[i]) {
                    'u' => (mode >> 6) & 7,
                    'g' => (mode >> 3) & 7,
                    else => mode & 7,
                };
                value = cls | (cls << 3) | (cls << 6);
                named = if (mentioned) who & 0o777 else 0o777;
                i += 1;
            } else {
                while (i < text.len) : (i += 1) {
                    switch (text[i]) {
                        'r' => value |= 0o444,
                        'w' => value |= 0o222,
                        'x' => value |= 0o111,
                        'X' => {
                            if (is_dir or (mode & 0o111) != 0) value |= 0o111;
                        },
                        's' => value |= set_id_bits,
                        't' => value |= 0o1000,
                        else => break,
                    }
                }
                named = value & who;
            }
            const kept: u16 = if (is_dir) set_id_bits & ~named else 0;
            value &= who & ~kept;
            if (!mentioned and !number) value &= ~umask;
            switch (op) {
                '+' => mode |= value,
                '-' => mode &= ~value,
                else => mode = (mode & ((all_bits & ~who) | kept)) | value,
            }
            // nothing but the next clause may follow a number
            if (number) break;
        }
        if (i >= text.len) return mode;
        if (text[i] != ',') return null;
        i += 1;
    }
}

/// Octal digits worth at most 07777.
fn octalValue(text: []const u8) ?u16 {
    const v = num.parseInt(u16, text, 8) catch return null;
    // parseInt takes a sign, which a mode does not
    if (text.len == 0 or !std.ascii.isDigit(text[0]) or v > all_bits) return null;
    return v;
}

test "octal" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 0o755), apply("755", 0, true, 0));
    try t.expectEqual(@as(?u16, 0o7777), apply("7777", 0, true, 0));
    try t.expectEqual(@as(?u16, 0), apply("0", 0o777, true, 0));
    try t.expect(apply("10000", 0, true, 0) == null);
    try t.expect(apply("789", 0, true, 0) == null);
    try t.expect(apply("", 0, true, 0) == null);
}

test "symbolic with umask 022 from 0777 (values measured with GNU 9.7)" {
    const t = std.testing;
    const u: u16 = 0o022;
    try t.expectEqual(@as(?u16, 0o577), apply("-w", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o666), apply("a-x", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o477), apply("u=r", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o555), apply("=rx", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o4777), apply("u+s", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o2777), apply("g+s", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o750), apply("u=rwx,g=rx,o=", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o722), apply("go-rx", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o777), apply("g=u", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0), apply("a=", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0), apply("=", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o755), apply("a+rx,go-w", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o7777), apply("u+s,g+s,o+t", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o1000), apply("=t", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o646), apply("g-w,-x", 0o777, true, u));
}

test "invalid" {
    const t = std.testing;
    try t.expect(apply("zz", 0, true, 0) == null);
    try t.expect(apply("u", 0, true, 0) == null);
    try t.expect(apply("u+q", 0, true, 0) == null);
    try t.expect(apply("u+r,", 0, true, 0) == null);
    try t.expect(apply("+r,,", 0, true, 0) == null);
}

test "numbers after an operator (GNU)" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 0o755), apply("=755", 0o666, false, 0o022));
    try t.expectEqual(@as(?u16, 0o644), apply("-022", 0o666, false, 0o022));
    try t.expectEqual(@as(?u16, 0o445), apply("a=r,+1", 0o666, false, 0o022));
    try t.expectEqual(@as(?u16, 0o755), apply("=755,u+x", 0o666, false, 0));
    for ([_][]const u8{ "u=755", "+10000", "=755x", "+7+r", "=+8", "-0_2" }) |bad| try t.expect(apply(bad, 0, false, 0) == null);
}

test "a directory keeps the set-id bits a mode does not name" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 0o6755), apply("u+s,g=rx", 0o2775, true, 0) orelse null);
    try t.expectEqual(@as(?u16, 0o4755), apply("u+s,g=rx", 0o2775, false, 0));
    try t.expectEqual(@as(?u16, 0o7757), apply("g=rx,u+s", 0o7777, true, 0));
    try t.expectEqual(@as(?u16, 0o2755), apply("755", 0o2775, true, 0));
    try t.expectEqual(@as(?u16, 0o755), apply("00755", 0o2775, true, 0));
    try t.expectEqual(@as(?u16, 0o755), apply("=755", 0o2775, true, 0));
    try t.expectEqual(@as(?u16, 0o775), apply("g-s", 0o2775, true, 0));
}

test "X" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 0o755), apply("a+X", 0o644, true, 0));
    try t.expectEqual(@as(?u16, 0o644), apply("a+X", 0o644, false, 0));
    try t.expectEqual(@as(?u16, 0o755), apply("a+X", 0o744, false, 0));
}

/// "rwxr-xr-x" style text of the permission bits (with s/S and t/T), as
/// shown by `chmod -v`.
pub fn modeString(buf: *[9]u8, m: u16) []const u8 {
    const rwx = "rwxrwxrwx";
    for (0..9) |k| buf[k] = if (m & (@as(u16, 1) << @intCast(8 - k)) != 0) rwx[k] else '-';
    if (m & 0o4000 != 0) buf[2] = if (buf[2] == 'x') 's' else 'S';
    if (m & 0o2000 != 0) buf[5] = if (buf[5] == 'x') 's' else 'S';
    if (m & 0o1000 != 0) buf[8] = if (buf[8] == 'x') 't' else 'T';
    return buf[0..9];
}

test "modeString" {
    var b: [9]u8 = undefined;
    try std.testing.expectEqualStrings("rwxr-xr-x", modeString(&b, 0o755));
    try std.testing.expectEqualStrings("rwsr-sr-t", modeString(&b, 0o7755));
    try std.testing.expectEqualStrings("rwSr-Sr-T", modeString(&b, 0o7644));
}
