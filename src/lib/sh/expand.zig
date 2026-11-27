// SPDX-License-Identifier: GPL-2.0-or-later
//! Word expansion: tilde, parameter, command substitution, arithmetic, field
//! splitting, pathname expansion and quote removal.
//!
//! References: POSIX.1-2024 Shell Command Language 2.6 "Word Expansions"
//! (the order is fixed: tilde/parameter/command/arithmetic, then field
//! splitting, then pathname expansion, then quote removal) and 2.14.3
//! "Patterns Used for File Name Expansion".
//!
//! Every byte produced while a word is expanded carries a flag saying where
//! it came from: `lit` (unquoted source text: glob characters are active but
//! it is never split), `quoted` (neither split nor a pattern) or `field`
//! (the unquoted result of an expansion: split and a pattern).

const std = @import("std");
const num = @import("../num.zig");
const sys = @import("../../sys.zig");
const ast = @import("ast.zig");
const arith = @import("arith.zig");
const pattern = @import("pattern.zig");
const lexer = @import("lexer.zig");
const diagmod = @import("diag.zig");
const exec = @import("exec.zig");
const shell = @import("shell.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

pub const Error = error{ Fatal, OutOfMemory };

const lit: u8 = 0;
const quoted: u8 = 1;
const field: u8 = 2;
/// Zero-width mark of an empty quoted part (`''`, `""`): it keeps a field
/// alive and separates it from neighbouring split results; never output.
const empty_q: u8 = 3;

const FieldBuf = struct {
    b: std.ArrayList(u8) = .empty,
    f: std.ArrayList(u8) = .empty,
};

const X = struct {
    sh: *Shell,
    a: Allocator,
    /// Fields completed by `$@` boundaries.
    done: std.ArrayList(FieldBuf) = .empty,
    cur: FieldBuf = .{},
    /// The current field exists even if empty (it contained a quoted part).
    marker: bool = false,
    /// A tilde after `=`/`:` expands (assignment values).
    assign: bool = false,
    /// Join `$@` boundaries with a space instead of making fields.
    join: bool = false,

    fn put(x: *X, c: u8, fl: u8) Error!void {
        try x.cur.b.append(x.a, c);
        try x.cur.f.append(x.a, fl);
    }

    fn putAll(x: *X, s: []const u8, fl: u8) Error!void {
        try x.cur.b.appendSlice(x.a, s);
        try x.cur.f.appendNTimes(x.a, fl, s.len);
    }

    fn boundary(x: *X) Error!void {
        if (x.join) {
            // `$@` in a context that does not split joins like `$*`: with
            // the first character of IFS (dash, FreeBSD sh)
            if (ifsFirst(x.sh)) |c| try x.put(c, quoted);
            return;
        }
        if (x.cur.b.items.len > 0 or x.marker) try x.done.append(x.a, x.cur);
        x.cur = .{};
        x.marker = false;
    }

    fn finish(x: *X) Error!void {
        if (x.cur.b.items.len > 0 or x.marker) try x.done.append(x.a, x.cur);
        x.cur = .{};
        x.marker = false;
    }
};

/// Report a fatal expansion error: the (non-interactive) shell exits with
/// status 2, as dash does.
pub fn fatal(sh: *Shell, kind: diagmod.Kind, subject: ?[]const u8, comptime fmt: []const u8, args: anytype) Error {
    sh.diagK(kind, subject, fmt, args);
    sh.status = 2;
    sh.flow = .exit_shell;
    return error.Fatal;
}

// --- public entry points ----------------------------------------------------

/// Expand each word into zero or more fields (with splitting and globbing).
pub fn fields(sh: *Shell, a: Allocator, words: []const ast.Word, out: *std.ArrayList([]const u8)) Error!void {
    for (words) |w| {
        var x: X = .{ .sh = sh, .a = a };
        for (w) |p| try part(&x, p, lit);
        try x.finish();
        for (x.done.items) |fb| try splitAndGlob(&x, fb, out);
    }
}

/// Expand one word to a single string (no splitting, no globbing).
pub fn string(sh: *Shell, a: Allocator, w: ast.Word) Error![]const u8 {
    return stringMode(sh, a, w, false, false);
}

/// Like `string`, for assignment values: tildes after `=`/`:` expand.
pub fn assignValue(sh: *Shell, a: Allocator, w: ast.Word) Error![]const u8 {
    return stringMode(sh, a, w, true, false);
}

/// Expand to a pattern: quoted characters are escaped with a backslash.
pub fn patternString(sh: *Shell, a: Allocator, w: ast.Word) Error![]const u8 {
    return stringMode(sh, a, w, false, true);
}

fn stringMode(sh: *Shell, a: Allocator, w: ast.Word, assign: bool, as_pattern: bool) Error![]const u8 {
    var x: X = .{ .sh = sh, .a = a, .assign = assign, .join = true };
    for (w) |p| try part(&x, p, lit);
    var out: std.ArrayList(u8) = .empty;
    for (x.cur.b.items, x.cur.f.items) |c, fl| {
        if (fl == empty_q) continue;
        if (as_pattern and fl == quoted and isPatternSpecial(c)) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}

fn isPatternSpecial(c: u8) bool {
    return switch (c) {
        '*', '?', '[', ']', '\\', '!', '^', '-' => true,
        else => false,
    };
}

// --- parts ------------------------------------------------------------------

fn part(x: *X, p: ast.Part, text_flag: u8) Error!void {
    switch (p) {
        .text => |t| try x.putAll(t, text_flag),
        .quoted => |t| {
            if (t.len == 0) try x.put(0, empty_q) else try x.putAll(t, quoted);
            x.marker = true;
        },
        .tilde => |u| try tilde(x, u, false),
        .atilde => |u| try tilde(x, u, true),
        .param => |pp| try param(x, pp, text_flag),
        .cmdsub => |c| {
            const out = if (c.body) |b| try exec.substitute(x.sh, x.a, b) else "";
            try x.putAll(out, if (c.quoted) quoted else field);
            if (c.quoted) x.marker = true;
        },
        .arith => |ar| {
            const text = try stringMode(x.sh, x.a, ar.expr, false, false);
            const v = try evalArith(x.sh, text);
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            try x.putAll(s, if (ar.quoted) quoted else field);
            if (ar.quoted) x.marker = true;
        },
    }
}

const ArithHost = struct {
    sh: *Shell,
    fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *ArithHost = @ptrCast(@alignCast(ctx));
        return self.sh.getVar(name);
    }
    fn set(ctx: *anyopaque, name: []const u8, v: i64) bool {
        const self: *ArithHost = @ptrCast(@alignCast(ctx));
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return false;
        self.sh.setVar(name, s) catch return false;
        return true;
    }
};

pub fn evalArith(sh: *Shell, text: []const u8) Error!i64 {
    var h: ArithHost = .{ .sh = sh };
    var ev: arith.Evaluator = .{ .host = .{ .ctx = &h, .get = ArithHost.get, .set = ArithHost.set }, .text = text };
    return ev.run() catch return fatal(sh, ev.kind, ev.subject, "{s}", .{ev.message()});
}

fn homeOf(sh: *Shell, a: Allocator, user: []const u8) ?[]const u8 {
    if (user.len == 0) return sh.getVar("HOME");
    const fd = sys.open("/etc/passwd", .{ .cloexec = true }, 0) catch return null;
    defer sys.close(fd);
    var data: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) catch return null;
        if (n == 0) break;
        data.appendSlice(a, buf[0..n]) catch |oe| {
            _ = sh.oom(oe);
            return null;
        };
    }
    var lines = std.mem.splitScalar(u8, data.items, '\n');
    while (lines.next()) |ln| {
        var f = std.mem.splitScalar(u8, ln, ':');
        const nm = f.next() orelse continue;
        if (!std.mem.eql(u8, nm, user)) continue;
        _ = f.next();
        _ = f.next();
        _ = f.next();
        _ = f.next();
        return f.next();
    }
    return null;
}

fn tilde(x: *X, user: []const u8, is_assign_tilde: bool) Error!void {
    if (is_assign_tilde and !x.assign) {
        try x.put('~', lit);
        try x.putAll(user, lit);
        return;
    }
    if (homeOf(x.sh, x.a, user)) |h| {
        try x.putAll(h, quoted);
        x.marker = true;
    } else {
        try x.put('~', lit);
        try x.putAll(user, lit);
    }
}

// --- parameters ---------------------------------------------------------------

const PV = union(enum) {
    unset,
    one: []const u8,
    many: []const []const u8,
};

fn lookup(x: *X, name: []const u8) Error!PV {
    const sh = x.sh;
    const c = name[0];
    switch (c) {
        '@', '*' => return .{ .many = @as([]const []const u8, @ptrCast(sh.params.items)) },
        '#' => return .{ .one = try std.fmt.allocPrint(x.a, "{d}", .{sh.params.items.len}) },
        'L' => if (std.mem.eql(u8, name, "LINENO")) return .{ .one = try std.fmt.allocPrint(x.a, "{d}", .{sh.line}) } else {
            const v = sh.getVar(name) orelse return .unset;
            return .{ .one = v };
        },
        '?' => {
            // `return N` with N above 255 leaves N in `$?` until the next command starts (dash, FreeBSD sh)
            if (sh.wide_seq != 0 and sh.wide_seq + 1 == sh.simple_seq and (sh.wide_status & 255) == sh.status)
                return .{ .one = try std.fmt.allocPrint(x.a, "{d}", .{sh.wide_status}) };
            return .{ .one = try std.fmt.allocPrint(x.a, "{d}", .{sh.status}) };
        },
        '$' => return .{ .one = try std.fmt.allocPrint(x.a, "{d}", .{sh.pid}) },
        '!' => return if (sh.bg_pid == 0) .unset else .{ .one = try std.fmt.allocPrint(x.a, "{d}", .{sh.bg_pid}) },
        '-' => return .{ .one = try optionLetters(x.a, sh) },
        '0'...'9' => {
            const n = num.parseInt(usize, name, 10) catch return .unset;
            if (n == 0) return .{ .one = sh.name };
            if (n > sh.params.items.len) return .unset;
            return .{ .one = sh.params.items[n - 1] };
        },
        else => {
            const v = sh.getVar(name) orelse return .unset;
            return .{ .one = v };
        },
    }
}

/// The letters of `$-` (dash's order).
pub fn optionLetters(a: Allocator, sh: *const Shell) Allocator.Error![]const u8 {
    const f = sh.flags;
    var out: std.ArrayList(u8) = .empty;
    const table = [_]struct { u8, bool }{
        .{ 'u', f.nounset }, .{ 'b', f.notify },      .{ 'a', f.allexport },  .{ 'C', f.noclobber },
        .{ 'v', f.verbose }, .{ 'x', f.xtrace },      .{ 's', f.stdin_mode }, .{ 'n', f.noexec },
        .{ 'm', f.monitor }, .{ 'i', f.interactive }, .{ 'f', f.noglob },     .{ 'e', f.errexit },
    };
    for (table) |e| if (e[1]) try out.append(a, e[0]);
    return out.items;
}

fn ifsFirst(sh: *Shell) ?u8 {
    const ifs = sh.getVar("IFS") orelse return ' ';
    return if (ifs.len == 0) null else ifs[0];
}

/// Emit a looked-up value in the current accumulator.
fn emit(x: *X, pv: PV, name: []const u8, is_quoted: bool) Error!void {
    const fl: u8 = if (is_quoted) quoted else field;
    switch (pv) {
        .unset => if (is_quoted and !(name.len > 0 and name[0] == '@')) {
            x.marker = true; // "$unset" is one empty field
        },
        .one => |v| {
            // an empty quoted value is a field that survives splitting of
            // an adjacent unquoted expansion (`"$e"$s`)
            if (is_quoted and v.len == 0) try x.put(0, empty_q);
            try x.putAll(v, fl);
            if (is_quoted) x.marker = true;
        },
        .many => |list| {
            if (name.len > 0 and name[0] == '*' and is_quoted) {
                var first = true;
                const sep = ifsFirst(x.sh);
                for (list) |v| {
                    if (!first) if (sep) |s| try x.put(s, quoted);
                    first = false;
                    try x.putAll(v, quoted);
                }
                x.marker = true;
                return;
            }
            for (list, 0..) |v, i| {
                if (i > 0) try x.boundary();
                if (is_quoted and v.len == 0) try x.put(0, empty_q);
                try x.putAll(v, fl);
                if (is_quoted) x.marker = true;
            }
        },
    }
}

/// `pv` with its text in the expansion's arena.
fn owned(x: *X, pv: PV) Error!PV {
    return switch (pv) {
        .unset => .unset,
        .one => |v| .{ .one = try x.a.dupe(u8, v) },
        .many => |list| blk: {
            const copy = try x.a.alloc([]const u8, list.len);
            for (copy, list) |*c, v| c.* = try x.a.dupe(u8, v);
            break :blk .{ .many = copy };
        },
    };
}

fn joined(x: *X, pv: PV) Error![]const u8 {
    switch (pv) {
        .unset => return "",
        .one => |v| return v,
        .many => |list| {
            var out: std.ArrayList(u8) = .empty;
            const sep = ifsFirst(x.sh);
            for (list, 0..) |v, i| {
                if (i > 0) if (sep) |s| try out.append(x.a, s);
                try out.appendSlice(x.a, v);
            }
            return out.items;
        },
    }
}

fn param(x: *X, p: *const ast.Param, text_flag: u8) Error!void {
    const sh = x.sh;
    if (p.op == .bad_subst) {
        sh.diagKind(.bad_substitution, p.name, "Bad substitution");
        sh.status = 2;
        sh.flow = .exit_shell;
        return error.Fatal;
    }
    // A copy: expanding the word of `${x#word}` and the like can assign the
    // variable, which frees the value it had.
    const pv = try owned(x, try lookup(x, p.name));
    const multi = p.name.len > 0 and (p.name[0] == '@' or p.name[0] == '*');
    const is_unset = switch (pv) {
        .unset => true,
        .many => |l| l.len == 0,
        .one => false,
    };
    const is_empty = is_unset or switch (pv) {
        .one => |v| v.len == 0,
        .many => |l| blk: {
            // `$@` and `$*` count as null when their joined text (the
            // parameters separated by the first IFS character) is empty:
            // `set -- ""` makes `${@:-x}` x, `set -- "" ""` does not
            // (dash; FreeBSD sh agrees for one empty parameter).
            if (l.len == 0) break :blk true;
            break :blk (try joined(x, pv)).len == 0;
        },
        .unset => true,
    };
    const missing = if (p.colon) is_empty else is_unset;
    switch (p.op) {
        .bad_subst => {
            sh.diagKind(.bad_substitution, p.name, "Bad substitution");
            sh.status = 2;
            sh.flow = .exit_shell;
            return error.Fatal;
        },
        .plain => {
            if (is_unset and sh.flags.nounset and !multi) return fatal(sh, .unset_variable, p.name, "{s}: parameter not set", .{p.name});
            try emit(x, pv, p.name, p.quoted);
        },
        .length => {
            if (is_unset and sh.flags.nounset and !multi) return fatal(sh, .unset_variable, p.name, "{s}: parameter not set", .{p.name});
            const n: usize = switch (pv) {
                .unset => 0,
                .one => |v| v.len,
                // `${#@}` and `${#*}` are unspecified; dash and FreeBSD sh
                // give the length of the joined parameters
                .many => (try joined(x, pv)).len,
            };
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
            try x.putAll(s, if (p.quoted) quoted else field);
            if (p.quoted) x.marker = true;
        },
        .use_default => {
            if (missing) {
                const tf: u8 = if (p.quoted) quoted else field;
                for (p.arg) |ap| try part(x, ap, tf);
                if (p.quoted) x.marker = true;
            } else try emit(x, pv, p.name, p.quoted);
        },
        .use_alternate => {
            if (!missing) {
                const tf: u8 = if (p.quoted) quoted else field;
                for (p.arg) |ap| try part(x, ap, tf);
                if (p.arg.len == 0 and p.quoted) x.marker = true;
            } else if (p.quoted) x.marker = true;
        },
        .assign_default => {
            if (missing) {
                if (!lexer.isName(p.name)) return fatal(sh, .cannot_assign, p.name, "{s}: cannot assign in this way", .{p.name});
                const v = try stringMode(sh, x.a, p.arg, false, false);
                sh.setVar(p.name, v) catch |e| switch (e) {
                    error.ReadOnly => return fatal(sh, .readonly_assignment, p.name, "{s}: is read only", .{p.name}),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                try x.putAll(v, if (p.quoted) quoted else field);
                if (p.quoted) x.marker = true;
            } else try emit(x, pv, p.name, p.quoted);
        },
        .error_if_unset => {
            if (missing) {
                const msg = try stringMode(sh, x.a, p.arg, false, false);
                if (p.arg.len == 0) {
                    if (p.colon) return fatal(sh, .parameter_error, null, "{s}: parameter null or not set", .{p.name});
                    return fatal(sh, .unset_variable, p.name, "{s}: parameter not set", .{p.name});
                }
                // the script's own message: all of it
                const text = try std.fmt.allocPrint(x.a, "{s}: {s}", .{ p.name, msg });
                sh.diagKind(.parameter_error, text, text);
                sh.status = 2;
                sh.flow = .exit_shell;
                return error.Fatal;
            }
            try emit(x, pv, p.name, p.quoted);
        },
        .trim_prefix_small, .trim_prefix_large, .trim_suffix_small, .trim_suffix_large => {
            if (is_unset and sh.flags.nounset and !multi) return fatal(sh, .unset_variable, p.name, "{s}: parameter not set", .{p.name});
            const pat = try stringMode(sh, x.a, p.arg, false, true);
            if (pv == .many and p.name[0] == '@') {
                // POSIX leaves `${@%pat}` unspecified. dash, FreeBSD sh and
                // busybox ash trim the positional parameters as one string
                // (joined by the first IFS character) and keep the field
                // boundaries: only the first parameter loses a prefix, only
                // the last one a suffix.
                const l = pv.many;
                const v = try joined(x, pv);
                const r = trim(v, pat, p.op);
                const prefix = p.op == .trim_prefix_small or p.op == .trim_prefix_large;
                const cut_front: usize = if (prefix) v.len - r.len else 0;
                const keep_end: usize = if (prefix) v.len else r.len;
                const sep: usize = if (ifsFirst(sh) != null) 1 else 0;
                const out = try x.a.alloc([]const u8, l.len);
                var off: usize = 0;
                for (l, out) |f, *o| {
                    const lo = @max(off, cut_front);
                    const hi = @min(off + f.len, keep_end);
                    o.* = if (hi > lo) v[lo..hi] else "";
                    off += f.len + sep;
                }
                try emit(x, .{ .many = out }, p.name, p.quoted);
                return;
            }
            const v = try joined(x, pv);
            const r = trim(v, pat, p.op);
            try x.putAll(r, if (p.quoted) quoted else field);
            if (p.quoted) x.marker = true;
        },
    }
    _ = text_flag;
}

/// Remove the shortest/longest prefix/suffix of `v` matching `pat`.
pub fn trim(v: []const u8, pat: []const u8, op: ast.ParamOp) []const u8 {
    switch (op) {
        .trim_prefix_small => {
            var i: usize = 0;
            while (i <= v.len) : (i += 1) if (pattern.match(pat, v[0..i])) return v[i..];
        },
        .trim_prefix_large => {
            var i: usize = v.len + 1;
            while (i > 0) {
                i -= 1;
                if (pattern.match(pat, v[0..i])) return v[i..];
            }
        },
        .trim_suffix_small => {
            var i: usize = v.len + 1;
            while (i > 0) {
                i -= 1;
                if (pattern.match(pat, v[i..])) return v[0..i];
            }
        },
        .trim_suffix_large => {
            var i: usize = 0;
            while (i <= v.len) : (i += 1) if (pattern.match(pat, v[i..])) return v[0..i];
        },
        else => {},
    }
    return v;
}

// --- field splitting and pathname expansion ---------------------------------------

fn splitAndGlob(x: *X, fb: FieldBuf, out: *std.ArrayList([]const u8)) Error!void {
    const sh = x.sh;
    var pieces: std.ArrayList(FieldBuf) = .empty;
    const ifs: []const u8 = sh.getVar("IFS") orelse " \t\n";
    const b = fb.b.items;
    const f = fb.f.items;
    var has_split = false;
    if (ifs.len > 0) {
        for (b, f) |c, fl| if (fl == field and std.mem.indexOfScalar(u8, ifs, c) != null) {
            has_split = true;
            break;
        };
    }
    if (!has_split) {
        try pieces.append(x.a, fb);
    } else {
        var cur: FieldBuf = .{};
        var have = false;
        var i: usize = 0;
        const isWs = struct {
            fn f2(s: []const u8, c: u8) bool {
                return (c == ' ' or c == '\t' or c == '\n') and std.mem.indexOfScalar(u8, s, c) != null;
            }
        }.f2;
        while (i < b.len) {
            const c = b[i];
            if (f[i] == field and std.mem.indexOfScalar(u8, ifs, c) != null) {
                if (isWs(ifs, c)) {
                    const was_have = have;
                    if (have) {
                        try pieces.append(x.a, cur);
                        cur = .{};
                        have = false;
                    }
                    i += 1;
                    while (i < b.len and f[i] == field and isWs(ifs, b[i])) i += 1;
                    if (i < b.len and f[i] == field and std.mem.indexOfScalar(u8, ifs, b[i]) != null and !isWs(ifs, b[i])) {
                        // leading white space then a delimiter: an empty field before it
                        if (!was_have and pieces.items.len == 0) try pieces.append(x.a, .{});
                        i += 1;
                        while (i < b.len and f[i] == field and isWs(ifs, b[i])) i += 1;
                    }
                    continue;
                }
                try pieces.append(x.a, cur);
                cur = .{};
                have = false;
                i += 1;
                while (i < b.len and f[i] == field and isWs(ifs, b[i])) i += 1;
                continue;
            }
            try cur.b.append(x.a, c);
            try cur.f.append(x.a, f[i]);
            have = true;
            i += 1;
        }
        if (have) try pieces.append(x.a, cur);
    }
    for (pieces.items) |pc| {
        var has_mark = false;
        for (pc.f.items) |fl| if (fl == empty_q) {
            has_mark = true;
            break;
        };
        if (!has_mark) {
            try glob(sh, x.a, pc, out);
            continue;
        }
        var clean: FieldBuf = .{};
        for (pc.b.items, pc.f.items) |c, fl| {
            if (fl == empty_q) continue;
            try clean.b.append(x.a, c);
            try clean.f.append(x.a, fl);
        }
        try glob(sh, x.a, clean, out);
    }
}

fn glob(sh: *Shell, a: Allocator, fb: FieldBuf, out: *std.ArrayList([]const u8)) Error!void {
    const b = fb.b.items;
    const f = fb.f.items;
    if (!sh.flags.noglob) {
        var maybe = false;
        for (b, f) |c, fl| if (fl != quoted and (c == '*' or c == '?' or c == '[')) {
            maybe = true;
            break;
        };
        if (maybe) {
            var pat: std.ArrayList(u8) = .empty;
            for (b, f) |c, fl| {
                if (fl == quoted and isPatternSpecial(c)) try pat.append(a, '\\');
                try pat.append(a, c);
            }
            if (pattern.hasMagic(pat.items)) {
                const before = out.items.len;
                try globWalk(a, pat.items, out);
                if (out.items.len > before) return;
            }
        }
    }
    try out.append(a, b);
}

/// `prefix` + `/` + `name`; slashes of the pattern are kept as they are
/// (`/.//etc` stays `/.//etc`, dash and FreeBSD sh). `lead` is the length of
/// the leading run of slashes of an absolute pattern, which already ends in one.
fn joinPath(a: Allocator, prefix: []const u8, name: []const u8, lead: usize) Allocator.Error![]const u8 {
    if (prefix.len == 0) return name;
    if (prefix.len <= lead) return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, name });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name });
}

fn lessThan(_: void, l: []u8, r: []u8) bool {
    return std.mem.lessThan(u8, l, r);
}

/// Order of the directory names that a pattern continues below: dash and
/// FreeBSD sh compare them with the `/` that follows (`a-b/f a.b/f a/f`).
fn lessThanDir(_: void, l: []u8, r: []u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        const lc: u8 = if (i < l.len) l[i] else if (i == l.len) '/' else return true;
        const rc: u8 = if (i < r.len) r[i] else if (i == r.len) '/' else return false;
        if (lc != rc) return lc < rc;
    }
}

fn globWalk(a: Allocator, pat: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, pat, '/');
    while (it.next()) |s| try segs.append(a, s);
    var prefix: []const u8 = "";
    var start: usize = 0;
    var lead: usize = 0;
    if (pat.len > 0 and pat[0] == '/') {
        while (lead < pat.len and pat[lead] == '/') lead += 1;
        prefix = pat[0..lead];
        start = lead;
    }
    try walk(a, prefix, lead, segs.items, start, out);
}

fn walk(a: Allocator, prefix: []const u8, lead: usize, segs: []const []const u8, idx: usize, out: *std.ArrayList([]const u8)) Error!void {
    if (idx >= segs.len) {
        try out.append(a, prefix);
        return;
    }
    const seg = segs[idx];
    const last = idx + 1 == segs.len;
    if (seg.len == 0) {
        // `a//b` or a trailing slash: keep it in the result.
        const p2 = try joinPath(a, prefix, "", lead);
        if (last) {
            if (sys.stat(prefix, true)) |info| {
                if (info.kind == .dir) try out.append(a, p2);
            } else |_| {}
            return;
        }
        return walk(a, p2, lead, segs, idx + 1, out);
    }
    if (!pattern.hasMagic(seg)) {
        const name = try pattern.unescape(a, seg);
        const path = try joinPath(a, prefix, name, lead);
        if (last) {
            _ = sys.stat(path, false) catch return;
            try out.append(a, path);
        } else try walk(a, path, lead, segs, idx + 1, out);
        return;
    }
    var names: std.ArrayList([]u8) = .empty;
    sys.listDir(a, prefix, &names) catch return;
    const dot_ok = seg[0] == '.' or (seg.len > 1 and seg[0] == '\\' and seg[1] == '.');
    // `.*` also matches `.` and `..` (dash and FreeBSD sh; decision 0009)
    if (dot_ok) {
        for ([_][]const u8{ ".", ".." }) |d| {
            var have = false;
            for (names.items) |nm| {
                if (std.mem.eql(u8, nm, d)) have = true;
            }
            if (!have) try names.append(a, try a.dupe(u8, d));
        }
    }
    if (last) std.mem.sort([]u8, names.items, {}, lessThan) else std.mem.sort([]u8, names.items, {}, lessThanDir);
    for (names.items) |nm| {
        if (nm[0] == '.' and !dot_ok) continue;
        if (!pattern.match(seg, nm)) continue;
        const path = try joinPath(a, prefix, nm, lead);
        if (last) {
            try out.append(a, path);
        } else {
            const info = sys.stat(path, true) catch continue;
            if (info.kind != .dir) continue;
            try walk(a, path, lead, segs, idx + 1, out);
        }
    }
}
