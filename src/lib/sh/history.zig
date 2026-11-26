// SPDX-License-Identifier: GPL-2.0-or-later
//! Command history (`HISTSIZE`, `HISTFILE`) and the `fc` utility.
//!
//! References: POSIX.1-2024 `fc` and the shell variables HISTFILE/HISTSIZE
//! (XCU 2.5.3). Output formats and diagnostics follow FreeBSD sh, which has
//! `fc` where dash has none: `fc -l` prints "%5d %s"; `fc -ln` the bare
//! command. A command is entered in the history after it ran, so `fc` never
//! lists itself and `-1` is the previous command.
//!
//! `history` (bash/csh) and `!` expansion are not POSIX and are not provided.

const std = @import("std");
const sys = @import("../../sys.zig");
const shell = @import("shell.zig");
const exec = @import("exec.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

pub const default_size: usize = 128;

pub const History = struct {
    gpa: Allocator,
    entries: std.ArrayList([]u8) = .empty,
    /// Number of the oldest entry (numbers never repeat).
    first: u64 = 1,
    max: usize = default_size,

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.gpa.free(e);
        self.entries.deinit(self.gpa);
    }

    /// Number the next entry will get.
    pub fn nextNumber(self: *const History) u64 {
        return self.first + self.entries.items.len;
    }

    pub fn setMax(self: *History, n: usize) void {
        self.max = @max(n, 1);
        self.trim();
    }

    fn trim(self: *History) void {
        while (self.entries.items.len > self.max) {
            self.gpa.free(self.entries.orderedRemove(0));
            self.first += 1;
        }
    }

    /// Enter a command (trailing newlines removed; empty and blank lines are
    /// not entered; a line equal to the previous one is not repeated).
    pub fn add(self: *History, line: []const u8) Allocator.Error!void {
        const t = std.mem.trimEnd(u8, line, "\n");
        if (std.mem.trim(u8, t, " \t\n").len == 0) return;
        // like FreeBSD sh (libedit unique mode): a line equal to the newest one is not repeated
        if (self.entries.items.len > 0 and std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], t)) return;
        const copy = try self.gpa.dupe(u8, t);
        errdefer self.gpa.free(copy);
        try self.entries.append(self.gpa, copy);
        self.trim();
    }

    pub fn get(self: *const History, number: u64) ?[]const u8 {
        if (number < self.first) return null;
        const i = number - self.first;
        if (i >= self.entries.items.len) return null;
        return self.entries.items[i];
    }

    pub fn lines(self: *const History) []const []u8 {
        return self.entries.items;
    }

    /// Read a history file (one command per line; `\n` for an embedded
    /// newline, `\\` for a backslash). A missing file is not an error.
    pub fn load(self: *History, path: []const u8) void {
        const fd = sys.open(path, .{ .cloexec = true }, 0) catch return;
        defer sys.close(fd);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.gpa);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = sys.read(fd, &chunk) catch return;
            if (n == 0) break;
            data.appendSlice(self.gpa, chunk[0..n]) catch return;
        }
        var it = std.mem.splitScalar(u8, data.items, '\n');
        while (it.next()) |raw| {
            if (raw.len == 0) continue;
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(self.gpa);
            var i: usize = 0;
            while (i < raw.len) : (i += 1) {
                if (raw[i] == '\\' and i + 1 < raw.len) {
                    i += 1;
                    line.append(self.gpa, if (raw[i] == 'n') '\n' else raw[i]) catch return;
                } else line.append(self.gpa, raw[i]) catch return;
            }
            self.add(line.items) catch return;
        }
    }

    pub fn save(self: *const History, path: []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        for (self.entries.items) |e| {
            for (e) |c| switch (c) {
                '\n' => out.appendSlice(self.gpa, "\\n") catch return,
                '\\' => out.appendSlice(self.gpa, "\\\\") catch return,
                else => out.append(self.gpa, c) catch return,
            };
            out.append(self.gpa, '\n') catch return;
        }
        const fd = sys.open(path, .{ .read = false, .write = true, .create = true, .trunc = true, .cloexec = true }, 0o600) catch return;
        defer sys.close(fd);
        sys.writeAll(fd, out.items) catch {};
    }
};

// --- fc ----------------------------------------------------------------------

const Resolve = union(enum) { num: u64, not_found, none };

/// Resolve an `fc` operand to an entry number.
fn resolveOperand(h: *const History, op: []const u8) Resolve {
    const last = h.nextNumber() -| 1;
    if (std.fmt.parseInt(i64, op, 10)) |n| {
        if (n > 0) return .{ .num = @intCast(n) };
        const back: u64 = @intCast(-n);
        if (back == 0) return .{ .num = last };
        if (back > h.entries.items.len) return .{ .num = h.first };
        return .{ .num = last + 1 - back };
    } else |_| {}
    var i = h.entries.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.startsWith(u8, h.entries.items[i], op)) return .{ .num = h.first + i };
    }
    return .not_found;
}

fn clamp(h: *const History, n: u64) u64 {
    const last = h.nextNumber() -| 1;
    return @min(@max(n, h.first), last);
}

pub fn fcCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    const hreal = sh.history orelse {
        sh.diagCmdK(.history_error, null, "fc", "history not active", .{});
        return 1;
    };
    // The command line that runs `fc` is already the newest entry: hide it.
    var hview = hreal.*;
    if (sh.hist_pending and hview.entries.items.len > 0) hview.entries.items.len -= 1;
    const h = &hview;
    var list = false;
    var no_num = false;
    var rev = false;
    var subst = false;
    var editor: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        // A negative number is an operand, not an option.
        if (std.ascii.isDigit(arg[1])) break;
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            switch (arg[j]) {
                'l' => list = true,
                'n' => no_num = true,
                'r' => rev = true,
                's' => subst = true,
                'e' => {
                    if (j + 1 < arg.len) {
                        editor = arg[j + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            sh.diagCmdK(.usage, null, "fc", "option requires an argument -- e", .{});
                            return 2;
                        }
                        editor = args[i];
                    }
                    j = arg.len;
                },
                else => {
                    sh.diagCmdK(.illegal_option, &[_]u8{ '-', arg[j] }, "fc", "Illegal option -{c}", .{arg[j]});
                    return 2;
                },
            }
        }
    }
    if (editor) |e| if (std.mem.eql(u8, e, "-")) {
        subst = true;
        editor = null;
    };
    const ops = args[i..];
    if (h.entries.items.len == 0) {
        if (list) return 0;
        sh.diagCmdK(.history_error, null, "fc", "history is empty", .{});
        return 1;
    }

    if (subst) {
        var old: ?[]const u8 = null;
        var new: []const u8 = "";
        var k: usize = 0;
        if (k < ops.len) if (std.mem.indexOfScalar(u8, ops[k], '=')) |eq| {
            old = ops[k][0..eq];
            new = ops[k][eq + 1 ..];
            k += 1;
        };
        var num: u64 = h.nextNumber() - 1;
        if (k < ops.len) switch (resolveOperand(h, ops[k])) {
            .num => |n| num = clamp(h, n),
            else => {
                sh.diagCmdK(.history_error, null, "fc", "history pattern not found: {s}", .{ops[k]});
                return 1;
            },
        };
        var text: []const u8 = h.get(num) orelse return 1;
        if (old) |o| if (o.len > 0) {
            if (std.mem.indexOf(u8, text, o)) |at| {
                text = std.mem.concat(a, u8, &.{ text[0..at], new, text[at + o.len ..] }) catch |oe| return sh.oom(oe);
            }
        };
        return runText(sh, a, text, true);
    }

    // Selection for -l and editing.
    const last_num = h.nextNumber() - 1;
    var first_n: u64 = if (list) (if (last_num >= h.first + 15) last_num - 15 else h.first) else last_num;
    var last_n: u64 = last_num;
    if (ops.len > 2) {
        sh.diagCmdK(.usage, null, "fc", "too many arguments", .{});
        return 2;
    }
    if (ops.len >= 1) switch (resolveOperand(h, ops[0])) {
        .num => |n| {
            first_n = clamp(h, n);
            if (ops.len < 2) last_n = if (list) last_num else first_n;
        },
        else => {
            sh.diagCmdK(.history_error, null, "fc", "history pattern not found: {s}", .{ops[0]});
            return 1;
        },
    };
    if (ops.len == 2) switch (resolveOperand(h, ops[1])) {
        .num => |n| last_n = clamp(h, n),
        else => {
            sh.diagCmdK(.history_error, null, "fc", "history pattern not found: {s}", .{ops[1]});
            return 1;
        },
    };
    var reverse = rev;
    if (first_n > last_n) {
        std.mem.swap(u64, &first_n, &last_n);
        reverse = !reverse;
    }

    if (list) {
        var out: std.ArrayList(u8) = .empty;
        var n = first_n;
        while (n <= last_n) : (n += 1) {
            const num = if (reverse) last_n - (n - first_n) else n;
            const t = h.get(num) orelse continue;
            if (no_num) {} else out.print(a, "{d: >5} ", .{num}) catch |oe| return sh.oom(oe);
            out.appendSlice(a, t) catch |oe| return sh.oom(oe);
            out.append(a, '\n') catch |oe| return sh.oom(oe);
        }
        _ = sh.out(out.items);
        return 0;
    }

    // Edit: write the commands to a temporary file, run the editor, then run
    // what is in the file.
    var body: std.ArrayList(u8) = .empty;
    var n = first_n;
    while (n <= last_n) : (n += 1) {
        const num = if (reverse) last_n - (n - first_n) else n;
        const t = h.get(num) orelse continue;
        body.appendSlice(a, t) catch |oe| return sh.oom(oe);
        body.append(a, '\n') catch |oe| return sh.oom(oe);
    }
    const ed = editor orelse sh.getVar("FCEDIT") orelse "ed";
    const tmpdir = sh.getVar("TMPDIR") orelse "/tmp";
    const path = std.fmt.allocPrint(a, "{s}/sh-fc.{d}", .{ tmpdir, sys.getpid() }) catch |oe| return sh.oom(oe);
    const fd = sys.open(path, .{ .read = false, .write = true, .create = true, .trunc = true, .cloexec = true }, 0o600) catch {
        sh.diagCmdK(.cannot_create, path, "fc", "cannot create {s}", .{path});
        return 1;
    };
    sys.writeAll(fd, body.items) catch {};
    sys.close(fd);
    defer {
        var buf: [4097]u8 = undefined;
        if (path.len < 4096) {
            @memcpy(buf[0..path.len], path);
            buf[path.len] = 0;
            _ = std.os.linux.unlink(@ptrCast(&buf));
        }
    }
    const cmd = std.fmt.allocPrint(a, "{s} '{s}'", .{ ed, path }) catch |oe| return sh.oom(oe);
    const st = exec.runSource(sh, cmd, .{}) catch |oe| return sh.oom(oe);
    if (st != 0) return st;
    const rfd = sys.open(path, .{ .cloexec = true }, 0) catch return 1;
    defer sys.close(rfd);
    var data: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const k = sys.read(rfd, &chunk) catch break;
        if (k == 0) break;
        data.appendSlice(a, chunk[0..k]) catch |oe| return sh.oom(oe);
    }
    return runText(sh, a, data.items, false);
}

/// Run the commands (echoed to standard error for `-s`, as FreeBSD sh does)  as the shell's input,
/// entering them in the history.
fn runText(sh: *Shell, a: Allocator, text: []const u8, echo: bool) u8 {
    const h = sh.history.?;
    // `text` may be a history entry, which adding to the history (here, or by
    // the command being run) can free
    const t = a.dupe(u8, std.mem.trimEnd(u8, text, "\n")) catch |oe| return sh.oom(oe);
    if (echo) {
        sh.errRaw(t);
        sh.errRaw("\n");
    }
    h.add(t) catch {};
    return exec.runSource(sh, t, .{}) catch 2;
}

test "history numbering and limit" {
    var h = History.init(std.testing.allocator);
    defer h.deinit();
    h.setMax(3);
    for ([_][]const u8{ "a", "b", "c", "d" }) |l| try h.add(l);
    try std.testing.expectEqual(@as(u64, 2), h.first);
    try std.testing.expectEqualStrings("d", h.get(4).?);
    try std.testing.expect(h.get(1) == null);
    try h.add("d");
    try std.testing.expectEqual(@as(usize, 3), h.entries.items.len);
}
