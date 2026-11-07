//! User and group databases read directly from /etc/passwd and /etc/group.
//!
//! This is the "files" backend only: there is no NSS, so users from LDAP,
//! systemd-userdbd, SSSD and the like are not seen. That is a deliberate scope
//! limit (docs/decisions/0004-files-only-user-database.md); it keeps the
//! library free of libc.
//!
//! References: passwd(5), group(5), Linux man-pages. POSIX does not specify
//! the file format, only the meaning of the fields.
//!
//! Lookup follows getpwnam(3)/getgrnam(3): the first matching line wins, and
//! malformed lines are skipped.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Passwd = struct {
    name: []const u8,
    passwd: []const u8,
    uid: u32,
    gid: u32,
    gecos: []const u8,
    dir: []const u8,
    shell: []const u8,
};

pub const Group = struct {
    name: []const u8,
    passwd: []const u8,
    gid: u32,
    /// Comma-separated member list, possibly empty.
    members: []const u8,
};

/// Parse one passwd(5) line. Null for comments, blank and malformed lines.
pub fn parsePasswd(line: []const u8) ?Passwd {
    if (line.len == 0 or line[0] == '#') return null;
    var it = std.mem.splitScalar(u8, line, ':');
    const name = it.next() orelse return null;
    const pw = it.next() orelse return null;
    const uid = parseId(it.next() orelse return null) orelse return null;
    const gid = parseId(it.next() orelse return null) orelse return null;
    const gecos = it.next() orelse return null;
    const dir = it.next() orelse return null;
    const shell = it.next() orelse return null;
    if (name.len == 0) return null;
    return .{ .name = name, .passwd = pw, .uid = uid, .gid = gid, .gecos = gecos, .dir = dir, .shell = shell };
}

/// Parse one group(5) line.
pub fn parseGroup(line: []const u8) ?Group {
    if (line.len == 0 or line[0] == '#') return null;
    var it = std.mem.splitScalar(u8, line, ':');
    const name = it.next() orelse return null;
    const pw = it.next() orelse return null;
    const gid = parseId(it.next() orelse return null) orelse return null;
    const members = it.next() orelse "";
    if (name.len == 0) return null;
    return .{ .name = name, .passwd = pw, .gid = gid, .members = members };
}

fn parseId(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// In-memory copy of the two files. Entries returned by lookups borrow from
/// it and are valid until `deinit`.
pub const Db = struct {
    gpa: Allocator,
    passwd_text: []u8 = &.{},
    group_text: []u8 = &.{},

    pub const default_passwd_path = "/etc/passwd";
    pub const default_group_path = "/etc/group";
    const max_file_bytes = 64 * 1024 * 1024;

    pub const Paths = struct {
        passwd: []const u8 = default_passwd_path,
        group: []const u8 = default_group_path,
    };

    /// Read both files. A missing file is an empty database (a minimal
    /// container may have none), any other failure is returned.
    pub fn load(io: Io, gpa: Allocator, paths: Paths) !Db {
        var db: Db = .{ .gpa = gpa };
        errdefer db.deinit();
        db.passwd_text = try readOrEmpty(io, gpa, paths.passwd);
        db.group_text = try readOrEmpty(io, gpa, paths.group);
        return db;
    }

    /// A database over text the caller already has (tests). The text is
    /// copied.
    pub fn fromText(gpa: Allocator, passwd_text: []const u8, group_text: []const u8) !Db {
        var db: Db = .{ .gpa = gpa };
        errdefer db.deinit();
        db.passwd_text = try gpa.dupe(u8, passwd_text);
        db.group_text = try gpa.dupe(u8, group_text);
        return db;
    }

    pub fn deinit(db: *Db) void {
        db.gpa.free(db.passwd_text);
        db.gpa.free(db.group_text);
        db.* = undefined;
    }

    fn readOrEmpty(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |e| switch (e) {
            error.FileNotFound => return gpa.alloc(u8, 0),
            else => return e,
        };
    }

    pub fn passwdIterator(db: *const Db) PasswdIterator {
        return .{ .lines = std.mem.splitScalar(u8, db.passwd_text, '\n') };
    }

    pub fn groupIterator(db: *const Db) GroupIterator {
        return .{ .lines = std.mem.splitScalar(u8, db.group_text, '\n') };
    }

    pub fn userByName(db: *const Db, name: []const u8) ?Passwd {
        var it = db.passwdIterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    pub fn userById(db: *const Db, uid: u32) ?Passwd {
        var it = db.passwdIterator();
        while (it.next()) |e| if (e.uid == uid) return e;
        return null;
    }

    pub fn groupByName(db: *const Db, name: []const u8) ?Group {
        var it = db.groupIterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    pub fn groupById(db: *const Db, gid: u32) ?Group {
        var it = db.groupIterator();
        while (it.next()) |e| if (e.gid == gid) return e;
        return null;
    }
};

pub const PasswdIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn next(it: *PasswdIterator) ?Passwd {
        while (it.lines.next()) |line| if (parsePasswd(line)) |e| return e;
        return null;
    }
};

pub const GroupIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn next(it: *GroupIterator) ?Group {
        while (it.lines.next()) |line| if (parseGroup(line)) |e| return e;
        return null;
    }
};

const test_passwd =
    \\# comment
    \\root:x:0:0:root:/root:/bin/bash
    \\bad line
    \\alice:x:1000:1000:Alice,,,:/home/alice:/bin/zsh
    \\alice2:x:1000:1001::/home/a2:/bin/sh
    \\nameless::5:5::/:/bin/false
    \\
;
const test_group =
    \\root:x:0:
    \\staff:x:50:alice,bob
    \\alice:x:1000:
    \\
;

test "lookups return the first match and skip bad lines" {
    var db = try Db.fromText(std.testing.allocator, test_passwd, test_group);
    defer db.deinit();
    try std.testing.expectEqual(@as(u32, 1000), db.userByName("alice").?.uid);
    try std.testing.expectEqualStrings("alice", db.userById(1000).?.name); // not alice2
    try std.testing.expectEqualStrings("/bin/zsh", db.userByName("alice").?.shell);
    try std.testing.expect(db.userByName("nobody") == null);
    try std.testing.expect(db.userByName("bad line") == null);
    try std.testing.expectEqual(@as(u32, 5), db.userByName("nameless").?.uid);
    try std.testing.expectEqualStrings("alice,bob", db.groupByName("staff").?.members);
    try std.testing.expectEqualStrings("alice", db.groupById(1000).?.name);
    try std.testing.expect(db.groupById(7) == null);
}

test "parsePasswd rejects non-numeric ids and short lines" {
    try std.testing.expect(parsePasswd("a:x:z:1:g:/:/bin/sh") == null);
    try std.testing.expect(parsePasswd("a:x:1:1:g:/") == null);
    try std.testing.expect(parsePasswd(":x:1:1:g:/:/bin/sh") == null);
}
