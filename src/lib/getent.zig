//! getent: look up entries in the system's administrative databases.
//!
//! References:
//!   - getent(1), Linux man-pages; glibc manual, "NSS Configuration File" and
//!     "Looking up services/protocols/networks" (the file formats).
//!   - passwd(5), group(5), shadow(5), gshadow(5), hosts(5), networks(5),
//!     protocols(5), services(5), rpc(5), ethers(5), aliases(5), Linux man-pages.
//!   - glibc 2.43 `getent`, run on the development machine, as the behavioural
//!     reference for output formats, key forms and exit codes. POSIX does not
//!     specify getent.
//!
//! Scope (decision 0004): the "files" backend only. Entries come from /etc
//! files; nothing consults nsswitch.conf, DNS, systemd-userdb, LDAP or NIS.
//! Where glibc's answer comes from such a source, ours is "not found" or
//! differs; docs/compatibility/getent.md lists the known cases.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const userdb = @import("userdb.zig");

pub const Database = enum {
    passwd,
    group,
    shadow,
    gshadow,
    hosts,
    ahosts,
    ahostsv4,
    ahostsv6,
    networks,
    protocols,
    services,
    rpc,
    ethers,
    aliases,
    initgroups,
    netgroup,

    pub fn parse(name: []const u8) ?Database {
        return std.meta.stringToEnum(Database, name);
    }

    pub fn defaultPath(db: Database) ?[]const u8 {
        return switch (db) {
            .passwd => "/etc/passwd",
            .group, .initgroups => "/etc/group",
            .shadow => "/etc/shadow",
            .gshadow => "/etc/gshadow",
            .hosts, .ahosts, .ahostsv4, .ahostsv6 => "/etc/hosts",
            .networks => "/etc/networks",
            .protocols => "/etc/protocols",
            .services => "/etc/services",
            .rpc => "/etc/rpc",
            .ethers => "/etc/ethers",
            .aliases => "/etc/aliases",
            .netgroup => null,
        };
    }
};

/// Every database name, in the order glibc lists them.
pub const database_names = [_][]const u8{
    "ahosts",   "ahostsv4",   "ahostsv6", "aliases",  "ethers", "group",     "gshadow",
    "hosts",    "initgroups", "netgroup", "networks", "passwd", "protocols", "rpc",
    "services", "shadow",
};

pub const Outcome = enum {
    found,
    /// A key matched nothing (getent exit status 2).
    not_found,
    /// No key given and the database cannot be listed (exit status 3).
    enumeration_unsupported,
};

pub const Options = struct {
    /// Replace the default path of the file backing the database (tests).
    path: ?[]const u8 = null,
    /// Directory that relative `path`s are resolved against; null is cwd.
    dir: ?Io.Dir = null,
    /// For `initgroups`: the passwd file used to find the user.
    passwd_path: []const u8 = "/etc/passwd",
};

pub const Error = error{ OutOfMemory, WriteFailed } || Io.Dir.ReadFileAllocError;

const max_file_bytes = 64 * 1024 * 1024;

/// Look `key` up in `db` and write each matching entry to `w`. With a null
/// key, list every entry. A file that is missing, or that we may not read
/// (shadow files as an ordinary user), counts as an empty database, as it does
/// for glibc's files backend.
pub fn query(io: Io, gpa: Allocator, db: Database, key: ?[]const u8, opts: Options, w: *Io.Writer) Error!Outcome {
    if (db == .netgroup) return if (key == null) .enumeration_unsupported else .not_found;
    const text = try readFile(io, gpa, opts.dir orelse Io.Dir.cwd(), opts.path orelse db.defaultPath().?);
    defer gpa.free(text);

    if (key == null and db == .initgroups) return .enumeration_unsupported;

    var any = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    switch (db) {
        .passwd => while (lines.next()) |line| {
            const e = userdb.parsePasswd(line) orelse continue;
            if (key) |k| {
                if (!(if (isNumber(k)) e.uid == parseU32(k) else std.mem.eql(u8, e.name, k))) continue;
            }
            try w.print("{s}:{s}:{d}:{d}:{s}:{s}:{s}\n", .{ e.name, e.passwd, e.uid, e.gid, e.gecos, e.dir, e.shell });
            any = true;
            if (key != null) break;
        },
        .group => while (lines.next()) |line| {
            const e = userdb.parseGroup(line) orelse continue;
            if (key) |k| {
                if (!(if (isNumber(k)) e.gid == parseU32(k) else std.mem.eql(u8, e.name, k))) continue;
            }
            try w.print("{s}:{s}:{d}:{s}\n", .{ e.name, e.passwd, e.gid, e.members });
            any = true;
            if (key != null) break;
        },
        .shadow => while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next().?;
            if (key) |k| if (!std.mem.eql(u8, name, k)) continue;
            try w.print("{s}:{s}", .{ name, f.next() orelse "" });
            // lstchg, min, max, warn, inact, expire, flag: numbers or empty.
            for (0..7) |_| {
                const field = f.next() orelse "";
                const n = std.fmt.parseInt(i64, field, 10) catch null;
                if (n) |v| try w.print(":{d}", .{v}) else try w.writeAll(":");
            }
            try w.writeByte('\n');
            any = true;
            if (key != null) break;
        },
        .gshadow => while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next().?;
            if (key) |k| if (!std.mem.eql(u8, name, k)) continue;
            try w.print("{s}:{s}:{s}:{s}\n", .{ name, f.next() orelse "", f.next() orelse "", f.next() orelse "" });
            any = true;
            if (key != null) break;
        },
        .services => any = try services(&lines, key, w),
        .protocols => any = try numbered(&lines, key, w, .protocols),
        .rpc => any = try numbered(&lines, key, w, .rpc),
        .networks => any = try networks(&lines, key, w),
        .hosts => any = try hosts(&lines, key, w),
        // Without a key glibc lists the hosts file like `hosts` does.
        .ahosts, .ahostsv4, .ahostsv6 => any = if (key) |k| try addrinfo(&lines, k, db, w) else try hosts(&lines, null, w),
        .ethers => any = try ethers(&lines, key, w),
        .aliases => any = try aliases(&lines, key, w),
        .initgroups => any = try initgroups(io, gpa, opts, opts.dir orelse Io.Dir.cwd(), text, key.?, w),
        .netgroup => unreachable,
    }
    return if (any) .found else .not_found;
}

fn readFile(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8) Error![]u8 {
    return dir.readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.NotDir => return gpa.alloc(u8, 0),
        else => return e,
    };
}

/// glibc's getent decides "number or name" by the first character alone and
/// then reads the number with atol(): "3270_mapper" is the number 3270.
fn isNumber(s: []const u8) bool {
    return s.len > 0 and s[0] >= '0' and s[0] <= '9';
}

/// atol(): the leading digits, saturating; null when there are none.
fn parseU32(s: []const u8) ?u32 {
    var v: u64 = 0;
    var n: usize = 0;
    while (n < s.len and s[n] >= '0' and s[n] <= '9') : (n += 1) {
        v = @min(v * 10 + (s[n] - '0'), std.math.maxInt(u32) + 1);
    }
    if (n == 0 or v > std.math.maxInt(u32)) return null;
    return @intCast(v);
}

/// Strip a '#' comment and surrounding blanks.
fn stripComment(line: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
    return std.mem.trim(u8, line[0..end], " \t\r");
}

fn fields(line: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, line, " \t");
}

fn printAliases(w: *Io.Writer, it: *std.mem.TokenIterator(u8, .any)) !void {
    while (it.next()) |a| try w.print(" {s}", .{a});
}

// -- services -----------------------------------------------------------------

fn services(lines: *std.mem.SplitIterator(u8, .scalar), key: ?[]const u8, w: *Io.Writer) !bool {
    // Key: NAME[/PROTO] or PORT[/PROTO].
    var want_name: ?[]const u8 = null;
    var want_port: ?u32 = null;
    var want_proto: ?[]const u8 = null;
    if (key) |k| {
        const slash = std.mem.indexOfScalar(u8, k, '/');
        const head = if (slash) |s| k[0..s] else k;
        if (slash) |s| want_proto = k[s + 1 ..];
        if (isNumber(head)) want_port = parseU32(head) else want_name = head;
    }
    var any = false;
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        if (line.len == 0) continue;
        var it = fields(line);
        const name = it.next().?;
        const portproto = it.next() orelse continue;
        const slash = std.mem.indexOfScalar(u8, portproto, '/') orelse continue;
        const port = parseU32(portproto[0..slash]) orelse continue;
        const proto = portproto[slash + 1 ..];

        if (key != null) {
            if (want_proto) |p| if (!std.mem.eql(u8, p, proto)) continue;
            if (want_port) |p| {
                if (p != port) continue;
            } else {
                var rest = it;
                var hit = std.mem.eql(u8, name, want_name.?);
                while (!hit) {
                    const a = rest.next() orelse break;
                    hit = std.mem.eql(u8, a, want_name.?);
                }
                if (!hit) continue;
            }
        }
        try w.print("{s:<21} {d}/{s}", .{ name, port, proto });
        try printAliases(w, &it);
        try w.writeByte('\n');
        any = true;
        if (key != null) break;
    }
    return any;
}

// -- protocols and rpc ----------------------------------------------------------

const Numbered = enum { protocols, rpc };

fn numbered(lines: *std.mem.SplitIterator(u8, .scalar), key: ?[]const u8, w: *Io.Writer, kind: Numbered) !bool {
    var any = false;
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        if (line.len == 0) continue;
        var it = fields(line);
        const name = it.next().?;
        const number_text = it.next() orelse continue;
        const number = std.fmt.parseInt(i64, number_text, 10) catch continue;
        if (key) |k| {
            var hit = false;
            if (isNumber(k)) {
                hit = if (parseU32(k)) |v| v == number else false;
            } else {
                hit = std.mem.eql(u8, name, k);
                var rest = it;
                while (!hit) {
                    const a = rest.next() orelse break;
                    hit = std.mem.eql(u8, a, k);
                }
            }
            if (!hit) continue;
        }
        switch (kind) {
            .protocols => try w.print("{s:<21} {d}", .{ name, number }),
            .rpc => try w.print("{s:<15} {d}", .{ name, number }),
        }
        // rpc: the first alias is preceded by two spaces, later ones by one.
        if (kind == .rpc and it.peek() != null) try w.writeByte(' ');
        try printAliases(w, &it);
        try w.writeByte('\n');
        any = true;
        if (key != null) break;
    }
    return any;
}

// -- networks -------------------------------------------------------------------

/// inet_network(3) for the dotted forms /etc/networks uses: "a.b.c.d",
/// "a.b.c", "a.b" or "a" with the value in the low-order bytes.
fn parseNetwork(text: []const u8) ?u32 {
    var parts: [4]u32 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |p| {
        if (n == 4) return null;
        parts[n] = std.fmt.parseInt(u8, p, 10) catch return null;
        n += 1;
    }
    if (n == 0) return null;
    var v: u32 = 0;
    for (parts[0..n]) |p| v = (v << 8) | p;
    return v;
}

fn formatNetwork(w: *Io.Writer, value: u32) !void {
    // glibc prints the host-order network number as a dotted quad whose
    // leading zero bytes are dropped for classful networks: 127 -> 127.0.0.0.
    var v = value;
    if (v < 0x100) v <<= 24 else if (v < 0x10000) v <<= 16 else if (v < 0x1000000) v <<= 8;
    try w.print("{d}.{d}.{d}.{d}", .{ v >> 24, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff });
}

fn networks(lines: *std.mem.SplitIterator(u8, .scalar), key: ?[]const u8, w: *Io.Writer) !bool {
    const key_net: ?u32 = if (key) |k| parseNetwork(k) else null;
    var any = false;
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        if (line.len == 0) continue;
        var it = fields(line);
        const name = it.next().?;
        const addr_text = it.next() orelse continue;
        const addr = parseNetwork(addr_text) orelse continue;
        if (key) |k| {
            var hit = key_net != null and key_net.? == addr;
            if (!hit) {
                hit = std.mem.eql(u8, name, k);
                var rest = it;
                while (!hit) {
                    const a = rest.next() orelse break;
                    hit = std.mem.eql(u8, a, k);
                }
            }
            if (!hit) continue;
        }
        try w.print("{s:<21} ", .{name});
        try formatNetwork(w, addr);
        try printAliases(w, &it);
        try w.writeByte('\n');
        any = true;
        if (key != null) break;
    }
    return any;
}

// -- hosts ----------------------------------------------------------------------

const Address = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    fn parse(text: []const u8) ?Address {
        if (Io.net.Ip4Address.parse(text, 0)) |a| return .{ .v4 = a.bytes } else |_| {}
        if (Io.net.Ip6Address.parse(text, 0)) |a| return .{ .v6 = a.bytes } else |_| {}
        return null;
    }

    fn eql(a: Address, b: Address) bool {
        return switch (a) {
            .v4 => |x| b == .v4 and std.mem.eql(u8, &x, &b.v4),
            .v6 => |x| b == .v6 and std.mem.eql(u8, &x, &b.v6),
        };
    }

    fn format(a: Address, w: *Io.Writer) Io.Writer.Error!void {
        switch (a) {
            .v4 => |b| try w.print("{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }),
            .v6 => |b| try formatV6(w, b),
        }
    }

    fn textLen(a: Address) usize {
        var buf: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        a.format(&w) catch return 0;
        return w.buffered().len;
    }
};

/// RFC 5952 text for an IPv6 address (what inet_ntop produces), including the
/// dotted form for IPv4-mapped addresses.
fn formatV6(w: *Io.Writer, b: [16]u8) Io.Writer.Error!void {
    var g: [8]u16 = undefined;
    for (0..8) |i| g[i] = (@as(u16, b[2 * i]) << 8) | b[2 * i + 1];
    // Longest run of zero groups (length >= 2) is replaced by "::".
    var best_start: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (g[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and g[j] == 0) j += 1;
        if (j - i > best_len) {
            best_len = j - i;
            best_start = i;
        }
        i = j;
    }
    if (best_len < 2) best_start = 8;
    const mapped = best_start == 0 and (best_len == 6 or (best_len == 5 and g[5] == 0xffff));
    var k: usize = 0;
    while (k < 8) {
        if (k == best_start) {
            try w.writeAll("::");
            k += best_len;
            if (mapped) {
                if (best_len == 5) try w.writeAll("ffff:");
                try w.print("{d}.{d}.{d}.{d}", .{ b[12], b[13], b[14], b[15] });
                return;
            }
            continue;
        }
        if (k > 0 and k != best_start + best_len) try w.writeByte(':');
        try w.print("{x}", .{g[k]});
        k += 1;
    }
}

const HostEntry = struct {
    addr: Address,
    names: std.mem.TokenIterator(u8, .any),
};

fn nextHost(lines: *std.mem.SplitIterator(u8, .scalar)) ?HostEntry {
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        if (line.len == 0) continue;
        var it = fields(line);
        const addr = Address.parse(it.next().?) orelse continue;
        if (it.peek() == null) continue;
        return .{ .addr = addr, .names = it };
    }
    return null;
}

fn printHost(w: *Io.Writer, e: HostEntry) !void {
    // "%-15s %s ..." : the address padded to 15 columns, then the names.
    var names = e.names;
    const len = e.addr.textLen();
    try e.addr.format(w);
    try w.splatByteAll(' ', if (len < 15) 15 - len else 0);
    try w.writeByte(' ');
    try w.writeAll(names.next().?);
    try printAliases(w, &names);
    try w.writeByte('\n');
}

fn hasName(e: HostEntry, name: []const u8) bool {
    var names = e.names;
    while (names.next()) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

fn hosts(lines: *std.mem.SplitIterator(u8, .scalar), key: ?[]const u8, w: *Io.Writer) !bool {
    var any = false;
    if (key == null) {
        while (nextHost(lines)) |e| {
            try printHost(w, e);
            any = true;
        }
        return any;
    }
    const k = key.?;
    if (Address.parse(k)) |want| {
        while (nextHost(lines)) |e| if (e.addr.eql(want)) {
            try printHost(w, e);
            return true;
        };
        return false;
    }
    // glibc asks for IPv6 first, then IPv4.
    const start = lines.*;
    inline for (.{ true, false }) |want_v6| {
        lines.* = start;
        while (nextHost(lines)) |e| {
            if ((e.addr == .v6) == want_v6 and hasName(e, k)) {
                try printHost(w, e);
                return true;
            }
        }
    }
    return false;
}

/// ahosts, ahostsv4, ahostsv6: one STREAM/DGRAM/RAW triple per address.
fn addrinfo(lines: *std.mem.SplitIterator(u8, .scalar), key: []const u8, db: Database, w: *Io.Writer) !bool {
    var any = false;
    const literal = Address.parse(key);
    while (nextHost(lines)) |e| {
        const matches = if (literal) |want| e.addr.eql(want) else hasName(e, key);
        if (!matches) continue;
        var shown: Address = e.addr;
        switch (db) {
            .ahostsv4 => if (e.addr != .v4) continue,
            .ahostsv6 => if (e.addr == .v4) {
                var mapped: [16]u8 = @splat(0);
                mapped[10] = 0xff;
                mapped[11] = 0xff;
                @memcpy(mapped[12..], &e.addr.v4);
                shown = .{ .v6 = mapped };
            },
            else => {},
        }
        const canonical = if (literal != null) key else blk: {
            var n = e.names;
            break :blk n.next().?;
        };
        const types = [_][]const u8{ "STREAM", "DGRAM ", "RAW   " };
        for (types, 0..) |t, i| {
            const len = shown.textLen();
            try shown.format(w);
            try w.splatByteAll(' ', if (len < 15) 15 - len else 0);
            try w.print(" {s} {s}\n", .{ t, if (i == 0) canonical else "" });
        }
        any = true;
        if (literal != null) break;
    }
    return any;
}

// -- ethers and aliases ---------------------------------------------------------

fn ethers(lines: *std.mem.SplitIterator(u8, .scalar), key: ?[]const u8, w: *Io.Writer) !bool {
    var any = false;
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        if (line.len == 0) continue;
        var it = fields(line);
        const mac_text = it.next().?;
        const host = it.next() orelse continue;
        var mac: [6]u8 = undefined;
        var parts = std.mem.splitScalar(u8, mac_text, ':');
        var n: usize = 0;
        while (parts.next()) |p| : (n += 1) {
            if (n == 6) break;
            mac[n] = std.fmt.parseInt(u8, p, 16) catch break;
        }
        if (n != 6) continue;
        if (key) |k| {
            var key_mac: ?[6]u8 = null;
            var kp = std.mem.splitScalar(u8, k, ':');
            var m: [6]u8 = undefined;
            var kn: usize = 0;
            while (kp.next()) |p| : (kn += 1) {
                if (kn == 6) break;
                m[kn] = std.fmt.parseInt(u8, p, 16) catch break;
            }
            if (kn == 6) key_mac = m;
            const hit = if (key_mac) |km| std.mem.eql(u8, &km, &mac) else std.mem.eql(u8, host, k);
            if (!hit) continue;
        }
        try w.print("{x}:{x}:{x}:{x}:{x}:{x} {s}\n", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], host });
        any = true;
        if (key != null) break;
    }
    return any;
}

fn aliases(lines: *std.mem.SplitIterator(u8, .scalar), key: ?[]const u8, w: *Io.Writer) !bool {
    var any = false;
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0) continue;
        if (key) |k| if (!std.ascii.eqlIgnoreCase(name, k)) continue;
        try w.print("{s}: ", .{name});
        var members = std.mem.tokenizeAny(u8, line[colon + 1 ..], ", \t");
        var first = true;
        while (members.next()) |m| {
            if (!first) try w.writeAll(", ");
            try w.writeAll(m);
            first = false;
        }
        try w.writeByte('\n');
        any = true;
        if (key != null) break;
    }
    return any;
}

// -- initgroups -----------------------------------------------------------------

/// `getent initgroups USER`: the groups USER is a listed member of, in group
/// file order, after the user name padded to 21 columns. glibc leaves the
/// user's primary group out of this list, and so do we.
fn initgroups(io: Io, gpa: Allocator, opts: Options, dir: Io.Dir, group_text: []const u8, user: []const u8, w: *Io.Writer) !bool {
    const passwd_text = try readFile(io, gpa, dir, opts.passwd_path);
    defer gpa.free(passwd_text);
    var known = false;
    var pl = std.mem.splitScalar(u8, passwd_text, '\n');
    while (pl.next()) |line| if (userdb.parsePasswd(line)) |e| {
        if (std.mem.eql(u8, e.name, user)) {
            known = true;
            break;
        }
    };
    // glibc answers for unknown users too (with no groups).
    try w.print("{s:<21}", .{user});
    var gl = std.mem.splitScalar(u8, group_text, '\n');
    while (gl.next()) |line| {
        const g = userdb.parseGroup(line) orelse continue;
        var members = std.mem.splitScalar(u8, g.members, ',');
        const member = while (members.next()) |m| {
            if (std.mem.eql(u8, m, user)) break true;
        } else false;
        if (!member or !known) continue;
        try w.print(" {d}", .{g.gid});
    }
    try w.writeByte('\n');
    return true;
}

// -- Tests ----------------------------------------------------------------------

const testing = std.testing;

fn runQuery(db: Database, key: ?[]const u8, text: []const u8, out: *std.ArrayList(u8)) !Outcome {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data", .data = text });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "passwd", .data = "alice:x:1000:1000::/h:/bin/sh\nbob:x:1001:1001::/h:/bin/sh\n" });
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const r = try query(testing.io, testing.allocator, db, key, .{ .path = "data", .dir = tmp.dir, .passwd_path = "passwd" }, &aw.writer);
    try out.appendSlice(testing.allocator, aw.written());
    return r;
}

fn expectQuery(db: Database, key: ?[]const u8, text: []const u8, outcome: Outcome, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(outcome, try runQuery(db, key, text, &out));
    try testing.expectEqualStrings(expected, out.items);
}

test "passwd and group by name and id" {
    const pw = "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000:A:/home/a:/bin/sh\n";
    try expectQuery(.passwd, "alice", pw, .found, "alice:x:1000:1000:A:/home/a:/bin/sh\n");
    try expectQuery(.passwd, "0", pw, .found, "root:x:0:0:root:/root:/bin/sh\n");
    try expectQuery(.passwd, "nosuch", pw, .not_found, "");
    try expectQuery(.passwd, null, pw, .found, "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000:A:/home/a:/bin/sh\n");
    try expectQuery(.group, "4", "adm:x:4:syslog,alice\n", .found, "adm:x:4:syslog,alice\n");
}

test "shadow prints numbers and empty fields" {
    try expectQuery(.shadow, "root", "root:!*:19000:0:99999:7:::\n", .found, "root:!*:19000:0:99999:7:::\n");
    try expectQuery(.shadow, "root", "root:!*:::::::\n", .found, "root:!*:::::::\n");
}

test "services: by name, port, protocol; aliases; comments" {
    const s = "# c\necho 7/tcp\nhttp 80/tcp www # web\ndomain 53/tcp\ndomain 53/udp\n";
    try expectQuery(.services, "http", s, .found, "http                  80/tcp www\n");
    try expectQuery(.services, "www", s, .found, "http                  80/tcp www\n");
    try expectQuery(.services, "53/udp", s, .found, "domain                53/udp\n");
    try expectQuery(.services, "domain", s, .found, "domain                53/tcp\n");
    try expectQuery(.services, "http/udp", s, .not_found, "");
}

test "protocols and rpc formats" {
    try expectQuery(.protocols, "ICMP", "icmp 1 ICMP\n", .found, "icmp                  1 ICMP\n");
    try expectQuery(.protocols, "6", "tcp 6 TCP\n", .found, "tcp                   6 TCP\n");
    try expectQuery(.rpc, "nfs", "nfs 100003 nfsprog\n", .found, "nfs             100003  nfsprog\n");
}

test "hosts: name prefers IPv6, address lookup, formatting" {
    const h = "127.0.0.1 localhost\n::1 ip6-localhost ip6-loopback\n10.0.0.1 a b\nfe00::0 net\n";
    try expectQuery(.hosts, "localhost", h, .found, "127.0.0.1       localhost\n");
    try expectQuery(.hosts, "::1", h, .found, "::1             ip6-localhost ip6-loopback\n");
    try expectQuery(.hosts, "10.0.0.1", h, .found, "10.0.0.1        a b\n");
    try expectQuery(.hosts, "B", h, .found, "10.0.0.1        a b\n");
    try expectQuery(.hosts, "net", h, .found, "fe00::          net\n");
    try expectQuery(.hosts, "nosuch", h, .not_found, "");
}

test "ahosts triples" {
    try expectQuery(.ahostsv4, "localhost", "127.0.0.1 localhost\n", .found, "127.0.0.1       STREAM localhost\n127.0.0.1       DGRAM  \n127.0.0.1       RAW    \n");
    try expectQuery(.ahostsv6, "localhost", "127.0.0.1 localhost\n", .found, "::ffff:127.0.0.1 STREAM localhost\n::ffff:127.0.0.1 DGRAM  \n::ffff:127.0.0.1 RAW    \n");
}

test "IPv6 formatting follows RFC 5952" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try formatV6(&w, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    try testing.expectEqualStrings("2001:db8::1", w.buffered());
    w = .fixed(&buf);
    try formatV6(&w, @splat(0));
    try testing.expectEqualStrings("::", w.buffered());
    w = .fixed(&buf);
    try formatV6(&w, .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0xab, 0xcd, 0, 0, 0, 0, 0, 1 });
    try testing.expectEqualStrings("fe80::abcd:0:0:1", w.buffered());
}

test "initgroups lists memberships without the primary group" {
    try expectQuery(.initgroups, "alice", "adm:x:4:alice,bob\nalice:x:1000:\nusers:x:100:alice\n", .found, "alice                 4 100\n");
    try expectQuery(.initgroups, "nosuch", "adm:x:4:alice\n", .found, "nosuch               \n");
    try expectQuery(.initgroups, null, "", .enumeration_unsupported, "");
}

test "netgroup and missing files" {
    try expectQuery(.netgroup, "x", "", .not_found, "");
    try expectQuery(.netgroup, null, "", .enumeration_unsupported, "");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const r = try query(testing.io, testing.allocator, .passwd, "root", .{ .path = "absent", .dir = tmp.dir }, &aw.writer);
    try testing.expectEqual(Outcome.not_found, r);
}
