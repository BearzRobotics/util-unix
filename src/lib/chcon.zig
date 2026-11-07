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
//! printed. The path of each entry is built as text and used with the
//! path-based xattr calls, relative to the current directory.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fsown = @import("fsown.zig");
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
    ancestors: std.ArrayList(fsown.Stat) = .empty,

    fn emit(e: *Engine, ev: Event) void {
        e.opts.reporter.on_event(e.opts.reporter.context, ev);
    }

    fn problem(e: *Engine, kind: ProblemKind, cause: ?anyerror) void {
        e.emit(.{ .problem = .{ .kind = kind, .path = e.path.items, .cause = cause } });
    }

    fn examine(e: *Engine, path: []const u8, level: usize) fsown.Error!fsown.Stat {
        const follow = switch (e.opts.traversal) {
            .physical => false,
            .command_line => level == 0,
            .logical => true,
        };
        const cwd = Io.Dir.cwd();
        return fsown.statAt(cwd, path, follow) catch |err| {
            if (follow and err == error.FileNotFound) return fsown.statAt(cwd, path, false) catch err;
            return err;
        };
    }

    fn visit(e: *Engine, level: usize) Allocator.Error!bool {
        const path = e.path.items;
        const st = e.examine(path, level) catch |err| {
            e.problem(.cannot_access, err);
            return false;
        };
        if (!(e.opts.recurse and st.isDir())) return e.change(st, false);

        if (e.opts.preserve_root) |root| {
            if (st.sameFile(root)) {
                e.problem(.dangerous_root, null);
                return false;
            }
        }
        if (e.opts.traversal == .logical) {
            for (e.ancestors.items) |a| if (a.sameFile(st)) return e.change(st, true);
        }

        const follow_open = switch (e.opts.traversal) {
            .physical => false,
            .command_line => level == 0,
            .logical => true,
        };
        var dir = Io.Dir.cwd().openDir(e.io, path, .{ .iterate = true, .follow_symlinks = follow_open }) catch |err| {
            e.problem(.cannot_read_directory, err);
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
            if (e.path.items.len == 0 or e.path.items[e.path.items.len - 1] != '/') try e.path.append(e.gpa, '/');
            try e.path.appendSlice(e.gpa, entry.name);
            ok = (try e.visit(level + 1)) and ok;
            e.path.shrinkRetainingCapacity(base_len);
        }
        return e.change(st, true) and ok;
    }

    /// Change the context of the current entry.
    fn change(e: *Engine, st: fsown.Stat, is_dir: bool) bool {
        _ = st;
        _ = is_dir;
        const path = e.path.items;
        const follow = e.opts.dereference;
        if (e.opts.verbose) e.emit(.{ .changing = path });

        switch (e.opts.target) {
            .full => |ctx| {
                selinux.setFileContext(path, ctx, follow) catch |err| {
                    e.emit(.{ .problem = .{ .kind = .change_failed, .path = path, .cause = err, .detail = ctx } });
                    return false;
                };
                return true;
            },
            .partial => |comps| {
                const old = selinux.getFileContext(e.gpa, path, follow) catch |err| {
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
                selinux.setFileContext(path, new, follow) catch |err| {
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
    var e: Engine = .{ .io = io, .gpa = gpa, .opts = opts };
    defer e.path.deinit(gpa);
    defer e.ancestors.deinit(gpa);
    var ok = true;
    for (paths) |p| {
        e.path.clearRetainingCapacity();
        try e.path.appendSlice(gpa, displayPath(p));
        e.ancestors.clearRetainingCapacity();
        ok = (try e.visit(0)) and ok;
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
