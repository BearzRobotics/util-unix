// SPDX-License-Identifier: GPL-2.0-or-later
//! times, kill, umask and ulimit. Part of builtins.zig.

const std = @import("std");
const num = @import("../../num.zig");
const sys = @import("../../../sys.zig");
const jobcmd = @import("../jobcmd.zig");
const mode_mod = @import("../../mode.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");
const optText = @import("common.zig").optText;
const parseNum = @import("common.zig").parseNum;

pub fn timesCmd(sh: *Shell, a: Allocator, _: []const []const u8) u8 {
    const t = sys.cpuTimes();
    const f = struct {
        fn fmt(al: Allocator, us: u64) []const u8 {
            const secs = us / 1_000_000;
            return std.fmt.allocPrint(al, "{d}m{d}.{d:0>6}s", .{ secs / 60, secs % 60, us % 1_000_000 }) catch "";
        }
    }.fmt;
    const text = std.fmt.allocPrint(a, "{s} {s}\n{s} {s}\n", .{ f(a, t.user), f(a, t.system), f(a, t.child_user), f(a, t.child_system) }) catch |oe| return sh.oom(oe);
    _ = sh.out(text);
    return 0;
}

pub fn killCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var sig: u8 = 15;
    if (i < args.len and std.mem.eql(u8, args[i], "-l")) {
        var out: std.ArrayList(u8) = .empty;
        if (i + 1 < args.len) {
            // `kill -l N`: a signal number or the exit status of a process
            // killed by it (128+N); 0, 128 and anything else is an error
            // (dash and FreeBSD sh).
            const n = parseNum(args[i + 1]) orelse {
                sh.diagCmdK(.kill_error, null, "kill", "invalid signal number or exit status: {s}", .{args[i + 1]});
                return 2;
            };
            const s: i64 = if (n > 128) n - 128 else n;
            if (s <= 0 or s >= sys.nsig or (s >= sys.signal_names.len and s < sys.rtmin)) {
                sh.diagCmdK(.kill_error, null, "kill", "invalid signal number or exit status: {s}", .{args[i + 1]});
                return 2;
            }
            var nb: [12]u8 = undefined;
            out.print(a, "{s}\n", .{sys.signalName(@intCast(s), &nb).?}) catch |oe| return sh.oom(oe);
        } else for (sys.signal_names[1..]) |nm| out.print(a, "{s}\n", .{nm}) catch |oe| return sh.oom(oe);
        _ = sh.out(out.items);
        return 0;
    }
    if (i < args.len and (std.mem.eql(u8, args[i], "-s") or std.mem.eql(u8, args[i], "-n"))) {
        if (i + 1 >= args.len) {
            sh.diagCmdK(.usage, null, "kill", "usage: kill [-s sigspec | -signum | -sigspec] [pid | job]... or kill -l [exitstatus]", .{});
            return 2;
        }
        sig = sys.signalNumber(args[i + 1]) orelse {
            sh.diagCmdK(.kill_error, null, "kill", "invalid signal number or name: {s}", .{args[i + 1]});
            return 2;
        };
        i += 2;
    } else if (i < args.len and args[i].len > 1 and args[i][0] == '-' and args[i][1] != '-') {
        sig = sys.signalNumber(args[i][1..]) orelse {
            sh.diagCmdK(.kill_error, null, "kill", "invalid signal number or name: {s}", .{args[i][1..]});
            return 2;
        };
        i += 1;
    }
    if (i < args.len and std.mem.eql(u8, args[i], "--")) i += 1;
    if (i >= args.len) {
        sh.diagCmdK(.usage, null, "kill", "usage: kill [-s sigspec | -signum | -sigspec] [pid | job]... or kill -l [exitstatus]", .{});
        return 2;
    }
    var st: u8 = 0;
    for (args[i..]) |p| {
        if (jobcmd.killJob(sh, p, sig)) |r| {
            if (r != 0) st = r;
            continue;
        }
        const pid = parseNum(p) orelse {
            sh.diagCmdK(.kill_error, null, "kill", "invalid pid {s}", .{p});
            st = 2;
            continue;
        };
        // a cut-down number could name another process, or -1, all of them
        const target = std.math.cast(i32, pid) orelse {
            sh.diagCmdK(.kill_error, null, "kill", "invalid pid {s}", .{p});
            st = 2;
            continue;
        };
        sys.kill(target, sig) catch {
            sh.diagCmdK(.kill_error, null, "kill", "{s}", .{sys.strerror(sys.errno())});
            st = 1;
        };
    }
    return st;
}

pub fn umaskCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var symbolic = false;
    if (i < args.len and std.mem.eql(u8, args[i], "-S")) {
        symbolic = true;
        i += 1;
    }
    if (i >= args.len) {
        const m = sys.umaskGet();
        if (symbolic) {
            const f = struct {
                fn p(al: Allocator, who: u8, bits: u32) []const u8 {
                    return std.fmt.allocPrint(al, "{c}={s}{s}{s}", .{ who, if (bits & 4 == 0) "r" else "", if (bits & 2 == 0) "w" else "", if (bits & 1 == 0) "x" else "" }) catch "";
                }
            }.p;
            _ = sh.out(std.fmt.allocPrint(a, "{s},{s},{s}\n", .{ f(a, 'u', (m >> 6) & 7), f(a, 'g', (m >> 3) & 7), f(a, 'o', m & 7) }) catch |oe| return sh.oom(oe));
        } else _ = sh.out(std.fmt.allocPrint(a, "{o:0>4}\n", .{m}) catch |oe| return sh.oom(oe));
        return 0;
    }
    if (args[i].len > 1 and args[i][0] == '-' and !std.mem.eql(u8, args[i], "--")) {
        sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{args[i][1]}), "umask", "Illegal option {s}", .{args[i]});
        return 2;
    }
    if (args[i].len > 0 and !std.ascii.isDigit(args[i][0])) {
        // symbolic mode (POSIX umask): applied to the permissions the mask
        // allows, i.e. its complement
        const perm: u16 = @intCast(~sys.umaskGet() & 0o777);
        // (chmod also takes numbers after an operator; umask does not)
        const numbers = std.mem.indexOfAny(u8, args[i], "01234567") != null;
        const np = (if (numbers) null else mode_mod.apply(args[i], perm, false, 0)) orelse {
            sh.diagCmdK(.illegal_number, args[i], "umask", "Illegal mode: {s}", .{args[i]});
            return 2;
        };
        _ = sys.umaskSet(~@as(u32, np) & 0o777);
        return 0;
    }
    const m = num.parseInt(u32, args[i], 8) catch {
        sh.diagCmdK(.illegal_number, args[i], "umask", "Illegal number: {s}", .{args[i]});
        return 2;
    };
    // a numeric mask keeps only the permission bits (dash, FreeBSD sh)
    _ = sys.umaskSet(m & 0o777);
    return 0;
}

pub fn ulimitCmd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var i: usize = 1;
    var res: u32 = 1; // -f
    // -f is the default, counted in blocks of 512 bytes (POSIX)
    var scale: u64 = 512;
    var hard = false;
    var soft_set = false;
    var all = false;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        for (args[i][1..]) |c| switch (c) {
            // the last of -H and -S wins (dash, FreeBSD sh)
            'H' => {
                hard = true;
                soft_set = false;
            },
            'S' => {
                soft_set = true;
                hard = false;
            },
            'a' => all = true,
            'f' => {
                res = 1;
                scale = 512;
            },
            'c' => {
                res = 4;
                scale = 512;
            },
            'd' => {
                res = 2;
                scale = 1024;
            },
            's' => {
                res = 3;
                scale = 1024;
            },
            'n' => {
                res = 7;
                scale = 1;
            },
            't' => {
                res = 0;
                scale = 1;
            },
            'v' => {
                res = 9;
                scale = 1024;
            },
            'm' => {
                res = 5;
                scale = 1024;
            },
            else => {
                sh.diagCmdK(.illegal_option, optText(a, "-{c}", .{c}), "ulimit", "Illegal option -{c}", .{c});
                return 2;
            },
        };
    }
    if (all) {
        if (i < args.len) {
            sh.diagCmdK(.usage, null, "ulimit", "too many arguments", .{});
            return 2;
        }
        // POSIX.1-2024 `ulimit -a`: every limit this shell knows, one per line
        const Row = struct { label: []const u8, opt: u8, res: u32, scale: u64 };
        const rows = [_]Row{
            .{ .label = "time(seconds)", .opt = 't', .res = 0, .scale = 1 },
            .{ .label = "file(blocks)", .opt = 'f', .res = 1, .scale = 512 },
            .{ .label = "data(kbytes)", .opt = 'd', .res = 2, .scale = 1024 },
            .{ .label = "stack(kbytes)", .opt = 's', .res = 3, .scale = 1024 },
            .{ .label = "coredump(blocks)", .opt = 'c', .res = 4, .scale = 512 },
            .{ .label = "memory(kbytes)", .opt = 'm', .res = 5, .scale = 1024 },
            .{ .label = "nofiles(descriptors)", .opt = 'n', .res = 7, .scale = 1 },
            .{ .label = "vmemory(kbytes)", .opt = 'v', .res = 9, .scale = 1024 },
        };
        var out: std.ArrayList(u8) = .empty;
        for (rows) |row| {
            const lim = sys.getrlimit(row.res) catch continue;
            const v = if (hard) lim.hard else lim.soft;
            out.print(a, "-{c}: {s:<22}", .{ row.opt, row.label }) catch |oe| return sh.oom(oe);
            if (v == sys.infinity) out.appendSlice(a, "unlimited\n") catch |oe| return sh.oom(oe) else out.print(a, "{d}\n", .{v / row.scale}) catch |oe| return sh.oom(oe);
        }
        _ = sh.out(out.items);
        return 0;
    }
    var cur = sys.getrlimit(res) catch {
        sh.diagCmdK(.bad_limit, null, "ulimit", "error getting limit ({s})", .{sys.strerror(sys.errno())});
        return 2;
    };
    if (i >= args.len) {
        const v = if (hard) cur.hard else cur.soft;
        if (v == sys.infinity) _ = sh.out("unlimited\n") else _ = sh.out(std.fmt.allocPrint(a, "{d}\n", .{v / scale}) catch |oe| return sh.oom(oe));
        return 0;
    }
    const v: u64 = if (std.mem.eql(u8, args[i], "unlimited")) sys.infinity else blk: {
        const n = num.parseInt(u64, args[i], 10) catch {
            sh.diagCmdK(.illegal_number, args[i], "ulimit", "bad number", .{});
            return 2;
        };
        // a value that does not fit once scaled is a bad number (FreeBSD sh; dash wraps silently)
        break :blk std.math.mul(u64, n, scale) catch {
            sh.diagCmdK(.illegal_number, args[i], "ulimit", "bad number", .{});
            return 2;
        };
    };
    if (i + 1 < args.len) {
        sh.diagCmdK(.usage, null, "ulimit", "too many arguments", .{});
        return 2;
    }
    if (hard or !soft_set) cur.hard = v;
    if (!hard or soft_set) cur.soft = v;
    sys.setrlimit(res, cur) catch {
        sh.diagCmdK(.bad_limit, null, "ulimit", "error setting limit ({s})", .{sys.strerror(sys.errno())});
        return 2;
    };
    return 0;
}
