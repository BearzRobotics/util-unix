// SPDX-License-Identifier: GPL-2.0-or-later
//! Shell pattern matching (fnmatch without FNM_PATHNAME handling, which the
//! pathname expansion in `expand.zig` does per path segment).
//!
//! References: POSIX.1-2024 Shell Command Language 2.14 "Pattern Matching
//! Notation": `?`, `*`, bracket expressions with `!` negation, ranges and
//! character classes, and backslash quoting. Single-byte (C locale) only.

const std = @import("std");

const BracketResult = struct { end: usize, matched: bool };

fn classMatch(name: []const u8, c: u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (eq(u8, name, "digit")) return std.ascii.isDigit(c);
    if (eq(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (eq(u8, name, "upper")) return std.ascii.isUpper(c);
    if (eq(u8, name, "lower")) return std.ascii.isLower(c);
    if (eq(u8, name, "space")) return std.ascii.isWhitespace(c);
    if (eq(u8, name, "blank")) return c == ' ' or c == '\t';
    if (eq(u8, name, "punct")) return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
    if (eq(u8, name, "print")) return std.ascii.isPrint(c);
    if (eq(u8, name, "graph")) return std.ascii.isPrint(c) and c != ' ';
    if (eq(u8, name, "cntrl")) return std.ascii.isControl(c);
    if (eq(u8, name, "xdigit")) return std.ascii.isHex(c);
    return false;
}

/// Where the ":]" closing a class name that starts at `start` is. A name is a
/// few letters: looking no further keeps a run of "[:" from taking cubic time.
fn classEnd(pat: []const u8, start: usize) ?usize {
    const longest = 16;
    var i = start;
    while (i < pat.len and i - start < longest and std.ascii.isAlphabetic(pat[i])) i += 1;
    return if (i + 1 < pat.len and pat[i] == ':' and pat[i + 1] == ']') i else null;
}

/// Match `c` against the bracket expression starting at `pat[start]` (the
/// `[`). Null when the expression is not terminated, in which case the `[`
/// is an ordinary character.
fn bracket(pat: []const u8, start: usize, c: u8) ?BracketResult {
    var i = start + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pat.len) {
        var lo = pat[i];
        if (lo == ']' and !first) return .{ .end = i + 1, .matched = matched != negate };
        first = false;
        if (lo == '[' and i + 1 < pat.len and pat[i + 1] == ':') {
            if (classEnd(pat, i + 2)) |e| {
                if (classMatch(pat[i + 2 .. e], c)) matched = true;
                i = e + 2;
                continue;
            }
        }
        if (lo == '\\' and i + 1 < pat.len) {
            i += 1;
            lo = pat[i];
        }
        i += 1;
        if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
            var hi = pat[i + 1];
            i += 2;
            if (hi == '\\' and i < pat.len) {
                hi = pat[i];
                i += 1;
            }
            if (lo <= c and c <= hi) matched = true;
        } else if (lo == c) matched = true;
    }
    return null;
}

/// True when `s` matches the whole pattern.
pub fn match(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star_p: ?usize = null;
    var star_i: usize = 0;
    const last_close = std.mem.lastIndexOfScalar(u8, pat, ']') orelse 0;
    while (i < s.len) {
        if (p < pat.len) {
            const pc = pat[p];
            var ok = false;
            var np = p + 1;
            switch (pc) {
                '*' => {
                    star_p = p;
                    star_i = i;
                    p += 1;
                    continue;
                },
                '?' => ok = true,
                '[' => {
                    if (if (p < last_close) bracket(pat, p, s[i]) else null) |r| {
                        ok = r.matched;
                        np = r.end;
                    } else ok = s[i] == '[';
                },
                '\\' => {
                    if (p + 1 < pat.len) {
                        ok = pat[p + 1] == s[i];
                        np = p + 2;
                    } else ok = s[i] == '\\';
                },
                else => ok = pc == s[i],
            }
            if (ok) {
                p = np;
                i += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            star_i += 1;
            i = star_i;
            p = sp + 1;
            continue;
        }
        return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// True when the pattern has an unquoted wildcard (`*`, `?`, or a `[` that
/// starts a bracket expression).
pub fn hasMagic(pat: []const u8) bool {
    // no "[" after the last "]" can open a bracket expression
    const last_close = std.mem.lastIndexOfScalar(u8, pat, ']') orelse 0;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        switch (pat[i]) {
            '\\' => i += 1,
            '*', '?' => return true,
            '[' => if (i < last_close and bracket(pat, i, 0) != null) return true,
            else => {},
        }
    }
    return false;
}

/// `pat` with the backslash escapes removed.
pub fn unescape(a: std.mem.Allocator, pat: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\' and i + 1 < pat.len) i += 1;
        try out.append(a, pat[i]);
    }
    return out.toOwnedSlice(a);
}

test "wildcards" {
    try std.testing.expect(match("a*c", "abbbc"));
    try std.testing.expect(match("*", ""));
    try std.testing.expect(!match("a?", "a"));
    try std.testing.expect(match("a?c", "abc"));
    try std.testing.expect(match("*.txt", "x.y.txt"));
    try std.testing.expect(!match("*.txt", "x.tx"));
    try std.testing.expect(match("a\\*b", "a*b"));
    try std.testing.expect(!match("a\\*b", "axb"));
}

test "brackets" {
    try std.testing.expect(match("[abc]x", "bx"));
    try std.testing.expect(match("[!abc]x", "dx"));
    try std.testing.expect(match("[^abc]x", "dx"));
    try std.testing.expect(match("[a-c]", "b"));
    try std.testing.expect(match("[]]", "]"));
    try std.testing.expect(match("[[:digit:]]", "7"));
    try std.testing.expect(!match("[[:digit:]]", "x"));
    try std.testing.expect(match("[a", "[a"));
    try std.testing.expect(match("[a-]", "-"));
}

test "runs of \"[:\" are matched in good time, and classes still work" {
    const t = std.testing;
    try t.expect(match("[[:digit:][:alpha:]]x", "7x"));
    try t.expect(match("[![:space:]]", "a"));
    try t.expect(!match("[[:digit:]]", "a"));
    var runs: [40000]u8 = undefined;
    for (&runs, 0..) |*c, n| c.* = if (n % 2 == 0) '[' else ':';
    try t.expect(!hasMagic(&runs));
    try t.expect(match(&runs, &runs));
    var closed = runs;
    closed[closed.len - 1] = ']';
    _ = hasMagic(&closed);
}
