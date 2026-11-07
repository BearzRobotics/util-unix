// SPDX-License-Identifier: GPL-2.0-or-later
//! stty: thin wrapper over `util_unix.stty`.
//!
//! References: GNU coreutils 9.7 "stty invocation"; POSIX.1-2024 stty. Exit
//! status 0 on success, 1 on any error (usage and system errors alike).
//!
//! Deviations: the terminal device named with -F is opened blocking (GNU opens
//! it with O_NONBLOCK), so a modem line that is waiting for carrier blocks the
//! open. See docs/compatibility/stty.md.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const st = uu.stty;
const cli = @import("../cli.zig");

const Style = enum { changed, all, save };

const long_names = [_][]const u8{ "all", "save", "file", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var style: Style = .changed;
    var seen_all = false;
    var seen_save = false;
    var device: ?[]const u8 = null;
    var settings = std.ArrayList([]const u8).empty;
    defer settings.deinit(ctx.gpa);

    var i: usize = 0;
    var past_options = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (past_options or a.len < 2 or a[0] != '-') {
            settings.append(ctx.gpa, a) catch return 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            past_options = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    settings.append(ctx.gpa, a) catch return 1;
                    continue;
                },
            };
            switch (k) {
                0 => seen_all = true,
                1 => seen_save = true,
                2 => {
                    if (eq) |e| {
                        device = a[e + 1 ..];
                    } else if (i + 1 < ctx.args.len) {
                        i += 1;
                        device = ctx.args[i];
                    } else {
                        settings.append(ctx.gpa, a) catch return 1;
                    }
                },
                3 => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        // A cluster of -a, -g and -F[DEVICE] is options; anything else (-echo,
        // -icanon) is a negated setting.
        var valid = true;
        for (a[1..], 1..) |c, pos| {
            if (c == 'F') break;
            if (c != 'a' and c != 'g') valid = false;
            _ = pos;
        }
        if (valid) {
            if (std.mem.indexOfScalar(u8, a, 'F')) |f| {
                if (f + 1 >= a.len and i + 1 >= ctx.args.len) valid = false;
            }
        }
        if (!valid) {
            settings.append(ctx.gpa, a) catch return 1;
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            switch (a[j]) {
                'a' => seen_all = true,
                'g' => seen_save = true,
                else => { // 'F': the rest of the argument, or the next one
                    if (j + 1 < a.len) {
                        device = a[j + 1 ..];
                    } else {
                        i += 1;
                        device = ctx.args[i];
                    }
                    j = a.len;
                },
            }
        }
    }

    // "drain" and "-drain" are accepted and change nothing; they do not count
    // as settings.
    {
        var kept: usize = 0;
        for (settings.items) |item| {
            if (std.mem.eql(u8, item, "drain") or std.mem.eql(u8, item, "-drain")) continue;
            settings.items[kept] = item;
            kept += 1;
        }
        settings.shrinkRetainingCapacity(kept);
    }

    if (seen_all and seen_save) {
        cli.warn(ctx, "the options for verbose and stty-readable output styles are\nmutually exclusive", .{});
        return 1;
    }
    if (seen_all) style = .all;
    if (seen_save) style = .save;
    if (style != .changed and settings.items.len > 0) {
        cli.warn(ctx, "when specifying an output style, modes may not be set", .{});
        return 1;
    }

    // Every setting is checked before the terminal is touched, as GNU does:
    // a bad argument is reported even without a terminal, and nothing is
    // printed or changed when one is bad.
    var ops = std.ArrayList(Op).empty;
    defer ops.deinit(ctx.gpa);
    if (!parseSettings(ctx, settings.items, &ops)) return 1;

    const name: []const u8 = device orelse "standard input";
    var file: ?Io.File = null;
    defer if (file) |f| f.close(ctx.io);
    if (device) |path| {
        file = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |e| {
            cli.warn(ctx, "{f}: {s}", .{ cli.quotef(path), cli.errText(e) });
            return 1;
        };
    }
    const fd: i32 = if (file) |f| f.handle else Io.File.stdin().handle;

    var term = st.getTermios(fd) catch |e| return deviceError(ctx, name, e);

    var obuf: [2048]u8 = undefined;
    var ow = Io.File.stdout().writerStreaming(ctx.io, &obuf);
    const out = &ow.interface;
    defer out.flush() catch {};

    switch (style) {
        .all => {
            const ws: ?st.WinSize = st.getWinSize(fd) catch null;
            st.writeAll(out, term, ws, screenColumns(ctx)) catch return 1;
            return finish(out);
        },
        .save => {
            st.writeSave(out, term) catch return 1;
            return finish(out);
        },
        .changed => {},
    }

    if (ops.items.len == 0) {
        st.writeChanged(out, term, screenColumns(ctx)) catch return 1;
        return finish(out);
    }

    var need_set = false;
    var new_rows: ?u16 = null;
    var new_cols: ?u16 = null;
    for (ops.items) |op| switch (op) {
        .mode => |m| {
            st.applyMode(&term, m.mode.*, m.reversed);
            need_set = true;
        },
        .char => |c| {
            term.cc[c.index] = c.value;
            need_set = true;
        },
        .ispeed => |code| {
            st.setInputSpeed(&term, code);
            need_set = true;
        },
        .ospeed => |code| {
            st.setOutputSpeed(&term, code);
            need_set = true;
        },
        .baud => |code| {
            st.setSpeed(&term, code);
            need_set = true;
        },
        .line => |n| {
            term.line = n;
            need_set = true;
        },
        .min => |n| {
            term.cc[st.min_index] = n;
            need_set = true;
        },
        .time => |n| {
            term.cc[st.time_index] = n;
            need_set = true;
        },
        .noop => {},
        .rows => |n| new_rows = n,
        .cols => |n| new_cols = n,
        .restore => |text| {
            term = st.parseSave(term, text).?;
            need_set = true;
        },
        .size => {
            const ws = st.getWinSize(fd) catch |e| return deviceError(ctx, name, e);
            out.print("{d} {d}\n", .{ ws.rows, ws.cols }) catch return 1;
        },
        .speed => {
            const i_speed = st.inputSpeed(term);
            const o_speed = st.outputSpeed(term);
            if (i_speed == o_speed) {
                out.print("{d}\n", .{o_speed}) catch return 1;
            } else out.print("{d} {d}\n", .{ i_speed, o_speed }) catch return 1;
        },
    };

    if (new_rows != null or new_cols != null) {
        var ws = st.getWinSize(fd) catch |e| return deviceError(ctx, name, e);
        if (new_rows) |r| ws.rows = r;
        if (new_cols) |c| ws.cols = c;
        st.setWinSize(fd, &ws) catch |e| return deviceError(ctx, name, e);
    }

    if (need_set) {
        st.setTermios(fd, &term, .drain) catch |e| return deviceError(ctx, name, e);
        const got = st.getTermios(fd) catch |e| return deviceError(ctx, name, e);
        if (!st.sameSettings(term, got)) {
            cli.warn(ctx, "{f}: unable to perform all requested operations", .{cli.quotef(name)});
            return 1;
        }
    }
    return finish(out);
}

/// One validated setting.
const Op = union(enum) {
    mode: struct { mode: *const st.Mode, reversed: bool },
    char: struct { index: u8, value: u8 },
    ispeed: u32,
    ospeed: u32,
    baud: u32,
    line: u8,
    min: u8,
    time: u8,
    rows: u16,
    cols: u16,
    restore: []const u8,
    size,
    speed,
    /// An argument that was reported and ignored.
    noop,
};

/// Turn the setting arguments into operations; false (after a diagnostic) when
/// one is invalid.
fn parseSettings(ctx: cli.Context, items: []const []const u8, ops: *std.ArrayList(Op)) bool {
    const eql = std.mem.eql;
    var k: usize = 0;
    while (k < items.len) : (k += 1) {
        const raw = items[k];
        var arg = raw;
        var reversed = false;
        if (arg.len > 0 and arg[0] == '-') {
            reversed = true;
            arg = arg[1..];
        }
        const op: Op = op: {
            if (st.findMode(arg)) |m| {
                if (!reversed or m.rev) break :op .{ .mode = .{ .mode = m, .reversed = reversed } };
                return invalidArgument(ctx, raw);
            }
            if (reversed) return invalidArgument(ctx, raw);
            if (st.findControlChar(arg)) |c| {
                if (k + 1 >= items.len) return missingArgument(ctx, arg);
                k += 1;
                const v = st.parseControlChar(items[k]) catch |e| return badInteger(ctx, items[k], e);
                break :op .{ .char = .{ .index = c.index, .value = v } };
            }
            if (eql(u8, arg, "ispeed") or eql(u8, arg, "ospeed")) {
                if (k + 1 >= items.len) return missingArgument(ctx, arg);
                k += 1;
                const code = st.speedCode(items[k]) orelse {
                    cli.warn(ctx, "invalid {s} {f}\nTry '{s} --help' for more information.", .{ arg, cli.quoteC(items[k]), ctx.name });
                    return false;
                };
                break :op if (eql(u8, arg, "ispeed")) .{ .ispeed = code } else .{ .ospeed = code };
            }
            if (eql(u8, arg, "line")) {
                if (k + 1 >= items.len) return missingArgument(ctx, arg);
                k += 1;
                const n = st.parseUnsigned(items[k]) catch |e| switch (e) {
                    error.InvalidInteger => return badInteger(ctx, items[k], e),
                    // GNU reports an out-of-range line discipline twice, keeps
                    // going and leaves the discipline alone.
                    error.OutOfRange => std.math.maxInt(u64),
                };
                if (n > 255) {
                    for (0..2) |_| cli.warn(ctx, "invalid line discipline {f}: Value too large for defined data type", .{cli.quoteC(items[k])});
                    break :op .noop;
                }
                break :op .{ .line = @intCast(n) };
            }
            if (eql(u8, arg, "min") or eql(u8, arg, "time")) {
                if (k + 1 >= items.len) return missingArgument(ctx, arg);
                k += 1;
                const n = st.parseUnsigned(items[k]) catch |e| return badInteger(ctx, items[k], e);
                if (n > 255) return badInteger(ctx, items[k], error.OutOfRange);
                break :op if (eql(u8, arg, "min")) .{ .min = @intCast(n) } else .{ .time = @intCast(n) };
            }
            if (eql(u8, arg, "rows") or eql(u8, arg, "cols") or eql(u8, arg, "columns")) {
                if (k + 1 >= items.len) return missingArgument(ctx, arg);
                k += 1;
                const n = st.parseUnsigned(items[k]) catch |e| return badInteger(ctx, items[k], e);
                // The kernel field is 16 bits wide and GNU stores the number
                // there without a range check.
                const v: u16 = @truncate(n);
                break :op if (eql(u8, arg, "rows")) .{ .rows = v } else .{ .cols = v };
            }
            if (eql(u8, arg, "size")) break :op .size;
            if (eql(u8, arg, "speed")) break :op .speed;
            if (st.looksLikeSave(arg)) break :op .{ .restore = arg };
            if (st.speedCode(arg)) |code| break :op .{ .baud = code };
            return invalidArgument(ctx, raw);
        };
        ops.append(ctx.gpa, op) catch {
            cli.warn(ctx, "out of memory", .{});
            return false;
        };
    }
    return true;
}

fn finish(out: *Io.Writer) u8 {
    out.flush() catch return 1;
    return 0;
}

/// Terminal width for wrapping: the terminal on standard output, else $COLUMNS,
/// else 80.
fn screenColumns(ctx: cli.Context) usize {
    if (st.getWinSize(Io.File.stdout().handle)) |ws| {
        if (ws.cols > 0) return ws.cols;
    } else |_| {}
    if (cli.getenv(ctx, "COLUMNS")) |text| {
        if (std.fmt.parseInt(usize, text, 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    }
    return 80;
}

fn deviceError(ctx: cli.Context, name: []const u8, e: st.IoctlError) u8 {
    const text: []const u8 = switch (e) {
        error.NotATerminal => "Inappropriate ioctl for device",
        error.AccessDenied => "Permission denied",
        error.InvalidArgument => "Invalid argument",
        error.NoDevice => "No such device or address",
        error.InputOutput => "Input/output error",
        error.Unsupported => "Operation not supported",
        error.Unexpected => "Unknown error",
    };
    cli.warn(ctx, "{f}: {s}", .{ cli.quotef(name), text });
    return 1;
}

// The diagnostics below return false: the callers are parse functions.
fn invalidArgument(ctx: cli.Context, arg: []const u8) bool {
    cli.warn(ctx, "invalid argument {f}\nTry '{s} --help' for more information.", .{ cli.quoteC(arg), ctx.name });
    return false;
}

fn missingArgument(ctx: cli.Context, arg: []const u8) bool {
    cli.warn(ctx, "missing argument to {f}\nTry '{s} --help' for more information.", .{ cli.quoteC(arg), ctx.name });
    return false;
}

fn badInteger(ctx: cli.Context, arg: []const u8, e: st.CharError) bool {
    switch (e) {
        error.InvalidInteger => cli.warn(ctx, "invalid integer argument: {f}", .{cli.quoteC(arg)}),
        error.OutOfRange => cli.warn(ctx, "invalid integer argument: {f}: Value too large for defined data type", .{cli.quoteC(arg)}),
    }
    return false;
}

const help_text = @embedFile("stty_help.txt");
