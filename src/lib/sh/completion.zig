// SPDX-License-Identifier: GPL-2.0-or-later
//! Tab completion for the interactive shell: the `readline.CompleteFn` the
//! shell installs. The editor does not touch the file system; this module
//! does, through `sys.zig`, on behalf of the shell.
//!
//! The word under the cursor is completed as
//!   - a variable name when it starts with `$` (or `${`),
//!   - a command (builtins, functions, aliases, executables in `$PATH`) when
//!     it is the first word of a simple command and has no `/`,
//!   - a file name otherwise (directories get a trailing `/`; special
//!     characters are backslash-escaped).

const std = @import("std");
const sys = @import("../../sys.zig");
const shell = @import("shell.zig");
const builtins = @import("builtins.zig");
const readline = @import("readline.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

fn isDelim(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '|' or c == '&' or c == '(' or c == ')' or c == '<' or c == '>';
}

/// Start of the word that ends at `cursor` (skips back over quoted blanks).
pub fn wordStart(line: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i > 0) {
        const c = line[i - 1];
        if (isDelim(c)) {
            // an escaped blank belongs to the word
            var bs: usize = 0;
            var k = i - 1;
            while (k > 0 and line[k - 1] == '\\') : (k -= 1) bs += 1;
            if (bs % 2 == 1 and (c == ' ' or c == '\t')) {
                i -= 1;
                continue;
            }
            break;
        }
        i -= 1;
    }
    return i;
}

fn commandPosition(line: []const u8, start: usize) bool {
    var i = start;
    while (i > 0 and (line[i - 1] == ' ' or line[i - 1] == '\t')) i -= 1;
    if (i == 0) return true;
    const c = line[i - 1];
    if (c == ';' or c == '|' or c == '&' or c == '(' or c == '\n' or c == '{') return true;
    // after a reserved word that introduces a command
    var j = i;
    while (j > 0 and !isDelim(line[j - 1])) j -= 1;
    const w = line[j..i];
    for ([_][]const u8{ "then", "do", "else", "elif", "if", "while", "until", "!" }) |r| if (std.mem.eql(u8, w, r)) return true;
    return false;
}

fn needsEscape(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\\', '\'', '"', '$', '`', '*', '?', '[', ']', '(', ')', '<', '>', '|', '&', ';', '#', '~', '!', '{', '}' => true,
        else => false,
    };
}

fn escaped(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (needsEscape(c) and !(c == '~' and i > 0)) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}

fn lessThan(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn sortUnique(list: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, list.items, {}, lessThan);
    var w: usize = 0;
    for (list.items, 0..) |x, i| {
        if (i > 0 and std.mem.eql(u8, x, list.items[w - 1])) continue;
        list.items[w] = x;
        w += 1;
    }
    list.shrinkRetainingCapacity(w);
}

fn completeVariable(sh: *Shell, a: Allocator, word: []const u8, start: usize) Allocator.Error!readline.Completion {
    const braced = std.mem.startsWith(u8, word, "${");
    const prefix = word[if (braced) 2 else 1..];
    var list: std.ArrayList([]const u8) = .empty;
    var it = sh.vars.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.value == null) continue;
        if (!std.mem.startsWith(u8, e.key_ptr.*, prefix)) continue;
        try list.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (braced) "${" else "$", e.key_ptr.*, if (braced) "}" else "" }));
    }
    sortUnique(&list);
    return .{ .start = start, .candidates = list.items };
}

fn completeCommand(sh: *Shell, a: Allocator, word: []const u8, start: usize) Allocator.Error!readline.Completion {
    var list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (builtins.nameAt(i)) |n| : (i += 1) {
        if (std.mem.startsWith(u8, n, word)) try list.append(a, n);
    }
    var fit = sh.funcs.iterator();
    while (fit.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, word)) try list.append(a, try a.dupe(u8, e.key_ptr.*));
    var ait = sh.aliases.iterator();
    while (ait.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, word)) try list.append(a, try a.dupe(u8, e.key_ptr.*));
    const path = sh.getVar("PATH") orelse "";
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| sh.gpa.free(n);
            names.deinit(sh.gpa);
        }
        sys.listDir(sh.gpa, if (dir.len == 0) "." else dir, &names) catch continue;
        for (names.items) |n| {
            if (!std.mem.startsWith(u8, n, word)) continue;
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, n });
            const info = sys.stat(full, true) catch continue;
            if (info.kind == .dir or !sys.access(full, 1)) continue;
            try list.append(a, try escaped(a, n));
        }
    }
    sortUnique(&list);
    return .{ .start = start, .candidates = list.items };
}

fn completeFile(sh: *Shell, a: Allocator, word: []const u8, start: usize) Allocator.Error!readline.Completion {
    // The word may contain backslash escapes: undo them for lookup.
    var plain: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    while (k < word.len) : (k += 1) {
        if (word[k] == '\\' and k + 1 < word.len) k += 1;
        try plain.append(a, word[k]);
    }
    const slash = std.mem.lastIndexOfScalar(u8, plain.items, '/');
    const dirpart = if (slash) |s| plain.items[0 .. s + 1] else "";
    const base = if (slash) |s| plain.items[s + 1 ..] else plain.items;
    var lookup: []const u8 = if (dirpart.len == 0) "." else dirpart;
    if (std.mem.startsWith(u8, lookup, "~/")) {
        if (sh.getVar("HOME")) |h| lookup = try std.fmt.allocPrint(a, "{s}/{s}", .{ h, lookup[2..] });
    }
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| sh.gpa.free(n);
        names.deinit(sh.gpa);
    }
    sys.listDir(sh.gpa, lookup, &names) catch return .{ .start = start };
    var list: std.ArrayList([]const u8) = .empty;
    for (names.items) |n| {
        if (!std.mem.startsWith(u8, n, base)) continue;
        if (n[0] == '.' and (base.len == 0 or base[0] != '.')) continue;
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ lookup, n });
        const is_dir = if (sys.stat(full, true)) |i| i.kind == .dir else |_| false;
        const rep = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ try escaped(a, dirpart), try escaped(a, n), if (is_dir) "/" else "" });
        try list.append(a, rep);
    }
    sortUnique(&list);
    return .{ .start = start, .candidates = list.items };
}

/// The `readline.CompleteFn` for a shell: `ctx` is the `*Shell`.
pub fn complete(ctx: ?*anyopaque, a: Allocator, line: []const u8, cursor: usize) Allocator.Error!readline.Completion {
    const sh: *Shell = @ptrCast(@alignCast(ctx.?));
    const start = wordStart(line, cursor);
    const word = line[start..cursor];
    if (word.len > 0 and word[0] == '$') return completeVariable(sh, a, word, start);
    if (commandPosition(line, start) and std.mem.indexOfScalar(u8, word, '/') == null and word.len > 0) return completeCommand(sh, a, word, start);
    return completeFile(sh, a, word, start);
}

test "word start" {
    try std.testing.expectEqual(@as(usize, 5), wordStart("echo abc", 8));
    try std.testing.expectEqual(@as(usize, 0), wordStart("ec", 2));
}
