// SPDX-License-Identifier: GPL-2.0-or-later
//! test and [. Part of builtins.zig.

const std = @import("std");
const diagmod = @import("../diag.zig");
const num = @import("../../num.zig");
const sys = @import("../../../sys.zig");
const osio = @import("../osio.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");
const parseNum = @import("common.zig").parseNum;

const TestErr = error{Syntax};

const T = struct {
    sh: *Shell,
    args: []const []const u8,
    i: usize = 0,
    name: []const u8,
    err: [160]u8 = undefined,
    err_len: usize = 0,
    st: u8 = 0,

    fn fail(self: *T, comptime fmt: []const u8, a: anytype) TestErr {
        const m = diagmod.bounded(&self.err, fmt, a);
        self.err_len = m.len;
        return error.Syntax;
    }

    fn cur(self: *const T) ?[]const u8 {
        return if (self.i < self.args.len) self.args[self.i] else null;
    }

    fn isUnary(s: []const u8) bool {
        if (s.len != 2 or s[0] != '-') return false;
        return std.mem.indexOfScalar(u8, "rwxefdcbpugkstznhLSOG", s[1]) != null;
    }

    fn binop(s: []const u8) ?enum { seq, sne, slt, sgt, eq, ne, gt, ge, lt, le, nt, ot, ef } {
        const m = std.mem.eql;
        if (m(u8, s, "=") or m(u8, s, "==")) return .seq;
        if (m(u8, s, "!=")) return .sne;
        if (m(u8, s, "<")) return .slt;
        if (m(u8, s, ">")) return .sgt;
        if (m(u8, s, "-eq")) return .eq;
        if (m(u8, s, "-ne")) return .ne;
        if (m(u8, s, "-gt")) return .gt;
        if (m(u8, s, "-ge")) return .ge;
        if (m(u8, s, "-lt")) return .lt;
        if (m(u8, s, "-le")) return .le;
        if (m(u8, s, "-nt")) return .nt;
        if (m(u8, s, "-ot")) return .ot;
        if (m(u8, s, "-ef")) return .ef;
        return null;
    }

    fn oexpr(self: *T) TestErr!bool {
        var res = try self.aexpr();
        while (self.cur()) |c| {
            if (!std.mem.eql(u8, c, "-o")) break;
            self.i += 1;
            const r = try self.aexpr();
            res = res or r;
        }
        return res;
    }

    fn aexpr(self: *T) TestErr!bool {
        var res = try self.nexpr();
        while (self.cur()) |c| {
            if (!std.mem.eql(u8, c, "-a")) break;
            self.i += 1;
            const r = try self.nexpr();
            res = res and r;
        }
        return res;
    }

    fn nexpr(self: *T) TestErr!bool {
        if (self.cur()) |c| if (std.mem.eql(u8, c, "!")) {
            self.i += 1;
            return !(try self.nexpr());
        };
        return self.primary();
    }

    fn num(self: *T, s: []const u8) TestErr!i64 {
        // blanks around the number are allowed (strtoimax; dash, FreeBSD sh)
        return parseNum(std.mem.trim(u8, s, " \t\n")) orelse self.fail("Illegal number: {s}", .{s});
    }

    fn primary(self: *T) TestErr!bool {
        const c = self.cur() orelse return false;
        if (std.mem.eql(u8, c, "(")) {
            self.i += 1;
            if (self.cur()) |n| if (std.mem.eql(u8, n, ")")) {
                self.i += 1;
                return false;
            };
            const r = try self.oexpr();
            const cl = self.cur() orelse return self.fail("closing paren expected", .{});
            if (!std.mem.eql(u8, cl, ")")) return self.fail("closing paren expected", .{});
            self.i += 1;
            return r;
        }
        // binary operator with the next token as operator takes precedence
        if (self.i + 1 < self.args.len) {
            if (binop(self.args[self.i + 1])) |op| {
                // `-a`/`-o`-style ambiguity: a unary operator followed by a
                // binary operator word is still a binary test of strings.
                if (self.i + 2 >= self.args.len) return self.fail("{s}: argument expected", .{self.args[self.i + 1]});
                const l = c;
                const r = self.args[self.i + 2];
                self.i += 3;
                return self.evalBin(op, l, r);
            }
        }
        if (isUnary(c)) {
            if (self.i + 1 >= self.args.len) {
                // `test -n` alone: a one-word expression is a string test.
                self.i += 1;
                return true;
            }
            const operand = self.args[self.i + 1];
            self.i += 2;
            return try self.evalUnary(c[1], operand);
        }
        self.i += 1;
        // A word followed by something that is not an operator is an error
        // unless it ends the expression or is followed by -a/-o/)
        return c.len > 0;
    }

    fn evalUnary(self: *T, op: u8, s: []const u8) TestErr!bool {
        switch (op) {
            'z' => return s.len == 0,
            'n' => return s.len > 0,
            't' => {
                const fd = parseNum(s) orelse return self.fail("Illegal number: {s}", .{s});
                if (fd < 0 or fd > std.math.maxInt(i32)) return false;
                return osio.isatty(self.sh.env.io, @intCast(fd));
            },
            'r' => return osio.access(self.sh.env.io, s, .{ .read = true }),
            'w' => return osio.access(self.sh.env.io, s, .{ .write = true }),
            'x' => return osio.access(self.sh.env.io, s, .{ .execute = true }),
            'e' => return if (sys.stat(s, true)) |_| true else |_| false,
            'h', 'L' => return if (sys.stat(s, false)) |i| i.kind == .symlink else |_| false,
            else => {},
        }
        const info = sys.stat(s, true) catch return false;
        return switch (op) {
            'f' => info.kind == .file,
            'd' => info.kind == .dir,
            'c' => info.kind == .char,
            'b' => info.kind == .block,
            'p' => info.kind == .fifo,
            'S' => info.kind == .socket,
            's' => info.size > 0,
            'u' => info.mode & 0o4000 != 0,
            'g' => info.mode & 0o2000 != 0,
            'k' => info.mode & 0o1000 != 0,
            'O' => info.uid == sys.geteuid(),
            'G' => info.gid == sys.getegid(),
            else => false,
        };
    }

    fn evalBin(self: *T, op: anytype, l: []const u8, r: []const u8) TestErr!bool {
        switch (op) {
            .seq => return std.mem.eql(u8, l, r),
            .sne => return !std.mem.eql(u8, l, r),
            .slt => return std.mem.order(u8, l, r) == .lt,
            .sgt => return std.mem.order(u8, l, r) == .gt,
            .eq, .ne, .gt, .ge, .lt, .le => {
                const a = try self.num(l);
                const b = try self.num(r);
                return switch (op) {
                    .eq => a == b,
                    .ne => a != b,
                    .gt => a > b,
                    .ge => a >= b,
                    .lt => a < b,
                    else => a <= b,
                };
            },
            .nt, .ot, .ef => {
                const x = sys.stat(l, true) catch null;
                const y = sys.stat(r, true) catch null;
                if (op == .ef) return x != null and y != null and x.?.ino == y.?.ino and x.?.dev == y.?.dev;
                if (op == .nt) {
                    if (x == null) return false;
                    if (y == null) return true;
                    return x.?.mtime_sec > y.?.mtime_sec or (x.?.mtime_sec == y.?.mtime_sec and x.?.mtime_nsec > y.?.mtime_nsec);
                }
                if (y == null) return false;
                if (x == null) return true;
                return x.?.mtime_sec < y.?.mtime_sec or (x.?.mtime_sec == y.?.mtime_sec and x.?.mtime_nsec < y.?.mtime_nsec);
            },
        }
    }
};

fn evalCounted(t: *T, args: []const []const u8) TestErr!bool {
    const eq = std.mem.eql;
    t.args = args;
    t.i = 0;
    switch (args.len) {
        0 => return false,
        1 => return args[0].len > 0,
        2 => {
            if (eq(u8, args[0], "!")) return args[1].len == 0;
            if (T.isUnary(args[0])) return t.evalUnary(args[0][1], args[1]);
            // dash and FreeBSD sh read `[ -a -a ]` as an empty AND and `[ -o -o ]`
            // as an empty OR: false and true, no error; any other `-a x` is an
            // error as above.
            if (eq(u8, args[0], "-a") and eq(u8, args[1], "-a")) return false;
            if (eq(u8, args[0], "-o") and eq(u8, args[1], "-o")) return true;
            return t.fail("{s}: unexpected operator", .{args[0]});
        },
        3 => {
            if (T.binop(args[1])) |op| return t.evalBin(op, args[0], args[2]);
            // `-a` and `-o` between two strings, whatever the strings are
            if (eq(u8, args[1], "-a")) return args[0].len > 0 and args[2].len > 0;
            if (eq(u8, args[1], "-o")) return args[0].len > 0 or args[2].len > 0;
            if (eq(u8, args[0], "!")) return !(try evalCounted(t, args[1..]));
            if (eq(u8, args[0], "(") and eq(u8, args[2], ")")) return args[1].len > 0;
        },
        4 => {
            if (eq(u8, args[0], "!")) return !(try evalCounted(t, args[1..]));
            if (eq(u8, args[0], "(") and eq(u8, args[3], ")")) return evalCounted(t, args[1..3]);
        },
        else => {},
    }
    t.args = args;
    t.i = 0;
    const r = try t.oexpr();
    if (t.i < args.len) return t.fail("{s}: unexpected operator", .{args[t.i]});
    return r;
}

fn runTest(sh: *Shell, name: []const u8, args: []const []const u8) u8 {
    var t: T = .{ .sh = sh, .args = args, .name = name };
    const r = evalCounted(&t, args) catch {
        sh.diagCmdK(.test_error, null, name, "{s}", .{t.err[0..t.err_len]});
        return 2;
    };
    return if (r) 0 else 1;
}

pub fn testCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    return runTest(sh, "test", args[1..]);
}

pub fn bracketCmd(sh: *Shell, _: Allocator, args: []const []const u8) u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[args.len - 1], "]")) {
        sh.diagCmdK(.test_error, null, "[", "missing ]", .{});
        return 2;
    }
    return runTest(sh, "[", args[1 .. args.len - 1]);
}
