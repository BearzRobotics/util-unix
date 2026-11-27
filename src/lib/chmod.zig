// SPDX-License-Identifier: GPL-2.0-or-later
//! Changing file mode bits: the engine behind chmod.
//!
//! References:
//!   - POSIX.1-2024 chmod:
//!     https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html
//!     (-R, -H, -L, -P; the mode grammar is in `mode.zig`).
//!   - GNU coreutils 9.7 manual, "chmod invocation" (-c, -f, -v, -h,
//!     --reference, --preserve-root), and observed GNU 9.7 behaviour
//!     (test/test_chmod.sh). Independent implementation.
//!
//! GNU details kept: symbolic modes without a `who` honour the umask; octal
//! modes of fewer than five digits leave the set-user-ID and set-group-ID bits
//! of a directory alone; symbolic links met while recursing are skipped
//! unless -L; the mode of a symbolic link itself cannot be changed.
//!
//! `run` handles one command-line operand (recursively with `recurse`), works
//! relative to open directories, and reports everything through `Reporter`
//! events. It never prints. A directory is changed before its contents
//! (pre-order, as fts does for chmod).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mode_mod = @import("mode.zig");
const fsown = @import("fsown.zig");
const treewalk = @import("treewalk.zig");

pub const Verbosity = enum {
    off,
    /// `-c`: report only actual changes.
    changes,
    /// `-v`: report every file processed.
    verbose,
};

/// Which symbolic links to follow while walking (`-P`, `-H`, `-L`).
pub const Traversal = treewalk.Traversal;

/// What to change the mode to.
pub const Change = union(enum) {
    /// A `chmod` MODE operand, octal or symbolic. Must satisfy `validMode`.
    mode_text: []const u8,
    /// `--reference`: set exactly these bits.
    fixed: u16,
};

/// True when `text` is a valid MODE operand.
pub fn validMode(text: []const u8) bool {
    return mode_mod.apply(text, 0o644, false, 0) != null;
}

pub const ProblemKind = enum {
    /// Could not examine the path ("cannot access").
    cannot_access,
    /// A symbolic link that points nowhere ("cannot operate on dangling
    /// symlink").
    dangling_symlink,
    /// With `dereference_links`, a link met on the way that names nothing.
    cannot_dereference,
    /// The change itself failed ("changing permissions of").
    changing_permissions,
    cannot_read_directory,
    /// Reading a directory failed part-way.
    read_failed,
    /// What was opened is not the directory that was examined: another process
    /// replaced it during the walk. It is not descended into.
    directory_changed,
    /// `preserve_root`: refused to change or enter "/" recursively. Reported
    /// even with `quiet`.
    dangerous_root,
};

pub const Problem = struct {
    kind: ProblemKind,
    path: []const u8,
    cause: ?anyerror = null,
};

pub const Event = union(enum) {
    /// A file was processed; reported for `-c` (only if the mode differs) and
    /// `-v` (always). `old` and `new` are the permission bits (07777).
    changed: struct { path: []const u8, old: u16, new: u16 },
    /// `-v`: an operand or entry could not be examined.
    could_not_access: []const u8,
    /// `-v`: a symbolic link was left alone, itself and what it names.
    link_skipped: []const u8,
    problem: Problem,
    /// The umask kept a bit the mode asked to clear or set (a failure,
    /// reported after the change was applied). `wanted` is what the mode text
    /// alone would have produced.
    umask_kept: struct { path: []const u8, got: u16, wanted: u16 },
};

/// Receives events. Slices in an event are valid only during the call.
pub const Reporter = struct {
    context: ?*anyopaque = null,
    on_event: *const fn (context: ?*anyopaque, event: Event) void,
};

pub const Options = struct {
    change: Change,
    /// The process umask, used by symbolic modes without a `who`.
    umask: u16 = 0,
    recurse: bool = false,
    /// Identity of "/" for `--preserve-root` (`fsown.statAt(cwd, "/", true)`):
    /// a recursive walk neither changes nor enters that directory, whether it is
    /// the operand or is reached through a link. Null disables the check.
    preserve_root: ?fsown.Stat = null,
    traversal: Traversal = .command_line,
    /// `-h`: do not look through symbolic links (they are then skipped, since
    /// their own mode cannot be changed).
    no_dereference: bool = false,
    verbosity: Verbosity = .off,
    /// `--dereference` given with `recurse`: also change what the links met on
    /// the way name. Which directories are walked is `traversal`'s business.
    dereference_links: bool = false,
    /// Report (and fail on) bits that the umask kept a symbolic mode from
    /// clearing. GNU does so only for a mode given like an option, as in
    /// `chmod -w f`, where it may surprise.
    report_umask: bool = false,
    /// `-f`: suppress problem reports (the result still reflects failure).
    quiet: bool = false,
    reporter: Reporter,
    /// Directory that relative paths are resolved against; null is the
    /// current directory.
    base: ?Io.Dir = null,
};

/// True when `path` names the root directory, however it is spelled ("/", "//",
/// "/.", "/tmp/..", a symlink to "/", a bind mount of it). For
/// `--preserve-root`. On Linux the files are compared by device and inode, which
/// needs no /proc; if "/" itself cannot be examined the answer is yes, so a
/// caller that guards on it fails closed.
pub fn isRoot(io: Io, path: []const u8) bool {
    if (path.len > 0 and std.mem.indexOfNone(u8, path, "/") == null) return true;
    if (fsown.statAt(Io.Dir.cwd(), "/", true)) |root| {
        // a path that cannot be examined is not walked either
        const st = fsown.statAt(Io.Dir.cwd(), path, true) catch return false;
        return st.sameFile(root);
    } else |err| {
        if (err != error.Unsupported) return true;
    }
    // elsewhere, compare resolved path names
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return false;
    return std.mem.eql(u8, buf[0..n], "/");
}

/// Process one operand. Returns true when nothing failed. `gpa` holds the
/// display path during a walk.
pub fn run(io: Io, gpa: Allocator, path: []const u8, opts: Options) Allocator.Error!bool {
    var e: Engine = .{ .io = io, .gpa = gpa, .opts = opts, .stack = .{ .io = io, .gpa = gpa, .base = opts.base orelse Io.Dir.cwd() } };
    defer e.path.deinit(gpa);
    defer e.stack.deinit();
    try e.path.appendSlice(gpa, path);
    return e.walk(path);
}

const Engine = struct {
    io: Io,
    gpa: Allocator,
    opts: Options,
    /// Display path of the entry being processed ("dir/sub/file").
    path: std.ArrayList(u8) = .empty,
    /// The directories the walk is inside.
    stack: treewalk.Stack(void),

    fn emit(e: *Engine, ev: Event) void {
        e.opts.reporter.on_event(e.opts.reporter.context, ev);
    }

    fn problem(e: *Engine, kind: ProblemKind, cause: ?anyerror) void {
        if (e.opts.quiet) return;
        e.emit(.{ .problem = .{ .kind = kind, .path = e.path.items, .cause = cause } });
    }

    /// A directory is gone, or something else is found in its place.
    fn lost(e: *Engine, err: anyerror) void {
        if (err == error.DirectoryChanged) e.problem(.directory_changed, null) else e.problem(.cannot_read_directory, err);
    }

    fn skippedLink(e: *Engine) void {
        if (e.opts.verbosity == .verbose) e.emit(.{ .link_skipped = e.path.items });
    }

    /// With -v the failed attempt is also named on standard output.
    fn couldNotAccess(e: *Engine) void {
        if (e.opts.verbosity == .verbose) e.emit(.{ .could_not_access = e.path.items });
    }

    fn follows(e: *Engine, is_arg: bool) bool {
        if (e.opts.no_dereference) return false;
        // -H, -L and -P say how to recurse; without that they mean nothing
        if (!e.opts.recurse or e.opts.dereference_links) return true;
        return e.opts.traversal.follows(is_arg);
    }

    /// Change the operand `path` and, with `recurse`, everything under it.
    fn walk(e: *Engine, path: []const u8) Allocator.Error!bool {
        var ok = try e.visit(e.stack.base, path, true);
        while (e.stack.depth() > 0) switch (try e.stack.step(&e.path)) {
            .entry => |at| ok = (try e.visit(at.dir, at.entry.name, false)) and ok,
            .lost => |err| {
                e.lost(err);
                ok = false;
                e.stack.pop();
            },
            .leave => |read_error| {
                if (read_error) |err| {
                    e.problem(.read_failed, err);
                    ok = false;
                }
                e.stack.pop();
            },
        };
        return ok;
    }

    /// Change one entry and, with `recurse`, make a directory the next one to
    /// walk. `name` is relative to `parent`.
    fn visit(e: *Engine, parent: Io.Dir, name: []const u8, is_arg: bool) Allocator.Error!bool {
        const follow = e.follows(is_arg);
        // What the entry itself is, before any link is followed.
        const lst = parent.statFile(e.io, name, .{ .follow_symlinks = false }) catch |err| {
            e.problem(.cannot_access, err);
            e.couldNotAccess();
            return false;
        };
        // Symbolic links met while recursing are skipped unless -L.
        const passed_by = !is_arg and e.opts.traversal != .logical;
        if (lst.kind == .sym_link and passed_by and !e.opts.dereference_links) {
            e.skippedLink();
            return true;
        }
        // chmod cannot change a symlink's own mode: leave it, as GNU does.
        // With -h that says nothing about walking: -R still goes through a
        // link to a directory where -H or -L says so.
        const walk_only = lst.kind == .sym_link and !follow;
        if (walk_only) {
            e.skippedLink();
            if (!(e.opts.no_dereference and e.opts.recurse and e.opts.traversal.follows(is_arg))) return true;
            const target = parent.statFile(e.io, name, .{}) catch return true;
            if (target.kind != .directory) return true;
        }
        const st = if (lst.kind == .sym_link)
            parent.statFile(e.io, name, .{}) catch |err| {
                const dangling: ProblemKind = if (passed_by) .cannot_dereference else .dangling_symlink;
                e.problem(if (err == error.FileNotFound) dangling else .cannot_access, err);
                e.couldNotAccess();
                return false;
            }
        else
            lst;
        // Links are looked through only for the operand the user named and for
        // an entry that was a link when examined. Anything else that turns into
        // a link before we act (another process can do that in a directory it
        // may write to) must not lead the change somewhere else.
        const through_link = (follow or walk_only) and (is_arg or lst.kind == .sym_link);
        // a link that is followed only to change what it names is not walked
        const descend = e.opts.recurse and st.kind == .directory and (lst.kind != .sym_link or e.opts.traversal.follows(is_arg));
        // Which directory was examined, to compare with the one opened below.
        // Linux only; elsewhere the no-follow open is the whole protection.
        const examined: ?fsown.Stat = if (descend) fsown.statAt(parent, name, through_link) catch null else null;

        if (descend) if (e.opts.preserve_root) |root| {
            // not knowing which directory this is counts as a refusal
            const seen = examined orelse {
                e.problem(.cannot_access, error.Unexpected);
                return false;
            };
            if (seen.sameFile(root)) {
                e.emit(.{ .problem = .{ .kind = .dangerous_root, .path = e.path.items } });
                return false;
            }
        };

        const ok = walk_only or e.apply(parent, name, st, through_link);

        // A link back to a directory we are inside of: GNU (through fts) does
        // not descend and does not warn; the entry is changed like a leaf.
        // Without this, -L recurses until the stack or the descriptors run out,
        // and with two such links takes practically forever.
        if (examined) |seen| if (e.stack.contains(seen)) return ok;

        if (descend) {
            const dir = e.stack.open(parent, name, through_link) catch |err| {
                e.problem(.cannot_read_directory, err);
                return false;
            };
            if (examined) |before| _ = e.stack.verify(dir, before) catch |err| {
                e.lost(err);
                return false;
            };
            try e.stack.push(dir, name, through_link, examined, e.path.items.len, {});
        }
        return ok;
    }

    /// Compute and set the new mode of one entry whose status is `st`.
    fn apply(e: *Engine, parent: Io.Dir, name: []const u8, st: Io.File.Stat, follow: bool) bool {
        const old: u16 = @intCast(st.permissions.toMode() & 0o7777);
        const is_dir = st.kind == .directory;
        var new: u16 = undefined;
        var text: ?[]const u8 = null;
        switch (e.opts.change) {
            .fixed => |bits| new = bits,
            .mode_text => |t| {
                text = t;
                new = mode_mod.apply(t, old, is_dir, e.opts.umask) orelse unreachable; // checked by validMode
            },
        }

        // Always set, even when the mode looks unchanged: GNU chmod 9.7 calls
        // fchmodat unconditionally (src/chmod.c, process_file).
        parent.setFilePermissions(e.io, name, .fromMode(new), .{ .follow_symlinks = follow }) catch |err| {
            e.problem(.changing_permissions, err);
            return false;
        };

        switch (e.opts.verbosity) {
            .off => {},
            .changes => if (old != new) e.emit(.{ .changed = .{ .path = e.path.items, .old = old, .new = new } }),
            .verbose => e.emit(.{ .changed = .{ .path = e.path.items, .old = old, .new = new } }),
        }

        // Bits the mode asked to clear that the umask made it leave.
        if (text) |t| if (e.opts.report_umask and !std.ascii.isDigit(t[0])) {
            const wanted = mode_mod.apply(t, old, is_dir, 0) orelse unreachable;
            if (new & ~wanted & 0o777 != 0) {
                if (!e.opts.quiet) e.emit(.{ .umask_kept = .{ .path = e.path.items, .got = new, .wanted = wanted } });
                return false;
            }
        };
        return true;
    }
};

// -- tests ---------------------------------------------------------------------

const testing = std.testing;

const Log = struct {
    list: std.ArrayList([]u8) = .empty,

    fn deinit(l: *Log) void {
        for (l.list.items) |s| testing.allocator.free(s);
        l.list.deinit(testing.allocator);
    }

    fn on(ctx: ?*anyopaque, ev: Event) void {
        const l: *Log = @ptrCast(@alignCast(ctx.?));
        const line = switch (ev) {
            .changed => |c| std.fmt.allocPrint(testing.allocator, "changed {s} {o:0>4}->{o:0>4}", .{ c.path, c.old, c.new }),
            .could_not_access => |p| std.fmt.allocPrint(testing.allocator, "noaccess {s}", .{p}),
            .link_skipped => |p| std.fmt.allocPrint(testing.allocator, "skipped {s}", .{p}),
            .problem => |p| std.fmt.allocPrint(testing.allocator, "problem {s} {s}", .{ @tagName(p.kind), p.path }),
            .umask_kept => |u| std.fmt.allocPrint(testing.allocator, "umask {s} {o:0>4} {o:0>4}", .{ u.path, u.got, u.wanted }),
        } catch @panic("oom");
        l.list.append(testing.allocator, line) catch @panic("oom");
    }

    fn reporter(l: *Log) Reporter {
        return .{ .context = l, .on_event = on };
    }
};

fn modeOf(dir: Io.Dir, name: []const u8) !u16 {
    const st = try dir.statFile(testing.io, name, .{});
    return @intCast(st.permissions.toMode() & 0o7777);
}

fn makeTree(tmp: *testing.TmpDir) !void {
    try tmp.dir.createDirPath(testing.io, "d/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/a", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/sub/b", .data = "" });
    try tmp.dir.symLink(testing.io, "a", "d/link", .{});
}

test "octal mode on one file, reported with -v and -c" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "" });
    try tmp.dir.setFilePermissions(testing.io, "f", .fromMode(0o644), .{});
    var log: Log = .{};
    defer log.deinit();
    var opts: Options = .{ .change = .{ .mode_text = "600" }, .verbosity = .verbose, .reporter = log.reporter(), .base = tmp.dir };
    try testing.expect(try run(testing.io, testing.allocator, "f", opts));
    try testing.expectEqual(@as(u16, 0o600), try modeOf(tmp.dir, "f"));
    opts.verbosity = .changes;
    try testing.expect(try run(testing.io, testing.allocator, "f", opts)); // no change: silent
    try testing.expectEqual(@as(usize, 1), log.list.items.len);
    try testing.expectEqualStrings("changed f 0644->0600", log.list.items[0]);
}

test "a traversal choice means nothing without recursion" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "" });
    try tmp.dir.setFilePermissions(testing.io, "f", .fromMode(0o666), .{});
    try tmp.dir.symLink(testing.io, "f", "l", .{});
    var log: Log = .{};
    defer log.deinit();
    const opts: Options = .{ .change = .{ .mode_text = "go-rwx" }, .traversal = .physical, .reporter = log.reporter(), .base = tmp.dir };
    try testing.expect(try run(testing.io, testing.allocator, "l", opts));
    try testing.expectEqual(@as(u16, 0o600), try modeOf(tmp.dir, "f"));
}

test "recursion is pre-order and skips symlinks met on the way" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(&tmp);
    var log: Log = .{};
    defer log.deinit();
    const opts: Options = .{ .change = .{ .mode_text = "go-rwx" }, .recurse = true, .verbosity = .verbose, .reporter = log.reporter(), .base = tmp.dir };
    try testing.expect(try run(testing.io, testing.allocator, "d", opts));
    try testing.expectEqualStrings("changed d", log.list.items[0][0..9]);
    // the link is named once, as left alone, and nothing is changed through it
    var skipped: usize = 0;
    for (log.list.items) |l| {
        if (std.mem.eql(u8, l, "skipped d/link")) skipped += 1 else try testing.expect(std.mem.indexOf(u8, l, "link") == null);
    }
    try testing.expectEqual(@as(usize, 1), skipped);
    try testing.expectEqual(@as(usize, 5), log.list.items.len); // d, a, sub, sub/b, link
}

test "a directory keeps setgid unless the mode names it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "d", .default_dir);
    try tmp.dir.setFilePermissions(testing.io, "d", .fromMode(0o2755), .{});
    var log: Log = .{};
    defer log.deinit();
    var opts: Options = .{ .change = .{ .mode_text = "750" }, .reporter = log.reporter(), .base = tmp.dir };
    try testing.expect(try run(testing.io, testing.allocator, "d", opts));
    try testing.expectEqual(@as(u16, 0o2750), try modeOf(tmp.dir, "d"));
    opts.change = .{ .mode_text = "02750" };
    try testing.expect(try run(testing.io, testing.allocator, "d", opts));
    try testing.expectEqual(@as(u16, 0o2750), try modeOf(tmp.dir, "d"));
    opts.change = .{ .mode_text = "00750" };
    try testing.expect(try run(testing.io, testing.allocator, "d", opts));
    try testing.expectEqual(@as(u16, 0o750), try modeOf(tmp.dir, "d"));
}

test "a missing file is a problem; quiet hides the report but not the failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: Log = .{};
    defer log.deinit();
    var opts: Options = .{ .change = .{ .mode_text = "600" }, .reporter = log.reporter(), .base = tmp.dir };
    try testing.expect(!try run(testing.io, testing.allocator, "nope", opts));
    try testing.expectEqualStrings("problem cannot_access nope", log.list.items[0]);
    opts.quiet = true;
    try testing.expect(!try run(testing.io, testing.allocator, "nope", opts));
    try testing.expectEqual(@as(usize, 1), log.list.items.len);
}

test "the umask leaves bits a symbolic mode asked to clear, and that is a failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "" });
    try tmp.dir.setFilePermissions(testing.io, "f", .fromMode(0o666), .{});
    var log: Log = .{};
    defer log.deinit();
    var opts: Options = .{ .change = .{ .mode_text = "-w" }, .umask = 0o022, .report_umask = true, .reporter = log.reporter(), .base = tmp.dir };
    // "-w" with no who clears only the bits outside the umask (u+w), so g+w
    // and o+w stay although the user asked for no write bits at all.
    try testing.expect(!try run(testing.io, testing.allocator, "f", opts));
    try testing.expectEqual(@as(u16, 0o466), try modeOf(tmp.dir, "f"));
    try testing.expectEqualStrings("umask f 0466 0444", log.list.items[0]);
    // not asked for: nothing to say
    opts.report_umask = false;
    try testing.expect(try run(testing.io, testing.allocator, "f", opts));
    try testing.expectEqual(@as(usize, 1), log.list.items.len);
}

test "--reference style fixed bits and a dangling link argument" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "" });
    try tmp.dir.symLink(testing.io, "nowhere", "dang", .{});
    var log: Log = .{};
    defer log.deinit();
    var opts: Options = .{ .change = .{ .fixed = 0o640 }, .reporter = log.reporter(), .base = tmp.dir };
    try testing.expect(try run(testing.io, testing.allocator, "f", opts));
    try testing.expectEqual(@as(u16, 0o640), try modeOf(tmp.dir, "f"));
    try testing.expect(!try run(testing.io, testing.allocator, "dang", opts));
    try testing.expectEqualStrings("problem dangling_symlink dang", log.list.items[0]);
    opts.no_dereference = true; // -h: the link itself, silently left alone
    try testing.expect(try run(testing.io, testing.allocator, "dang", opts));
}

/// Replaces the directory `tree/sub` the moment its change is reported, which is
/// after the walk examined and changed it and before it opens it.
const Swap = struct {
    dir: Io.Dir,
    with: enum { link, other_directory },
    done: bool = false,

    fn on(ctx: ?*anyopaque, ev: Event) void {
        const s: *Swap = @ptrCast(@alignCast(ctx.?));
        if (s.done or ev != .changed or !std.mem.eql(u8, ev.changed.path, "tree/sub")) return;
        s.done = true;
        s.dir.rename("tree/sub", s.dir, "moved", testing.io) catch @panic("rename");
        switch (s.with) {
            .link => s.dir.symLink(testing.io, "../victim", "tree/sub", .{}) catch @panic("symlink"),
            .other_directory => s.dir.rename("victim", s.dir, "tree/sub", testing.io) catch @panic("rename"),
        }
    }
};

fn expectSwapContained(traversal: Traversal, with: @TypeOf(@as(Swap, undefined).with)) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "tree/sub");
    try tmp.dir.createDir(testing.io, "victim", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "victim/secret", .data = "" });
    try tmp.dir.setFilePermissions(testing.io, "victim/secret", .fromMode(0o600), .{});
    var swap: Swap = .{ .dir = tmp.dir, .with = with };
    const ok = try run(testing.io, testing.allocator, "tree", .{
        .change = .{ .fixed = 0o755 },
        .recurse = true,
        .traversal = traversal,
        .verbosity = .verbose,
        .reporter = .{ .context = &swap, .on_event = Swap.on },
        .base = tmp.dir,
    });
    try testing.expect(swap.done);
    try testing.expect(!ok);
    const secret = if (with == .link) "victim/secret" else "tree/sub/secret";
    try testing.expectEqual(@as(u16, 0o600), try modeOf(tmp.dir, secret));
}

test "a subdirectory swapped for a symlink during the walk is not followed" {
    try expectSwapContained(.command_line, .link);
    try expectSwapContained(.physical, .link);
    // under -L too: the entry examined was a directory, not a link
    try expectSwapContained(.logical, .link);
}

test "a subdirectory swapped for another directory during the walk is not entered" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try expectSwapContained(.command_line, .other_directory);
}

test "isRoot recognises every spelling of the root directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "/", "//", "/.", "/..", "/./.", "/tmp/.." }) |path| try testing.expect(isRoot(testing.io, path));
    for ([_][]const u8{ "/tmp", ".", "/nonexistent-zz", "" }) |path| try testing.expect(!isRoot(testing.io, path));
}

test "preserve_root stops the walk at that directory however it is reached" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "tree");
    try tmp.dir.createDir(testing.io, "other", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other/canary", .data = "" });
    try tmp.dir.setFilePermissions(testing.io, "other/canary", .fromMode(0o600), .{});
    try tmp.dir.setFilePermissions(testing.io, "other", .fromMode(0o700), .{});
    try tmp.dir.symLink(testing.io, "../other", "tree/link", .{});
    var log: Log = .{};
    defer log.deinit();
    var opts: Options = .{
        .change = .{ .fixed = 0o755 },
        .recurse = true,
        .traversal = .logical,
        .quiet = true, // the refusal is reported all the same
        .preserve_root = try fsown.statAt(tmp.dir, "other", true), // pretend it is "/"
        .reporter = log.reporter(),
        .base = tmp.dir,
    };
    for ([_][]const u8{ "tree", "other" }) |operand| {
        try testing.expect(!try run(testing.io, testing.allocator, operand, opts));
        try testing.expectEqual(@as(u16, 0o700), try modeOf(tmp.dir, "other"));
        try testing.expectEqual(@as(u16, 0o600), try modeOf(tmp.dir, "other/canary"));
    }
    try testing.expectEqualStrings("problem dangerous_root tree/link", log.list.items[0]);
    try testing.expectEqualStrings("problem dangerous_root other", log.list.items[1]);
    // without recursion the directory itself may be changed
    opts.recurse = false;
    try testing.expect(try run(testing.io, testing.allocator, "other", opts));
}

test "-L does not descend into a directory it is already inside" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "d/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/sub/b", .data = "" });
    try tmp.dir.symLink(testing.io, ".", "d/self", .{});
    try tmp.dir.symLink(testing.io, "..", "d/sub/up", .{});
    var log: Log = .{};
    defer log.deinit();
    try testing.expect(try run(testing.io, testing.allocator, "d", .{
        .change = .{ .fixed = 0o755 },
        .recurse = true,
        .traversal = .logical,
        .verbosity = .verbose,
        .reporter = log.reporter(),
        .base = tmp.dir,
    }));
    // d, self, sub, sub/b, sub/up: each once
    try testing.expectEqual(@as(usize, 5), log.list.items.len);
}

test "validMode accepts GNU forms and rejects junk" {
    try testing.expect(validMode("755"));
    try testing.expect(validMode("u=rwx,go=rx"));
    try testing.expect(!validMode("999"));
    try testing.expect(!validMode(""));
    try testing.expect(!validMode("u+q"));
}
