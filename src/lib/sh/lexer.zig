// SPDX-License-Identifier: GPL-2.0-or-later
//! Lexical definitions of the POSIX shell language: token types, operator
//! recognition, reserved words and name syntax.
//!
//! The scanner proper lives in `parser.zig` because command substitution
//! `$( )` needs the grammar to find its own end (POSIX 2.3, "Token
//! Recognition"). References: POSIX.1-2024 Shell Command Language 2.2-2.4.

const std = @import("std");
const ast = @import("ast.zig");

pub const Op = enum {
    semi, // ;
    amp, // &
    pipe, // |
    and_if, // &&
    or_if, // ||
    lparen, // (
    rparen, // )
    dsemi, // ;;
    less, // <
    great, // >
    dless, // <<
    dgreat, // >>
    lessand, // <&
    greatand, // >&
    lessgreat, // <>
    dlessdash, // <<-
    clobber, // >|

    pub fn text(op: Op) []const u8 {
        return switch (op) {
            .semi => ";",
            .amp => "&",
            .pipe => "|",
            .and_if => "&&",
            .or_if => "||",
            .lparen => "(",
            .rparen => ")",
            .dsemi => ";;",
            .less => "<",
            .great => ">",
            .dless => "<<",
            .dgreat => ">>",
            .lessand => "<&",
            .greatand => ">&",
            .lessgreat => "<>",
            .dlessdash => "<<-",
            .clobber => ">|",
        };
    }

    pub fn isRedirect(op: Op) bool {
        return switch (op) {
            .less, .great, .dless, .dgreat, .lessand, .greatand, .lessgreat, .dlessdash, .clobber => true,
            else => false,
        };
    }
};

pub const Token = struct {
    tag: Tag,
    line: u32,
    /// Byte offsets of the token in the source.
    start: usize = 0,
    end: usize = 0,

    pub const Tag = union(enum) {
        eof,
        newline,
        word: ast.Word,
        /// A digit string directly before `<` or `>`.
        io_number: i32,
        op: Op,
    };
};

pub const Reserved = enum { kw_if, kw_then, kw_else, kw_elif, kw_fi, kw_do, kw_done, kw_case, kw_esac, kw_while, kw_until, kw_for, kw_in, lbrace, rbrace, bang };

const reserved_table = [_]struct { []const u8, Reserved }{
    .{ "if", .kw_if },
    .{ "then", .kw_then },
    .{ "else", .kw_else },
    .{ "elif", .kw_elif },
    .{ "fi", .kw_fi },
    .{ "do", .kw_do },
    .{ "done", .kw_done },
    .{ "case", .kw_case },
    .{ "esac", .kw_esac },
    .{ "while", .kw_while },
    .{ "until", .kw_until },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "{", .lbrace },
    .{ "}", .rbrace },
    .{ "!", .bang },
};

pub fn reservedText(r: Reserved) []const u8 {
    for (reserved_table) |e| if (e[1] == r) return e[0];
    unreachable;
}

/// The reserved word a word token spells, if it is a single unquoted
/// literal (POSIX 2.4: quoting any character makes it an ordinary word).
pub fn reservedOf(w: ast.Word) ?Reserved {
    if (w.len != 1) return null;
    const t = switch (w[0]) {
        .text => |t| t,
        else => return null,
    };
    for (reserved_table) |e| if (std.mem.eql(u8, e[0], t)) return e[1];
    return null;
}

/// Characters that end an unquoted word.
pub fn isMeta(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', ';', '&', '|', '<', '>', '(', ')' => true,
        else => false,
    };
}

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True when `s` is a POSIX name (portable identifier).
pub fn isName(s: []const u8) bool {
    if (s.len == 0 or !isNameStart(s[0])) return false;
    for (s[1..]) |c| if (!isNameChar(c)) return false;
    return true;
}

/// POSIX special built-in utilities (XCU 2.15); dash refuses them as
/// function names.
pub fn isSpecialBuiltin(name: []const u8) bool {
    const names = [_][]const u8{ ":", ".", "break", "continue", "eval", "exec", "exit", "export", "readonly", "return", "set", "shift", "times", "trap", "unset" };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub fn isSpecialParam(c: u8) bool {
    return switch (c) {
        '@', '*', '#', '?', '-', '$', '!' => true,
        else => false,
    };
}

test "names and reserved words" {
    try std.testing.expect(isName("a_1"));
    try std.testing.expect(!isName("1a"));
    try std.testing.expect(!isName(""));
    const w: ast.Word = &.{.{ .text = "while" }};
    try std.testing.expectEqual(Reserved.kw_while, reservedOf(w).?);
    const q: ast.Word = &.{.{ .quoted = "while" }};
    try std.testing.expect(reservedOf(q) == null);
}
