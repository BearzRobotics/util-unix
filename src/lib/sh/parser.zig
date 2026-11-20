// SPDX-License-Identifier: GPL-2.0-or-later
//! Scanner and recursive-descent parser for the POSIX shell command language.
//!
//! The parser is incremental: `nextCommand` returns one complete command at a
//! time, so a script's earlier lines run before a later syntax error is seen
//! (as in every real shell). Nothing here touches the operating system.
//!
//! References: POSIX.1-2024 Shell Command Language, 2.2 Quoting, 2.3 Token
//! Recognition, 2.4 Reserved Words, 2.5 Parameters and Variables, 2.6 Word
//! Expansions, 2.7 Redirection, 2.9-2.10 Commands and Grammar.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const diagmod = @import("diag.zig");
const Allocator = std.mem.Allocator;
const Token = lexer.Token;
const Op = lexer.Op;
const Reserved = lexer.Reserved;
const Node = ast.Node;

pub const Error = error{ Syntax, OutOfMemory };

/// Where and why a parse failed. `message` is complete text such as
/// `Syntax error: ")" unexpected`.
pub const Diag = struct {
    line: u32 = 0,
    /// 1-based column, 0 when unknown (inside a sub-parse).
    col: u32 = 0,
    end_col: u32 = 0,
    kind: diagmod.Kind = .unexpected_token,
    /// Offending token text (borrowed from the source) and the token that
    /// would have been valid (static text).
    token: []const u8 = "",
    expected: []const u8 = "",
    opener: ?diagmod.Opener = null,
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Source of alias definitions; the shell supplies one (builtin `alias`).
pub const AliasLookup = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
};

const PendingHere = struct {
    redir: *ast.Redirect,
    delim: []const u8,
    strip: bool,
    quoted: bool,
    line: u32,
};

const ScanCtx = enum { normal, dquote, brace, text };

const Builder = struct {
    parts: std.ArrayList(ast.Part) = .empty,
    buf: std.ArrayList(u8) = .empty,
    buf_q: bool = false,
    assign: bool = false,
    after_sep: bool = false,

    fn flush(b: *Builder, a: Allocator) Allocator.Error!void {
        if (b.buf.items.len == 0) return;
        const s = try a.dupe(u8, b.buf.items);
        b.buf.clearRetainingCapacity();
        try b.parts.append(a, if (b.buf_q) .{ .quoted = s } else .{ .text = s });
    }

    fn lit(b: *Builder, a: Allocator, c: u8, quoted: bool) Allocator.Error!void {
        if (b.buf.items.len > 0 and b.buf_q != quoted) try b.flush(a);
        b.buf_q = quoted;
        try b.buf.append(a, c);
        b.after_sep = false;
    }

    fn push(b: *Builder, a: Allocator, p: ast.Part) Allocator.Error!void {
        try b.flush(a);
        try b.parts.append(a, p);
        b.after_sep = false;
    }

    fn emptyQuote(b: *Builder, a: Allocator) Allocator.Error!void {
        try b.flush(a);
        try b.parts.append(a, .{ .quoted = "" });
        b.after_sep = false;
    }

    fn atStart(b: *const Builder) bool {
        return b.parts.items.len == 0 and b.buf.items.len == 0;
    }

    fn finish(b: *Builder, a: Allocator) Allocator.Error!ast.Word {
        try b.flush(a);
        return b.parts.toOwnedSlice(a);
    }
};

pub const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    peeked: ?Token = null,
    tok_start: usize = 0,
    dq_start: usize = 0,
    dq_line: u32 = 1,
    openers: std.ArrayList(diagmod.Opener) = .empty,
    /// Set when a here-document ran to the end of the input.
    warn_heredoc: ?struct { line: u32, delim: []const u8 } = null,
    here: std.ArrayList(PendingHere) = .empty,
    diag: *Diag,
    aliases: ?AliasLookup = null,
    /// Last alias expanded; stops direct self-reference.
    /// Aliases being read: (name, end offset of its text in `src`); an alias
    /// is not expanded again inside its own text (POSIX 2.3.1).
    active: std.ArrayList(struct { name: []const u8, end: usize }) = .empty,
    alias_budget: u32 = 200,
    blank_marks: std.ArrayList(usize) = .empty,
    /// Offsets (in `src`) where a backslash-newline was removed by `joinLines`,
    /// so line numbers stay those of the original text.
    conts: []const usize = &.{},
    cont_idx: usize = 0,
    /// A line number offset for sub-parsers.
    depth: u32 = 0,

    pub fn init(a: Allocator, src: []const u8, diag: *Diag) Parser {
        return .{ .a = a, .src = src, .diag = diag };
    }

    /// Parser for a whole program: line continuations (backslash-newline,
    /// POSIX 2.2.1) are removed everywhere but in single quotes and comments.
    pub fn initProgram(a: Allocator, src: []const u8, diag: *Diag) Allocator.Error!Parser {
        var p = init(a, src, diag);
        const j = try joinLines(a, src);
        p.src = j.text;
        p.conts = j.conts;
        return p;
    }

    /// Length of the unread original text (undoing `joinLines`).
    pub fn origTailLen(self: *const Parser) usize {
        var n = self.src.len - @min(self.pos, self.src.len);
        for (self.conts) |c| if (c >= self.pos) {
            n += 2;
        };
        return n;
    }

    fn fixLine(self: *Parser) void {
        while (self.cont_idx < self.conts.len and self.conts[self.cont_idx] <= self.pos) {
            self.line += 1;
            self.cont_idx += 1;
        }
    }

    // --- diagnostics -------------------------------------------------------

    fn colOf(self: *const Parser, off: usize) u32 {
        if (self.depth > 0) return 0;
        var ls = @min(off, self.src.len);
        while (ls > 0 and self.src[ls - 1] != '\n') ls -= 1;
        return @intCast(off - ls + 1);
    }

    fn pushOpener(self: *Parser, name: []const u8, t: Token) Allocator.Error!void {
        try self.openers.append(self.a, .{ .name = name, .line = t.line, .column = self.colOf(t.start) });
    }

    fn popOpener(self: *Parser) void {
        _ = self.openers.pop();
    }

    fn failK(self: *Parser, kind: diagmod.Kind, comptime fmt: []const u8, args: anytype) Error {
        self.fixLine();
        const msg = std.fmt.bufPrint(&self.diag.buf, fmt, args) catch self.diag.buf[0..0];
        self.diag.len = msg.len;
        self.diag.line = self.line;
        self.diag.kind = kind;
        self.diag.col = self.colOf(self.pos);
        self.diag.end_col = self.diag.col + 1;
        self.diag.token = "";
        self.diag.expected = "";
        self.diag.opener = null;
        return error.Syntax;
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        return self.failK(.unexpected_token, fmt, args);
    }

    /// An unterminated quote or substitution opened at `off`.
    fn failOpen(self: *Parser, kind: diagmod.Kind, name: []const u8, off: usize, line: u32, comptime fmt: []const u8, args: anytype) Error {
        const e = self.failK(kind, fmt, args);
        self.diag.opener = .{ .name = name, .line = line, .column = self.colOf(off) };
        self.diag.col = self.colOf(self.src.len);
        return e;
    }

    fn tokenName(t: Token.Tag, buf: []u8) []const u8 {
        return switch (t) {
            .eof => "end of file",
            .newline => "newline",
            .word => |w| if (lexer.reservedOf(w)) |r| std.fmt.bufPrint(buf, "\"{s}\"", .{lexer.reservedText(r)}) catch "word" else "word",
            .io_number => "word",
            .op => |o| std.fmt.bufPrint(buf, "\"{s}\"", .{o.text()}) catch "operator",
        };
    }

    fn unexpected(self: *Parser, t: Token, expecting: ?[]const u8) Error {
        var nb: [32]u8 = undefined;
        const nm = tokenName(t.tag, &nb);
        self.line = t.line;
        var err: Error = undefined;
        if (expecting) |e| {
            err = self.fail("Syntax error: {s} unexpected (expecting \"{s}\")", .{ nm, e });
        } else err = self.fail("Syntax error: {s} unexpected", .{nm});
        self.diag.line = t.line;
        self.diag.col = self.colOf(t.start);
        self.diag.end_col = self.colOf(t.end);
        if (self.diag.end_col <= self.diag.col) self.diag.end_col = self.diag.col + 1;
        self.diag.token = switch (t.tag) {
            .eof => "",
            .newline => "newline",
            else => self.src[@min(t.start, self.src.len)..@min(t.end, self.src.len)],
        };
        if (expecting) |e| {
            self.diag.expected = e;
            if (self.openers.items.len > 0) {
                self.diag.opener = self.openers.items[self.openers.items.len - 1];
                self.diag.kind = .mismatched_closer;
            }
        }
        return err;
    }

    // --- character level ---------------------------------------------------

    fn cur(self: *const Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn at(self: *const Parser, off: usize) ?u8 {
        return if (self.pos + off < self.src.len) self.src[self.pos + off] else null;
    }

    fn adv(self: *Parser) void {
        if (self.src[self.pos] == '\n') self.line += 1;
        self.pos += 1;
    }

    // --- tokens ------------------------------------------------------------

    pub fn peek(self: *Parser) Error!Token {
        if (self.peeked) |t| return t;
        const t = try self.lex();
        self.peeked = t;
        return t;
    }

    pub fn next(self: *Parser) Error!Token {
        const t = try self.peek();
        self.peeked = null;
        return t;
    }

    fn lex(self: *Parser) Error!Token {
        var t = try self.lexRaw();
        t.start = self.tok_start;
        t.end = self.pos;
        return t;
    }

    fn lexRaw(self: *Parser) Error!Token {
        while (true) {
            self.fixLine();
            self.tok_start = self.pos;
            const c = self.cur() orelse return .{ .tag = .eof, .line = self.line };
            if (lexer.isBlank(c)) {
                self.pos += 1;
                continue;
            }
            if (c == '\\' and self.at(1) == '\n') {
                self.adv();
                self.adv();
                continue;
            }
            if (c == '#') {
                while (self.cur()) |d| {
                    if (d == '\n') break;
                    self.pos += 1;
                }
                continue;
            }
            const line = self.line;
            if (c == '\n') {
                self.adv();
                if (self.here.items.len > 0) try self.readHeredocs();
                return .{ .tag = .newline, .line = line };
            }
            if (try self.lexOperator()) |op| return .{ .tag = .{ .op = op }, .line = line };
            if (std.ascii.isDigit(c)) {
                var i: usize = 0;
                while (self.at(i)) |d| : (i += 1) if (!std.ascii.isDigit(d)) break;
                if (self.at(i)) |d| if (d == '<' or d == '>') {
                    const n = std.fmt.parseInt(i32, self.src[self.pos .. self.pos + i], 10) catch return self.failK(.bad_fd_number, "Syntax error: Bad file descriptor number", .{});
                    self.pos += i;
                    return .{ .tag = .{ .io_number = n }, .line = line };
                };
            }
            var b: Builder = .{};
            try self.scanParts(&b, .normal, false);
            return .{ .tag = .{ .word = try b.finish(self.a) }, .line = line };
        }
    }

    fn lexOperator(self: *Parser) Error!?Op {
        const c = self.cur().?;
        const n = self.at(1);
        const n2 = self.at(2);
        const r: struct { Op, usize } = switch (c) {
            ';' => if (n == ';') .{ .dsemi, 2 } else .{ .semi, 1 },
            '&' => if (n == '&') .{ .and_if, 2 } else .{ .amp, 1 },
            '|' => if (n == '|') .{ .or_if, 2 } else .{ .pipe, 1 },
            '(' => .{ .lparen, 1 },
            ')' => .{ .rparen, 1 },
            '<' => if (n == '<') (if (n2 == '-') .{ .dlessdash, 3 } else .{ .dless, 2 }) else if (n == '&') .{ .lessand, 2 } else if (n == '>') .{ .lessgreat, 2 } else .{ .less, 1 },
            '>' => if (n == '>') .{ .dgreat, 2 } else if (n == '&') .{ .greatand, 2 } else if (n == '|') .{ .clobber, 2 } else .{ .great, 1 },
            else => return null,
        };
        self.pos += r[1];
        return r[0];
    }

    // --- words -------------------------------------------------------------

    fn scanParts(self: *Parser, b: *Builder, ctx: ScanCtx, in_dq: bool) Error!void {
        const a = self.a;
        while (true) {
            const c = self.cur() orelse switch (ctx) {
                .normal, .text => return,
                .dquote => return self.failOpen(.unterminated_quote, "\"", self.dq_start, self.dq_line, "Syntax error: Unterminated quoted string", .{}),
                .brace => return self.failK(.bad_substitution, "Syntax error: Missing '}}'", .{}),
            };
            switch (ctx) {
                .normal => if (lexer.isMeta(c)) return,
                .dquote => if (c == '"') return,
                .brace => if (c == '}') return,
                .text => {},
            }
            switch (c) {
                '\\' => {
                    const n = self.at(1);
                    if (n == null) {
                        try b.lit(a, '\\', true);
                        self.pos += 1;
                    } else if (n.? == '\n') {
                        self.adv();
                        self.adv();
                    } else if (in_dq) {
                        const special = switch (n.?) {
                            '$', '`', '\\' => true,
                            '"' => ctx != .text,
                            '}' => ctx == .brace,
                            else => false,
                        };
                        if (special) {
                            try b.lit(a, n.?, true);
                        } else {
                            try b.lit(a, '\\', true);
                            try b.lit(a, n.?, true);
                        }
                        self.pos += 2;
                    } else {
                        try b.lit(a, n.?, true);
                        self.adv();
                        self.adv();
                    }
                },
                '\'' => {
                    if (in_dq or ctx == .text) {
                        try b.lit(a, c, in_dq);
                        self.pos += 1;
                    } else {
                        const qoff = self.pos;
                        const qline = self.line;
                        self.pos += 1;
                        const start = self.pos;
                        while (self.cur()) |d| {
                            if (d == '\'') break;
                            self.adv();
                        } else return self.failOpen(.unterminated_quote, "'", qoff, qline, "Syntax error: Unterminated quoted string", .{});
                        try b.push(a, .{ .quoted = try a.dupe(u8, self.src[start..self.pos]) });
                        self.pos += 1;
                    }
                },
                '"' => {
                    if (ctx == .text) {
                        try b.lit(a, c, true);
                        self.pos += 1;
                    } else {
                        self.dq_start = self.pos;
                        self.dq_line = self.line;
                        self.pos += 1;
                        var inner: Builder = .{};
                        try self.scanParts(&inner, .dquote, true);
                        self.pos += 1; // closing quote
                        try inner.flush(a);
                        if (inner.parts.items.len == 0) {
                            try b.emptyQuote(a);
                        } else {
                            try b.flush(a);
                            try b.parts.appendSlice(a, inner.parts.items);
                            b.after_sep = false;
                        }
                    }
                },
                '$' => try self.scanDollar(b, ctx, in_dq),
                '`' => try self.scanBackquote(b, in_dq),
                '~' => {
                    if (!in_dq and ctx != .text and (b.atStart() or b.after_sep)) {
                        if (self.tryTilde(b, ctx)) |t| {
                            try b.push(a, if (b.atStart()) .{ .tilde = t } else .{ .atilde = t });
                            continue;
                        }
                    }
                    try b.lit(a, c, in_dq);
                    self.pos += 1;
                },
                '=' => {
                    if (ctx == .normal and !b.assign and b.parts.items.len == 0 and !b.buf_q and lexer.isName(b.buf.items)) {
                        b.assign = true;
                        try b.lit(a, c, false);
                        b.after_sep = true;
                    } else try b.lit(a, c, in_dq);
                    self.pos += 1;
                },
                ':' => {
                    try b.lit(a, c, in_dq);
                    if (b.assign and !in_dq) b.after_sep = true;
                    self.pos += 1;
                },
                else => {
                    if (c == '\n') self.line += 1;
                    try b.lit(a, c, in_dq);
                    self.pos += 1;
                },
            }
        }
    }

    /// At a `~`: the user name when it forms a tilde-prefix, advancing past it.
    fn tryTilde(self: *Parser, b: *const Builder, ctx: ScanCtx) ?[]const u8 {
        var i: usize = 1;
        while (self.at(i)) |c| : (i += 1) {
            if (c == '/' or lexer.isMeta(c)) break;
            if (c == ':' and b.assign) break;
            if (ctx == .brace and c == '}') break;
            if (c == '\\' or c == '\'' or c == '"' or c == '$' or c == '`') return null;
        }
        const name = self.src[self.pos + 1 .. self.pos + i];
        self.pos += i;
        return name;
    }

    fn scanDollar(self: *Parser, b: *Builder, ctx: ScanCtx, in_dq: bool) Error!void {
        const a = self.a;
        const n = self.at(1) orelse {
            try b.lit(a, '$', in_dq);
            self.pos += 1;
            return;
        };
        if (n == '\'' and !in_dq and ctx != .text) return self.scanDollarQuote(b);
        if (n == '{') {
            self.pos += 2;
            return self.scanBraced(b, in_dq);
        }
        if (n == '(') {
            if (self.at(2) == '(') {
                if (try self.tryArith(b, in_dq)) return;
            }
            self.pos += 2;
            const body = try self.parseSubstBody();
            try b.push(a, .{ .cmdsub = .{ .body = body, .quoted = in_dq } });
            return;
        }
        if (lexer.isNameStart(n)) {
            var i: usize = 1;
            while (self.at(i)) |c| : (i += 1) if (!lexer.isNameChar(c)) break;
            const p = try a.create(ast.Param);
            p.* = .{ .name = try a.dupe(u8, self.src[self.pos + 1 .. self.pos + i]), .quoted = in_dq };
            self.pos += i;
            try b.push(a, .{ .param = p });
            return;
        }
        if (std.ascii.isDigit(n) or lexer.isSpecialParam(n)) {
            const p = try a.create(ast.Param);
            p.* = .{ .name = try a.dupe(u8, self.src[self.pos + 1 .. self.pos + 2]), .quoted = in_dq };
            self.pos += 2;
            try b.push(a, .{ .param = p });
            return;
        }
        try b.lit(a, '$', in_dq);
        self.pos += 1;
    }

    /// `$'...'` (POSIX.1-2024 XCU 2.2.4 Dollar-Single-Quotes): backslash
    /// escapes are decoded; the result is quoted text.
    fn scanDollarQuote(self: *Parser, b: *Builder) Error!void {
        const a = self.a;
        const qoff = self.pos;
        const qline = self.line;
        self.pos += 2;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.cur() orelse return self.failOpen(.unterminated_quote, "$'", qoff, qline, "Syntax error: Unterminated quoted string", .{});
            if (c == '\'') break;
            if (c != '\\') {
                try out.append(a, c);
                self.adv();
                continue;
            }
            const e = self.at(1) orelse return self.failOpen(.unterminated_quote, "$'", qoff, qline, "Syntax error: Unterminated quoted string", .{});
            self.pos += 2;
            switch (e) {
                'a' => try out.append(a, 7),
                'b' => try out.append(a, 8),
                'e', 'E' => try out.append(a, 27),
                'f' => try out.append(a, 12),
                'n' => try out.append(a, '\n'),
                'r' => try out.append(a, '\r'),
                't' => try out.append(a, '\t'),
                'v' => try out.append(a, 11),
                '\\', '\'', '"', '?' => try out.append(a, e),
                'c' => {
                    const x = self.cur() orelse continue;
                    self.pos += 1;
                    // `\c\\` is control-backslash: the escaped backslash is one unit
                    if (x == '\\' and self.cur() == '\\') self.pos += 1;
                    try out.append(a, if (x == '?') 127 else x & 0x1f);
                },
                'x' => {
                    var v: u32 = 0;
                    var k: usize = 0;
                    while (k < 2) : (k += 1) {
                        const h = self.cur() orelse break;
                        const d = std.fmt.charToDigit(h, 16) catch break;
                        v = v * 16 + d;
                        self.pos += 1;
                    }
                    try out.append(a, @truncate(v));
                },
                '0'...'7' => {
                    var v: u32 = e - '0';
                    var k: usize = 1;
                    while (k < 3) : (k += 1) {
                        const h = self.cur() orelse break;
                        if (h < '0' or h > '7') break;
                        v = v * 8 + (h - '0');
                        self.pos += 1;
                    }
                    try out.append(a, @truncate(v));
                },
                'u', 'U' => {
                    var v: u32 = 0;
                    var k: usize = 0;
                    const max: usize = if (e == 'u') 4 else 8;
                    while (k < max) : (k += 1) {
                        const h = self.cur() orelse break;
                        const d = std.fmt.charToDigit(h, 16) catch break;
                        v = v *% 16 +% d;
                        self.pos += 1;
                    }
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(@min(v, 0x10ffff)), &enc) catch 0;
                    try out.appendSlice(a, enc[0..n]);
                },
                else => {
                    try out.append(a, '\\');
                    try out.append(a, e);
                },
            }
        }
        self.pos += 1;
        try b.push(a, .{ .quoted = out.items });
    }

    /// Skip an unknown `${...}` form to its closing brace; the expander
    /// reports "Bad substitution" if the word is ever expanded.
    fn badSubst(self: *Parser, b: *Builder, in_dq: bool, start: usize) Error!void {
        var depth: usize = 1;
        var i = start;
        while (i < self.src.len) : (i += 1) {
            switch (self.src[i]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        } else return self.failK(.bad_substitution, "Syntax error: Missing '}}'", .{});
        const p = try self.a.create(ast.Param);
        p.* = .{ .name = try self.a.dupe(u8, self.src[start..i]), .op = .bad_subst, .quoted = in_dq };
        for (self.src[start..i]) |c| if (c == '\n') {
            self.line += 1;
        };
        self.pos = i + 1;
        try b.push(self.a, .{ .param = p });
    }

    fn scanBraced(self: *Parser, b: *Builder, in_dq: bool) Error!void {
        const a = self.a;
        const bstart = self.pos;
        const p = try a.create(ast.Param);
        p.* = .{ .name = "", .quoted = in_dq };
        var c = self.cur() orelse return self.failK(.bad_substitution, "Syntax error: Missing '}}'", .{});
        var length = false;
        if (c == '#') {
            const n = self.at(1);
            if (n != null and n.? != '}' and (lexer.isNameStart(n.?) or std.ascii.isDigit(n.?) or n.? == '@' or n.? == '*' or n.? == '$' or n.? == '!' or n.? == '?' or n.? == '-' or n.? == '#')) {
                // `${#name}` is the length; `${#}` and `${#-...}` use `#` itself.
                // `${##}`, `${#-}`, `${#?}`, `${#$}`, `${#!}` are the length of
                // that special parameter (dash, FreeBSD sh); `${#-x}` stays
                // the default value of `#`.
                if (!(n.? == '?' or n.? == '$' or n.? == '!' or n.? == '-' or n.? == '#') or self.at(2) == '}') {
                    length = true;
                    self.pos += 1;
                    c = self.cur().?;
                }
            }
        }
        // parameter name
        if (lexer.isNameStart(c)) {
            var i: usize = 0;
            while (self.at(i)) |d| : (i += 1) if (!lexer.isNameChar(d)) break;
            p.name = try a.dupe(u8, self.src[self.pos .. self.pos + i]);
            self.pos += i;
        } else if (std.ascii.isDigit(c)) {
            var i: usize = 0;
            while (self.at(i)) |d| : (i += 1) if (!std.ascii.isDigit(d)) break;
            p.name = try a.dupe(u8, self.src[self.pos .. self.pos + i]);
            self.pos += i;
        } else if (lexer.isSpecialParam(c)) {
            p.name = try a.dupe(u8, self.src[self.pos .. self.pos + 1]);
            self.pos += 1;
        } else return self.badSubst(b, in_dq, bstart);

        const d = self.cur() orelse return self.failK(.bad_substitution, "Syntax error: Missing '}}'", .{});
        if (length) {
            if (d != '}') return self.badSubst(b, in_dq, bstart);
            p.op = .length;
            self.pos += 1;
            try b.push(a, .{ .param = p });
            return;
        }
        if (d == '}') {
            self.pos += 1;
            try b.push(a, .{ .param = p });
            return;
        }
        var op: ast.ParamOp = undefined;
        switch (d) {
            ':' => {
                const e = self.at(1) orelse return self.failK(.bad_substitution, "Syntax error: Missing '}}'", .{});
                op = switch (e) {
                    '-' => .use_default,
                    '=' => .assign_default,
                    '?' => .error_if_unset,
                    '+' => .use_alternate,
                    else => return self.badSubst(b, in_dq, bstart),
                };
                p.colon = true;
                self.pos += 2;
            },
            '-' => {
                op = .use_default;
                self.pos += 1;
            },
            '=' => {
                op = .assign_default;
                self.pos += 1;
            },
            '?' => {
                op = .error_if_unset;
                self.pos += 1;
            },
            '+' => {
                op = .use_alternate;
                self.pos += 1;
            },
            '#' => {
                if (self.at(1) == '#') {
                    op = .trim_prefix_large;
                    self.pos += 2;
                } else {
                    op = .trim_prefix_small;
                    self.pos += 1;
                }
            },
            '%' => {
                if (self.at(1) == '%') {
                    op = .trim_suffix_large;
                    self.pos += 2;
                } else {
                    op = .trim_suffix_small;
                    self.pos += 1;
                }
            },
            else => return self.badSubst(b, in_dq, bstart),
        }
        p.op = op;
        // in an assignment the word of `${x-word}` also expands tildes after
        // colons (dash, FreeBSD sh)
        var inner: Builder = .{ .assign = b.assign };
        // the word of `#` `##` `%` `%%` is a pattern even inside double quotes:
        // its own quotes and unquoted characters keep their meaning (POSIX 2.6.2)
        const trim_op = op == .trim_prefix_small or op == .trim_prefix_large or op == .trim_suffix_small or op == .trim_suffix_large;
        try self.scanParts(&inner, .brace, in_dq and !trim_op);
        self.pos += 1; // the closing brace
        p.arg = try inner.finish(a);
        try b.push(a, .{ .param = p });
    }

    /// At `$((`: parse an arithmetic expansion if the text closes with `))`.
    fn tryArith(self: *Parser, b: *Builder, in_dq: bool) Error!bool {
        const start = self.pos + 3;
        var i = start;
        var depth: usize = 0;
        while (i < self.src.len) : (i += 1) {
            const c = self.src[i];
            if (c == '(') {
                depth += 1;
            } else if (c == ')') {
                if (depth == 0) {
                    if (i + 1 < self.src.len and self.src[i + 1] == ')') break;
                    return self.failOpen(.unterminated_arithmetic, "$((", self.pos, self.line, "Syntax error: Missing '))'", .{});
                }
                depth -= 1;
            }
        } else return self.failOpen(.unterminated_arithmetic, "$((", self.pos, self.line, "Syntax error: Missing '))'", .{});
        const text = self.src[start..i];
        var sub = Parser.init(self.a, text, self.diag);
        sub.line = self.line;
        sub.depth = self.depth + 1;
        var inner: Builder = .{};
        try sub.scanParts(&inner, .text, true);
        const expr = try inner.finish(self.a);
        for (text) |c| if (c == '\n') {
            self.line += 1;
        };
        self.pos = i + 2;
        try b.push(self.a, .{ .arith = .{ .expr = expr, .quoted = in_dq } });
        return true;
    }

    /// After `$(`: parse commands up to the closing `)`.
    fn parseSubstBody(self: *Parser) Error!?*const Node {
        const cs_off = self.pos - 2;
        const cs_line = self.line;
        const saved = self.peeked;
        self.peeked = null;
        // here-documents of the enclosing command read their bodies after the
        // line that closes this substitution, not at its first newline
        const outer_here = self.here;
        self.here = .empty;
        const body = try self.parseList(.compound);
        const t = try self.next();
        self.here = outer_here;
        switch (t.tag) {
            .op => |o| if (o == .rparen) {
                self.peeked = saved;
                return body;
            },
            else => {},
        }
        const e = self.unexpected(t, ")");
        if (t.tag == .eof) {
            self.diag.kind = .unterminated_command_substitution;
            self.diag.opener = .{ .name = "$(", .line = cs_line, .column = self.colOf(cs_off) };
            self.diag.expected = "";
        }
        return e;
    }

    fn scanBackquote(self: *Parser, b: *Builder, in_dq: bool) Error!void {
        const a = self.a;
        const boff = self.pos;
        const bline = self.line;
        self.pos += 1;
        var text: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.cur() orelse return self.failOpen(.unterminated_quote, "`", boff, bline, "Syntax error: Unterminated quoted string", .{});
            if (c == '`') break;
            if (c == '\\' and self.at(1) == '\n') {
                // backslash-newline is a continuation, also inside quotes
                self.pos += 2;
                self.line += 1;
                continue;
            }
            if (c == '\\') {
                const n = self.at(1) orelse return self.failOpen(.unterminated_quote, "`", boff, bline, "Syntax error: Unterminated quoted string", .{});
                if (n == '$' or n == '`' or n == '\\' or (in_dq and n == '"')) {
                    try text.append(a, n);
                    self.pos += 2;
                    continue;
                }
                try text.append(a, '\\');
                self.pos += 1;
                continue;
            }
            if (c == '\n') self.line += 1;
            try text.append(a, c);
            self.pos += 1;
        }
        self.pos += 1;
        var sub = Parser.init(a, text.items, self.diag);
        sub.aliases = self.aliases;
        sub.line = self.line;
        sub.depth = self.depth + 1;
        const body = try sub.parseList(.compound);
        const t = try sub.next();
        if (t.tag != .eof) return sub.unexpected(t, null);
        try b.push(a, .{ .cmdsub = .{ .body = body, .quoted = in_dq } });
    }

    // --- here-documents ----------------------------------------------------

    fn readHeredocs(self: *Parser) Error!void {
        const a = self.a;
        for (self.here.items) |h| {
            var body: std.ArrayList(u8) = .empty;
            var found = false;
            while (self.pos < self.src.len) {
                const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
                var ln = self.src[self.pos..end];
                self.pos = @min(end + 1, self.src.len);
                self.line += 1;
                if (h.strip) ln = std.mem.trimStart(u8, ln, "\t");
                if (std.mem.eql(u8, ln, h.delim)) {
                    found = true;
                    break;
                }
                try body.appendSlice(a, ln);
                // end of input inside the body: dash and FreeBSD sh keep the
                // text exactly, with no newline the input did not have
                if (end < self.src.len) try body.append(a, '\n');
            }
            if (!found) self.warn_heredoc = .{ .line = h.line, .delim = h.delim };
            if (h.quoted) {
                const parts = try a.alloc(ast.Part, 1);
                parts[0] = .{ .quoted = body.items };
                h.redir.body = parts;
            } else {
                var sub = Parser.init(a, body.items, self.diag);
                sub.line = self.line;
                sub.depth = self.depth + 1;
                var inner: Builder = .{};
                try sub.scanParts(&inner, .text, true);
                h.redir.body = try inner.finish(a);
            }
        }
        self.here.clearRetainingCapacity();
    }

    // --- grammar -----------------------------------------------------------

    /// The next complete command (a `list` or single node), or null at the
    /// end of the input.
    pub fn nextCommand(self: *Parser) Error!?*const Node {
        while (true) {
            const t = try self.peek();
            switch (t.tag) {
                .newline => _ = try self.next(),
                .eof => return null,
                else => break,
            }
        }
        const n = try self.parseList(.top);
        const t = try self.peek();
        switch (t.tag) {
            .newline => _ = try self.next(),
            .eof => {},
            else => return self.unexpected(t, null),
        }
        return n;
    }

    const ListCtx = enum { top, compound };

    fn isTerminator(t: Token) bool {
        switch (t.tag) {
            .op => |o| return o == .rparen or o == .dsemi,
            .word => |w| {
                const r = lexer.reservedOf(w) orelse return false;
                return switch (r) {
                    .kw_then, .kw_else, .kw_elif, .kw_fi, .kw_do, .kw_done, .kw_esac, .rbrace => true,
                    else => false,
                };
            },
            else => return false,
        }
    }

    fn skipNewlines(self: *Parser) Error!void {
        while ((try self.peek()).tag == .newline) _ = try self.next();
    }

    fn mkSimple(self: *Parser, line: u32, s: usize, e: usize, kind: ast.Kind) Error!*const Node {
        const n = try self.a.create(Node);
        n.* = .{ .line = line, .kind = kind, .col = if (e > s) self.colOf(s) else 0, .end_col = if (e > s) self.colOf(e) else 0 };
        return n;
    }

    fn mk(self: *Parser, line: u32, kind: ast.Kind) Error!*const Node {
        const n = try self.a.create(Node);
        n.* = .{ .line = line, .kind = kind };
        return n;
    }

    /// A list of and-or lists separated by `;`, `&` (and newlines inside
    /// compound commands). Returns null when empty.
    fn parseList(self: *Parser, ctx: ListCtx) Error!?*const Node {
        var items: std.ArrayList(ast.ListItem) = .empty;
        const first_line = (try self.peek()).line;
        if (ctx == .compound) try self.skipNewlines();
        while (true) {
            try self.aliasAt();
            const t = try self.peek();
            if (ctx == .compound) {
                if (t.tag == .eof or isTerminator(t)) break;
            } else switch (t.tag) {
                .newline, .eof => break,
                else => {},
            }
            if (t.tag == .op and (t.tag.op == .semi or t.tag.op == .amp)) return self.unexpected(t, null);
            const n = try self.parseAndOr();
            var bg = false;
            const s = try self.peek();
            var sep = false;
            switch (s.tag) {
                .op => |o| if (o == .semi) {
                    _ = try self.next();
                    sep = true;
                } else if (o == .amp) {
                    _ = try self.next();
                    bg = true;
                    sep = true;
                },
                .newline => if (ctx == .compound) {
                    sep = true;
                },
                else => {},
            }
            try items.append(self.a, .{ .node = n, .background = bg });
            if (!sep) break;
            if (ctx == .compound) try self.skipNewlines();
        }
        if (items.items.len == 0) return null;
        if (items.items.len == 1 and !items.items[0].background) return items.items[0].node;
        return try self.mk(first_line, .{ .list = try items.toOwnedSlice(self.a) });
    }

    fn parseAndOr(self: *Parser) Error!*const Node {
        var left = try self.parsePipeline();
        while (true) {
            const t = try self.peek();
            const op: ast.AndOrOp = switch (t.tag) {
                .op => |o| switch (o) {
                    .and_if => .and_if,
                    .or_if => .or_if,
                    else => return left,
                },
                else => return left,
            };
            _ = try self.next();
            try self.skipNewlines();
            const right = try self.parsePipeline();
            left = try self.mk(t.line, .{ .and_or = .{ .left = left, .op = op, .right = right } });
        }
    }

    fn parsePipeline(self: *Parser) Error!*const Node {
        var t = try self.peek();
        var negate = false;
        while (true) {
            switch (t.tag) {
                .word => |w| if (lexer.reservedOf(w) == .bang) {
                    _ = try self.next();
                    negate = !negate;
                    t = try self.peek();
                    continue;
                },
                else => {},
            }
            break;
        }
        const line = t.line;
        const first = try self.parseCommand();
        var cmds: std.ArrayList(*const Node) = .empty;
        try cmds.append(self.a, first);
        while (true) {
            const p = try self.peek();
            switch (p.tag) {
                .op => |o| if (o != .pipe) break,
                else => break,
            }
            _ = try self.next();
            try self.skipNewlines();
            try cmds.append(self.a, try self.parseCommand());
        }
        if (cmds.items.len == 1 and !negate) return first;
        return self.mk(line, .{ .pipeline = .{ .negate = negate, .commands = try cmds.toOwnedSlice(self.a) } });
    }

    /// Replace the peeked word by its alias value if it names one. A value
    /// ending in a blank makes the word after it eligible too (POSIX 2.3.1);
    /// `blank_marks` holds the offsets where such values end.
    fn aliasStep(self: *Parser, allow_reserved: bool) Error!bool {
        const al = self.aliases orelse return false;
        if (self.alias_budget == 0) return false;
        const t = try self.peek();
        const w = switch (t.tag) {
            .word => |w| w,
            else => return false,
        };
        if (w.len != 1) return false;
        const name = switch (w[0]) {
            .text => |s| s,
            else => return false,
        };
        if (!allow_reserved and lexer.reservedOf(w) != null) return false;
        for (self.active.items) |ac| if (ac.end > t.start and std.mem.eql(u8, ac.name, name)) return false;
        const val = al.get(al.ctx, name) orelse return false;
        self.alias_budget -= 1;
        for (self.active.items) |*ac| ac.end = (ac.end + val.len) -| self.pos;
        try self.active.append(self.a, .{ .name = name, .end = val.len });
        const ns = try self.a.alloc(u8, val.len + self.src.len - self.pos);
        @memcpy(ns[0..val.len], val);
        @memcpy(ns[val.len..], self.src[self.pos..]);
        for (self.blank_marks.items) |*m| m.* = (m.* + val.len) -| self.pos;
        if (self.conts.len > 0) {
            var keep: std.ArrayList(usize) = .empty;
            for (self.conts) |c| if (c >= self.pos) try keep.append(self.a, c - self.pos + val.len);
            self.conts = keep.items;
            self.cont_idx = 0;
        }
        if (val.len > 0 and (val[val.len - 1] == ' ' or val[val.len - 1] == '\t')) try self.blank_marks.append(self.a, val.len);
        self.src = ns;
        self.pos = 0;
        self.peeked = null;
        return true;
    }

    fn maybeAlias(self: *Parser) Error!void {
        while (try self.aliasStep(false)) {}
    }

    /// Alias substitution at a position where a command or a reserved word can start.
    fn aliasAt(self: *Parser) Error!void {
        try self.aliasPending();
        try self.maybeAlias();
    }

    /// Called before each word of a simple command: the word right after an
    /// alias value that ended in a blank is alias-expanded as well.
    fn aliasPending(self: *Parser) Error!void {
        while (self.blank_marks.items.len > 0) {
            const t = try self.peek();
            var due = false;
            var i: usize = 0;
            while (i < self.blank_marks.items.len) {
                if (self.blank_marks.items[i] <= t.start) {
                    due = true;
                    _ = self.blank_marks.swapRemove(i);
                } else i += 1;
            }
            if (!due) return;
            if (!(try self.aliasStep(true))) return;
        }
    }

    fn parseCommand(self: *Parser) Error!*const Node {
        try self.maybeAlias();
        const t = try self.peek();
        switch (t.tag) {
            .word => |w| if (lexer.reservedOf(w)) |r| {
                const node: *const Node = switch (r) {
                    .kw_if => try self.parseIf(),
                    .kw_while, .kw_until => try self.parseLoop(r == .kw_until),
                    .kw_for => try self.parseFor(),
                    .kw_case => try self.parseCase(),
                    .lbrace => try self.parseGroup(),
                    else => return self.unexpected(t, null),
                };
                return self.parseTrailingRedirs(node, t.line);
            },
            .op => |o| switch (o) {
                .lparen => {
                    _ = try self.next();
                    try self.pushOpener("(", t);
                    defer self.popOpener();
                    const body = (try self.parseList(.compound)) orelse return self.emptyBody(")");
                    const c = try self.next();
                    if (!(c.tag == .op and c.tag.op == .rparen)) return self.unexpected(c, ")");
                    return self.parseTrailingRedirs(try self.mk(t.line, .{ .subshell = body }), t.line);
                },
                .rparen, .semi, .amp, .pipe, .and_if, .or_if, .dsemi => return self.unexpected(t, null),
                else => {},
            },
            .eof, .newline => return self.unexpected(t, null),
            else => {},
        }
        return self.parseSimple();
    }

    fn parseTrailingRedirs(self: *Parser, node: *const Node, line: u32) Error!*const Node {
        var redirs: std.ArrayList(*ast.Redirect) = .empty;
        while (try self.tryRedirect()) |r| try redirs.append(self.a, r);
        if (redirs.items.len == 0) return node;
        return self.mk(line, .{ .redirected = .{ .body = node, .redirs = try redirs.toOwnedSlice(self.a) } });
    }

    /// An empty compound-list where one is required: at the end of the input
    /// the missing closer is named, otherwise the offending token is.
    fn emptyBody(self: *Parser, closer: []const u8) Error {
        const t = self.peek() catch |e| return e;
        return self.unexpected(t, if (t.tag == .eof) closer else null);
    }

    fn expectReserved(self: *Parser, want: Reserved) Error!void {
        try self.aliasAt();
        const t = try self.next();
        switch (t.tag) {
            .word => |w| if (lexer.reservedOf(w) == want) return,
            else => {},
        }
        return self.unexpected(t, lexer.reservedText(want));
    }

    fn peekIs(self: *Parser, want: Reserved) Error!bool {
        try self.aliasAt();
        const t = try self.peek();
        return switch (t.tag) {
            .word => |w| lexer.reservedOf(w) == want,
            else => false,
        };
    }

    fn parseGroup(self: *Parser) Error!*const Node {
        const ot = try self.next();
        const line = ot.line;
        try self.pushOpener("{", ot);
        defer self.popOpener();
        const body = (try self.parseList(.compound)) orelse return self.emptyBody("}");
        try self.expectReserved(.rbrace);
        return self.mk(line, .{ .group = body });
    }

    fn parseIf(self: *Parser) Error!*const Node {
        const ot = try self.next(); // `if` or `elif`
        const line = ot.line;
        try self.pushOpener(if (self.openers.items.len > 0 and false) "elif" else "if", ot);
        defer self.popOpener();
        const cond = (try self.parseList(.compound)) orelse return self.unexpected(try self.peek(), "then");
        try self.expectReserved(.kw_then);
        const then = (try self.parseList(.compound)) orelse return self.emptyBody("fi");
        var otherwise: ?*const Node = null;
        if (try self.peekIs(.kw_elif)) {
            otherwise = try self.parseIf();
            return self.mk(line, .{ .if_clause = .{ .cond = cond, .then = then, .otherwise = otherwise } });
        }
        if (try self.peekIs(.kw_else)) {
            _ = try self.next();
            otherwise = (try self.parseList(.compound)) orelse return self.emptyBody("fi");
        }
        try self.expectReserved(.kw_fi);
        return self.mk(line, .{ .if_clause = .{ .cond = cond, .then = then, .otherwise = otherwise } });
    }

    fn parseLoop(self: *Parser, until: bool) Error!*const Node {
        const ot = try self.next();
        const line = ot.line;
        try self.pushOpener(if (until) "until" else "while", ot);
        defer self.popOpener();
        const cond = (try self.parseList(.compound)) orelse return self.unexpected(try self.peek(), "do");
        try self.expectReserved(.kw_do);
        const body = (try self.parseList(.compound)) orelse return self.emptyBody("done");
        try self.expectReserved(.kw_done);
        return self.mk(line, .{ .loop = .{ .until = until, .cond = cond, .body = body } });
    }

    fn parseFor(self: *Parser) Error!*const Node {
        const ot = try self.next();
        const line = ot.line;
        try self.pushOpener("for", ot);
        defer self.popOpener();
        const nt = try self.next();
        const name = switch (nt.tag) {
            .word => |w| blk: {
                if (w.len == 1 and w[0] == .text and lexer.isName(w[0].text)) break :blk w[0].text;
                const e = self.failK(.bad_for_variable, "Syntax error: Bad for loop variable", .{});
                self.diag.token = self.src[nt.start..nt.end];
                self.diag.line = nt.line;
                self.diag.col = self.colOf(nt.start);
                self.diag.end_col = self.colOf(nt.end);
                return e;
            },
            else => return self.unexpected(nt, null),
        };
        try self.skipNewlines();
        var words: ?[]const ast.Word = null;
        if (try self.peekIs(.kw_in)) {
            _ = try self.next();
            var list: std.ArrayList(ast.Word) = .empty;
            while (true) {
                const t = try self.peek();
                switch (t.tag) {
                    .word => |w| {
                        _ = try self.next();
                        try list.append(self.a, w);
                    },
                    .op => |o| if (o == .semi) {
                        _ = try self.next();
                        break;
                    } else return self.unexpected(t, "do"),
                    .newline => {
                        _ = try self.next();
                        break;
                    },
                    else => return self.unexpected(t, "do"),
                }
            }
            words = try list.toOwnedSlice(self.a);
        } else {
            const t = try self.peek();
            if (t.tag == .op and t.tag.op == .semi) _ = try self.next();
        }
        try self.skipNewlines();
        try self.expectReserved(.kw_do);
        const body = (try self.parseList(.compound)) orelse return self.emptyBody("done");
        try self.expectReserved(.kw_done);
        return self.mk(line, .{ .for_clause = .{ .name = name, .words = words, .body = body } });
    }

    fn parseCase(self: *Parser) Error!*const Node {
        const ot = try self.next();
        const line = ot.line;
        try self.pushOpener("case", ot);
        defer self.popOpener();
        const wt = try self.next();
        const word = switch (wt.tag) {
            .word => |w| w,
            else => return self.unexpected(wt, null),
        };
        try self.skipNewlines();
        try self.expectReserved(.kw_in);
        try self.skipNewlines();
        var items: std.ArrayList(ast.CaseItem) = .empty;
        while (true) {
            if (try self.peekIs(.kw_esac)) break;
            try self.aliasAt();
            var t = try self.next();
            if (t.tag == .op and t.tag.op == .lparen) {
                try self.aliasAt();
                t = try self.next();
            }
            var pats: std.ArrayList(ast.Word) = .empty;
            while (true) {
                switch (t.tag) {
                    .word => |w| try pats.append(self.a, w),
                    else => return self.unexpected(t, if (pats.items.len == 0) "esac" else ")"),
                }
                try self.aliasAt();
                t = try self.next();
                if (t.tag == .op and t.tag.op == .pipe) {
                    try self.aliasAt();
                    t = try self.next();
                    continue;
                }
                if (t.tag == .op and t.tag.op == .rparen) break;
                return self.unexpected(t, ")");
            }
            const body = try self.parseList(.compound);
            try items.append(self.a, .{ .patterns = try pats.toOwnedSlice(self.a), .body = body });
            try self.aliasAt();
            const e = try self.peek();
            if (e.tag == .op and e.tag.op == .dsemi) {
                _ = try self.next();
                try self.skipNewlines();
                continue;
            }
            if (!(try self.peekIs(.kw_esac))) return self.unexpected(e, ";;");
            break;
        }
        try self.expectReserved(.kw_esac);
        return self.mk(line, .{ .case_clause = .{ .word = word, .items = try items.toOwnedSlice(self.a) } });
    }

    fn assignSplit(self: *Parser, w: ast.Word) Error!?ast.Assign {
        if (w.len == 0) return null;
        const first = switch (w[0]) {
            .text => |t| t,
            else => return null,
        };
        const eq = std.mem.indexOfScalar(u8, first, '=') orelse return null;
        if (!lexer.isName(first[0..eq])) return null;
        var value: std.ArrayList(ast.Part) = .empty;
        if (eq + 1 < first.len) try value.append(self.a, .{ .text = first[eq + 1 ..] });
        try value.appendSlice(self.a, w[1..]);
        return .{ .name = first[0..eq], .value = try value.toOwnedSlice(self.a) };
    }

    fn tryRedirect(self: *Parser) Error!?*ast.Redirect {
        var t = try self.peek();
        var fd: ?i32 = null;
        if (t.tag == .io_number) {
            fd = t.tag.io_number;
            _ = try self.next();
            t = try self.peek();
        }
        const op = switch (t.tag) {
            .op => |o| if (o.isRedirect()) o else return null,
            else => return null,
        };
        _ = try self.next();
        const wt = try self.next();
        const target = switch (wt.tag) {
            .word => |w| w,
            else => {
                const e = self.unexpected(wt, null);
                self.diag.kind = .missing_redirect_target;
                self.diag.expected = op.text();
                return e;
            },
        };
        const r = try self.a.create(ast.Redirect);
        r.* = .{ .fd = fd, .op = switch (op) {
            .less => .in,
            .great => .out,
            .dgreat => .append,
            .clobber => .clobber,
            .lessand => .dup_in,
            .greatand => .dup_out,
            .lessgreat => .read_write,
            else => .heredoc,
        }, .target = target, .line = t.line };
        if (r.op == .heredoc) {
            var delim: std.ArrayList(u8) = .empty;
            var quoted = false;
            for (target) |p| switch (p) {
                .text => |s| try delim.appendSlice(self.a, s),
                .quoted => |s| {
                    quoted = true;
                    try delim.appendSlice(self.a, s);
                },
                // a command substitution in the delimiter is an error (dash,
                // FreeBSD sh); POSIX leaves the delimiter's expansions undefined
                .cmdsub => return self.failK(.unexpected_token, "Syntax error: Illegal eof marker for << redirection", .{}),
                else => quoted = quoted,
            };
            r.target = &.{};
            try self.here.append(self.a, .{ .redir = r, .delim = delim.items, .strip = op == .dlessdash, .quoted = quoted, .line = t.line });
        }
        return r;
    }

    fn parseSimple(self: *Parser) Error!*const Node {
        const a = self.a;
        const line = (try self.peek()).line;
        var assigns: std.ArrayList(ast.Assign) = .empty;
        var words: std.ArrayList(ast.Word) = .empty;
        var redirs: std.ArrayList(*ast.Redirect) = .empty;
        var cmd_start: usize = 0;
        var cmd_end: usize = 0;
        while (true) {
            if (try self.tryRedirect()) |r| {
                try redirs.append(a, r);
                continue;
            }
            try self.aliasPending();
            // the command name after assignments or redirections is in command position
            if (words.items.len == 0 and (assigns.items.len > 0 or redirs.items.len > 0)) try self.maybeAlias();
            const t = try self.peek();
            const w = switch (t.tag) {
                .word => |w| w,
                else => break,
            };
            if (words.items.len == 0) {
                if (try self.assignSplit(w)) |asg| {
                    _ = try self.next();
                    if (assigns.items.len == 0) {
                        cmd_start = t.start;
                        cmd_end = t.end;
                    }
                    try assigns.append(a, asg);
                    continue;
                }
            }
            _ = try self.next();
            if (words.items.len == 0) {
                cmd_start = t.start;
                cmd_end = t.end;
            }
            try words.append(a, w);
            // function definition: name ( ) body
            if (words.items.len == 1 and assigns.items.len == 0 and redirs.items.len == 0) {
                const p = try self.peek();
                if (p.tag == .op and p.tag.op == .lparen) {
                    const fname = if (w.len == 1 and w[0] == .text and lexer.isName(w[0].text)) w[0].text else return self.unexpected(p, null);
                    if (lexer.isSpecialBuiltin(fname)) {
                        const e = self.failK(.bad_function_name, "Syntax error: Bad function name", .{});
                        self.diag.token = fname;
                        self.diag.line = t.line;
                        self.diag.col = self.colOf(t.start);
                        self.diag.end_col = self.colOf(t.end);
                        return e;
                    }
                    _ = try self.next();
                    const c = try self.next();
                    if (!(c.tag == .op and c.tag.op == .rparen)) return self.unexpected(c, ")");
                    try self.skipNewlines();
                    const bt = try self.peek();
                    const body = switch (bt.tag) {
                        .word => |bw| if (lexer.reservedOf(bw) != null) try self.parseCommand() else return self.unexpected(bt, null),
                        .op => |o| if (o == .lparen) try self.parseCommand() else return self.unexpected(bt, null),
                        else => return self.unexpected(bt, null),
                    };
                    return self.mk(line, .{ .function = .{ .name = fname, .body = body } });
                }
            }
        }
        self.blank_marks.clearRetainingCapacity();
        if (assigns.items.len == 0 and words.items.len == 0 and redirs.items.len == 0) return self.unexpected(try self.peek(), null);
        return self.mkSimple(line, cmd_start, cmd_end, .{ .simple = .{
            .assigns = try assigns.toOwnedSlice(a),
            .words = try words.toOwnedSlice(a),
            .redirs = try redirs.toOwnedSlice(a),
        } });
    }

};

const HereDelim = struct { text: []const u8, strip: bool };

/// Remove backslash-newline pairs (POSIX 2.2.1) outside single quotes, comments
/// and here-document bodies. Returns the new text and the offsets in it where
/// a pair was removed.
fn joinLines(a: Allocator, src: []const u8) Allocator.Error!struct { text: []const u8, conts: []const usize } {
    if (std.mem.indexOf(u8, src, "\\\n") == null) return .{ .text = src, .conts = &.{} };
    var out: std.ArrayList(u8) = .empty;
    var conts: std.ArrayList(usize) = .empty;
    var pending: std.ArrayList(HereDelim) = .empty;
    var i: usize = 0;
    var dq = false;
    var word_start = true;
    while (i < src.len) {
        const c = src[i];
        if (c == '\n' and pending.items.len > 0) {
            try out.append(a, '\n');
            i += 1;
            for (pending.items) |h| {
                while (i < src.len) {
                    const e = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
                    var ln = src[i..e];
                    const full = if (e < src.len) src[i .. e + 1] else src[i..e];
                    try out.appendSlice(a, full);
                    i = @min(e + 1, src.len);
                    if (h.strip) ln = std.mem.trimStart(u8, ln, "\t");
                    if (std.mem.eql(u8, ln, h.text)) break;
                }
            }
            pending.clearRetainingCapacity();
            word_start = true;
            continue;
        }
        switch (c) {
            '\\' => {
                if (i + 1 < src.len and src[i + 1] == '\n') {
                    try conts.append(a, out.items.len);
                    i += 2;
                    continue;
                }
                try out.append(a, c);
                if (i + 1 < src.len) try out.append(a, src[i + 1]);
                i += 2;
                word_start = false;
                continue;
            },
            '\'' => if (!dq) {
                const e = std.mem.indexOfScalarPos(u8, src, i + 1, '\'') orelse src.len - 1;
                try out.appendSlice(a, src[i .. e + 1]);
                i = e + 1;
                word_start = false;
                continue;
            },
            '"' => dq = !dq,
            '#' => if (!dq and word_start) {
                const e = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
                try out.appendSlice(a, src[i..e]);
                i = e;
                continue;
            },
            '<' => if (!dq and i + 2 < src.len and src[i + 1] == '<' and src[i + 2] != '<') {
                var j = i + 2;
                var strip = false;
                if (src[j] == '-') {
                    strip = true;
                    j += 1;
                }
                try out.appendSlice(a, src[i..j]);
                while (j < src.len and (src[j] == ' ' or src[j] == '\t')) : (j += 1) try out.append(a, src[j]);
                var dl: std.ArrayList(u8) = .empty;
                while (j < src.len) {
                    const d = src[j];
                    if (d == ' ' or d == '\t' or d == '\n' or d == ';' or d == '&' or d == '|' or d == '<' or d == '>' or d == '(' or d == ')') break;
                    try out.append(a, d);
                    j += 1;
                    if (d == '\'' or d == '"') continue;
                    if (d == '\\' and j < src.len) {
                        try out.append(a, src[j]);
                        try dl.append(a, src[j]);
                        j += 1;
                        continue;
                    }
                    try dl.append(a, d);
                }
                try pending.append(a, .{ .text = dl.items, .strip = strip });
                i = j;
                word_start = false;
                continue;
            },
            else => {},
        }
        try out.append(a, c);
        word_start = c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '&' or c == '|' or c == '(' or c == ')';
        i += 1;
    }
    return .{ .text = out.items, .conts = conts.items };
}

/// Parse text as the body of an unquoted here-document: only `$` and backquote
/// expansions (used for PS4, which is expanded when it is printed).
pub fn parseText(a: Allocator, text: []const u8) Error!ast.Word {
    var d: Diag = .{};
    var sub = Parser.init(a, text, &d);
    sub.depth = 1;
    var inner: Builder = .{};
    try sub.scanParts(&inner, .text, true);
    return inner.finish(a);
}

/// Parse a whole source text. The result owns its arena. On a syntax error
/// `diag` is filled and `error.Syntax` returned.
pub fn parseProgram(gpa: Allocator, src: []const u8, diag: *Diag) Error!ast.Program {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var p = try Parser.initProgram(a, src, diag);
    var cmds: std.ArrayList(*const Node) = .empty;
    while (try p.nextCommand()) |n| try cmds.append(a, n);
    return .{ .arena = arena, .commands = try cmds.toOwnedSlice(a) };
}

fn testParse(src: []const u8) !ast.Program {
    var d: Diag = .{};
    return parseProgram(std.testing.allocator, src, &d);
}

test "simple command with assignment and redirect" {
    var p = try testParse("A=1 B=\"x y\" echo hi >out 2>&1\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.commands.len);
    const s = p.commands[0].kind.simple;
    try std.testing.expectEqual(@as(usize, 2), s.assigns.len);
    try std.testing.expectEqualStrings("A", s.assigns[0].name);
    try std.testing.expectEqual(@as(usize, 2), s.words.len);
    try std.testing.expectEqual(@as(usize, 2), s.redirs.len);
    try std.testing.expectEqual(@as(?i32, 2), s.redirs[1].fd);
}

test "and-or is left associative and pipelines negate" {
    var p = try testParse("! a | b && c || d\n");
    defer p.deinit();
    const top = p.commands[0].kind.and_or;
    try std.testing.expectEqual(ast.AndOrOp.or_if, top.op);
    const l = top.left.kind.and_or;
    try std.testing.expectEqual(ast.AndOrOp.and_if, l.op);
    try std.testing.expect(l.left.kind.pipeline.negate);
    try std.testing.expectEqual(@as(usize, 2), l.left.kind.pipeline.commands.len);
}

test "compound commands and functions" {
    var p = try testParse("f() { if a; then b; elif c; then d; else e; fi; }\nfor x in 1 2; do echo $x; done\ncase $x in a|b) echo;; *) :;; esac\nwhile :; do break; done\n(echo sub)\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 5), p.commands.len);
    try std.testing.expectEqualStrings("f", p.commands[0].kind.function.name);
    try std.testing.expectEqual(@as(usize, 2), p.commands[2].kind.case_clause.items.len);
}

test "here-document bodies attach after the newline" {
    var p = try testParse("cat <<EOF\nhello $x\nEOF\necho after\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.commands.len);
    const r = p.commands[0].kind.simple.redirs[0];
    try std.testing.expectEqual(ast.RedirOp.heredoc, r.op);
    try std.testing.expectEqual(@as(usize, 3), r.body.len);
}

test "parameter expansion forms" {
    var p = try testParse("echo ${x:-def} ${#x} ${x%%.*} ${x##a} $((1+2)) $(echo hi) `date`\n");
    defer p.deinit();
    const w = p.commands[0].kind.simple.words;
    try std.testing.expectEqual(ast.ParamOp.use_default, w[1][0].param.op);
    try std.testing.expect(w[1][0].param.colon);
    try std.testing.expectEqual(ast.ParamOp.length, w[2][0].param.op);
    try std.testing.expectEqual(ast.ParamOp.trim_suffix_large, w[3][0].param.op);
    try std.testing.expect(w[5][0] == .arith);
    try std.testing.expect(w[6][0] == .cmdsub);
    try std.testing.expect(w[7][0] == .cmdsub);
}

test "syntax errors carry dash-style text" {
    var d: Diag = .{};
    try std.testing.expectError(error.Syntax, parseProgram(std.testing.allocator, "if true; then echo\n", &d));
    try std.testing.expectEqualStrings("Syntax error: end of file unexpected (expecting \"fi\")", d.message());
    try std.testing.expectError(error.Syntax, parseProgram(std.testing.allocator, "echo )\n", &d));
    try std.testing.expectEqualStrings("Syntax error: \")\" unexpected", d.message());
    try std.testing.expectError(error.Syntax, parseProgram(std.testing.allocator, "echo 'abc\n", &d));
    try std.testing.expectEqualStrings("Syntax error: Unterminated quoted string", d.message());
}

test "tilde prefixes" {
    var p = try testParse("echo ~ ~root/x a=~:~/y\n");
    defer p.deinit();
    const w = p.commands[0].kind.simple.words;
    try std.testing.expect(w[1][0] == .tilde);
    try std.testing.expectEqualStrings("root", w[2][0].tilde);
}

const fuzz_corpus = [_][]const u8{
    "echo 'a' \"b $(c)\" `d` $((1+2)) ${x:-y}\n",
    "cat <<EOF\n$x $(echo hi) `date`\nEOF\ncat <<-'E'\n\tbody\n\tE\n",
    "if a; then b; elif c; then d; else e; fi\nwhile :; do break; done\nuntil false; do :; done\n",
    "case $x in a|b) echo;; (c) :;; *) ;; esac\nfor i in 1 2 3; do echo $i; done\n",
    "f() { echo \"$@\"; } >&2\n(cd /; ls) | sort -r && echo ok || echo bad &\n",
    "x=$((1 + (2 * 3) % 4 << 1 ? 5 : 6)); y=${x#*/}${x%%.*}${#x}\n",
    "echo $(echo $(echo \"nested `deep`\"))\necho \"a\\\"b\" 'c' d\\ e # comment\n",
    "! true; 2>&1 echo a; exec 3<>f; echo >|g; echo ~root/x a=~:~/y\n",
};

fn parseOnce(bytes: []const u8) void {
    var d: Diag = .{};
    var prog = parseProgram(std.testing.allocator, bytes, &d) catch return;
    prog.deinit();
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const n = smith.slice(&buf);
    parseOnce(buf[0..n]);
}

test "fuzz: the parser never crashes, hangs or leaks" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &fuzz_corpus });
}

test "mutation: corpus scripts with random byte damage parse or fail cleanly" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    const specials = "'\"`$(){};|&<>\n\\#~ =";
    for (fuzz_corpus) |seed| {
        parseOnce(seed);
        var iter: usize = 0;
        while (iter < 600) : (iter += 1) {
            const len = @min(seed.len, buf.len);
            @memcpy(buf[0..len], seed[0..len]);
            var cur: usize = len;
            const edits = 1 + rnd.uintLessThan(usize, 4);
            var k: usize = 0;
            while (k < edits) : (k += 1) {
                switch (rnd.uintLessThan(u8, 3)) {
                    0 => buf[rnd.uintLessThan(usize, cur)] = specials[rnd.uintLessThan(usize, specials.len)],
                    1 => cur = rnd.uintLessThan(usize, cur) + 1,
                    else => buf[rnd.uintLessThan(usize, cur)] = rnd.int(u8),
                }
            }
            parseOnce(buf[0..cur]);
        }
    }
}
