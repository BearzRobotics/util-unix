// SPDX-License-Identifier: GPL-2.0-or-later
//! read. Part of builtins.zig.

const std = @import("std");
const sys = @import("../../../sys.zig");
const osio = @import("../osio.zig");
const lexer = @import("../lexer.zig");
const exec = @import("../exec.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");
const optText = @import("common.zig").optText;

pub fn readCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var raw = false;
    var delim: u8 = '\n';
    var i: usize = 1;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        var j: usize = 1;
        while (j < args[i].len) : (j += 1) switch (args[i][j]) {
            'r' => raw = true,
            'd' => {
                // POSIX 2024: the line ends at this byte (a NUL if empty)
                var arg = args[i][j + 1 ..];
                if (arg.len == 0) {
                    if (i + 1 >= args.len) {
                        sh.diagCmdK(.usage, null, "read", "No arg for -d option", .{});
                        return 2;
                    }
                    i += 1;
                    arg = args[i];
                }
                delim = if (arg.len > 0) arg[0] else 0;
                break;
            },
            'p' => {
                // `read -p prompt` is not POSIX; dash and FreeBSD sh accept it and
                // write the prompt to standard error when reading a terminal.
                // It is the rest of this word, or the next one.
                var prompt = args[i][j + 1 ..];
                if (prompt.len == 0) {
                    if (i + 1 >= args.len) {
                        sh.diagCmdK(.usage, null, "read", "No arg for -p option", .{});
                        return 2;
                    }
                    i += 1;
                    prompt = args[i];
                }
                if (osio.isatty(sh.env.io, 0)) sh.errRaw(prompt);
                break;
            },
            else => |c| {
                sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "read", "Illegal option -{c}", .{c});
                return 2;
            },
        };
    }
    const names = args[i..];
    if (names.len == 0) {
        sh.diagCmdK(.usage, null, "read", "arg count", .{});
        return 2;
    }
    var bytes: std.ArrayList(u8) = .empty;
    var esc: std.ArrayList(bool) = .empty;
    var got_eof = false;

    var escaped = false;
    while (true) {
        var ch: [1]u8 = undefined;
        const n = sys.read(0, &ch) catch {
            if (sys.errno() == sys.E_INTR) {
                exec.checkTraps(sh);
                if (sh.flow != .none) return sh.status; // the trap left the shell (exit, return)
                continue;
            }
            return 1;
        };
        if (n == 0) {
            got_eof = true;
            break;
        }

        const c = ch[0];
        // as in script text and $(...): what a program gets would stop there
        if (c == 0 and delim != 0) continue;
        if (escaped) {
            escaped = false;
            if (c == '\n') continue;
            bytes.append(a, c) catch |oe| return sh.oom(oe);
            esc.append(a, true) catch |oe| return sh.oom(oe);
            continue;
        }
        if (c == '\\' and !raw) {
            escaped = true;
            continue;
        }
        if (c == delim) break;
        bytes.append(a, c) catch |oe| return sh.oom(oe);
        esc.append(a, false) catch |oe| return sh.oom(oe);
    }
    // a copy: IFS may be one of the names being read
    const ifs: []const u8 = a.dupe(u8, sh.getVar("IFS") orelse " \t\n") catch |oe| return sh.oom(oe);
    const isIfs = struct {
        fn f(s: []const u8, c: u8) bool {
            return std.mem.indexOfScalar(u8, s, c) != null;
        }
    }.f;
    const isWs = struct {
        fn f(s: []const u8, c: u8) bool {
            return (c == ' ' or c == '\t' or c == '\n') and std.mem.indexOfScalar(u8, s, c) != null;
        }
    }.f;
    const b = bytes.items;
    var pos: usize = 0;
    for (names, 0..) |name, idx| {
        if (!lexer.isName(name)) {
            sh.diagCmdK(.bad_variable_name, name, "read", "{s}: bad variable name", .{name});
            return 2;
        }
        while (pos < b.len and !esc.items[pos] and isWs(ifs, b[pos])) pos += 1;
        var val: std.ArrayList(u8) = .empty;
        if (idx + 1 == names.len) {
            val.appendSlice(a, b[pos..]) catch |oe| return sh.oom(oe);
            // trim trailing IFS whitespace
            while (val.items.len > 0) {
                const li = pos + val.items.len - 1;
                if (!esc.items[li] and isWs(ifs, b[li])) _ = val.pop() else break;
            }
            // a single trailing non-whitespace delimiter ends the last field too
            // (POSIX 2.6.5: "A-B-" with two names gives "B"); not when the
            // remainder holds another such delimiter ("C-D -")
            if (val.items.len > 0) {
                const li = pos + val.items.len - 1;
                if (!esc.items[li] and isIfs(ifs, b[li]) and !isWs(ifs, b[li])) {
                    // only when what precedes is one field: any delimiter in
                    // it, white space included, means there are several
                    var before = val.items.len - 1;
                    while (before > 0 and !esc.items[pos + before - 1] and isWs(ifs, b[pos + before - 1])) before -= 1;
                    var other = false;
                    for (val.items[0..before], 0..) |ch, k| if (!esc.items[pos + k] and isIfs(ifs, ch)) {
                        other = true;
                    };
                    if (!other) {
                        _ = val.pop();
                        while (val.items.len > 0) {
                            const lj = pos + val.items.len - 1;
                            if (!esc.items[lj] and isWs(ifs, b[lj])) _ = val.pop() else break;
                        }
                    }
                }
            }
            pos = b.len;
        } else {
            while (pos < b.len and (esc.items[pos] or !isIfs(ifs, b[pos]))) : (pos += 1) val.append(a, b[pos]) catch |oe| return sh.oom(oe);
            // consume the delimiter
            while (pos < b.len and !esc.items[pos] and isWs(ifs, b[pos])) pos += 1;
            if (pos < b.len and !esc.items[pos] and isIfs(ifs, b[pos]) and !isWs(ifs, b[pos])) {
                pos += 1;
                while (pos < b.len and !esc.items[pos] and isWs(ifs, b[pos])) pos += 1;
            }
        }
        sh.setVar(name, val.items) catch |e| switch (e) {
            error.ReadOnly => {
                sh.diagCmdK(.readonly_assignment, name, "read", "{s}: is read only", .{name});
                return 2;
            },
            error.OutOfMemory => return sh.oom(error.OutOfMemory),
        };
    }
    if (got_eof) return 1;
    return 0;
}
