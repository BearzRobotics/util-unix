// SPDX-License-Identifier: GPL-2.0-or-later
//! Shell arithmetic: the integer expression language of `$(( ))`.
//!
//! References: POSIX.1-2024 Shell Command Language 2.6.4 "Arithmetic
//! Expansion" (the C-language integer operators; signed 64-bit `intmax_t`),
//! with dash's diagnostics. No comma operator, `**`, `++` or `--` (not
//! required by POSIX; dash rejects them too).

const std = @import("std");

pub const Error = error{Arith};

/// How the evaluator reads and writes shell variables.
pub const Host = struct {
    ctx: *anyopaque,
    /// Value of a variable, null when unset.
    get: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
    /// Assign a variable; false when it is read-only.
    set: *const fn (ctx: *anyopaque, name: []const u8, value: i64) bool,
};

const Tok = union(enum) {
    eof,
    num: i64,
    name: []const u8,
    op: []const u8,
    bad,
};

pub const Evaluator = struct {
    host: Host,
    text: []const u8,
    pos: usize = 0,
    tok: Tok = .eof,
    /// Non-zero while evaluating an operand that is skipped (`&&`, `||`,
    /// `?:`): no side effects and no division errors.
    skip: u32 = 0,
    msg_buf: [200]u8 = undefined,
    msg_len: usize = 0,

    pub fn message(self: *const Evaluator) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }

    fn fail(self: *Evaluator, comptime fmt: []const u8, args: anytype) Error {
        const m = std.fmt.bufPrint(&self.msg_buf, fmt, args) catch self.msg_buf[0..0];
        self.msg_len = m.len;
        return error.Arith;
    }

    fn failExpr(self: *Evaluator, what: []const u8) Error {
        return self.fail("arithmetic expression: {s}: \"{s}\"", .{ what, self.text });
    }

    pub fn eval(host: Host, text: []const u8) struct { value: ?i64, msg: [200]u8, msg_len: usize } {
        var e: Evaluator = .{ .host = host, .text = text };
        const v = e.run() catch return .{ .value = null, .msg = e.msg_buf, .msg_len = e.msg_len };
        return .{ .value = v, .msg = e.msg_buf, .msg_len = 0 };
    }

    pub fn run(self: *Evaluator) Error!i64 {
        try self.advance();
        const v = try self.assignment();
        if (self.tok != .eof) return self.failExpr("expecting EOF");
        return v;
    }

    // --- tokens ---

    fn advance(self: *Evaluator) Error!void {
        const s = self.text;
        while (self.pos < s.len and (s[self.pos] == ' ' or s[self.pos] == '\t' or s[self.pos] == '\n')) self.pos += 1;
        if (self.pos >= s.len) {
            self.tok = .eof;
            return;
        }
        const c = s[self.pos];
        if (std.ascii.isDigit(c)) {
            self.tok = .{ .num = try self.number() };
            return;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const st = self.pos;
            while (self.pos < s.len and (std.ascii.isAlphanumeric(s[self.pos]) or s[self.pos] == '_')) self.pos += 1;
            self.tok = .{ .name = s[st..self.pos] };
            return;
        }
        const ops3 = [_][]const u8{ "<<=", ">>=" };
        const ops2 = [_][]const u8{ "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=" };
        for (ops3) |o| if (std.mem.startsWith(u8, s[self.pos..], o)) {
            self.tok = .{ .op = o };
            self.pos += 3;
            return;
        };
        for (ops2) |o| if (std.mem.startsWith(u8, s[self.pos..], o)) {
            self.tok = .{ .op = o };
            self.pos += 2;
            return;
        };
        const single = "+-*/%<>&^|!~?:()=";
        if (std.mem.indexOfScalar(u8, single, c)) |i| {
            self.tok = .{ .op = single[i .. i + 1] };
            self.pos += 1;
            return;
        }
        self.pos += 1;
        self.tok = .bad;
    }

    fn number(self: *Evaluator) Error!i64 {
        const s = self.text;
        const st = self.pos;
        var base: u8 = 10;
        if (s[st] == '0' and st + 1 < s.len and (s[st + 1] == 'x' or s[st + 1] == 'X') and st + 2 < s.len and std.ascii.isHex(s[st + 2])) {
            base = 16;
            self.pos += 2;
        } else if (s[st] == '0') {
            base = 8;
        }
        const ds = self.pos;
        while (self.pos < s.len and std.fmt.charToDigit(s[self.pos], base) != error.InvalidCharacter) self.pos += 1;
        const digits = s[ds..self.pos];
        if (digits.len == 0) return 0;
        return parseWrapping(digits, base);
    }

    fn isOp(self: *const Evaluator, o: []const u8) bool {
        return switch (self.tok) {
            .op => |t| std.mem.eql(u8, t, o),
            else => false,
        };
    }

    // --- variables ---

    fn varValue(self: *Evaluator, name: []const u8) Error!i64 {
        const v = self.host.get(self.host.ctx, name) orelse return 0;
        if (v.len == 0) return 0;
        return parseNumber(v) orelse self.fail("Illegal number: {s}", .{v});
    }

    // --- grammar ---

    fn assignment(self: *Evaluator) Error!i64 {
        if (self.tok == .name) {
            const save_pos = self.pos;
            const save_tok = self.tok;
            const name = self.tok.name;
            try self.advance();
            if (self.tok == .op) {
                const o = self.tok.op;
                const is_assign = std.mem.eql(u8, o, "=") or (o.len >= 2 and o[o.len - 1] == '=' and !std.mem.eql(u8, o, "==") and !std.mem.eql(u8, o, "!=") and !std.mem.eql(u8, o, "<=") and !std.mem.eql(u8, o, ">="));
                if (is_assign) {
                    try self.advance();
                    const rhs = try self.assignment();
                    var val = rhs;
                    if (o.len > 1) {
                        const cur_v = if (self.skip == 0) try self.varValue(name) else 0;
                        val = try self.binop(o[0 .. o.len - 1], cur_v, rhs);
                    }
                    if (self.skip == 0 and !self.host.set(self.host.ctx, name, val)) return self.fail("{s}: is read only", .{name});
                    return val;
                }
            }
            self.pos = save_pos;
            self.tok = save_tok;
        }
        return self.ternary();
    }

    fn ternary(self: *Evaluator) Error!i64 {
        const c = try self.binary(0);
        if (!self.isOp("?")) return c;
        try self.advance();
        if (c == 0) self.skip += 1;
        const a = try self.assignment();
        if (c == 0) self.skip -= 1;
        if (!self.isOp(":")) return self.failExpr("expecting ':'");
        try self.advance();
        if (c != 0) self.skip += 1;
        const b = try self.assignment();
        if (c != 0) self.skip -= 1;
        return if (c != 0) a else b;
    }

    const levels = [_][]const []const u8{
        &.{"||"},
        &.{"&&"},
        &.{"|"},
        &.{"^"},
        &.{"&"},
        &.{ "==", "!=" },
        &.{ "<", "<=", ">", ">=" },
        &.{ "<<", ">>" },
        &.{ "+", "-" },
        &.{ "*", "/", "%" },
    };

    fn binary(self: *Evaluator, level: usize) Error!i64 {
        if (level == levels.len) return self.unary();
        var left = try self.binary(level + 1);
        while (true) {
            var matched: ?[]const u8 = null;
            for (levels[level]) |o| if (self.isOp(o)) {
                matched = o;
                break;
            };
            const o = matched orelse return left;
            try self.advance();
            if (std.mem.eql(u8, o, "&&")) {
                if (left == 0) self.skip += 1;
                const r = try self.binary(level + 1);
                if (left == 0) self.skip -= 1;
                left = @intFromBool(left != 0 and r != 0);
            } else if (std.mem.eql(u8, o, "||")) {
                if (left != 0) self.skip += 1;
                const r = try self.binary(level + 1);
                if (left != 0) self.skip -= 1;
                left = @intFromBool(left != 0 or r != 0);
            } else {
                const r = try self.binary(level + 1);
                left = try self.binop(o, left, r);
            }
        }
    }

    fn binop(self: *Evaluator, o: []const u8, a: i64, b: i64) Error!i64 {
        const eq = std.mem.eql;
        if (eq(u8, o, "*")) return a *% b;
        if (eq(u8, o, "/") or eq(u8, o, "%")) {
            if (b == 0) {
                if (self.skip > 0) return 0;
                return self.failExpr("division by zero");
            }
            if (b == -1) return if (o[0] == '/') 0 -% a else 0;
            return if (o[0] == '/') @divTrunc(a, b) else @rem(a, b);
        }
        if (eq(u8, o, "+")) return a +% b;
        if (eq(u8, o, "-")) return a -% b;
        if (eq(u8, o, "<<")) return a << @as(u6, @truncate(@as(u64, @bitCast(b))));
        if (eq(u8, o, ">>")) return a >> @as(u6, @truncate(@as(u64, @bitCast(b))));
        if (eq(u8, o, "<")) return @intFromBool(a < b);
        if (eq(u8, o, "<=")) return @intFromBool(a <= b);
        if (eq(u8, o, ">")) return @intFromBool(a > b);
        if (eq(u8, o, ">=")) return @intFromBool(a >= b);
        if (eq(u8, o, "==")) return @intFromBool(a == b);
        if (eq(u8, o, "!=")) return @intFromBool(a != b);
        if (eq(u8, o, "&")) return a & b;
        if (eq(u8, o, "^")) return a ^ b;
        if (eq(u8, o, "|")) return a | b;
        unreachable;
    }

    fn unary(self: *Evaluator) Error!i64 {
        if (self.tok == .op) {
            const o = self.tok.op;
            if (std.mem.eql(u8, o, "-")) {
                try self.advance();
                return 0 -% try self.unary();
            }
            if (std.mem.eql(u8, o, "+")) {
                try self.advance();
                return self.unary();
            }
            if (std.mem.eql(u8, o, "!")) {
                try self.advance();
                return @intFromBool((try self.unary()) == 0);
            }
            if (std.mem.eql(u8, o, "~")) {
                try self.advance();
                return ~(try self.unary());
            }
            if (std.mem.eql(u8, o, "(")) {
                try self.advance();
                const v = try self.assignment();
                if (!self.isOp(")")) return self.failExpr("expecting ')'");
                try self.advance();
                return v;
            }
        }
        switch (self.tok) {
            .num => |n| {
                try self.advance();
                return n;
            },
            .name => |nm| {
                const v = if (self.skip > 0) 0 else try self.varValue(nm);
                try self.advance();
                return v;
            },
            else => return self.failExpr("expecting primary"),
        }
    }
};

fn parseWrapping(digits: []const u8, base: u8) i64 {
    var v: u64 = 0;
    for (digits) |c| {
        const d = std.fmt.charToDigit(c, base) catch unreachable;
        v = v *% base +% d;
    }
    return @bitCast(v);
}

/// strtoimax-style parse of a whole string (base 0); null when not a number.
pub fn parseNumber(s: []const u8) ?i64 {
    var t = std.mem.trimStart(u8, s, " \t\n");
    var neg = false;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    if (t.len == 0) return null;
    var base: u8 = 10;
    if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        base = 16;
        t = t[2..];
    } else if (t.len > 1 and t[0] == '0') {
        base = 8;
        t = t[1..];
    }
    for (t) |c| if (std.fmt.charToDigit(c, base) == error.InvalidCharacter) return null;
    const v = parseWrapping(t, base);
    return if (neg) 0 -% v else v;
}

const TestHost = struct {
    vars: std.StringHashMapUnmanaged([]const u8) = .empty,
    fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        return self.vars.get(name);
    }
    fn set(ctx: *anyopaque, name: []const u8, v: i64) bool {
        _ = ctx;
        _ = name;
        _ = v;
        return true;
    }
};

fn ev(text: []const u8) !i64 {
    var h: TestHost = .{};
    const r = Evaluator.eval(.{ .ctx = &h, .get = TestHost.get, .set = TestHost.set }, text);
    return r.value orelse error.Arith;
}

test "precedence and associativity" {
    try std.testing.expectEqual(@as(i64, 14), try ev("2+3*4"));
    try std.testing.expectEqual(@as(i64, 20), try ev("(2+3)*4"));
    try std.testing.expectEqual(@as(i64, -3), try ev("-7/2"));
    try std.testing.expectEqual(@as(i64, -1), try ev("-7%3"));
    try std.testing.expectEqual(@as(i64, 3), try ev("1?2?3:4:5"));
    try std.testing.expectEqual(@as(i64, 8), try ev("010"));
    try std.testing.expectEqual(@as(i64, 31), try ev("0x1F"));
    try std.testing.expectEqual(@as(i64, 7), try ev("5|3"));
    try std.testing.expectEqual(@as(i64, -4), try ev("-16>>2"));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), try ev("9223372036854775807+1"));
}

test "errors" {
    try std.testing.expectError(error.Arith, ev("1/0"));
    try std.testing.expectError(error.Arith, ev("1+"));
    try std.testing.expectError(error.Arith, ev("08"));
    try std.testing.expectEqual(@as(i64, 0), try ev("0&&1/0"));
    try std.testing.expectEqual(@as(i64, 1), try ev("1||1/0"));
}
