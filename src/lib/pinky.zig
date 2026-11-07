// SPDX-License-Identifier: GPL-2.0-or-later
//! pinky: a lightweight finger. Short format lists the user sessions found in a
//! utmp-format file; long format describes accounts from the passwd file and the
//! users' `.project` and `.plan` files.
//!
//! References: GNU coreutils 9.7 manual, "pinky invocation". The long format was
//! derived by running GNU pinky against synthetic passwd files and home
//! directories (test/test_pinky.sh). The short format could not be compared with
//! GNU pinky: the GNU build available for this project reads systemd-logind
//! sessions instead of the utmp file, so the row layout and the idle text are
//! reconstructed from the layout GNU printed for a real session plus the
//! documented columns, and are covered by golden tests only.
//!
//! Not supported: systemd-logind sessions, `--lookup`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const userdb = @import("userdb.zig");
const utmp = @import("utmp.zig");
const who = @import("who.zig");
const localtime = @import("localtime.zig");

pub const Options = struct {
    /// -l: long format.
    long: bool = false,
    /// -b off: Directory and Shell lines in long format.
    home_and_shell: bool = true,
    /// -h off, -p off: the .project and .plan files in long format.
    project: bool = true,
    plan: bool = true,
    /// -f off: the heading line in short format.
    heading: bool = true,
    /// -w, -i, -q off: the Name column.
    fullname: bool = true,
    /// -i, -q off: the Where column.
    where: bool = true,
    /// -q off: the Idle column.
    idle: bool = true,
    style: who.TimeStyle = .classic,
    now: i64,
};

/// The display name for a passwd gecos field: the text before the first comma,
/// with each `&` replaced by the login name starting with a capital letter.
/// Written into `buf` (truncated if it does not fit).
pub fn realName(buf: []u8, gecos: []const u8, login: []const u8) []const u8 {
    const field = gecos[0 .. std.mem.indexOfScalar(u8, gecos, ',') orelse gecos.len];
    var w: Io.Writer = .fixed(buf);
    for (field) |c| {
        if (c == '&') {
            for (login, 0..) |lc, i| w.writeByte(if (i == 0) std.ascii.toUpper(lc) else lc) catch return w.buffered();
        } else w.writeByte(c) catch return w.buffered();
    }
    return w.buffered();
}

/// Long format for one account: login line, optionally directory and shell, the
/// project and plan files, then a blank line. An unknown login gets only its
/// first line, with `???` as the name.
pub fn writeLong(io: Io, gpa: Allocator, w: *Io.Writer, db: *const userdb.Db, login: []const u8, o: Options) !void {
    var name_buf: [512]u8 = undefined;
    const pw = db.userByName(login) orelse {
        try w.print("Login name: {s:<28}In real life:  ???\n", .{login});
        return;
    };
    try w.print("Login name: {s:<28}In real life:  {s}\n", .{ pw.name, realName(&name_buf, pw.gecos, pw.name) });
    if (o.home_and_shell) try w.print("Directory: {s:<29}Shell:  {s}\n", .{ pw.dir, pw.shell });
    if (o.project) {
        if (try readHomeFile(io, gpa, pw.dir, ".project")) |text| {
            defer gpa.free(text);
            try w.writeAll("Project: ");
            try w.writeAll(text);
        }
    }
    if (o.plan) {
        if (try readHomeFile(io, gpa, pw.dir, ".plan")) |text| {
            defer gpa.free(text);
            try w.writeAll("Plan:\n");
            try w.writeAll(text);
        }
    }
    try w.writeByte('\n');
}

fn readHomeFile(io: Io, gpa: Allocator, dir: []const u8, name: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
    defer gpa.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null, // unreadable or missing: skipped, as GNU does
    };
}

/// Idle column text: blank under a minute, `HH:MM` under a day, else `Nd`.
pub fn idleText(buf: []u8, last: i64, now: i64) []const u8 {
    const idle = now - last;
    if (idle < 60) return "     ";
    if (idle < 24 * 3600) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(idle, 3600))), @as(u64, @intCast(@divFloor(@mod(idle, 3600), 60))) }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}d", .{@as(u64, @intCast(@divFloor(idle, 24 * 3600)))}) catch "";
}

/// Short format: one row per user session in `data`, limited to the logins in
/// `users` when that list is not empty.
pub fn writeShort(
    io: Io,
    w: *Io.Writer,
    data: []const u8,
    zone: *const localtime.Zone,
    db: *const userdb.Db,
    users: []const []const u8,
    o: Options,
) Io.Writer.Error!void {
    if (o.heading) {
        try w.writeAll("Login    ");
        // Without the name column the mesg-character column is still there.
        try w.writeAll(if (o.fullname) "Name                 " else " ");
        try w.writeAll("TTY      ");
        if (o.idle) try w.writeAll("Idle   ");
        // "When" is padded to the width of the time column, plus the separator
        // that the Where column adds.
        try w.print("{s:<[1]}", .{ "When", o.style.width() });
        if (o.where) try w.writeAll(" Where");
        try w.writeByte('\n');
    }
    var tbuf: [64]u8 = undefined;
    var ibuf: [32]u8 = undefined;
    var nbuf: [512]u8 = undefined;
    var i: usize = 0;
    while (utmp.record(data, i)) |r| : (i += 1) {
        if (!utmp.isUserProcess(r)) continue;
        if (users.len > 0) {
            var wanted = false;
            for (users) |u| {
                if (std.mem.eql(u8, u[0..@min(u.len, 32)], r.user)) wanted = true;
            }
            if (!wanted) continue;
        }
        const info = who.ttyInfo(io, r.line);
        const mesg: u8 = if (!info.exists) '?' else if (info.group_writable) ' ' else '*';
        const line = if (std.mem.startsWith(u8, r.line, "/dev/")) r.line[5..] else r.line;
        try w.print("{s:<8}", .{r.user});
        if (o.fullname) {
            if (db.userByName(r.user)) |pw| {
                const name = realName(&nbuf, pw.gecos, pw.name);
                try w.print(" {s:<19}", .{name[0..@min(name.len, 19)]});
            } else try w.print(" {s:>19}", .{"        ???"});
        }
        try w.print(" {c}{s:<8}", .{ mesg, line });
        if (o.idle) {
            const text = if (info.atime) |a| idleText(&ibuf, a, o.now) else "?????";
            try w.print(" {s:<6}", .{text});
        }
        try w.print(" {s}", .{who.formatTime(&tbuf, o.style, zone, r.time)});
        if (o.where and r.host.len > 0) try w.print(" {s}", .{r.host});
        try w.writeByte('\n');
    }
}

test "real names" {
    var buf: [64]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("Alice Smith", realName(&buf, "Alice Smith,Room 5,555", "alice"));
    try t.expectEqualStrings("Dr. Carol Q. Public", realName(&buf, "Dr. & Q. Public", "carol"));
    try t.expectEqualStrings("", realName(&buf, "", "x"));
}

test "idle text" {
    var buf: [16]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("     ", idleText(&buf, 100, 130));
    try t.expectEqualStrings("15:24", idleText(&buf, 0, 15 * 3600 + 24 * 60 + 5));
    try t.expectEqualStrings("3d", idleText(&buf, 0, 3 * 86400 + 5));
}

test "long format of an unknown and a known account" {
    const t = std.testing;
    var db = try userdb.Db.fromText(t.allocator, "bob:x:1:1:&,Room:/nonexistent/bob:/bin/sh\n", "");
    defer db.deinit();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeLong(t.io, t.allocator, &w, &db, "nosuch", .{ .now = 0 });
    try writeLong(t.io, t.allocator, &w, &db, "bob", .{ .now = 0 });
    try t.expectEqualStrings(
        "Login name: nosuch                      In real life:  ???\n" ++
            "Login name: bob                         In real life:  Bob\n" ++
            "Directory: /nonexistent/bob             Shell:  /bin/sh\n\n",
        w.buffered(),
    );
}

test "short format golden output" {
    const t = std.testing;
    var db = try userdb.Db.fromText(t.allocator, "alice:x:1:1:Alice Smith,,:/home/alice:/bin/sh\n", "");
    defer db.deinit();
    var rec: [utmp.record_size]u8 = @splat(0);
    const endian = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(i16, rec[0..2], 7, endian);
    @memcpy(rec[8..16], "nosuchpt"); // no such terminal: '?' and unknown idle
    @memcpy(rec[44..49], "alice");
    @memcpy(rec[76..85], "h.example");
    std.mem.writeInt(i32, rec[340..344], 1762518896, endian);
    var zone: localtime.Zone = .{};
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeShort(t.io, &w, &rec, &zone, &db, &.{}, .{ .now = 1762600000, .style = .iso });
    try t.expectEqualStrings(
        "Login    Name                 TTY      Idle   When             Where\n" ++
            "alice    Alice Smith         ?nosuchpt ?????  2025-11-07 12:34 h.example\n",
        w.buffered(),
    );
    w = .fixed(&buf);
    try writeShort(t.io, &w, &rec, &zone, &db, &.{"bob"}, .{ .now = 0, .heading = false });
    try t.expectEqualStrings("", w.buffered());
}
