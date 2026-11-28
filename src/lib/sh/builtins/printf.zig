// SPDX-License-Identifier: GPL-2.0-or-later
//! echo and printf. Part of builtins.zig.

const std = @import("std");
const arith = @import("../arith.zig");
const fmtfloat = @import("../fmtfloat.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");

/// Process backslash escapes of `echo`/`%b`; returns false at `\c`.
fn escapes(a: Allocator, out: *std.ArrayList(u8), s: []const u8, is_b: bool) Allocator.Error!bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) {
            try out.append(a, c);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'a' => try out.append(a, 7),
            'b' => try out.append(a, 8),
            'c' => return false,
            'e' => try out.append(a, 27),
            'f' => try out.append(a, 12),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            't' => try out.append(a, '\t'),
            'v' => try out.append(a, 11),
            '\\' => try out.append(a, '\\'),
            '0' => {
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '7') : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                try out.append(a, @truncate(v));
            },
            '1'...'7' => |d| {
                // \ddd (also in a %b operand, as dash, bash and FreeBSD sh)
                _ = is_b;
                var v: u32 = d - '0';
                var n: usize = 0;
                while (n < 2 and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '7') : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                try out.append(a, @truncate(v));
            },
            else => |o| {
                try out.append(a, '\\');
                try out.append(a, o);
            },
        }
    }
    return true;
}

pub fn echoCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var newline = true;
    if (i < args.len and std.mem.eql(u8, args[i], "-n")) {
        newline = false;
        i += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var go = true;
    while (i < args.len and go) : (i += 1) {
        if (!first) out.append(a, ' ') catch |oe| return sh.oom(oe);
        first = false;
        go = escapes(a, &out, args[i], false) catch |oe| return sh.oom(oe);
    }
    if (go and newline) out.append(a, '\n') catch |oe| return sh.oom(oe);
    if (!sh.out(out.items)) {
        sh.diagCmdK(.io_error, "I/O error", "echo", "I/O error", .{});
        return 1;
    }
    return 0;
}

/// A complete integer operand with its range checked like strtoimax / strtoumax: out of
/// range clamps (INT64_MAX/MIN, UINT64_MAX) and the status becomes 1; a negative number
/// converted as unsigned wraps (dash, bash, FreeBSD sh).
fn printfRanged(sh: *Shell, s: []const u8, st: *u8, unsigned: bool) ?i64 {
    var t = std.mem.trimStart(u8, s, " \t\n\x0b\x0c\r");
    var neg = false;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    var base: u8 = 10;
    if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        base = 16;
        t = t[2..];
    } else if (t.len > 1 and t[0] == '0') {
        base = 8;
        t = t[1..];
    }
    if (t.len == 0) return null;
    var mag: u128 = 0;
    for (t) |c| {
        const d = std.fmt.charToDigit(c, base) catch return null;
        mag = mag * base + d;
        if (mag > (1 << 70)) mag = 1 << 70; // saturate: far beyond any limit
    }
    var range = false;
    var out: i64 = 0;
    if (unsigned) {
        if (mag > std.math.maxInt(u64)) {
            range = true;
            out = -1; // UINT64_MAX
        } else {
            const m: u64 = @intCast(mag);
            out = @bitCast(if (neg) 0 -% m else m);
        }
    } else if (neg) {
        if (mag > (1 << 63)) {
            range = true;
            out = std.math.minInt(i64);
        } else out = @intCast(-@as(i128, @intCast(mag)));
    } else if (mag > std.math.maxInt(i64)) {
        range = true;
        out = std.math.maxInt(i64);
    } else out = @intCast(mag);
    if (range) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: Result too large", .{s});
        st.* = 1;
    }
    return out;
}

fn printfNumber(sh: *Shell, s: []const u8, st: *u8) i64 {
    return printfNumberK(sh, s, st, false);
}

fn printfNumberK(sh: *Shell, s: []const u8, st: *u8, unsigned: bool) i64 {
    if (s.len == 0) return 0;
    if (s[0] == '\'' or s[0] == '"') return if (s.len > 1) s[1] else 0;
    if (printfRanged(sh, s, st, unsigned)) |v| return v;
    if (arith.parseNumber(s)) |v| return v;
    // As strtoimax: the longest valid prefix, in the base its start names
    // (`09` is 0 and `0778` is 077), and a failure.
    var end: usize = 0;
    while (end < s.len and (s[end] == ' ' or (s[end] >= '\t' and s[end] <= '\r'))) end += 1;
    if (end < s.len and (s[end] == '-' or s[end] == '+')) end += 1;
    var base: u8 = 10;
    var digits_start = end;
    if (end < s.len and s[end] == '0') {
        base = 8;
        // (`0x` with no digit after it is a 0 followed by an x)
        if (end + 2 < s.len and (s[end + 1] == 'x' or s[end + 1] == 'X') and std.ascii.isHex(s[end + 2])) {
            base = 16;
            end += 2;
            digits_start = end;
        }
    }
    while (end < s.len) : (end += 1) _ = std.fmt.charToDigit(s[end], base) catch break;
    if (end > digits_start) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: not completely converted", .{s});
        st.* = 1;
        return printfRanged(sh, s[0..end], st, unsigned) orelse 0;
    }
    sh.diagCmdK(.printf_number, s, "printf", "{s}: expected numeric value", .{s});
    st.* = 1;
    return 0;
}

fn printfFloat(sh: *Shell, s: []const u8, st: *u8) f64 {
    if (s.len == 0) return 0;
    if (s[0] == '\'' or s[0] == '"') return if (s.len > 1) @floatFromInt(s[1]) else 0;
    const p = fmtfloat.parsePrefix(s);
    if (p.used == 0) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: expected numeric value", .{s});
        st.* = 1;
        return 0;
    }
    if (p.used < s.len) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: not completely converted", .{s});
        st.* = 1;
    } else if (p.range) {
        sh.diagCmdK(.printf_number, s, "printf", "{s}: Numerical result out of range", .{s});
        st.* = 1;
    }
    return p.value;
}

pub fn printfCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    if (i < args.len and std.mem.eql(u8, args[i], "--")) i += 1 else if (i < args.len and args[i].len > 1 and args[i][0] == '-') {
        // no options (POSIX utility syntax guidelines aside): `printf -v x` is an error as in dash and FreeBSD sh
        sh.diagCmdK(.illegal_option, args[i], "printf", "Illegal option {s}", .{args[i][0..2]});
        return 2;
    }
    if (i >= args.len) {
        sh.diagCmdK(.usage, null, "printf", "usage: printf format [arg ...]", .{});
        return 2;
    }
    const fmt = args[i];
    i += 1;
    const rest = args[i..];
    var out: std.ArrayList(u8) = .empty;
    var ai: usize = 0;
    var st: u8 = 0;
    while (true) {
        const start_ai = ai;
        var consumed_any = false;
        var k: usize = 0;
        var stop = false;
        while (k < fmt.len and !stop) : (k += 1) {
            const c = fmt[k];
            if (c == '\\') {
                // format-string escapes
                var j = k + 1;
                if (j >= fmt.len) {
                    out.append(a, '\\') catch |oe| return sh.oom(oe);
                    break;
                }
                var tmp: std.ArrayList(u8) = .empty;
                // \NNN octal (up to three digits) as in the format
                if (fmt[j] >= '0' and fmt[j] <= '7') {
                    var v: u32 = 0;
                    var n: usize = 0;
                    while (n < 3 and j < fmt.len and fmt[j] >= '0' and fmt[j] <= '7') : (n += 1) {
                        v = v * 8 + (fmt[j] - '0');
                        j += 1;
                    }
                    out.append(a, @truncate(v)) catch |oe| return sh.oom(oe);
                    k = j - 1;
                    continue;
                }
                const seg = fmt[k .. k + 2];
                if (fmt[j] == '"' or fmt[j] == '\'') {
                    out.append(a, fmt[j]) catch |oe| return sh.oom(oe);
                } else {
                    _ = escapes(a, &tmp, seg, true) catch |oe| return sh.oom(oe);
                    out.appendSlice(a, tmp.items) catch |oe| return sh.oom(oe);
                }
                k += 1;
                continue;
            }
            if (c != '%') {
                out.append(a, c) catch |oe| return sh.oom(oe);
                continue;
            }
            k += 1;
            if (k >= fmt.len) {
                sh.diagCmdK(.usage, null, "printf", "%: invalid directive", .{});
                _ = sh.out(out.items);
                return 1;
            }
            if (fmt[k] == '%') {
                out.append(a, '%') catch |oe| return sh.oom(oe);
                continue;
            }
            // flags, width, precision
            var left = false;
            var plus = false;
            var space = false;
            var alt = false;
            var zero = false;
            while (k < fmt.len) : (k += 1) switch (fmt[k]) {
                '-' => left = true,
                '+' => plus = true,
                ' ' => space = true,
                '#' => alt = true,
                '0' => zero = true,
                else => break,
            };
            var width: usize = 0;
            if (k < fmt.len and fmt[k] == '*') {
                const v = if (ai < rest.len) printfNumber(sh, rest[ai], &st) else 0;
                ai += 1;
                if (v < 0) {
                    left = true;
                    width = @abs(v);
                } else width = @intCast(v);
                k += 1;
            } else while (k < fmt.len and std.ascii.isDigit(fmt[k])) : (k += 1) width = width *| 10 +| (fmt[k] - '0');
            var prec: ?usize = null;
            if (k < fmt.len and fmt[k] == '.') {
                k += 1;
                var p: usize = 0;
                if (k < fmt.len and fmt[k] == '*') {
                    const v = if (ai < rest.len) printfNumber(sh, rest[ai], &st) else 0;
                    ai += 1;
                    // a negative one counts as none (C, and so POSIX)
                    if (v >= 0) {
                        p = @intCast(v);
                        prec = p;
                    }
                    k += 1;
                } else {
                    while (k < fmt.len and std.ascii.isDigit(fmt[k])) : (k += 1) p = p *| 10 +| (fmt[k] - '0');
                    prec = p;
                }
            }
            if (k >= fmt.len) {
                sh.diagCmdK(.usage, null, "printf", "%: invalid directive", .{});
                _ = sh.out(out.items);
                return 1;
            }
            const conv = fmt[k];
            // for a string the precision only cuts, so any value will do
            const cuts = conv == 's' or conv == 'b';
            if (width > fmtfloat.max_precision or (!cuts and (prec orelse 0) > fmtfloat.max_precision)) {
                sh.diagCmdK(.usage, null, "printf", "field width or precision too large", .{});
                _ = sh.out(out.items);
                return 2;
            }
            const arg: ?[]const u8 = if (ai < rest.len) rest[ai] else null;
            if (arg != null) consumed_any = true;
            var body: std.ArrayList(u8) = .empty;
            switch (conv) {
                's' => {
                    ai += 1;
                    var s = arg orelse "";
                    if (prec) |p| s = s[0..@min(p, s.len)];
                    body.appendSlice(a, s) catch |oe| return sh.oom(oe);
                },
                'b' => {
                    ai += 1;
                    var tmp: std.ArrayList(u8) = .empty;
                    const cont_ = escapes(a, &tmp, arg orelse "", true) catch |oe| return sh.oom(oe);
                    var s: []const u8 = tmp.items;
                    if (prec) |p| s = s[0..@min(p, s.len)];
                    body.appendSlice(a, s) catch |oe| return sh.oom(oe);
                    if (!cont_) stop = true;
                },
                'c' => {
                    ai += 1;
                    if (arg) |s| if (s.len > 0) body.append(a, s[0]) catch |oe| return sh.oom(oe);
                },
                'd', 'i' => {
                    ai += 1;
                    const v = if (arg) |s| printfNumber(sh, s, &st) else 0;
                    var digits: std.ArrayList(u8) = .empty;
                    const mag: u64 = if (v < 0) @as(u64, @bitCast(-%v)) else @intCast(v);
                    digits.print(a, "{d}", .{mag}) catch |oe| return sh.oom(oe);
                    if (prec) |p| padDigits(a, &digits, p, mag == 0) catch |oe| return sh.oom(oe);
                    const sign: []const u8 = if (v < 0) "-" else if (plus) "+" else if (space) " " else "";
                    padNum(a, &body, sign, digits.items, width, left, zero and prec == null) catch |oe| return sh.oom(oe);
                    width = 0;
                },
                'u', 'o', 'x', 'X' => {
                    ai += 1;
                    const v: u64 = @bitCast(if (arg) |s| printfNumberK(sh, s, &st, true) else 0);
                    var digits: std.ArrayList(u8) = .empty;
                    switch (conv) {
                        'u' => digits.print(a, "{d}", .{v}) catch |oe| return sh.oom(oe),
                        'o' => digits.print(a, "{o}", .{v}) catch |oe| return sh.oom(oe),
                        'x' => digits.print(a, "{x}", .{v}) catch |oe| return sh.oom(oe),
                        else => digits.print(a, "{X}", .{v}) catch |oe| return sh.oom(oe),
                    }
                    // `%#.0o` of zero is still "0"
                    if (prec) |p| padDigits(a, &digits, p, v == 0 and !(alt and conv == 'o')) catch |oe| return sh.oom(oe);
                    // `#` makes octal start with a 0, which the precision may have done
                    const zero_first = digits.items.len > 0 and digits.items[0] == '0';
                    const pre: []const u8 = if (alt and v != 0) (if (conv == 'x') "0x" else if (conv == 'X') "0X" else if (conv == 'o' and !zero_first) "0" else "") else "";
                    padNum(a, &body, pre, digits.items, width, left, zero and prec == null) catch |oe| return sh.oom(oe);
                    width = 0;
                },
                'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A' => {
                    ai += 1;
                    const x = if (arg) |s| printfFloat(sh, s, &st) else 0.0;
                    const r = fmtfloat.format(a, x, .{ .conv = conv, .prec = prec, .alt = alt }) catch |oe| return sh.oom(oe);
                    const sign: []const u8 = if (r.neg) "-" else if (plus) "+" else if (space) " " else "";
                    const hex_prefix: usize = if (std.ascii.toLower(conv) == 'a' and r.finite) 2 else 0;
                    if (zero and !left and r.finite and width > sign.len + r.body.len) {
                        // zeros go after the sign (and the 0x of %a)
                        body.appendSlice(a, sign) catch |oe| return sh.oom(oe);
                        body.appendSlice(a, r.body[0..hex_prefix]) catch |oe| return sh.oom(oe);
                        body.appendNTimes(a, '0', width - sign.len - r.body.len) catch |oe| return sh.oom(oe);
                        body.appendSlice(a, r.body[hex_prefix..]) catch |oe| return sh.oom(oe);
                    } else {
                        body.appendSlice(a, sign) catch |oe| return sh.oom(oe);
                        body.appendSlice(a, r.body) catch |oe| return sh.oom(oe);
                    }
                },
                else => {
                    sh.diagCmdK(.usage, null, "printf", "%{c}: invalid directive", .{conv});
                    _ = sh.out(out.items);
                    return 2; // dash; FreeBSD sh and bash say 1, POSIX only wants non-zero
                },
            }
            // pad strings
            if (body.items.len < width) {
                const pad = width - body.items.len;
                if (left) {
                    out.appendSlice(a, body.items) catch |oe| return sh.oom(oe);
                    out.appendNTimes(a, ' ', pad) catch |oe| return sh.oom(oe);
                } else {
                    out.appendNTimes(a, ' ', pad) catch |oe| return sh.oom(oe);
                    out.appendSlice(a, body.items) catch |oe| return sh.oom(oe);
                }
            } else out.appendSlice(a, body.items) catch |oe| return sh.oom(oe);
        }
        if (stop) break;
        if (ai >= rest.len or ai == start_ai or !consumed_any) break;
    }
    if (!sh.out(out.items)) {
        sh.diagCmdK(.io_error, "I/O error", "printf", "I/O error", .{});
        return 1;
    }
    return st;
}

/// An integer's precision: at least `prec` digits. Zero with precision zero has none.
fn padDigits(a: Allocator, digits: *std.ArrayList(u8), prec: usize, is_zero: bool) Allocator.Error!void {
    if (prec == 0 and is_zero) digits.clearRetainingCapacity();
    const len = digits.items.len;
    if (prec <= len) return;
    // in one step: inserting a zero at a time is quadratic
    try digits.resize(a, prec);
    @memmove(digits.items[prec - len ..], digits.items[0..len]);
    @memset(digits.items[0 .. prec - len], '0');
}

fn padNum(a: Allocator, body: *std.ArrayList(u8), sign: []const u8, digits: []const u8, width: usize, left: bool, zero: bool) Allocator.Error!void {
    const len = sign.len + digits.len;
    const pad = if (width > len) width - len else 0;
    if (left) {
        try body.appendSlice(a, sign);
        try body.appendSlice(a, digits);
        try body.appendNTimes(a, ' ', pad);
    } else if (zero) {
        try body.appendSlice(a, sign);
        try body.appendNTimes(a, '0', pad);
        try body.appendSlice(a, digits);
    } else {
        try body.appendNTimes(a, ' ', pad);
        try body.appendSlice(a, sign);
        try body.appendSlice(a, digits);
    }
}
