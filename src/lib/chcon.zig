// SPDX-License-Identifier: GPL-2.0-or-later
//! Changing the SELinux security context of files: the engine behind chcon.
//!
//! References: GNU coreutils 9.7 manual, "chcon invocation"; selinux(8);
//! setxattr(2). The upstream source of GNU chcon was not consulted: the order
//! of operations and the messages were derived by running GNU chcon on files in
//! a scratch directory (test/test_chcon.sh), where `security.selinux` is an
//! ordinary extended attribute because the host kernel has no SELinux.
//!
//! Like ownership, the walk handles a directory's contents before the
//! directory itself. Everything is reported through `Reporter`; nothing is
//! printed.
//!
//! The operand is used by its path. Everything below it is reached relative to
//! open directories: each entry is opened with `O_PATH`, checked to be the file
//! that was examined, and its attribute is read and set through
//! `/proc/self/fd`, so that renaming or replacing a directory during the walk
//! cannot send a change somewhere else. A recursive walk therefore needs /proc.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fsown = @import("fsown.zig");
const treewalk = @import("treewalk.zig");
const selinux = @import("selinux.zig");

pub const Traversal = enum { physical, command_line, logical };

/// What the new context is.
pub const Target = union(enum) {
    /// A complete context, stored as given.
    full: []const u8,
    /// Components to substitute into each file's current context.
    partial: selinux.Components,
};

pub const ProblemKind = enum {
    cannot_access,
    cannot_read_directory,
    read_failed,
    dangerous_root,
    /// The file has no context, so a partial one cannot be applied.
    unlabeled,
    /// Could not read the file's current context (`cause`).
    get_failed,
    /// The current context is not `user:role:type[:range]` (`detail` is it).
    create_failed,
    /// A new component is invalid; `component` says which and `detail` is the value.
    set_component_failed,
    /// Storing the context failed (`cause`); `detail` is the context.
    change_failed,
    /// What was opened is not what was examined: another process replaced it
    /// during the walk. It is neither changed nor entered.
    file_changed,
    /// An entry below the operand cannot be changed safely without
    /// /proc/self/fd.
    proc_unavailable,
};

pub const Problem = struct {
    kind: ProblemKind,
    path: []const u8,
    cause: ?anyerror = null,
    detail: []const u8 = "",
    component: ?selinux.Which = null,
};

pub const Event = union(enum) {
    /// Verbose only: about to change `path`.
    changing: []const u8,
    problem: Problem,
};

pub const Reporter = struct {
    context: ?*anyopaque = null,
    on_event: *const fn (context: ?*anyopaque, event: Event) void,
};

pub const Options = struct {
    target: Target,
    recurse: bool = false,
    traversal: Traversal = .physical,
    /// Change what a symbolic link points to (default), not the link itself.
    dereference: bool = true,
    verbose: bool = false,
    /// Identity of "/" for `--preserve-root`; null disables the check.
    preserve_root: ?fsown.Stat = null,
    reporter: Reporter,
};

const Engine = struct {
    io: Io,
    gpa: Allocator,
    opts: Options,
    path: std.ArrayList(u8) = .empty,
    /// The directories the walk is inside; each keeps what to change on the
    /// way out.
    stack: treewalk.Stack(Pending),

    /// A `Subject` without the handle and name, which the stack supplies.
    const Pending = struct { follow: bool, identity: ?fsown.Stat };

    fn emit(e: *Engine, ev: Event) void {
        e.opts.reporter.on_event(e.opts.reporter.context, ev);
    }

    fn problem(e: *Engine, kind: ProblemKind, cause: ?anyerror) void {
        e.emit(.{ .problem = .{ .kind = kind, .path = e.path.items, .cause = cause } });
    }

    fn examine(e: *Engine, parent: Io.Dir, name: []const u8, level: usize) fsown.Error!fsown.Stat {
        const follow = switch (e.opts.traversal) {
            .physical => false,
            .command_line => level == 0,
            .logical => true,
        };
        return fsown.statAt(parent, name, follow) catch |err| {
            if (follow and err == error.FileNotFound) return fsown.statAt(parent, name, false) catch err;
            return err;
        };
    }

    /// Which file a change of `name` is meant for, as found before anything
    /// else happens to it.
    const Subject = struct {
        parent: Io.Dir,
        name: []const u8,
        level: usize,
        /// Look through a final link when changing: only where it was one.
        follow: bool,
        /// Null when it cannot be examined (a dangling link to be followed).
        identity: ?fsown.Stat,
    };

    fn subject(e: *Engine, parent: Io.Dir, name: []const u8, level: usize) Subject {
        var follow = e.opts.dereference;
        if (level > 0 and follow) {
            follow = if (fsown.statAt(parent, name, false)) |own| own.isLink() else |_| false;
        }
        return .{ .parent = parent, .name = name, .level = level, .follow = follow, .identity = if (level > 0) fsown.statAt(parent, name, follow) catch null else null };
    }

    /// Change the operand `path` and, with `recurse`, everything under it, a
    /// directory's contents before the directory.
    fn walk(e: *Engine, path: []const u8) Allocator.Error!bool {
        var ok = try e.visit(e.stack.base, path, 0);
        while (e.stack.depth() > 0) {
            const top = e.stack.top();
            e.path.shrinkRetainingCapacity(top.path_len);
            const dir = e.stack.topDir() catch |err| {
                e.lost(err);
                ok = false;
                e.stack.pop();
                continue;
            };
            if (top.nextEntry()) |entry| {
                if (e.path.items.len == 0 or e.path.items[e.path.items.len - 1] != '/') try e.path.append(e.gpa, '/');
                try e.path.appendSlice(e.gpa, entry.name);
                ok = (try e.visit(dir, entry.name, e.stack.depth())) and ok;
                continue;
            }
            if (top.read_error) |err| {
                e.problem(.read_failed, err);
                ok = false;
            }
            if (e.stack.parentDir()) |parent| {
                ok = e.change(.{
                    .parent = parent,
                    .name = top.name,
                    .level = e.stack.depth() - 1,
                    .follow = top.data.follow,
                    .identity = top.data.identity,
                }) and ok;
            } else |err| {
                e.lost(err);
                ok = false;
            }
            e.stack.pop();
        }
        return ok;
    }

    /// A directory the walk had to open again is gone.
    fn lost(e: *Engine, err: anyerror) void {
        if (err == error.DirectoryChanged) e.problem(.file_changed, null) else e.problem(.cannot_read_directory, err);
    }

    /// `name` is relative to `parent`; `e.path` is the same entry for display.
    fn visit(e: *Engine, parent: Io.Dir, name: []const u8, level: usize) Allocator.Error!bool {
        const target = e.subject(parent, name, level);
        const st = e.examine(parent, name, level) catch |err| {
            e.problem(.cannot_access, err);
            return false;
        };
        if (!(e.opts.recurse and st.isDir())) return e.change(target);

        if (e.opts.preserve_root) |root| {
            if (st.sameFile(root)) {
                e.problem(.dangerous_root, null);
                return false;
            }
        }
        if (e.opts.traversal == .logical) {
            if (e.stack.contains(st)) return e.change(target);
        }

        const follow_open = switch (e.opts.traversal) {
            .physical => false,
            .command_line => level == 0,
            .logical => true,
        };
        const dir = e.stack.open(parent, name, follow_open) catch |err| {
            e.problem(.cannot_read_directory, err);
            return false;
        };
        const opened = fsown.statHandle(dir.handle) catch |err| {
            dir.close(e.io);
            e.problem(.cannot_read_directory, err);
            return false;
        };
        if (!opened.sameFile(st)) {
            dir.close(e.io);
            e.problem(.file_changed, null);
            return false;
        }
        try e.stack.push(dir, name, follow_open, st, e.path.items.len, .{ .follow = target.follow, .identity = target.identity });
        return true;
    }

    /// Change the context of the current entry.
    fn change(e: *Engine, target: Subject) bool {
        const path = e.path.items;
        if (e.opts.verbose) e.emit(.{ .changing = path });

        // What the attribute calls are given: the operand's own path, or below
        // it the magic link of a descriptor for the file that was examined.
        var at: []const u8 = path;
        var follow = target.follow;
        var proc_buf: [32]u8 = undefined;
        var handle: ?std.posix.fd_t = null;
        defer if (handle) |h| fsown.closeHandle(h);
        if (target.level > 0) {
            const h = fsown.openPath(target.parent, target.name, target.follow) catch |err| {
                if (e.opts.target == .full) {
                    e.emit(.{ .problem = .{ .kind = .change_failed, .path = path, .cause = err, .detail = e.opts.target.full } });
                } else e.problem(.get_failed, err);
                return false;
            };
            handle = h;
            const now = fsown.statHandle(h) catch null;
            if (now == null or target.identity == null or !now.?.sameFile(target.identity.?)) {
                e.problem(.file_changed, null);
                return false;
            }
            at = std.fmt.bufPrint(&proc_buf, "/proc/self/fd/{d}", .{h}) catch unreachable; // an i32 fits
            _ = fsown.statAt(Io.Dir.cwd(), at, false) catch {
                e.problem(.proc_unavailable, null);
                return false;
            };
            follow = true; // the magic link itself; it stops at the opened file
        }

        switch (e.opts.target) {
            .full => |ctx| {
                selinux.setFileContext(at, ctx, follow) catch |err| {
                    e.emit(.{ .problem = .{ .kind = .change_failed, .path = path, .cause = err, .detail = ctx } });
                    return false;
                };
                return true;
            },
            .partial => |comps| {
                const old = selinux.getFileContext(e.gpa, at, follow) catch |err| {
                    if (err == error.NoContext) {
                        e.problem(.unlabeled, null);
                    } else {
                        e.problem(.get_failed, err);
                    }
                    return false;
                };
                defer e.gpa.free(old);
                var diag: selinux.Edit = .{};
                const new = selinux.edit(e.gpa, old, comps, &diag) catch |err| {
                    switch (err) {
                        error.BadContext => e.emit(.{ .problem = .{ .kind = .create_failed, .path = path, .cause = error.InvalidArgument, .detail = old } }),
                        error.BadComponent => {
                            const which = diag.bad.?;
                            const value = switch (which) {
                                .user => comps.user.?,
                                .role => comps.role.?,
                                .type => comps.type.?,
                                .range => comps.range.?,
                            };
                            e.emit(.{ .problem = .{ .kind = .set_component_failed, .path = path, .cause = error.InvalidArgument, .detail = value, .component = which } });
                        },
                        error.OutOfMemory => e.problem(.change_failed, error.OutOfMemory),
                    }
                    return false;
                };
                defer e.gpa.free(new);
                selinux.setFileContext(at, new, follow) catch |err| {
                    e.emit(.{ .problem = .{ .kind = .change_failed, .path = path, .cause = err, .detail = new } });
                    return false;
                };
                return true;
            },
        }
    }
};

/// Strip surplus trailing slashes the way fts does ("dir//" is shown "dir/").
fn displayPath(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 2 and path[end - 1] == '/' and path[end - 2] == '/') end -= 1;
    return path[0..end];
}

/// Change the context of each of `paths`. True when every file was processed
/// without a problem; the only error is out-of-memory.
pub fn run(io: Io, gpa: Allocator, opts: Options, paths: []const []const u8) Allocator.Error!bool {
    var e: Engine = .{ .io = io, .gpa = gpa, .opts = opts, .stack = .{ .io = io, .gpa = gpa, .base = Io.Dir.cwd() } };
    defer e.path.deinit(gpa);
    defer e.stack.deinit();
    var ok = true;
    for (paths) |p| {
        e.path.clearRetainingCapacity();
        try e.path.appendSlice(gpa, displayPath(p));
        ok = (try e.walk(p)) and ok;
    }
    return ok;
}

test "setting a full context on a file and a partial one after it" {
    const t = std.testing;
    if (!selinux.is_linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(t.io, "f", .{});
    f.close(t.io);
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(t.io, "f", &buf);
    const path = buf[0..n];

    const Sink = struct {
        problems: usize = 0,
        fn on(context: ?*anyopaque, ev: Event) void {
            const s: *@This() = @ptrCast(@alignCast(context.?));
            if (ev == .problem) s.problems += 1;
        }
    };
    var sink: Sink = .{};
    const rep: Reporter = .{ .context = &sink, .on_event = Sink.on };
    const ok = try run(t.io, t.allocator, .{ .target = .{ .full = "u:r:t:s0" }, .reporter = rep }, &.{path});
    if (!ok) return error.SkipZigTest; // this file system refuses security.* for us
    try t.expect(try run(t.io, t.allocator, .{ .target = .{ .partial = .{ .type = "nt" } }, .reporter = rep }, &.{path}));
    const got = try selinux.getFileContext(t.allocator, path, true);
    defer t.allocator.free(got);
    try t.expectEqualStrings("u:r:nt:s0", got);
    try t.expectEqual(@as(usize, 0), sink.problems);
}
