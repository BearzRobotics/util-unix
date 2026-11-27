// SPDX-License-Identifier: GPL-2.0-or-later
//! Exact formatting of binary64 values for the `printf` builtin: the
//! conversions `%e %E %f %F %g %G %a %A` of POSIX printf(3) with C
//! semantics (round-half-even of the exact binary value, so the output is
//! identical to glibc for every value and precision).
//!
//! The exact decimal expansion of the double is computed with big integers
//! (mantissa * 2^e is an integer or mantissa * 5^k / 10^k), then rounded as
//! a decimal string. Fast enough for a shell builtin (at most about 1100
//! digits).
//!
//! References: ISO C 7.23.6.1 (fprintf), POSIX XCU printf.

const std = @import("std");
const Allocator = std.mem.Allocator;
const big = std.math.big.int;

pub const Spec = struct {
    conv: u8, // one of eEfFgGaA
    prec: ?usize = null,
    alt: bool = false, // '#'
};

pub const Result = struct {
    /// "-" for negative values (including -0 and -nan), else empty.
    neg: bool,
    /// The unsigned text: digits, point, exponent, or inf/nan.
    body: []const u8,
    /// False for inf and nan: the zero flag is then ignored.
    finite: bool,
};

const Digits = struct {
    /// Decimal digits of the value without leading zeros ("" for zero).
    ds: []const u8,
    /// Value = 0.ds * 10^point  (point = number of digits before the decimal point).
    point: i32,
};

fn exactDecimal(a: Allocator, mant: u64, e2: i32) Allocator.Error!Digits {
    if (mant == 0) return .{ .ds = "", .point = 0 };
    var m = big.Managed.initSet(a, mant) catch return error.OutOfMemory;
    var shift10: i32 = 0; // value = m * 10^(-shift10)
    if (e2 >= 0) {
        m.shiftLeft(&m, @intCast(e2)) catch return error.OutOfMemory;
    } else {
        var p5 = big.Managed.initSet(a, 5) catch return error.OutOfMemory;
        p5.pow(&p5, @intCast(-e2)) catch return error.OutOfMemory;
        m.mul(&m, &p5) catch return error.OutOfMemory;
        shift10 = -e2;
    }
    const s = m.toString(a, 10, .lower) catch return error.OutOfMemory;
    return .{ .ds = s, .point = @as(i32, @intCast(s.len)) - shift10 };
}

/// Round `d` to `keep` leading digits (keep may be <= 0 or > len). Returns
/// the digits (exactly max(keep,0) of them, zero padded) and the possibly
/// incremented point.
fn roundDigits(a: Allocator, d: Digits, keep: i64) Allocator.Error!Digits {
    var point = d.point;
    if (keep < 0) return .{ .ds = "", .point = point };
    const k: usize = @intCast(keep);
    var out = try a.alloc(u8, k + 1);
    @memset(out, '0');
    const n = @min(k, d.ds.len);
    @memcpy(out[0..n], d.ds[0..n]);
    var up = false;
    if (d.ds.len > k) {
        const next = d.ds[k];
        if (next > '5') {
            up = true;
        } else if (next == '5') {
            var rest_nonzero = false;
            for (d.ds[k + 1 ..]) |c| if (c != '0') {
                rest_nonzero = true;
                break;
            };
            if (rest_nonzero) {
                up = true;
            } else {
                // exact tie: to even
                const last: u8 = if (k == 0) '0' else d.ds[k - 1];
                up = (last - '0') % 2 == 1;
            }
        }
    }
    if (up) {
        var i: usize = k;
        while (i > 0) {
            i -= 1;
            if (out[i] == '9') {
                out[i] = '0';
            } else {
                out[i] += 1;
                break;
            }
        } else {
            // carry out of the top: 99.9 -> 100.0
            out[0] = '1';
            @memset(out[1..k], '0');
            if (k == 0) {
                // rounding "" up: value becomes 1 at the next position
                out = try a.dupe(u8, "1");
                return .{ .ds = out, .point = point + 1 };
            }
            point += 1;
            return .{ .ds = out[0..k], .point = point };
        }
    }
    return .{ .ds = out[0..k], .point = point };
}

fn appendExp(a: Allocator, out: *std.ArrayList(u8), upper: bool, e: i32, marker_p: bool) Allocator.Error!void {
    try out.append(a, if (marker_p) (if (upper) 'P' else 'p') else (if (upper) 'E' else 'e'));
    try out.append(a, if (e < 0) '-' else '+');
    const m: u32 = @intCast(if (e < 0) -e else e);
    if (marker_p) {
        try out.print(a, "{d}", .{m});
    } else try out.print(a, "{d:0>2}", .{m});
}

fn fixed(a: Allocator, out: *std.ArrayList(u8), d: Digits, prec: usize, alt: bool) Allocator.Error!void {
    // keep digits up to `prec` places after the point
    const keep: i64 = @as(i64, d.point) + @as(i64, @intCast(prec));
    var r: Digits = undefined;
    if (d.ds.len == 0) {
        r = .{ .ds = "", .point = 0 };
    } else if (keep < 0) {
        r = .{ .ds = "", .point = 0 };
    } else if (keep == 0) {
        // value < 10^-prec: rounds to 0 or to one unit in the last place
        const up = blk: {
            if (d.ds[0] > '5') break :blk true;
            if (d.ds[0] < '5') break :blk false;
            for (d.ds[1..]) |c| if (c != '0') break :blk true;
            break :blk false; // exact tie, previous digit is 0 (even)
        };
        r = if (up) .{ .ds = "1", .point = d.point + 1 } else .{ .ds = "", .point = 0 };
    } else r = try roundDigits(a, d, keep);
    // integer part
    if (r.ds.len == 0 or r.point <= 0) {
        try out.append(a, '0');
    } else {
        var i: usize = 0;
        const ip: usize = @intCast(r.point);
        while (i < ip) : (i += 1) try out.append(a, if (i < r.ds.len) r.ds[i] else '0');
    }
    if (prec > 0 or alt) try out.append(a, '.');
    var j: usize = 0;
    while (j < prec) : (j += 1) {
        // digit at position r.point + j (0-based in r.ds)
        const idx: i64 = @as(i64, r.point) + @as(i64, @intCast(j));
        try out.append(a, if (r.ds.len > 0 and idx >= 0 and idx < r.ds.len) r.ds[@intCast(idx)] else '0');
    }
}

fn scientific(a: Allocator, out: *std.ArrayList(u8), d: Digits, prec: usize, alt: bool, upper: bool) Allocator.Error!i32 {
    var r: Digits = .{ .ds = "", .point = 0 };
    var exp10: i32 = 0;
    if (d.ds.len > 0) {
        r = try roundDigits(a, d, @intCast(prec + 1));
        exp10 = r.point - 1;
    }
    try out.append(a, if (r.ds.len > 0) r.ds[0] else '0');
    if (prec > 0 or alt) try out.append(a, '.');
    var j: usize = 1;
    while (j <= prec) : (j += 1) try out.append(a, if (j < r.ds.len) r.ds[j] else '0');
    try appendExp(a, out, upper, exp10, false);
    return exp10;
}

fn hexFloat(a: Allocator, out: *std.ArrayList(u8), bits: u64, spec: Spec) Allocator.Error!void {
    const upper = spec.conv == 'A';
    const be: u32 = @intCast((bits >> 52) & 0x7ff);
    var frac: u64 = bits & ((1 << 52) - 1);
    var lead: u64 = 1;
    var e: i32 = @as(i32, @intCast(be)) - 1023;
    if (be == 0) {
        if (frac == 0) {
            lead = 0;
            e = 0;
        } else {
            lead = 0;
            e = -1022;
        }
    }
    var nd: usize = 13;
    if (spec.prec) |p| {
        if (p < 13) {
            // round the 52-bit fraction (with the lead digit) to p hex digits
            const drop: u6 = @intCast((13 - p) * 4);
            const full: u64 = (lead << 52) | frac;
            const half: u64 = @as(u64, 1) << (drop - 1);
            const rem = full & ((@as(u64, 1) << drop) - 1);
            var q = full >> drop;
            if (rem > half or (rem == half and (q & 1) == 1)) q += 1;
            const lead_shift: u6 = @intCast(p * 4);
            lead = q >> lead_shift;
            frac = if (p == 0) 0 else q & ((@as(u64, 1) << lead_shift) - 1);
            frac <<= drop;
            // a carry can make lead 2 (0x1.f..8 -> 0x2.0)
        }
        nd = p;
    } else {
        // shortest exact: strip trailing zero nibbles
        nd = 13;
        var f = frac;
        while (nd > 0 and (f & 0xf) == 0) : (nd -= 1) f >>= 4;
    }
    try out.appendSlice(a, if (upper) "0X" else "0x");
    try out.append(a, @intCast('0' + lead));
    if (nd > 0 or spec.alt) try out.append(a, '.');
    const digs = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var i: usize = 0;
    while (i < nd) : (i += 1) {
        if (i < 13) {
            const sh: u6 = @intCast((12 - i) * 4);
            try out.append(a, digs[@intCast((frac >> sh) & 0xf)]);
        } else try out.append(a, '0');
    }
    try appendExp(a, out, upper, e, true);
}

/// The largest precision, and in `printf` field width, that is honoured. The
/// result is built in memory, so some limit is needed.
pub const max_precision = 1 << 24;

/// Format `x` according to `spec`. The result text is allocated from `a`.
/// A precision above `max_precision` is taken as that.
pub fn format(a: Allocator, x: f64, spec: Spec) Allocator.Error!Result {
    const bits: u64 = @bitCast(x);
    const neg = (bits >> 63) != 0;
    const upper = std.ascii.isUpper(spec.conv);
    var out: std.ArrayList(u8) = .empty;
    if (std.math.isNan(x) or std.math.isInf(x)) {
        const s: []const u8 = if (std.math.isNan(x)) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf");
        return .{ .neg = neg, .body = s, .finite = false };
    }
    const be: u32 = @intCast((bits >> 52) & 0x7ff);
    const frac: u64 = bits & ((1 << 52) - 1);
    const lc = std.ascii.toLower(spec.conv);
    if (lc == 'a') {
        try hexFloat(a, &out, bits, spec);
        return .{ .neg = neg, .body = out.items, .finite = true };
    }
    const mant: u64 = if (be == 0) frac else (frac | (1 << 52));
    const e2: i32 = (if (be == 0) @as(i32, 1) else @as(i32, @intCast(be))) - 1075;
    const d = try exactDecimal(a, mant, e2);
    const prec = @min(spec.prec orelse 6, max_precision);
    switch (lc) {
        'f' => try fixed(a, &out, d, prec, spec.alt),
        'e' => _ = try scientific(a, &out, d, prec, spec.alt, upper),
        else => {
            // %g
            const p: usize = if (prec == 0) 1 else prec;
            var probe: std.ArrayList(u8) = .empty;
            const x10 = if (d.ds.len == 0) 0 else blk: {
                const r = try roundDigits(a, d, @intCast(p));
                _ = &probe;
                break :blk r.point - 1;
            };
            if (x10 >= -4 and x10 < @as(i32, @intCast(p))) {
                try fixed(a, &out, d, @intCast(@as(i32, @intCast(p)) - 1 - x10), spec.alt);
                if (!spec.alt) stripZeros(&out, false);
            } else {
                _ = try scientific(a, &out, d, p - 1, spec.alt, upper);
                if (!spec.alt) stripZeros(&out, true);
            }
        },
    }
    return .{ .neg = neg, .body = out.items, .finite = true };
}

/// Remove trailing fractional zeros (and a bare point) as `%g` does; with
/// `exp` the exponent suffix is kept.
fn stripZeros(out: *std.ArrayList(u8), exp: bool) void {
    var tail_start: usize = out.items.len;
    if (exp) {
        tail_start = std.mem.indexOfAny(u8, out.items, "eE").?;
    }
    if (std.mem.indexOfScalar(u8, out.items[0..tail_start], '.') == null) return;
    var end = tail_start;
    while (end > 0 and out.items[end - 1] == '0') end -= 1;
    if (end > 0 and out.items[end - 1] == '.') end -= 1;
    if (exp) {
        const suffix_len = out.items.len - tail_start;
        std.mem.copyForwards(u8, out.items[end .. end + suffix_len], out.items[tail_start..]);
        out.items.len = end + suffix_len;
    } else out.items.len = end;
}

pub const Parsed = struct { value: f64, used: usize, range: bool };

/// strtod: the longest numeric prefix of `s` (leading blanks skipped).
/// `used` is 0 when there is none.
pub fn parsePrefix(s: []const u8) Parsed {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= '\t' and s[i] <= '\r'))) i += 1;
    const start = i;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    const body = i;
    const rest = s[i..];
    const lower = struct {
        fn starts(t: []const u8, p: []const u8) bool {
            if (t.len < p.len) return false;
            for (p, 0..) |c, k| if (std.ascii.toLower(t[k]) != c) return false;
            return true;
        }
    };
    if (lower.starts(rest, "infinity")) return .{ .value = if (neg) -std.math.inf(f64) else std.math.inf(f64), .used = body + 8, .range = false };
    if (lower.starts(rest, "inf")) return .{ .value = if (neg) -std.math.inf(f64) else std.math.inf(f64), .used = body + 3, .range = false };
    if (lower.starts(rest, "nan")) {
        var n = body + 3;
        if (n < s.len and s[n] == '(') {
            var k = n + 1;
            while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_')) k += 1;
            if (k < s.len and s[k] == ')') n = k + 1;
        }
        const nan = std.math.nan(f64);
        return .{ .value = if (neg) -nan else nan, .used = n, .range = false };
    }
    var end = i;
    if (lower.starts(rest, "0x")) {
        var k = i + 2;
        var nd: usize = 0;
        while (k < s.len and std.ascii.isHex(s[k])) : (k += 1) nd += 1;
        if (k < s.len and s[k] == '.') {
            k += 1;
            while (k < s.len and std.ascii.isHex(s[k])) : (k += 1) nd += 1;
        }
        if (nd > 0) {
            end = k;
            if (k < s.len and (s[k] == 'p' or s[k] == 'P')) {
                var q = k + 1;
                if (q < s.len and (s[q] == '+' or s[q] == '-')) q += 1;
                const qs = q;
                while (q < s.len and std.ascii.isDigit(s[q])) q += 1;
                if (q > qs) end = q;
            }
        } else {
            // "0x" alone: the number is the 0
            return .{ .value = if (neg) -0.0 else 0.0, .used = i + 1, .range = false };
        }
    } else {
        var k = i;
        var nd: usize = 0;
        while (k < s.len and std.ascii.isDigit(s[k])) : (k += 1) nd += 1;
        if (k < s.len and s[k] == '.') {
            k += 1;
            while (k < s.len and std.ascii.isDigit(s[k])) : (k += 1) nd += 1;
        }
        if (nd == 0) return .{ .value = 0, .used = 0, .range = false };
        end = k;
        if (k < s.len and (s[k] == 'e' or s[k] == 'E')) {
            var q = k + 1;
            if (q < s.len and (s[q] == '+' or s[q] == '-')) q += 1;
            const qs = q;
            while (q < s.len and std.ascii.isDigit(s[q])) q += 1;
            if (q > qs) end = q;
        }
    }
    const text = s[start..end];
    var v: f64 = std.fmt.parseFloat(f64, text) catch return .{ .value = 0, .used = 0, .range = false };
    const range = std.math.isInf(v) or (v != 0 and @abs(v) < std.math.floatMin(f64)) or (v == 0 and hasNonzeroDigit(text));
    if (std.math.isNan(v)) v = 0;
    return .{ .value = v, .used = end, .range = range };
}

fn hasNonzeroDigit(t: []const u8) bool {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    if (t.len >= i + 2 and t[i] == '0' and (t[i + 1] == 'x' or t[i + 1] == 'X')) return false;
    while (i < t.len and t[i] != 'e' and t[i] != 'E') : (i += 1) if (t[i] >= '1' and t[i] <= '9') return true;
    return false;
}

test "fixed, scientific and general" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("0.100000000000000005551115123126", (try format(a, 0.1, .{ .conv = 'f', .prec = 30 })).body);
    try std.testing.expectEqualStrings("1.234568e+04", (try format(a, 12345.678, .{ .conv = 'e' })).body);
    try std.testing.expectEqualStrings("0.0001", (try format(a, 0.0001, .{ .conv = 'g' })).body);
    try std.testing.expectEqualStrings("1e+06", (try format(a, 1e6, .{ .conv = 'g' })).body);
    try std.testing.expectEqualStrings("0x1.8p+0", (try format(a, 1.5, .{ .conv = 'a' })).body);
    try std.testing.expectEqualStrings("2", (try format(a, 2.5, .{ .conv = 'f', .prec = 0 })).body);
    try std.testing.expectEqualStrings("1", (try format(a, 0.9, .{ .conv = 'f', .prec = 0 })).body);
    try std.testing.expectEqualStrings("0x0.0000000000001p-1022", (try format(a, 5e-324, .{ .conv = 'a' })).body);
}
