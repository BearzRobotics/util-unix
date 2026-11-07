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

pub const Verbosity = enum {
    off,
    /// `-c`: report only actual changes.
    changes,
    /// `-v`: report every file processed.
    verbose,
};

/// Which symbolic links to follow while recursing (`-P`, `-H`, `-L`).
pub const Traversal = enum {
    /// `-P`: never follow a symbolic link to a directory.
    physical,
    /// `-H`: follow links named on the command line only.
    command_line,
    /// `-L`: follow every link to a directory.
    logical,
};

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
    /// The change itself failed ("changing permissions of").
    changing_permissions,
    cannot_read_directory,
    /// Reading a directory failed part-way.
    read_failed,
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
    traversal: Traversal = .command_line,
    /// `-h`: do not look through symbolic links (they are then skipped, since
    /// their own mode cannot be changed).
    no_dereference: bool = false,
    verbosity: Verbosity = .off,
    /// `-f`: suppress problem reports (the result still reflects failure).
    quiet: bool = false,
    reporter: Reporter,
    /// Directory that relative paths are resolved against; null is the
    /// current directory.
    base: ?Io.Dir = null,
};

/// True when `path` names the root directory, literally or through links
/// ("/", "//", "/.", a symlink to "/"). For `--preserve-root`.
pub fn isRoot(io: Io, path: []const u8) bool {
    if (path.len > 0 and std.mem.indexOfNone(u8, path, "/") == null) return true;
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return false;
    return std.mem.eql(u8, buf[0..n], "/");
}

/// Process one operand. Returns true when nothing failed. `gpa` holds the
/// display path during a walk.
pub fn run(io: Io, gpa: Allocator, path: []const u8, opts: Options) Allocator.Error!bool {
    var e: Engine = .{ .io = io, .gpa = gpa, .opts = opts };
    defer e.path.deinit(gpa);
    try e.path.appendSlice(gpa, path);
    return e.visit(opts.base orelse Io.Dir.cwd(), path, true);
}

const Engine = struct {
    io: Io,
    gpa: Allocator,
    opts: Options,
    /// Display path of the entry being processed ("dir/sub/file").
    path: std.ArrayList(u8) = .empty,

    fn emit(e: *Engine, ev: Event) void {
        e.opts.reporter.on_event(e.opts.reporter.context, ev);
    }

    fn problem(e: *Engine, kind: ProblemKind, cause: ?anyerror) void {
        if (e.opts.quiet) return;
        e.emit(.{ .problem = .{ .kind = kind, .path = e.path.items, .cause = cause } });
    }

    /// With -v the failed attempt is also named on standard output.
    fn couldNotAccess(e: *Engine) void {
        if (e.opts.verbosity == .verbose) e.emit(.{ .could_not_access = e.path.items });
    }

    fn follows(e: *Engine, is_arg: bool) bool {
        if (e.opts.no_dereference) return false;
        return switch (e.opts.traversal) {
            .physical => false,
            .command_line => is_arg,
            .logical => true,
        };
    }

    /// Change one entry and, with `recurse`, its children. `name` is relative
    /// to `parent`.
    fn visit(e: *Engine, parent: Io.Dir, name: []const u8, is_arg: bool) Allocator.Error!bool {
        const follow = e.follows(is_arg);
        // What the entry itself is, before any link is followed.
        const lst = parent.statFile(e.io, name, .{ .follow_symlinks = false }) catch |err| {
            e.problem(.cannot_access, err);
            e.couldNotAccess();
            return false;
        };
        // Symbolic links met while recursing are skipped unless -L.
        if (lst.kind == .sym_link and !is_arg and e.opts.traversal != .logical) return true;
        const st = if (lst.kind == .sym_link and follow)
            parent.statFile(e.io, name, .{}) catch |err| {
                e.problem(if (err == error.FileNotFound) .dangling_symlink else .cannot_access, err);
                e.couldNotAccess();
                return false;
            }
        else
            lst;
        // chmod cannot change a symlink's own mode: leave it, as GNU does.
        if (lst.kind == .sym_link and !follow) return true;

        var ok = e.apply(parent, name, st, follow);

        if (e.opts.recurse and st.kind == .directory) {
            var dir = parent.openDir(e.io, name, .{ .iterate = true }) catch |err| {
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
                // fts appends "/name", avoiding a doubled slash after "dir/".
                if (e.path.items.len == 0 or e.path.items[e.path.items.len - 1] != '/') try e.path.append(e.gpa, '/');
                try e.path.appendSlice(e.gpa, entry.name);
                ok = (try e.visit(dir, entry.name, false)) and ok;
                e.path.shrinkRetainingCapacity(base_len);
            }
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
                // A directory keeps its set-user-ID and set-group-ID bits
                // unless the mode says so explicitly: octal modes of fewer
                // than five digits and symbolic modes that never mention `s`
                // leave them alone.
                if (is_dir) {
                    const octal = std.ascii.isDigit(t[0]);
                    if ((octal and t.len < 5) or (!octal and std.mem.indexOfScalar(u8, t, 's') == null)) new |= old & 0o6000;
                }
            },
        }

        // Always set, even when the mode looks unchanged: the file system may
        // hold bits stat did not show, and GNU does the same.
        parent.setFilePermissions(e.io, name, .fromMode(new), .{ .follow_symlinks = follow }) catch |err| {
            e.problem(.changing_permissions, err);
            return false;
        };

        switch (e.opts.verbosity) {
            .off => {},
            .changes => if (old != new) e.emit(.{ .changed = .{ .path = e.path.items, .old = old, .new = new } }),
            .verbose => e.emit(.{ .changed = .{ .path = e.path.items, .old = old, .new = new } }),
        }

        // A symbolic mode applied under a umask: bits the user asked for but
        // the umask held back.
        if (text) |t| if (!std.ascii.isDigit(t[0])) {
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

test "recursion is pre-order and skips symlinks met on the way" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(&tmp);
    var log: Log = .{};
    defer log.deinit();
    const opts: Options = .{ .change = .{ .mode_text = "go-rwx" }, .recurse = true, .verbosity = .verbose, .reporter = log.reporter(), .base = tmp.dir };
    try testing.expect(try run(testing.io, testing.allocator, "d", opts));
    try testing.expectEqualStrings("changed d", log.list.items[0][0..9]);
    for (log.list.items) |l| try testing.expect(std.mem.indexOf(u8, l, "link") == null);
    try testing.expectEqual(@as(usize, 4), log.list.items.len); // d, a, sub, sub/b
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
    const opts: Options = .{ .change = .{ .mode_text = "-w" }, .umask = 0o022, .reporter = log.reporter(), .base = tmp.dir };
    // "-w" with no who clears only the bits outside the umask (u+w), so g+w
    // and o+w stay although the user asked for no write bits at all.
    try testing.expect(!try run(testing.io, testing.allocator, "f", opts));
    try testing.expectEqual(@as(u16, 0o466), try modeOf(tmp.dir, "f"));
    try testing.expectEqualStrings("umask f 0466 0444", log.list.items[0]);
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

test "validMode accepts GNU forms and rejects junk" {
    try testing.expect(validMode("755"));
    try testing.expect(validMode("u=rwx,go=rx"));
    try testing.expect(!validMode("999"));
    try testing.expect(!validMode(""));
    try testing.expect(!validMode("u+q"));
}
