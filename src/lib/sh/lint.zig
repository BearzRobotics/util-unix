// SPDX-License-Identifier: GPL-2.0-or-later
//! `sh --check`: static checks on the syntax tree of a POSIX script. Nothing
//! is executed. The checks and their message texts are this project's own;
//! docs/sh-diagnostics.md maps each code to the nearest ShellCheck id.

const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

pub const Finding = struct {
    kind: diag.Kind,
    line: u32,
    column: u32,
    end_column: u32,
    subject: []const u8,
};

const Ctx = struct {
    a: Allocator,
    out: *std.ArrayList(Finding),
    /// True while the node's failure is observed (condition, `&&`/`||`).
    checked: bool = false,

    fn add(c: *Ctx, kind: diag.Kind, n: *const ast.Node, subject: []const u8) Allocator.Error!void {
        try c.out.append(c.a, .{ .kind = kind, .line = n.line, .column = n.col, .end_column = n.end_col, .subject = subject });
    }
};

fn wordText(w: ast.Word) ?[]const u8 {
    if (w.len != 1) return null;
    return switch (w[0]) {
        .text => |t| t,
        .quoted => |t| t,
        else => null,
    };
}

fn isSafeParam(name: []const u8) bool {
    return name.len == 1 and (name[0] == '?' or name[0] == '#' or name[0] == '$' or name[0] == '!' or name[0] == '-' or name[0] == '@' or name[0] == '*');
}

fn unquotedExpansion(w: ast.Word) ?[]const u8 {
    for (w) |p| switch (p) {
        .param => |pp| if (!pp.quoted and !isSafeParam(pp.name) and pp.op != .length) return pp.name,
        .cmdsub => |c| if (!c.quoted) return "$(...)",
        else => {},
    };
    return null;
}

/// `${x:?}` stops the command when `x` is unset or empty, and `${x:-word}` and
/// `${x:=word}` put the word in its place: with a literal one that is not
/// empty, the expansion cannot be empty.
fn cannotBeEmpty(p: ast.Param) bool {
    if (!p.colon) return false;
    return switch (p.op) {
        .error_if_unset => true,
        .use_default, .assign_default => for (p.arg) |part| {
            switch (part) {
                .text, .quoted => |t| if (t.len > 0) break true,
                else => {},
            }
        } else false,
        else => false,
    };
}

/// True for a path that starts with a variable and goes on with a "/": were
/// the variable empty, it would name something under the root.
fn startsWithParamAndSlash(w: ast.Word) bool {
    if (w.len == 0 or w[0] != .param) return false;
    if (cannotBeEmpty(w[0].param.*)) return false;
    for (w[1..]) |p| switch (p) {
        .text, .quoted => |t| if (std.mem.indexOfScalar(u8, t, '/') != null) return true,
        else => {},
    };
    return false;
}

fn checkSimple(c: *Ctx, n: *const ast.Node, s: ast.Simple) Allocator.Error!void {
    if (s.words.len == 0) return;
    const name = wordText(s.words[0]) orelse return;
    const eq = std.mem.eql;
    if (eq(u8, name, "[[") or eq(u8, name, "]]")) try c.add(.lint_double_bracket, n, name);
    if (eq(u8, name, "function")) try c.add(.lint_function_keyword, n, name);
    if (eq(u8, name, "source")) try c.add(.lint_source, n, name);
    if (eq(u8, name, "local")) try c.add(.lint_local, n, name);
    if (eq(u8, name, "cd") and !c.checked) try c.add(.lint_cd_unchecked, n, name);
    if (eq(u8, name, "echo") and s.words.len > 1) {
        if (wordText(s.words[1])) |f| if (eq(u8, f, "-e") or eq(u8, f, "-E")) try c.add(.lint_echo_option, n, f);
    }
    if (eq(u8, name, "[") or eq(u8, name, "test")) {
        for (s.words[1..]) |w| if (wordText(w)) |t| if (eq(u8, t, "==")) try c.add(.lint_double_equals, n, "==");
    }
    if (eq(u8, name, "rm")) {
        var recursive = false;
        for (s.words[1..]) |w| if (wordText(w)) |t| {
            if (eq(u8, t, "--recursive")) recursive = true;
            // "-r" or "-R" among short options
            if (t.len > 1 and t[0] == '-' and t[1] != '-' and std.mem.indexOfAny(u8, t[1..], "rR") != null) recursive = true;
        };
        if (recursive) for (s.words[1..]) |w| if (startsWithParamAndSlash(w)) try c.add(.lint_rm_variable, n, "rm -r");
    }
    for (s.words[1..]) |w| if (unquotedExpansion(w)) |nm| {
        try c.add(.lint_unquoted_expansion, n, nm);
        break;
    };
}

/// The first line opening a definition with the `function` keyword and a brace
/// on the same line. `function f {` is not POSIX syntax: `{` is an argument, so
/// the closing brace is a syntax error and `check` never sees a tree. `--check`
/// calls this after a syntax error to name the actual mistake.
pub fn functionKeywordLine(source: []const u8) ?Finding {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 0;
    while (lines.next()) |line| {
        number += 1;
        const text = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, text, "function ") and !std.mem.startsWith(u8, text, "function\t")) continue;
        var rest = std.mem.trimStart(u8, text["function".len..], " \t");
        var n: usize = 0;
        while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_' or rest[n] == '-')) n += 1;
        if (n == 0) continue;
        rest = std.mem.trimStart(u8, rest[n..], " \t");
        if (std.mem.startsWith(u8, rest, "()")) rest = std.mem.trimStart(u8, rest[2..], " \t");
        if (!std.mem.startsWith(u8, rest, "{")) continue;
        const column: u32 = @intCast(line.len - text.len + 1);
        return .{ .kind = .lint_function_keyword, .line = number, .column = column, .end_column = column + 8, .subject = "function" };
    }
    return null;
}

test "the function keyword is found where it does not parse" {
    const hit = functionKeywordLine("echo a\n  function f {\n :\n }\n").?;
    try std.testing.expectEqual(@as(u32, 2), hit.line);
    try std.testing.expectEqual(@as(u32, 3), hit.column);
    try std.testing.expect(functionKeywordLine("function f() { :; }") != null);
    try std.testing.expect(functionKeywordLine("functional f {") == null);
    try std.testing.expect(functionKeywordLine("echo function f {") == null);
    try std.testing.expect(functionKeywordLine("function f") == null);
}

/// The commands inside a word's substitutions, however deep, are commands of
/// the script too. Nothing observes whether they fail.
fn walkWord(c: *Ctx, w: ast.Word) Allocator.Error!void {
    for (w) |p| switch (p) {
        .cmdsub => |sub| {
            const saved = c.checked;
            c.checked = false;
            try walk(c, sub.body);
            c.checked = saved;
        },
        .param => |pp| try walkWord(c, pp.arg),
        .arith => |ar| try walkWord(c, ar.expr),
        else => {},
    };
}

fn walkRedirects(c: *Ctx, redirs: []const *ast.Redirect) Allocator.Error!void {
    for (redirs) |r| {
        try walkWord(c, r.target);
        try walkWord(c, r.body);
    }
}

fn walk(c: *Ctx, node: ?*const ast.Node) Allocator.Error!void {
    const n = node orelse return;
    switch (n.kind) {
        .simple => |s| {
            try checkSimple(c, n, s);
            for (s.assigns) |as| try walkWord(c, as.value);
            for (s.words) |w| try walkWord(c, w);
            try walkRedirects(c, s.redirs);
        },
        .pipeline => |p| for (p.commands) |x| try walk(c, x),
        .and_or => |ao| {
            const saved = c.checked;
            c.checked = true;
            try walk(c, ao.left);
            c.checked = saved;
            try walk(c, ao.right);
        },
        .list => |items| for (items) |it| try walk(c, it.node),
        .subshell => |b| try walk(c, b),
        .group => |b| try walk(c, b),
        .redirected => |r| {
            try walk(c, r.body);
            try walkRedirects(c, r.redirs);
        },
        .if_clause => |i| {
            const saved = c.checked;
            c.checked = true;
            try walk(c, i.cond);
            c.checked = saved;
            try walk(c, i.then);
            try walk(c, i.otherwise);
        },
        .loop => |l| {
            const saved = c.checked;
            c.checked = true;
            try walk(c, l.cond);
            c.checked = saved;
            try walk(c, l.body);
        },
        .for_clause => |f| {
            if (f.words) |ws| for (ws) |w| if (unquotedExpansion(w)) |nm| {
                try c.add(.lint_unquoted_expansion, n, nm);
                break;
            };
            if (f.words) |ws| for (ws) |w| try walkWord(c, w);
            try walk(c, f.body);
        },
        .case_clause => |cc| {
            try walkWord(c, cc.word);
            for (cc.items) |it| {
                for (it.patterns) |pat| try walkWord(c, pat);
                try walk(c, it.body);
            }
        },
        .function => |f| try walk(c, f.body),
    }
}

/// Run the checks over the commands of a parsed program.
pub fn check(a: Allocator, commands: []const *const ast.Node, out: *std.ArrayList(Finding)) Allocator.Error!void {
    var c: Ctx = .{ .a = a, .out = out };
    for (commands) |n| try walk(&c, n);
}

test "lint finds the common mistakes" {
    const parser = @import("parser.zig");
    var d: parser.Diag = .{};
    var prog = try parser.parseProgram(std.testing.allocator, "cd /tmp\nrm -rf $d/\n[[ a ]]\necho -e x\nls $files\ncd /x || exit 1\n", &d);
    defer prog.deinit();
    var out: std.ArrayList(Finding) = .empty;
    defer out.deinit(std.testing.allocator);
    try check(std.testing.allocator, prog.commands, &out);
    var kinds: [8]bool = @splat(false);
    for (out.items) |f| switch (f.kind) {
        .lint_cd_unchecked => kinds[0] = true,
        .lint_rm_variable => kinds[1] = true,
        .lint_double_bracket => kinds[2] = true,
        .lint_echo_option => kinds[3] = true,
        .lint_unquoted_expansion => kinds[4] = true,
        else => {},
    };
    for (kinds[0..5]) |k| try std.testing.expect(k);
    var cd_count: usize = 0;
    for (out.items) |f| if (f.kind == .lint_cd_unchecked) {
        cd_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), cd_count);
}

test "lint looks inside substitutions, and knows every spelling of rm -r" {
    const parser = @import("parser.zig");
    const t = std.testing;
    for ([_][]const u8{
        "x=$(rm -rf $d/)",
        "echo \"$(rm -rf $d/)\"",
        "rm -fR \"$dir/\"",
        "rm -Rf \"$dir/\"",
        "rm --recursive \"$dir/\"",
        "case $(rm -r $d/) in *) :;; esac",
        "case x in $(rm -r $d/)) :;; esac",
        "for i in $(rm -r $d/); do :; done",
        ": ${x-$(rm -r $d/)}",
        ": $(( $(rm -r $d/) + 1 ))",
        ": >$(rm -r $d/)",
        "cat <<E\n$(rm -r $d/)\nE",
        "{ :; } 2>$(rm -r $d/)",
    }) |script| {
        var d: parser.Diag = .{};
        var prog = try parser.parseProgram(t.allocator, script, &d);
        defer prog.deinit();
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var out: std.ArrayList(Finding) = .empty;
        try check(arena.allocator(), prog.commands, &out);
        for (out.items) |f| {
            if (f.kind == .lint_rm_variable) break;
        } else {
            std.debug.print("nothing found in: {s}\n", .{script});
            return error.TestUnexpectedResult;
        }
    }
}
