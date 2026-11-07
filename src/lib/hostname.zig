// SPDX-License-Identifier: GPL-2.0-or-later
//! hostname: read and set the system host name, and look names up in the hosts
//! file.
//!
//! References: gethostname(2), sethostname(2), uname(2), hosts(5); the
//! behavior of `hostname` 3.25 (the Debian/net-tools program) for the wrapper.
//!
//! Host name resolution uses /etc/hosts only (no DNS, no NSS), the same
//! boundary as decision 0004 for the user databases. A name that is not in
//! the file therefore cannot be completed to a fully qualified name here.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const proc = @import("proc.zig");

const is_linux = builtin.os.tag == .linux;

/// Longest host name the Linux kernel accepts (HOST_NAME_MAX, not counting the NUL).
pub const max_len = 64;

pub const SetError = error{ PermissionDenied, NameTooLong, Unexpected, Unsupported };

/// Set the host name with sethostname(2). Needs CAP_SYS_ADMIN in the UTS
/// namespace; an empty name is allowed by the kernel. The kernel checks the
/// privilege before the length, so an over-long name from an unprivileged
/// caller is `PermissionDenied`.
pub fn set(name: []const u8) SetError!void {
    if (comptime !is_linux) return error.Unsupported;
    return switch (linux.errno(linux.syscall2(.sethostname, @intFromPtr(name.ptr), name.len))) {
        .SUCCESS => {},
        .PERM => error.PermissionDenied,
        .INVAL => error.NameTooLong,
        else => error.Unexpected,
    };
}

/// The part of `name` before the first dot.
pub fn short(name: []const u8) []const u8 {
    return name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
}

/// The part of `name` after the first dot, or null when it has none.
pub fn domain(name: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    return name[dot + 1 ..];
}

/// First line of a host-name file that is neither blank nor a comment,
/// trimmed (what `hostname -F` uses). Null when there is none.
pub fn fromFileText(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        return line;
    }
    return null;
}

/// What a hosts-file search found for a name.
pub const HostsMatch = struct {
    /// The first name on the first matching line (the "canonical" name).
    canonical: []const u8,
    /// The remaining names on that line, space-separated as written.
    aliases: []const u8,
    /// IPv4 addresses (text) of every matching line, in file order. Owned.
    addresses: []const []const u8,

    pub fn deinit(m: HostsMatch, gpa: Allocator) void {
        gpa.free(m.addresses);
    }
};

/// Find `name` (case-insensitive) among the host names of `text`, a hosts(5)
/// file. Borrows from `text`; free with `HostsMatch.deinit`.
pub fn lookup(gpa: Allocator, text: []const u8, name: []const u8) Allocator.Error!?HostsMatch {
    var found: ?HostsMatch = null;
    var addrs: std.ArrayList([]const u8) = .empty;
    errdefer addrs.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const addr = fields.next() orelse continue;
        const first = fields.next() orelse continue;
        var matches = std.ascii.eqlIgnoreCase(first, name);
        const rest_start = fields.index;
        while (!matches) {
            const f = fields.next() orelse break;
            matches = std.ascii.eqlIgnoreCase(f, name);
        }
        if (!matches) continue;
        if (isIpv4(addr)) try addrs.append(gpa, addr);
        if (found == null) {
            found = .{
                .canonical = first,
                .aliases = std.mem.trim(u8, line[@min(rest_start, line.len)..], " \t"),
                .addresses = &.{},
            };
        }
    }
    var m = found orelse {
        addrs.deinit(gpa);
        return null;
    };
    m.addresses = try addrs.toOwnedSlice(gpa);
    return m;
}

fn isIpv4(text: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |p| {
        _ = std.fmt.parseInt(u8, p, 10) catch return false;
        parts += 1;
    }
    return parts == 4;
}

test "short and domain split at the first dot" {
    const t = std.testing;
    try t.expectEqualStrings("host", short("host.example.com"));
    try t.expectEqualStrings("host", short("host"));
    try t.expectEqualStrings("example.com", domain("host.example.com").?);
    try t.expect(domain("host") == null);
}

test "a host-name file skips comments and blanks" {
    try std.testing.expectEqualStrings("foo", fromFileText("# c\n\n  foo \nbar\n").?);
    try std.testing.expect(fromFileText("# only\n\n") == null);
}

test "hosts lookup finds the canonical name, aliases and addresses" {
    const text =
        \\127.0.0.1 localhost
        \\127.0.1.1 box.example.org box # comment
        \\10.0.0.5 box
        \\::1 ip6-localhost box
        \\
    ;
    const m = (try lookup(std.testing.allocator, text, "BOX")).?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("box.example.org", m.canonical);
    try std.testing.expectEqualStrings("box", m.aliases);
    try std.testing.expectEqual(@as(usize, 2), m.addresses.len);
    try std.testing.expectEqualStrings("127.0.1.1", m.addresses[0]);
    try std.testing.expectEqualStrings("10.0.0.5", m.addresses[1]);
    try std.testing.expect(try lookup(std.testing.allocator, text, "nobody") == null);
}
