// SPDX-License-Identifier: GPL-2.0-or-later
//! Tab completion for the interactive shell: the `readline.CompleteFn` the
//! shell installs. The editor does not touch the file system; this module
//! does, through `sys.zig`, on behalf of the shell.
//!
//! The word under the cursor is completed as
//!   - a variable name when it starts with `$` (or `${`),
//!   - a command (builtins, functions, aliases, executables in `$PATH`) when
//!     it is the first word of a simple command and has no `/`,
//!   - a file name otherwise (directories get a trailing `/`).
//!
//! The completion is written in the quoting the word is in at the cursor:
//! inside '...', "..." or $'...', else with backslashes. A leading `~/`,
//! `~user/` or `$NAME/` stays as typed. A name with a control character in it
//! is always written as $'...': a backslash does not quote a newline.

const std = @import("std");
const sys = @import("../../sys.zig");
const shell = @import("shell.zig");
const builtins = @import("builtins.zig");
const expand = @import("expand.zig");
const readline = @import("readline.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

fn isDelim(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '|' or c == '&' or c == '(' or c == ')' or c == '<' or c == '>';
}

const Quote = enum { none, single, double, dollar };

/// Reads shell text for its quoting, one character at a time.
const Scan = struct {
    text: []const u8,
    i: usize = 0,
    quote: Quote = .none,

    const Step = union(enum) {
        /// an unquoted blank or operator character
        delim,
        /// a quote opened or closed, or a backslash with nothing after it
        mark,
        /// one character of the word, as it stands after quote removal
        char: u8,
    };

    fn next(self: *Scan) ?Step {
        if (self.i >= self.text.len) return null;
        const c = self.text[self.i];
        self.i += 1;
        const after: ?u8 = if (self.i < self.text.len) self.text[self.i] else null;
        switch (self.quote) {
            .none => {
                if (isDelim(c)) return .delim;
                if (c == '\\') {
                    const e = after orelse return .mark;
                    self.i += 1;
                    return .{ .char = e };
                }
                if (c == '$' and after == '\'') {
                    self.i += 1;
                    self.quote = .dollar;
                    return .mark;
                }
                if (c == '\'') {
                    self.quote = .single;
                    return .mark;
                }
                if (c == '"') {
                    self.quote = .double;
                    return .mark;
                }
            },
            .single => if (c == '\'') {
                self.quote = .none;
                return .mark;
            },
            .double => {
                if (c == '"') {
                    self.quote = .none;
                    return .mark;
                }
                if (c == '\\') if (after) |e| if (e == '$' or e == '`' or e == '"' or e == '\\') {
                    self.i += 1;
                    return .{ .char = e };
                };
            },
            .dollar => {
                if (c == '\'') {
                    self.quote = .none;
                    return .mark;
                }
                if (c == '\\') {
                    const e = after orelse return .mark;
                    self.i += 1;
                    // the three-digit octal form is what `quoted` writes
                    if (e >= '0' and e <= '7') {
                        var v: u8 = e - '0';
                        var n: usize = 1;
                        while (n < 3 and self.i < self.text.len and self.text[self.i] >= '0' and self.text[self.i] <= '7') : (n += 1) {
                            v = v *% 8 +% (self.text[self.i] - '0');
                            self.i += 1;
                        }
                        return .{ .char = v };
                    }
                    return .{ .char = switch (e) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        else => e,
                    } };
                }
            },
        }
        return .{ .char = c };
    }
};

/// Start of the word that ends at `cursor`: quoted and escaped blanks belong to it.
pub fn wordStart(line: []const u8, cursor: usize) usize {
    var sc: Scan = .{ .text = line[0..cursor] };
    var start: usize = 0;
    while (sc.next()) |step| if (step == .delim) {
        start = sc.i;
    };
    return start;
}

/// How much of `prefix`, the common beginning of some completions, may be put
/// on the line: not a part that ends in the middle of an escape, which would
/// change what is typed next.
pub fn wholePrefix(prefix: []const u8) usize {
    var sc: Scan = .{ .text = prefix };
    while (sc.i < prefix.len) {
        const at = sc.i;
        const quote = sc.quote;
        _ = sc.next();
        if (prefix[at] != '\\') continue;
        const used = sc.i - at;
        // nothing after the backslash
        if (used == 1 and (quote == .none or quote == .dollar)) return at;
        // an octal escape cut short
        if (quote == .dollar and sc.i == prefix.len and used > 1 and used < 4 and prefix[at + 1] >= '0' and prefix[at + 1] <= '7') return at;
    }
    return prefix.len;
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

fn hasControl(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

/// The part of a word being completed that stays as it was typed.
const Kept = struct {
    /// as typed
    raw: []const u8 = "",
    /// the directory it names, for looking files up
    dir: []const u8 = "",
    /// the quoting at its end
    quote: Quote = .none,
};

/// A leading `~/`, `~user/`, `$NAME/` or `${NAME}/`, the last two also inside "...".
fn keptPrefix(sh: *Shell, a: Allocator, word: []const u8) Allocator.Error!Kept {
    const slash = std.mem.indexOfScalar(u8, word, '/') orelse return .{};
    const head = word[0..slash];
    if (head.len > 0 and head[0] == '~') {
        const user = head[1..];
        if (std.mem.indexOfAny(u8, user, "\\'\"$`") != null) return .{};
        const home = (if (user.len == 0) sh.getVar("HOME") else expand.homeOf(sh, a, user)) orelse return .{};
        return .{ .raw = word[0 .. slash + 1], .dir = try std.fmt.allocPrint(a, "{s}/", .{home}) };
    }
    const quote: Quote = if (head.len > 0 and head[0] == '"') .double else .none;
    var name = head[if (quote == .double) 1 else 0..];
    if (name.len < 2 or name[0] != '$') return .{};
    name = name[1..];
    if (name.len > 2 and name[0] == '{' and name[name.len - 1] == '}') name = name[1 .. name.len - 1];
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return .{};
    const value = sh.getVar(name) orelse return .{};
    return .{ .raw = word[0 .. slash + 1], .dir = try std.fmt.allocPrint(a, "{s}/", .{value}), .quote = quote };
}

/// `kept` followed by `text` (the rest of the word, unquoted) in quoting
/// `quote`. A directory is left open for what goes in it.
fn quoted(a: Allocator, kept: Kept, text: []const u8, quote: Quote, is_dir: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, kept.raw);
    const style: Quote = if (hasControl(text)) .dollar else quote;
    var open = kept.quote;
    if (open != .none and open != style) {
        try out.append(a, '"');
        open = .none;
    }
    if (open == .none) try out.appendSlice(a, switch (style) {
        .none => "",
        .single => "'",
        .double => "\"",
        .dollar => "$'",
    });
    for (text, 0..) |c, i| switch (style) {
        .none => {
            // `~` and `#` are special only at the start of a word
            if (needsEscape(c) and !((c == '~' or c == '#') and (i > 0 or kept.raw.len > 0))) try out.append(a, '\\');
            try out.append(a, c);
        },
        .single => if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c),
        .double => {
            if (c == '$' or c == '`' or c == '"' or c == '\\') try out.append(a, '\\');
            try out.append(a, c);
        },
        .dollar => switch (c) {
            '\n' => try out.appendSlice(a, "\\n"),
            '\t' => try out.appendSlice(a, "\\t"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\\', '\'' => try out.appendSlice(a, &.{ '\\', c }),
            else => if (c < 0x20 or c == 0x7f) try out.print(a, "\\{o:0>3}", .{c}) else try out.append(a, c),
        },
    };
    const close: []const u8 = switch (style) {
        .none => "",
        .single, .dollar => "'",
        .double => "\"",
    };
    // a $'...' is closed even for a directory: more is typed outside it
    if (!is_dir or style == .dollar) try out.appendSlice(a, close);
    if (is_dir) try out.append(a, '/');
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

fn completeCommand(sh: *Shell, a: Allocator, word: []const u8, quote: Quote, start: usize) Allocator.Error!readline.Completion {
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
            try list.append(a, try a.dupe(u8, n));
        }
    }
    sortUnique(&list);
    for (list.items) |*n| n.* = try quoted(a, .{}, n.*, quote, false);
    return .{ .start = start, .candidates = list.items };
}

/// `typed` is the word after `kept`, unquoted.
fn completeFile(sh: *Shell, a: Allocator, kept: Kept, typed: []const u8, quote: Quote, start: usize) Allocator.Error!readline.Completion {
    const slash = std.mem.lastIndexOfScalar(u8, typed, '/');
    const dirpart = if (slash) |s| typed[0 .. s + 1] else "";
    const base = if (slash) |s| typed[s + 1 ..] else typed;
    var lookup: []const u8 = try std.mem.concat(a, u8, &.{ kept.dir, dirpart });
    if (lookup.len == 0) lookup = ".";
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
        try list.append(a, try quoted(a, kept, try std.mem.concat(a, u8, &.{ dirpart, n }), quote, is_dir));
    }
    sortUnique(&list);
    return .{ .start = start, .candidates = list.items };
}

/// The `readline.CompleteFn` for a shell: `ctx` is the `*Shell`.
pub fn complete(ctx: ?*anyopaque, a: Allocator, line: []const u8, cursor: usize) Allocator.Error!readline.Completion {
    const sh: *Shell = @ptrCast(@alignCast(ctx.?));
    const start = wordStart(line, cursor);
    const word = line[start..cursor];
    if (isVariableName(word)) return completeVariable(sh, a, word, start);
    const kept = try keptPrefix(sh, a, word);
    // the quoting at the cursor, and the rest of the word without it
    var sc: Scan = .{ .text = word, .i = kept.raw.len, .quote = kept.quote };
    var typed: std.ArrayList(u8) = .empty;
    while (sc.next()) |step| switch (step) {
        .char => |c| try typed.append(a, c),
        else => {},
    };
    if (kept.raw.len == 0 and commandPosition(line, start) and std.mem.indexOfScalar(u8, typed.items, '/') == null and typed.items.len > 0) {
        return completeCommand(sh, a, typed.items, sc.quote, start);
    }
    return completeFile(sh, a, kept, typed.items, sc.quote, start);
}

/// `$`, `${` or either with the start of a name: not the start of a path.
fn isVariableName(word: []const u8) bool {
    if (word.len == 0 or word[0] != '$') return false;
    const from: usize = if (std.mem.startsWith(u8, word, "${")) 2 else 1;
    for (word[from..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

test "word start" {
    try std.testing.expectEqual(@as(usize, 5), wordStart("echo abc", 8));
    try std.testing.expectEqual(@as(usize, 0), wordStart("ec", 2));
    try std.testing.expectEqual(@as(usize, 3), wordStart("ls 'my fil", 10));
    try std.testing.expectEqual(@as(usize, 3), wordStart("ls \"a \\\" b", 9));
    try std.testing.expectEqual(@as(usize, 3), wordStart("ls a\\ b", 7));
}

test "a common prefix does not end inside an escape" {
    try std.testing.expectEqual(@as(usize, 1), wholePrefix("a\\"));
    try std.testing.expectEqual(@as(usize, 3), wholePrefix("a\\\\"));
    // a backslash is only itself between single quotes
    try std.testing.expectEqual(@as(usize, 3), wholePrefix("'a\\"));
    try std.testing.expectEqual(@as(usize, 3), wholePrefix("$'a\\00"));
    try std.testing.expectEqual(@as(usize, 7), wholePrefix("$'a\\001"));
}
