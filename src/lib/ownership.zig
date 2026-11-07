//! Changing the owner and group of files: the engine behind chown and chgrp.
//!
//! References:
//!   - POSIX.1-2024 `chown` and `chgrp`:
//!     https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chown.html
//!     https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chgrp.html
//!     (options -R, -H, -L, -P, -h; the symlink and traversal rules).
//!   - GNU coreutils 9.7 manual, "chown invocation" and "chgrp invocation"
//!     (--from, --reference, -c/-f/-v, --preserve-root, --dereference).
//!   - GNU coreutils 9.7 `src/chown-core.c`, read for the order of operations
//!     and the exact conditions behind each message. Independent implementation.
//!
//! The engine walks each path (recursively with `recurse`), decides per entry
//! whether the `--from` filter allows a change, performs it with
//! `fchownat`-style calls relative to open directories (so a path component
//! swapped for a symlink during a long walk cannot redirect a change), and
//! reports everything through `Reporter` events. It never prints.
//!
//! Traversal order matches fts as GNU uses it: with `recurse`, a directory's
//! contents are handled before the directory itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fsown = @import("fsown.zig");
const userdb = @import("userdb.zig");

pub const Verbosity = enum {
    off,
    /// `-c`: report only actual changes.
    changes,
    /// `-v`: report every file processed.
    verbose,
};

/// Which symbolic links to follow while walking (`-P`, `-H`, `-L`).
pub const Traversal = enum {
    /// `-P`: never follow a symbolic link to a directory.
    physical,
    /// `-H`: follow links named on the command line only.
    command_line,
    /// `-L`: follow every link to a directory.
    logical,
};

pub const ChangeStatus = enum {
    succeeded,
    failed,
    no_change_requested,
    /// `-h` on a system that cannot change a link's own owner.
    not_applied,
};

/// What happened to one file; only produced for `-c` / `-v`.
pub const Change = struct {
    path: []const u8,
    status: ChangeStatus,
    /// Current owner and group, as names (or decimal ids). Null when the file
    /// could not be examined.
    old_user: ?[]const u8,
    old_group: ?[]const u8,
    /// New owner and group as they should be shown. Null: not being changed.
    /// An empty `new_user` with a group means "ownership :GROUP" wording.
    new_user: ?[]const u8,
    new_group: ?[]const u8,
};

pub const ProblemKind = enum {
    /// Could not examine `path` ("cannot access").
    cannot_access,
    cannot_read_directory,
    /// Could not look through a symbolic link ("cannot dereference").
    cannot_dereference,
    /// The change itself failed; `cause` says why.
    changing_ownership,
    changing_group,
    /// Reading a directory failed part-way.
    read_failed,
    /// `--preserve-root`: refused to touch "/" recursively.
    dangerous_root,
};

pub const Problem = struct {
    kind: ProblemKind,
    path: []const u8,
    cause: ?anyerror = null,
};

pub const Event = union(enum) {
    change: Change,
    problem: Problem,
};

/// Receives events. Slices in an event are valid only during the call.
pub const Reporter = struct {
    context: ?*anyopaque = null,
    on_event: *const fn (context: ?*anyopaque, event: Event) void,
};

pub const Options = struct {
    /// New owner and group; null leaves that id alone.
    uid: ?u32 = null,
    gid: ?u32 = null,
    /// `--from`: only change files whose current owner / group match.
    required_uid: ?u32 = null,
    required_gid: ?u32 = null,
    recurse: bool = false,
    traversal: Traversal = .physical,
    /// Change what a symbolic link points to (default), not the link itself
    /// (`-h`). With `recurse` and `.physical` traversal the caller sets false.
    dereference: bool = true,
    verbosity: Verbosity = .off,
    /// `-f`: suppress error reports (exit status still reflects failure).
    quiet: bool = false,
    /// Identity of "/" for `--preserve-root`; null disables the check.
    preserve_root: ?fsown.Stat = null,
    /// Names to show for the new owner and group (as typed by the user).
    user_name: ?[]const u8 = null,
    group_name: ?[]const u8 = null,
    /// Used to turn ids into names in `Change` events.
    db: *const userdb.Db,
    reporter: Reporter,
    /// Directory that relative paths are resolved against; null is the
    /// current directory.
    base: ?Io.Dir = null,
};

const max_depth_hint = 4096;

const Engine = struct {
    io: Io,
    gpa: Allocator,
    opts: Options,
    base: Io.Dir,
    /// Display path of the entry being processed ("dir/sub/file").
    path: std.ArrayList(u8) = .empty,
    /// Device/inode of the directories on the way down, for cycle detection.
    ancestors: std.ArrayList(fsown.Stat) = .empty,

    fn emit(e: *Engine, ev: Event) void {
        e.opts.reporter.on_event(e.opts.reporter.context, ev);
    }

    fn problem(e: *Engine, kind: ProblemKind, cause: ?anyerror) void {
        if (e.opts.quiet) return;
        e.emit(.{ .problem = .{ .kind = kind, .path = e.path.items, .cause = cause } });
    }

    fn isRoot(e: *Engine, st: fsown.Stat) bool {
        const root = e.opts.preserve_root orelse return false;
        return st.sameFile(root);
    }

    /// Stat the way the traversal mode says an entry at `level` is examined.
    fn examine(e: *Engine, parent: Io.Dir, name: []const u8, level: usize) fsown.Error!fsown.Stat {
        const follow = switch (e.opts.traversal) {
            .physical => false,
            .command_line => level == 0,
            .logical => true,
        };
        return fsown.statAt(parent, name, follow) catch |err| {
            // A dangling link is still an entry (fts: FTS_SLNONE).
            if (follow and err == error.FileNotFound) return fsown.statAt(parent, name, false) catch err;
            return err;
        };
    }

    /// True when nothing about an entry's current owner is needed: no
    /// `--from`, no report, no dereferencing, no root check, and no -L. Entries
    /// below the top level are then changed straight from the directory
    /// listing's own file type, without a stat of each (GNU's FTS_NOSTAT).
    fn canSkipStat(e: *Engine) bool {
        const o = e.opts;
        return !o.dereference and o.verbosity == .off and o.required_uid == null and
            o.required_gid == null and o.preserve_root == null and o.traversal != .logical;
    }

    /// Fast path of `visit` for an entry known only by its listed type.
    fn visitUnstatted(e: *Engine, parent: Io.Dir, name: []const u8, kind: Io.File.Kind) Allocator.Error!bool {
        var ok = true;
        if (kind == .directory) {
            var dir = parent.openDir(e.io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
                e.problem(.cannot_read_directory, err);
                return false;
            };
            defer dir.close(e.io);
            const base_len = e.path.items.len;
            var it = dir.iterate();
            while (true) {
                const entry = (it.next(e.io) catch |err| {
                    e.problem(.read_failed, err);
                    ok = false;
                    break;
                }) orelse break;
                if (e.path.items.len == 0 or e.path.items[e.path.items.len - 1] != '/') try e.path.append(e.gpa, '/');
                try e.path.appendSlice(e.gpa, entry.name);
                ok = (try e.visitListed(dir, entry)) and ok;
                e.path.shrinkRetainingCapacity(base_len);
            }
        }
        fsown.chownAt(parent, name, e.opts.uid, e.opts.gid, false) catch |err| {
            e.problem(if (e.opts.uid != null) .changing_ownership else .changing_group, err);
            ok = false;
        };
        return ok;
    }

    /// One entry of a directory listing.
    fn visitListed(e: *Engine, parent: Io.Dir, entry: Io.Dir.Entry) Allocator.Error!bool {
        if (e.canSkipStat() and entry.kind != .unknown) return e.visitUnstatted(parent, entry.name, entry.kind);
        return e.visit(parent, entry.name, 1);
    }

    /// Process one entry; for a directory with `recurse`, its contents first.
    fn visit(e: *Engine, parent: Io.Dir, name: []const u8, level: usize) Allocator.Error!bool {
        const st = e.examine(parent, name, level) catch |err| {
            e.problem(.cannot_access, err);
            e.describeUnexamined();
            return false;
        };

        if (!(e.opts.recurse and st.isDir())) return e.changeOwner(parent, name, st, st.isDir());

        if (e.isRoot(st)) {
            e.problem(.dangerous_root, null);
            return false;
        }
        if (e.opts.traversal == .logical) {
            // A link back to a directory we are inside of: GNU (via fts) does
            // not descend and does not warn; the entry is changed like a leaf.
            for (e.ancestors.items) |a| if (a.sameFile(st)) return e.changeOwner(parent, name, st, true);
        }

        const follow_open = switch (e.opts.traversal) {
            .physical => false,
            .command_line => level == 0,
            .logical => true,
        };
        var dir = parent.openDir(e.io, name, .{ .iterate = true, .follow_symlinks = follow_open }) catch |err| {
            e.problem(.cannot_read_directory, err);
            e.describeUnexamined();
            return false;
        };
        defer dir.close(e.io);

        try e.ancestors.append(e.gpa, st);
        defer _ = e.ancestors.pop();

        var ok = true;
        const base_len = e.path.items.len;
        var it = dir.iterate();
        while (true) {
            const entry = (it.next(e.io) catch |err| {
                e.problem(.read_failed, err);
                ok = false;
                break;
            }) orelse break;
            // fts appends "/name", avoiding a doubled slash after "dir/".
            if (e.path.items.len == 0 or e.path.items[e.path.items.len - 1] != '/') try e.path.append(e.gpa, '/');
            try e.path.appendSlice(e.gpa, entry.name);
            ok = (if (level == 0) try e.visitListed(dir, entry) else try e.visit(dir, entry.name, level + 1)) and ok;
            e.path.shrinkRetainingCapacity(base_len);
        }

        // Post-order: the directory itself.
        return (e.changeOwner(parent, name, st, true)) and ok;
    }

    const IdBuf = struct {
        buf: [12]u8 = undefined,
        fn fmt(b: *IdBuf, id: u32) []const u8 {
            return std.fmt.bufPrint(&b.buf, "{d}", .{id}) catch unreachable;
        }
    };

    /// An entry that could not be examined: with -v GNU still reports the
    /// failed attempt, without the old owner.
    fn describeUnexamined(e: *Engine) void {
        if (e.opts.verbosity == .verbose) e.describeChange(null, .failed);
    }

    fn describeChange(e: *Engine, st: ?fsown.Stat, status: ChangeStatus) void {
        var ou: IdBuf = .{};
        var og: IdBuf = .{};
        var nu: IdBuf = .{};
        var ng: IdBuf = .{};
        const db = e.opts.db;
        var old_user: ?[]const u8 = null;
        var old_group: ?[]const u8 = null;
        if (st) |s| {
            old_user = if (db.userById(s.uid)) |pw| pw.name else ou.fmt(s.uid);
            old_group = if (db.groupById(s.gid)) |gr| gr.name else og.fmt(s.gid);
        }
        const new_user: ?[]const u8 = e.opts.user_name orelse if (e.opts.uid) |u| nu.fmt(u) else null;
        const new_group: ?[]const u8 = e.opts.group_name orelse if (e.opts.gid) |g| ng.fmt(g) else null;
        e.emit(.{ .change = .{
            .path = e.path.items,
            .status = status,
            .old_user = old_user,
            .old_group = old_group,
            .new_user = new_user,
            .new_group = new_group,
        } });
    }

    /// GNU `change_file_owner` for a successfully examined entry.
    /// `st` is what the walk saw (the link itself for a symbolic link in
    /// physical mode); `is_dir` says the walk treats the entry as a directory.
    fn changeOwner(e: *Engine, parent: Io.Dir, name: []const u8, st: fsown.Stat, is_dir: bool) bool {
        const o = e.opts;
        var ok = true;
        var file_stats = st;

        // Looking through a symbolic link to learn about its referent.
        if (o.dereference and st.isLink()) {
            if (fsown.statAt(parent, name, true)) |s| {
                file_stats = s;
            } else |err| {
                e.problem(.cannot_dereference, err);
                ok = false;
            }
        }

        var do_chown = ok and
            (o.required_uid == null or o.required_uid.? == file_stats.uid) and
            (o.required_gid == null or o.required_gid.? == file_stats.gid);

        // A symbolic link to "/" reached while walking with -L.
        if (ok and is_dir and e.isRoot(file_stats)) {
            e.problem(.dangerous_root, null);
            return false;
        }

        // Linux can always change a symbolic link's own owner, so the
        // "not applied" outcome GNU has for other systems never arises here.
        const symlink_changed = true;
        if (do_chown) {
            var cause: ?anyerror = null;
            if (!o.dereference) {
                fsown.chownAt(parent, name, o.uid, o.gid, false) catch |err| {
                    ok = false;
                    cause = err;
                };
            } else switch (e.restrictedChown(parent, name, file_stats)) {
                .done => {},
                .ordinary => fsown.chownAt(parent, name, o.uid, o.gid, true) catch |err| {
                    ok = false;
                    cause = err;
                },
                .failed => |err| {
                    ok = false;
                    cause = err;
                },
                .excluded => {
                    do_chown = false;
                    ok = false;
                },
            }
            if (do_chown and !ok) e.problem(if (o.uid != null) .changing_ownership else .changing_group, cause);
        }

        if (o.verbosity != .off) {
            const changed = (do_chown and ok and symlink_changed) and
                !((o.uid == null or o.uid.? == file_stats.uid) and (o.gid == null or o.gid.? == file_stats.gid));
            if (changed or o.verbosity == .verbose) {
                const status: ChangeStatus = if (!ok) .failed else if (!symlink_changed) .not_applied else if (!changed) .no_change_requested else .succeeded;
                e.describeChange(file_stats, status);
            }
        }
        return ok;
    }

    const Restricted = union(enum) { done, ordinary, failed: anyerror, excluded };

    /// With `--from` and a referent that is a regular file or directory, open
    /// it, check that it is still the file that was examined and still matches
    /// the filter, and change it through the descriptor. This closes the window
    /// in which the name could be swapped for a symbolic link to another file
    /// (GNU: `restricted_chown`).
    fn restrictedChown(e: *Engine, parent: Io.Dir, name: []const u8, orig: fsown.Stat) Restricted {
        const o = e.opts;
        if (o.required_uid == null and o.required_gid == null) return .ordinary;
        if (!orig.isReg() and !orig.isDir()) return .ordinary;

        if (orig.isDir()) {
            var d = parent.openDir(e.io, name, .{ .iterate = true }) catch |err| {
                return if (err == error.AccessDenied) .ordinary else .{ .failed = err };
            };
            defer d.close(e.io);
            const now = fsown.statHandle(d.handle) catch |err| return .{ .failed = err };
            if (!now.sameFile(orig)) return .excluded;
            if (!e.stillMatches(now)) return .done;
            d.setOwner(e.io, o.uid, o.gid) catch |err| return .{ .failed = err };
            return .done;
        }

        var f = parent.openFile(e.io, name, .{ .mode = .read_only }) catch |err| blk: {
            if (err != error.AccessDenied) return .{ .failed = err };
            break :blk parent.openFile(e.io, name, .{ .mode = .write_only }) catch |err2| {
                return if (err2 == error.AccessDenied) .ordinary else .{ .failed = err2 };
            };
        };
        defer f.close(e.io);
        const now = fsown.statHandle(f.handle) catch |err| return .{ .failed = err };
        if (!now.sameFile(orig)) return .excluded;
        if (!e.stillMatches(now)) return .done;
        f.setOwner(e.io, o.uid, o.gid) catch |err| return .{ .failed = err };
        return .done;
    }

    fn stillMatches(e: *Engine, st: fsown.Stat) bool {
        return (e.opts.required_uid == null or e.opts.required_uid.? == st.uid) and
            (e.opts.required_gid == null or e.opts.required_gid.? == st.gid);
    }
};

/// Strip surplus trailing slashes the way fts does: "dir//" is shown as
/// "dir/". A lone "/" or "//" is left alone.
fn displayPath(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 2 and path[end - 1] == '/' and path[end - 2] == '/') end -= 1;
    return path[0..end];
}

/// Change ownership of each of `paths`. Returns true when every file was
/// processed without error. Problems and (with `-c`/`-v`) changes are reported
/// through `opts.reporter`; the only error is out-of-memory.
pub fn run(io: Io, gpa: Allocator, opts: Options, paths: []const []const u8) Allocator.Error!bool {
    var e: Engine = .{ .io = io, .gpa = gpa, .opts = opts, .base = opts.base orelse Io.Dir.cwd() };
    defer e.path.deinit(gpa);
    defer e.ancestors.deinit(gpa);
    var ok = true;
    for (paths) |p| {
        e.path.clearRetainingCapacity();
        try e.path.appendSlice(gpa, displayPath(p));
        e.ancestors.clearRetainingCapacity();
        ok = (try e.visit(e.base, p, 0)) and ok;
    }
    return ok;
}

// -- Tests --------------------------------------------------------------------

const testing = std.testing;

const Collector = struct {
    gpa: Allocator,
    lines: std.ArrayList([]u8) = .empty,

    fn deinit(c: *Collector) void {
        for (c.lines.items) |l| c.gpa.free(l);
        c.lines.deinit(c.gpa);
    }

    fn onEvent(context: ?*anyopaque, ev: Event) void {
        const c: *Collector = @ptrCast(@alignCast(context.?));
        const line = switch (ev) {
            .change => |ch| std.fmt.allocPrint(c.gpa, "{t} {s}", .{ ch.status, ch.path }),
            .problem => |p| std.fmt.allocPrint(c.gpa, "problem:{t} {s}", .{ p.kind, p.path }),
        } catch @panic("OOM");
        c.lines.append(c.gpa, line) catch @panic("OOM");
    }

    fn expect(c: *Collector, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len, c.lines.items.len);
        for (expected, c.lines.items) |want, got| try testing.expectEqualStrings(want, got);
    }
};

fn emptyDb() !userdb.Db {
    return userdb.Db.fromText(testing.allocator, "", "");
}

/// Own gid of a file, for building "change to the group it already has" cases.
fn ownGid(dir: Io.Dir, name: []const u8) !u32 {
    return (try fsown.statAt(dir, name, true)).gid;
}

test "recursive walk reports children before their directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "d/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/a", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/sub/b", .data = "" });

    var db = try emptyDb();
    defer db.deinit();
    var col: Collector = .{ .gpa = testing.allocator };
    defer col.deinit();
    const gid = try ownGid(tmp.dir, "d");
    const ok = try run(testing.io, testing.allocator, .{
        .gid = gid,
        .recurse = true,
        .dereference = false,
        .verbosity = .verbose,
        .db = &db,
        .reporter = .{ .context = &col, .on_event = Collector.onEvent },
        .base = tmp.dir,
    }, &.{"d"});
    try testing.expect(ok);
    // Directory-entry order is up to the file system; check the invariants.
    try testing.expectEqual(@as(usize, 4), col.lines.items.len);
    try testing.expectEqualStrings("no_change_requested d", col.lines.items[3]); // last
    for (col.lines.items[0..3]) |l| try testing.expect(std.mem.indexOf(u8, l, "d/") != null);
}

test "--from that does not match leaves the file alone and reports retained" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "" });
    var db = try emptyDb();
    defer db.deinit();
    var col: Collector = .{ .gpa = testing.allocator };
    defer col.deinit();
    const gid = try ownGid(tmp.dir, "f");
    const ok = try run(testing.io, testing.allocator, .{
        .gid = gid,
        .required_gid = gid +% 1, // matches nothing
        .verbosity = .verbose,
        .db = &db,
        .reporter = .{ .context = &col, .on_event = Collector.onEvent },
        .base = tmp.dir,
    }, &.{"f"});
    try testing.expect(ok);
    try col.expect(&.{"no_change_requested f"});
}

test "missing path is reported and makes run return false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try emptyDb();
    defer db.deinit();
    var col: Collector = .{ .gpa = testing.allocator };
    defer col.deinit();
    const ok = try run(testing.io, testing.allocator, .{
        .gid = 0,
        .db = &db,
        .reporter = .{ .context = &col, .on_event = Collector.onEvent },
        .base = tmp.dir,
    }, &.{"nonexistent"});
    try testing.expect(!ok);
    try col.expect(&.{"problem:cannot_access nonexistent"});
}

test "quiet suppresses problems but not the result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try emptyDb();
    defer db.deinit();
    var col: Collector = .{ .gpa = testing.allocator };
    defer col.deinit();
    const ok = try run(testing.io, testing.allocator, .{
        .gid = 0,
        .quiet = true,
        .db = &db,
        .reporter = .{ .context = &col, .on_event = Collector.onEvent },
        .base = tmp.dir,
    }, &.{"nonexistent"});
    try testing.expect(!ok);
    try col.expect(&.{});
}

test "--preserve-root refuses to recurse into the identified directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "d");
    var db = try emptyDb();
    defer db.deinit();
    var col: Collector = .{ .gpa = testing.allocator };
    defer col.deinit();
    const gid = try ownGid(tmp.dir, "d");
    const ok = try run(testing.io, testing.allocator, .{
        .gid = gid,
        .recurse = true,
        .dereference = false,
        .preserve_root = try fsown.statAt(tmp.dir, "d", true), // pretend d is "/"
        .db = &db,
        .reporter = .{ .context = &col, .on_event = Collector.onEvent },
        .base = tmp.dir,
    }, &.{"d"});
    try testing.expect(!ok);
    try col.expect(&.{"problem:dangerous_root d"});
}

test "a symlink back to an ancestor is a leaf, not a loop (-L)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "d");
    try tmp.dir.symLink(testing.io, ".", "d/self", .{});
    var db = try emptyDb();
    defer db.deinit();
    var col: Collector = .{ .gpa = testing.allocator };
    defer col.deinit();
    const gid = try ownGid(tmp.dir, "d");
    const ok = try run(testing.io, testing.allocator, .{
        .gid = gid,
        .recurse = true,
        .traversal = .logical,
        .verbosity = .verbose,
        .db = &db,
        .reporter = .{ .context = &col, .on_event = Collector.onEvent },
        .base = tmp.dir,
    }, &.{"d"});
    try testing.expect(ok);
    try col.expect(&.{ "no_change_requested d/self", "no_change_requested d" });
}

test "displayPath trims surplus trailing slashes" {
    try testing.expectEqualStrings("d/", displayPath("d//"));
    try testing.expectEqualStrings("d/", displayPath("d/"));
    try testing.expectEqualStrings("//", displayPath("//"));
    try testing.expectEqualStrings("d", displayPath("d"));
}
