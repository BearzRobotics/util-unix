// SPDX-License-Identifier: GPL-2.0-or-later
//! What the recursive walks of chmod, chown/chgrp and chcon share: the
//! directory stack, the step from one entry to the next, which links to follow,
//! the path shown to the user, and the check that what was opened is what was
//! examined.
//!
//! A walk must survive any depth of tree, which any user can create. So the
//! stack lives on the heap (no recursion), and only a bounded number of the
//! directories on it are held open. A directory that was closed is opened again
//! when the walk comes back to it, through ".." of the child being left or, when
//! that does not lead there (the child was reached through a symbolic link), by
//! name from the nearest directory still open. Either way what was opened must
//! have the device and inode seen the first time, so a tree rearranged during
//! the walk cannot lead it elsewhere. The same idea as fts(3).
//!
//! A directory's names are read in full when it is pushed, since a read position
//! does not survive closing the directory.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fsown = @import("fsown.zig");

/// How many directories of the stack stay open, when descriptors allow it.
pub const default_max_open = 32;

pub const Entry = struct { name: []const u8, kind: Io.File.Kind };

/// Which symbolic links to follow while walking (`-P`, `-H`, `-L`).
pub const Traversal = enum {
    /// `-P`: never follow a symbolic link to a directory.
    physical,
    /// `-H`: follow links named on the command line only.
    command_line,
    /// `-L`: follow every link to a directory.
    logical,

    /// Whether a link is followed; `operand` says it was named by the caller
    /// and not found in a directory.
    pub fn follows(t: Traversal, operand: bool) bool {
        return switch (t) {
            .physical => false,
            .command_line => operand,
            .logical => true,
        };
    }
};

/// An operand as it is shown: surplus trailing slashes are stripped the way
/// fts does it ("dir//" is shown "dir/"). A lone "/" or "//" is left alone.
pub fn displayPath(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 2 and path[end - 1] == '/' and path[end - 2] == '/') end -= 1;
    return path[0..end];
}

/// A walk reports a failed call and goes on, but a request to cancel is
/// delivered only once: if `err` is that, make it be delivered again. The walk
/// then ends at its next `checkCancel`.
pub fn keepCancel(io: Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
}

/// What a walk does next, in the innermost directory.
pub const Step = union(enum) {
    /// The directory could not be opened again (`error.DirectoryChanged` when
    /// something else is found in its place). Report it and `pop`.
    lost: anyerror,
    /// Visit this entry of `dir`.
    entry: struct { dir: Io.Dir, entry: Entry },
    /// All entries are done. Holds the error if reading them was cut short.
    /// Do what is due on leaving, then `pop`.
    leave: ?anyerror,
};

/// `Data` is whatever the walk wants to keep for each directory.
pub fn Stack(comptime Data: type) type {
    return struct {
        const Self = @This();

        pub const Frame = struct {
            /// Null while closed to save descriptors.
            dir: ?Io.Dir,
            /// Name relative to the parent frame (to `base` for the first).
            /// Borrowed: it must live as long as the frame does.
            name: []const u8,
            /// A final symbolic link was followed to open it.
            follow: bool,
            /// Null where it cannot be known; such a frame is never closed.
            identity: ?fsown.Stat,
            /// Length of the walk's display path when it names this directory.
            path_len: usize,
            data: Data,
            names: []u8,
            entries: []Entry,
            next: usize = 0,
            /// Reading the directory failed after `entries`.
            read_error: ?anyerror,

            pub fn nextEntry(f: *Frame) ?Entry {
                if (f.next == f.entries.len) return null;
                defer f.next += 1;
                return f.entries[f.next];
            }
        };

        io: Io,
        gpa: Allocator,
        base: Io.Dir,
        max_open: usize = default_max_open,
        frames: std.ArrayList(Frame) = .empty,
        open_count: usize = 0,
        /// No frame below this index can be closed to free a descriptor.
        first_open: usize = 0,

        pub fn deinit(s: *Self) void {
            while (s.frames.items.len > 0) s.discard();
            s.frames.deinit(s.gpa);
        }

        pub fn depth(s: *const Self) usize {
            return s.frames.items.len;
        }

        /// The innermost directory. The pointer is good until the next `push`.
        pub fn top(s: *Self) *Frame {
            return &s.frames.items[s.frames.items.len - 1];
        }

        /// True when the directory `st` is one the walk is inside.
        pub fn contains(s: *const Self, st: fsown.Stat) bool {
            for (s.frames.items) |f| if (f.identity) |id| if (id.sameFile(st)) return true;
            return false;
        }

        /// Open a directory for the walk, closing others of the stack (never
        /// the innermost, which the caller is usually working in) if the
        /// process has run out of descriptors.
        pub fn open(s: *Self, parent: Io.Dir, name: []const u8, follow: bool) Io.Dir.OpenError!Io.Dir {
            return s.openKeeping(parent, name, follow, null);
        }

        fn openKeeping(s: *Self, parent: Io.Dir, name: []const u8, follow: bool, keep: ?usize) Io.Dir.OpenError!Io.Dir {
            while (true) {
                return parent.openDir(s.io, name, .{ .iterate = true, .follow_symlinks = follow }) catch |err| switch (err) {
                    error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => {
                        if (s.closeOne(keep)) continue;
                        return err;
                    },
                    else => return err,
                };
            }
        }

        /// Make `dir`, already open, the innermost directory and read its names.
        /// The stack closes `dir`, also when this fails.
        pub fn push(s: *Self, dir: Io.Dir, name: []const u8, follow: bool, identity: ?fsown.Stat, path_len: usize, data: Data) (Allocator.Error || Io.Cancelable)!void {
            var frame: Frame = .{
                .dir = dir,
                .name = name,
                .follow = follow,
                .identity = identity,
                .path_len = path_len,
                .data = data,
                .names = &.{},
                .entries = &.{},
                .read_error = null,
            };
            errdefer dir.close(s.io);

            var names: std.ArrayList(u8) = .empty;
            defer names.deinit(s.gpa);
            const Span = struct { len: usize, kind: Io.File.Kind };
            var spans: std.ArrayList(Span) = .empty;
            defer spans.deinit(s.gpa);
            var it = dir.iterate();
            while (true) {
                const entry = (it.next(s.io) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    frame.read_error = err;
                    break;
                }) orelse break;
                try names.appendSlice(s.gpa, entry.name);
                try spans.append(s.gpa, .{ .len = entry.name.len, .kind = entry.kind });
            }

            try s.frames.ensureUnusedCapacity(s.gpa, 1);
            frame.entries = try s.gpa.alloc(Entry, spans.items.len);
            errdefer s.gpa.free(frame.entries);
            frame.names = try names.toOwnedSlice(s.gpa);
            var at: usize = 0;
            for (frame.entries, spans.items) |*e, span| {
                e.* = .{ .name = frame.names[at..][0..span.len], .kind = span.kind };
                at += span.len;
            }
            s.frames.appendAssumeCapacity(frame);
            s.open_count += 1;
            s.trim(null);
        }

        /// The innermost directory's handle, opening it again if needed. It
        /// stays good until the next `push` or `pop`.
        pub fn topDir(s: *Self) anyerror!Io.Dir {
            const i = s.frames.items.len - 1;
            return s.frames.items[i].dir orelse s.reopen(i);
        }

        /// Take the walk's next step. `path` is its display path, which is set
        /// to name the entry returned, or else the innermost directory.
        pub fn step(s: *Self, path: *std.ArrayList(u8)) Allocator.Error!Step {
            const frame = s.top();
            path.shrinkRetainingCapacity(frame.path_len);
            const dir = s.topDir() catch |err| return .{ .lost = err };
            const entry = frame.nextEntry() orelse return .{ .leave = frame.read_error };
            // fts appends "/name", avoiding a doubled slash after "dir/".
            if (path.items.len == 0 or path.items[path.items.len - 1] != '/') try path.append(s.gpa, '/');
            try path.appendSlice(s.gpa, entry.name);
            return .{ .entry = .{ .dir = dir, .entry = entry } };
        }

        /// Require the just opened `dir` to be the file `examined`, and return
        /// its status. `dir` is closed when this fails.
        pub fn verify(s: *Self, dir: Io.Dir, examined: ?fsown.Stat) !fsown.Stat {
            errdefer dir.close(s.io);
            const opened = try fsown.statHandle(dir.handle);
            if (examined) |before| if (!opened.sameFile(before)) return error.DirectoryChanged;
            return opened;
        }

        /// The handle that the innermost directory's `name` is relative to.
        pub fn parentDir(s: *Self) anyerror!Io.Dir {
            if (s.frames.items.len == 1) return s.base;
            const i = s.frames.items.len - 2;
            return s.frames.items[i].dir orelse s.reopen(i);
        }

        /// Leave the innermost directory.
        pub fn pop(s: *Self) void {
            // While the child is still open, ".." is the cheap way back. If it
            // fails, `topDir` tries again by name and reports.
            const n = s.frames.items.len;
            if (n >= 2 and s.frames.items[n - 2].dir == null) {
                _ = s.reopen(n - 2) catch |err| keepCancel(s.io, err);
            }
            s.discard();
        }

        fn discard(s: *Self) void {
            const frame = s.frames.pop().?;
            if (frame.dir) |d| {
                d.close(s.io);
                s.open_count -= 1;
            }
            s.gpa.free(frame.entries);
            s.gpa.free(frame.names);
            s.first_open = @min(s.first_open, s.frames.items.len -| 1);
        }

        /// Close the outermost directory that can be closed, other than the
        /// innermost and `keep`.
        fn closeOne(s: *Self, keep: ?usize) bool {
            var i = s.first_open;
            while (i + 1 < s.frames.items.len) : (i += 1) {
                const f = &s.frames.items[i];
                const closable = f.dir != null and f.identity != null;
                if (closable and i != keep) {
                    f.dir.?.close(s.io);
                    f.dir = null;
                    s.open_count -= 1;
                    return true;
                }
                if (!closable and i == s.first_open) s.first_open += 1;
            }
            return false;
        }

        fn trim(s: *Self, keep: ?usize) void {
            while (s.open_count > s.max_open) if (!s.closeOne(keep)) return;
        }

        /// Open `name` and require it to be the directory of frame `k`.
        fn openSame(s: *Self, parent: Io.Dir, name: []const u8, follow: bool, k: usize, keep: ?usize) anyerror!Io.Dir {
            const dir = try s.openKeeping(parent, name, follow, keep);
            _ = try s.verify(dir, s.frames.items[k].identity.?);
            return dir;
        }

        fn adopt(s: *Self, i: usize, dir: Io.Dir) void {
            s.frames.items[i].dir = dir;
            s.open_count += 1;
            s.first_open = @min(s.first_open, i);
        }

        fn reopen(s: *Self, i: usize) anyerror!Io.Dir {
            const frames = s.frames.items;
            if (i + 1 < frames.len) if (frames[i + 1].dir) |child| {
                // `keep`: do not close the child we are going through
                if (s.openSame(child, "..", false, i, i + 1)) |dir| {
                    s.adopt(i, dir);
                    s.trim(i);
                    return dir;
                } else |_| {}
            };

            // By name, from the nearest directory still open.
            var k = i;
            while (k > 0 and frames[k - 1].dir == null) k -= 1;
            var from: Io.Dir = if (k == 0) s.base else frames[k - 1].dir.?;
            var anchor: ?usize = if (k == 0) null else k - 1;
            // a handle on the way that no frame keeps
            var loose: ?Io.Dir = null;
            defer if (loose) |d| d.close(s.io);
            while (k <= i) : (k += 1) {
                const dir = try s.openSame(from, frames[k].name, frames[k].follow, k, anchor);
                if (loose) |d| d.close(s.io);
                loose = null;
                from = dir;
                // keep the last few, which the walk will want next
                if (i - k < @max(1, s.max_open / 2)) {
                    s.adopt(k, dir);
                    anchor = k;
                    s.trim(k);
                } else {
                    loose = dir;
                    anchor = null;
                }
            }
            return from;
        }
    };
}

// -- tests ---------------------------------------------------------------------

const testing = std.testing;

test "displayPath trims surplus trailing slashes" {
    try testing.expectEqualStrings("d/", displayPath("d//"));
    try testing.expectEqualStrings("d/", displayPath("d/"));
    try testing.expectEqualStrings("//", displayPath("//"));
    try testing.expectEqualStrings("d", displayPath("d"));
}

/// Push `path`'s directories one at a time, as a walk would.
fn descend(s: *Stack(void), names: []const []const u8, follow: bool) !void {
    for (names) |name| {
        const parent = if (s.depth() == 0) s.base else try s.topDir();
        const id = try fsown.statAt(parent, name, follow);
        const dir = try s.open(parent, name, follow);
        try s.push(dir, name, follow, id, 0, {});
    }
}

test "directories closed on the way down are opened again on the way up" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a/b/c/d/e");
    var s: Stack(void) = .{ .io = testing.io, .gpa = testing.allocator, .base = tmp.dir, .max_open = 2 };
    defer s.deinit();
    try descend(&s, &.{ "a", "b", "c", "d", "e" }, false);
    try testing.expectEqual(@as(usize, 2), s.open_count);
    while (s.depth() > 0) {
        _ = try s.topDir();
        _ = try s.parentDir();
        try testing.expect(s.open_count <= 2);
        s.pop();
    }
    try testing.expectEqual(@as(usize, 0), s.open_count);
}

test "after a followed link the way back is by name" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "top/mid");
    try tmp.dir.createDirPath(testing.io, "other/x/y");
    try tmp.dir.symLink(testing.io, "../../other/x", "top/mid/link", .{});
    var s: Stack(void) = .{ .io = testing.io, .gpa = testing.allocator, .base = tmp.dir, .max_open = 1 };
    defer s.deinit();
    // ".." of the link's target is "other", not "mid"
    try descend(&s, &.{ "top", "mid", "link", "y" }, true);
    const mid = try fsown.statAt(tmp.dir, "top/mid", false);
    s.pop(); // y
    s.pop(); // link
    const back = try s.topDir();
    try testing.expect((try fsown.statHandle(back.handle)).sameFile(mid));
}

test "a directory moved during the walk is not mistaken for its replacement" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a/b/c");
    try tmp.dir.createDirPath(testing.io, "elsewhere");
    var s: Stack(void) = .{ .io = testing.io, .gpa = testing.allocator, .base = tmp.dir, .max_open = 1 };
    defer s.deinit();
    try descend(&s, &.{ "a", "b", "c" }, false);
    // "c" leaves "b", and "b" is replaced: neither way leads back
    try tmp.dir.rename("a/b/c", tmp.dir, "elsewhere/c", testing.io);
    try tmp.dir.rename("a/b", tmp.dir, "elsewhere/b", testing.io);
    try tmp.dir.createDir(testing.io, "a/b", .default_dir);
    s.pop();
    try testing.expectError(error.DirectoryChanged, s.topDir());
}
