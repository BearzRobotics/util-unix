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
const fsown = @import("fsown.zig");
const who = @import("who.zig");
const localtime = @import("localtime.zig");

pub const Options = struct {
    /// Show control characters in login records, account fields and the
    /// .project and .plan files as '?' (the files keep their newlines and
    /// tabs): for a terminal.
    mask_controls: bool = false,
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
    const pw = db.userByName(login) orelse {
        try w.writeAll("Login name: ");
        try writeField(w, login, 28, o);
        try w.writeAll("In real life:  ???\n");
        return;
    };
    try w.writeAll("Login name: ");
    try writeField(w, pw.name, 28, o);
    try w.writeAll("In real life:  ");
    // room for the whole name, each '&' in it standing for the login name
    const name_buf = try gpa.alloc(u8, pw.gecos.len + std.mem.count(u8, pw.gecos, "&") * pw.name.len);
    defer gpa.free(name_buf);
    try writeField(w, realName(name_buf, pw.gecos, pw.name), 0, o);
    try w.writeByte('\n');
    if (o.home_and_shell) {
        try w.writeAll("Directory: ");
        try writeField(w, pw.dir, 29, o);
        try w.writeAll("Shell:  ");
        try writeField(w, pw.shell, 0, o);
        try w.writeByte('\n');
    }
    if (o.project) try showHomeFile(io, gpa, w, pw, ".project", "Project: ", o);
    if (o.plan) try showHomeFile(io, gpa, w, pw, ".plan", "Plan:\n", o);
    try w.writeByte('\n');
}

/// Write one value from an account or a login record, padded to `width`.
fn writeField(w: *Io.Writer, text: []const u8, width: usize, o: Options) Io.Writer.Error!void {
    if (!o.mask_controls) {
        try w.writeAll(text);
    } else {
        var chunk: [256]u8 = undefined;
        var rest = text;
        while (rest.len > 0) {
            var n = @min(rest.len, chunk.len);
            // do not cut a UTF-8 character in two
            while (n < rest.len and n > 0 and rest[n] & 0xc0 == 0x80) n -= 1;
            if (n == 0) n = @min(rest.len, chunk.len);
            @memcpy(chunk[0..n], rest[0..n]);
            utmp.maskControls(chunk[0..n], false);
            try w.writeAll(chunk[0..n]);
            rest = rest[n..];
        }
    }
    if (text.len < width) try w.splatByteAll(' ', width - text.len);
}

/// Write `heading` and the file `name` from `pw`'s home directory, if there is
/// one to show. The user decides what is at that path, and whoever runs this
/// may be able to read more than they can. So only a regular file is shown (a
/// FIFO would block, a device may never end), and only one that the account
/// owns or that anyone may read: a link to another's private file shows
/// nothing. A missing or unreadable file is skipped, as GNU does.
fn showHomeFile(io: Io, gpa: Allocator, w: *Io.Writer, pw: userdb.Passwd, name: []const u8, heading: []const u8, o: Options) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ pw.dir, name });
    defer gpa.free(path);
    try io.checkCancel();
    const fd = fsown.openForChange(Io.Dir.cwd(), path, .read) catch return;
    defer fsown.closeHandle(fd);
    const st = fsown.statHandle(fd) catch return;
    if (!st.isReg() or (st.uid != pw.uid and st.mode & 0o004 == 0)) return;
    try w.writeAll(heading);
    try copyFile(io, w, fd, o.mask_controls);
}

/// Copy the open file to `w`, however long it is.
fn copyFile(io: Io, w: *Io.Writer, fd: std.posix.fd_t, mask: bool) !void {
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var buf: [4096]u8 = undefined;
    var kept: usize = 0;
    while (true) {
        const n = file.readStreaming(io, &.{buf[kept..]}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        const have = kept + n;
        // when masking, hold back what the next read may complete
        const ready = if (mask and n > 0) completeLength(buf[0..have]) else have;
        if (mask) utmp.maskControls(buf[0..ready], true);
        try w.writeAll(buf[0..ready]);
        if (n == 0) return;
        kept = have - ready;
        @memmove(buf[0..kept], buf[ready..have]);
    }
}

/// The length of `text` without a final carriage return or the start of a
/// UTF-8 character that is not all there.
fn completeLength(text: []const u8) usize {
    if (text.len > 0 and text[text.len - 1] == '\r') return text.len - 1;
    var back: usize = 1;
    while (back <= @min(text.len, 3)) : (back += 1) {
        const c = text[text.len - back];
        if (c & 0xc0 == 0x80) continue;
        const need = std.unicode.utf8ByteSequenceLength(c) catch return text.len;
        return if (need > back) text.len - back else text.len;
    }
    return text.len;
}

test "what is held back between reads" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 2), completeLength("ab"));
    try t.expectEqual(@as(usize, 2), completeLength("ab\r"));
    try t.expectEqual(@as(usize, 2), completeLength("ab\xc3"));
    try t.expectEqual(@as(usize, 4), completeLength("ab\xc3\xa9"));
    try t.expectEqual(@as(usize, 1), completeLength("a\xe2\x82"));
    try t.expectEqual(@as(usize, 1), completeLength("a\xf0\x9f\x98"));
    try t.expectEqual(@as(usize, 3), completeLength("a\x80\x80"));
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
    var mbuf: utmp.MaskBuffer = undefined;
    var i: usize = 0;
    while (utmp.record(data, i)) |r| : (i += 1) {
        if (!utmp.isUserProcess(r)) continue;
        // what is shown; `r` is what is looked up
        const shown = if (o.mask_controls) utmp.masked(r, &mbuf) else r;
        if (users.len > 0) {
            var wanted = false;
            for (users) |u| {
                if (std.mem.eql(u8, u[0..@min(u.len, 32)], r.user)) wanted = true;
            }
            if (!wanted) continue;
        }
        const info = who.ttyInfo(io, r.line);
        const mesg: u8 = if (!info.exists) '?' else if (info.group_writable) ' ' else '*';
        const line = if (std.mem.startsWith(u8, shown.line, "/dev/")) shown.line[5..] else shown.line;
        try w.print("{s:<8}", .{shown.user});
        if (o.fullname) {
            if (db.userByName(r.user)) |pw| {
                const name = realName(&nbuf, pw.gecos, pw.name);
                var cut: [19]u8 = undefined;
                const n = @min(name.len, cut.len);
                @memcpy(cut[0..n], name[0..n]);
                if (o.mask_controls) utmp.maskControls(cut[0..n], false);
                try w.print(" {s:<19}", .{cut[0..n]});
            } else try w.print(" {s:>19}", .{"        ???"});
        }
        try w.print(" {c}{s:<8}", .{ mesg, line });
        if (o.idle) {
            const text = if (info.atime) |a| idleText(&ibuf, a, o.now) else "?????";
            try w.print(" {s:<6}", .{text});
        }
        try w.print(" {s}", .{who.formatTime(&tbuf, o.style, zone, r.time)});
        if (o.where and shown.host.len > 0) try w.print(" {s}", .{shown.host});
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
    utmp.putTime(utmp.native, &rec, 1762518896);
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
