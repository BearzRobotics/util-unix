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

fn endsWithSlashAfterParam(w: ast.Word) bool {
    var saw_param = false;
    for (w) |p| switch (p) {
        .param => saw_param = true,
        .text, .quoted => |t| if (saw_param and std.mem.indexOfScalar(u8, t, '/') != null) return true,
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
            if (t.len > 1 and t[0] == '-' and std.mem.indexOfScalar(u8, t, 'r') != null) recursive = true;
            if (eq(u8, t, "-R")) recursive = true;
        };
        if (recursive) for (s.words[1..]) |w| if (endsWithSlashAfterParam(w)) try c.add(.lint_rm_variable, n, "rm -r");
    }
    for (s.words[1..]) |w| if (unquotedExpansion(w)) |nm| {
        try c.add(.lint_unquoted_expansion, n, nm);
        break;
    };
}

fn walk(c: *Ctx, node: ?*const ast.Node) Allocator.Error!void {
    const n = node orelse return;
    switch (n.kind) {
        .simple => |s| try checkSimple(c, n, s),
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
        .redirected => |r| try walk(c, r.body),
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
            try walk(c, f.body);
        },
        .case_clause => |cc| for (cc.items) |it| try walk(c, it.body),
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
