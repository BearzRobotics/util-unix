// SPDX-License-Identifier: GPL-2.0-or-later
//! Operating-system facilities that std.Io (Zig 0.17.1) does not provide.
//!
//! Commands and the library do their file, stream and process I/O through
//! `std.Io` (ai/AGENTS.md §13). The only exception so far is signal
//! dispositions, for which std.Io has no API (checked 2026-11-07 against
//! `~/.zvm/0.17.1/lib/std/Io*`). It is isolated here, and only in the
//! executable wrappers: the library never changes process-wide state.
//! See docs/decisions/0003-std-io-exceptions.md.

const std = @import("std");
const builtin = @import("builtin");

const has_posix = builtin.os.tag != .windows and builtin.os.tag != .wasi;

pub const Signal = enum { pipe };

fn setDisposition(sig: Signal, handler: ?std.posix.Sigaction.handler_fn) void {
    if (comptime !has_posix) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(switch (sig) {
        .pipe => .PIPE,
    }, &act, null);
}

/// Ignore `sig` for the rest of the process.
pub fn ignoreSignal(sig: Signal) void {
    setDisposition(sig, std.posix.SIG.IGN);
}

/// Restore the default action of `sig`.
pub fn defaultSignal(sig: Signal) void {
    setDisposition(sig, std.posix.SIG.DFL);
}

/// Zig's runtime ignores SIGPIPE, which would turn `cmd | head` into a write
/// error message. The conventional behaviour is to die silently, so every
/// entry point restores the default action. A command that must see EPIPE
/// can set it back to ignore with `ignoreSignal`; none does yet.
pub fn restoreSigpipe() void {
    defaultSignal(.pipe);
}

/// Put SIGPIPE and SIGIO back to what the process inherited. `std.Io.Threaded`
/// installs a do-nothing handler for both at startup and keeps the original
/// actions; restoring those (rather than forcing the default) keeps a signal
/// that was ignored on entry ignored, which POSIX requires of a shell (XCU 2.15 trap:
/// "Signals that were ignored on entry to a non-interactive shell cannot be trapped or reset").
pub fn restoreInheritedSignals(io: std.Io) void {
    if (comptime !is_linux) return restoreSigpipe();
    const t: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata));
    if (!t.have_signal_handler) return restoreSigpipe();
    if (comptime @TypeOf(t.old_sig_io) != void) std.posix.sigaction(.IO, &t.old_sig_io, null);
    if (comptime @TypeOf(t.old_sig_pipe) != void) std.posix.sigaction(.PIPE, &t.old_sig_pipe, null);
}

// ---------------------------------------------------------------------------
// Process and descriptor layer for the POSIX shell (decision 0009).
//
// Everything below is Linux only (std.os.linux raw system calls); on other
// systems the functions report ENOSYS. Each group is one row of
// docs/std-io-gaps.md (rows 17-27): `std.Io` has no fork, no descriptor-number
// level redirection, no pipe() and no signal handlers.
//
// Error convention: a failing call returns `error.Sys`; the errno is in
// `errno()` (single-threaded use only, like the shell that needs it).
// ---------------------------------------------------------------------------

const linux = std.os.linux;
const is_linux = builtin.os.tag == .linux;

pub const Error = error{Sys};
var last_errno: u16 = 0;

/// errno of the most recent failed `sys` call.
pub fn errno() u16 {
    return last_errno;
}

pub const E_AGAIN: u16 = 11;
pub const E_NOENT: u16 = 2;
pub const E_INTR: u16 = 4;
pub const E_2BIG: u16 = 7;
pub const E_NOEXEC: u16 = 8;
pub const E_BADF: u16 = 9;
pub const E_NOMEM: u16 = 12;
pub const E_ACCES: u16 = 13;
pub const E_EXIST: u16 = 17;
pub const E_NOTDIR: u16 = 20;
pub const E_ISDIR: u16 = 21;
pub const E_INVAL: u16 = 22;
pub const E_PIPE: u16 = 32;
pub const E_NAMETOOLONG: u16 = 36;
pub const E_NOSYS: u16 = 38;

fn check(r: usize) Error!usize {
    if (comptime !is_linux) {
        last_errno = E_NOSYS;
        return error.Sys;
    }
    const e = linux.errno(r);
    if (e != .SUCCESS) {
        last_errno = @backingInt(e);
        return error.Sys;
    }
    return r;
}

fn nosys() Error {
    last_errno = E_NOSYS;
    return error.Sys;
}

/// strerror(3) text in the C locale for the errors a shell meets.
pub fn strerror(e: u16) []const u8 {
    return switch (e) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        3 => "No such process",
        4 => "Interrupted system call",
        5 => "Input/output error",
        7 => "Argument list too long",
        8 => "Exec format error",
        9 => "Bad file descriptor",
        10 => "No child processes",
        11 => "Resource temporarily unavailable",
        12 => "Cannot allocate memory",
        13 => "Permission denied",
        14 => "Bad address",
        16 => "Device or resource busy",
        17 => "File exists",
        18 => "Invalid cross-device link",
        19 => "No such device",
        20 => "Not a directory",
        21 => "Is a directory",
        22 => "Invalid argument",
        23 => "Too many open files in system",
        24 => "Too many open files",
        25 => "Inappropriate ioctl for device",
        26 => "Text file busy",
        27 => "File too large",
        28 => "No space left on device",
        29 => "Illegal seek",
        30 => "Read-only file system",
        31 => "Too many links",
        32 => "Broken pipe",
        36 => "File name too long",
        38 => "Function not implemented",
        39 => "Directory not empty",
        40 => "Too many levels of symbolic links",
        else => "Unknown error",
    };
}

const path_max = 4096;

/// A NUL-terminated copy of `path` on the caller's stack.
const CPath = struct {
    buf: [path_max + 1]u8 = undefined,
    fn init(self: *CPath, path: []const u8) Error![:0]const u8 {
        if (path.len > path_max) {
            last_errno = E_NAMETOOLONG;
            return error.Sys;
        }
        @memcpy(self.buf[0..path.len], path);
        self.buf[path.len] = 0;
        return self.buf[0..path.len :0];
    }
};

pub const OpenFlags = struct {
    write: bool = false,
    read: bool = true,
    create: bool = false,
    excl: bool = false,
    trunc: bool = false,
    append: bool = false,
    cloexec: bool = false,
    directory: bool = false,
};

/// open(2). `read` and `write` select O_RDONLY, O_WRONLY or O_RDWR.
pub fn open(path: []const u8, f: OpenFlags, mode: u32) Error!i32 {
    if (comptime !is_linux) return nosys();
    var cp: CPath = .{};
    const p = try cp.init(path);
    const o: linux.O = .{
        .ACCMODE = if (f.write and f.read) .RDWR else if (f.write) .WRONLY else .RDONLY,
        .CREAT = f.create,
        .EXCL = f.excl,
        .TRUNC = f.trunc,
        .APPEND = f.append,
        .CLOEXEC = f.cloexec,
        .DIRECTORY = f.directory,
    };
    while (true) {
        const r = linux.openat(linux.AT.FDCWD, p, o, @intCast(mode));
        // a caught signal is reported (E_INTR) so the shell can run its trap and retry
        if (linux.errno(r) == .INTR and !any_pending) continue;
        return @intCast(try check(r));
    }
}

pub fn close(fd: i32) void {
    if (comptime !is_linux) return;
    _ = linux.close(fd);
}

/// read(2); `error.Sys` with errno E_INTR when a signal interrupts it.
pub fn read(fd: i32, buf: []u8) Error!usize {
    if (comptime !is_linux) return nosys();
    return check(linux.read(fd, buf.ptr, buf.len));
}

/// Write all of `bytes`, retrying on EINTR and short writes.
pub fn writeAll(fd: i32, bytes: []const u8) Error!void {
    if (comptime !is_linux) return nosys();
    var off: usize = 0;
    while (off < bytes.len) {
        const r = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(r) == .INTR) continue;
        off += try check(r);
    }
}

pub fn dup(fd: i32) Error!i32 {
    if (comptime !is_linux) return nosys();
    return @intCast(try check(linux.dup(fd)));
}

/// dup2(2); returns `new`. `old == new` only checks that `old` is open.
pub fn dup2(old: i32, new: i32) Error!i32 {
    if (comptime !is_linux) return nosys();
    while (true) {
        const r = linux.dup2(old, new);
        if (linux.errno(r) == .INTR) continue;
        return @intCast(try check(r));
    }
}

/// Duplicate `fd` onto the lowest free descriptor >= `min`, close-on-exec.
pub fn dupAbove(fd: i32, min: i32) Error!i32 {
    if (comptime !is_linux) return nosys();
    const F_DUPFD_CLOEXEC = 1030;
    return @intCast(try check(linux.fcntl(fd, F_DUPFD_CLOEXEC, @intCast(min))));
}

/// Clear O_NONBLOCK; false if that could not be done or it was not set.
pub fn setBlocking(fd: i32) bool {
    if (comptime !is_linux) return false;
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return false;
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    if (flags & nonblock == 0) return false;
    return linux.errno(linux.fcntl(fd, linux.F.SETFL, flags & ~@as(usize, nonblock))) == .SUCCESS;
}

pub fn setCloexec(fd: i32, on: bool) void {
    if (comptime !is_linux) return;
    _ = linux.fcntl(fd, linux.F.SETFD, if (on) linux.FD_CLOEXEC else 0);
}

pub fn fdIsOpen(fd: i32) bool {
    if (comptime !is_linux) return false;
    return linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) == .SUCCESS;
}

/// pipe2(O_CLOEXEC): { read end, write end }. Neither end is descriptor 0, 1
/// or 2, even when one of those is closed: callers move the ends onto them.
pub fn pipe() Error![2]i32 {
    if (comptime !is_linux) return nosys();
    var fds: [2]i32 = undefined;
    _ = try check(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    errdefer for (fds) |fd| close(fd);
    for (&fds) |*fd| {
        if (fd.* > 2) continue;
        const moved = try dupAbove(fd.*, 10);
        close(fd.*);
        fd.* = moved;
    }
    return fds;
}

/// An anonymous in-memory file (memfd_create) holding `bytes`, positioned at
/// 0 and not close-on-exec; used for here-documents of any size.
pub fn memfileWith(bytes: []const u8) Error!i32 {
    if (comptime !is_linux) return nosys();
    const fd: i32 = @intCast(try check(linux.memfd_create("sh-heredoc", 0)));
    errdefer close(fd);
    try writeAll(fd, bytes);
    _ = try check(linux.lseek(fd, 0, 0));
    return fd;
}

/// fork(2): 0 in the child, the child's pid in the parent.
pub fn fork() Error!i32 {
    if (comptime !is_linux) return nosys();
    return @intCast(try check(linux.fork()));
}

pub fn exit(status: u8) noreturn {
    if (comptime is_linux) linux.exit_group(status);
    std.process.exit(status);
}

pub fn getpid() i32 {
    return if (comptime is_linux) @intCast(linux.getpid()) else 0;
}

pub fn geteuid() u32 {
    return if (comptime is_linux) linux.geteuid() else 0;
}

pub fn getegid() u32 {
    return if (comptime is_linux) linux.getegid() else 0;
}

pub fn getppid() i32 {
    return if (comptime is_linux) @intCast(linux.getppid()) else 0;
}

/// execve(2) with `argv` and `envp` given as slices. Returns only on error
/// (errno in `errno()`); `gpa` is used for the NUL-terminated copies (the
/// caller is a forked child that never frees them).
pub fn execve(gpa: std.mem.Allocator, path: []const u8, argv: []const []const u8, envp: []const []const u8) Error!void {
    if (comptime !is_linux) return nosys();
    const oom = struct {
        fn f() Error {
            last_errno = E_NOMEM;
            return error.Sys;
        }
    }.f;
    const pz = gpa.dupeSentinel(u8, path, 0) catch return oom();
    const av = gpa.alloc(?[*:0]const u8, argv.len + 1) catch return oom();
    const ev = gpa.alloc(?[*:0]const u8, envp.len + 1) catch return oom();
    for (argv, 0..) |a, i| av[i] = (gpa.dupeSentinel(u8, a, 0) catch return oom()).ptr;
    av[argv.len] = null;
    for (envp, 0..) |a, i| ev[i] = (gpa.dupeSentinel(u8, a, 0) catch return oom()).ptr;
    ev[envp.len] = null;
    _ = try check(linux.execve(pz.ptr, @ptrCast(av.ptr), @ptrCast(ev.ptr)));
}

pub const WaitResult = struct { pid: i32, status: u32 };

/// wait4(2) for `pid` (-1 for any child). With `nohang`, pid is 0 when no
/// child has changed state. EINTR is reported (errno E_INTR) so the shell can
/// run traps.
pub fn waitpid(pid: i32, nohang: bool) Error!WaitResult {
    if (comptime !is_linux) return nosys();
    var st: i32 = 0;
    const r = try check(linux.wait4(pid, &st, if (nohang) linux.W.NOHANG else 0, null));
    return .{ .pid = @intCast(r), .status = @bitCast(st) };
}

/// Decode a wait status the way a shell reports it: exit code, or 128+signal.
pub fn statusCode(status: u32) u8 {
    if (comptime !is_linux) return 1;
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    if (linux.W.IFSIGNALED(status)) return @intCast(128 + (status & 0x7f));
    return 1;
}

/// The terminating signal of a wait status, or 0.
pub fn statusSignal(status: u32) u8 {
    if (comptime !is_linux) return 0;
    if (linux.W.IFSIGNALED(status)) return @intCast(status & 0x7f);
    return 0;
}

pub fn chdir(path: []const u8) Error!void {
    if (comptime !is_linux) return nosys();
    var cp: CPath = .{};
    const p = try cp.init(path);
    _ = try check(linux.chdir(p.ptr));
}

/// The current directory as the kernel knows it, written into `buf`.
pub fn getcwd(buf: []u8) Error![]const u8 {
    if (comptime !is_linux) return nosys();
    const r = try check(linux.getcwd(buf.ptr, buf.len));
    if (r == 0) return buf[0..0];
    return buf[0 .. r - 1];
}

pub fn kill(pid: i32, sig: u8) Error!void {
    if (comptime !is_linux) return nosys();
    _ = try check(linux.kill(pid, @fromBackingInt(@intCast(sig))));
}

pub const FileKind = enum { none, file, dir, symlink, fifo, socket, block, char };

pub const FileInfo = struct {
    kind: FileKind,
    mode: u32,
    size: u64,
    uid: u32,
    gid: u32,
    ino: u64,
    dev: u64,
    mtime_sec: i64,
    mtime_nsec: u32,
};

/// statx(2). `follow` false is lstat.
pub fn stat(path: []const u8, follow: bool) Error!FileInfo {
    if (comptime !is_linux) return nosys();
    var cp: CPath = .{};
    const p = try cp.init(path);
    var sx: linux.Statx = undefined;
    _ = try check(linux.statx(linux.AT.FDCWD, p.ptr, if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &sx));
    return infoOf(&sx);
}

pub fn fstat(fd: i32) Error!FileInfo {
    if (comptime !is_linux) return nosys();
    var sx: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &sx));
    return infoOf(&sx);
}

fn infoOf(sx: *const linux.Statx) FileInfo {
    const fmt = sx.mode & 0o170000;
    return .{
        .kind = switch (fmt) {
            0o100000 => .file,
            0o040000 => .dir,
            0o120000 => .symlink,
            0o010000 => .fifo,
            0o140000 => .socket,
            0o060000 => .block,
            0o020000 => .char,
            else => .none,
        },
        .mode = sx.mode & 0o7777,
        .size = sx.size,
        .uid = sx.uid,
        .gid = sx.gid,
        .ino = sx.ino,
        .dev = (@as(u64, sx.dev_major) << 32) | sx.dev_minor,
        .mtime_sec = sx.mtime.sec,
        .mtime_nsec = sx.mtime.nsec,
    };
}

/// access(2) with real ids: `mode` bits 4 read, 2 write, 1 execute, 0 exists.
pub fn access(path: []const u8, mode: u32) bool {
    if (comptime !is_linux) return false;
    var cp: CPath = .{};
    const p = cp.init(path) catch return false;
    return linux.errno(linux.faccessat(linux.AT.FDCWD, p.ptr, mode, 0)) == .SUCCESS;
}

pub fn isatty(fd: i32) bool {
    if (comptime !is_linux) return false;
    var tio: [64]u8 = undefined;
    return linux.errno(linux.ioctl(fd, 0x5401, @intFromPtr(&tio))) == .SUCCESS;
}

/// Names in directory `path` (without "." and ".."), each owned by `gpa`.
pub fn listDir(gpa: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]u8)) (Error || error{OutOfMemory})!void {
    if (comptime !is_linux) return nosys();
    const fd = try open(if (path.len == 0) "." else path, .{ .directory = true, .cloexec = true }, 0);
    defer close(fd);
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = try check(linux.getdents64(fd, &buf, buf.len));
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const name_z = buf[off + 19 .. off + reclen];
            const name = name_z[0..std.mem.indexOfScalar(u8, name_z, 0).?];
            off += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            try out.append(gpa, try gpa.dupe(u8, name));
        }
    }
}

/// Set the umask and return the previous one.
pub fn umaskSet(mask: u32) u32 {
    if (comptime !is_linux) return 0o22;
    return @intCast(linux.syscall1(.umask, mask));
}

/// Read the umask (set-and-restore; single-threaded callers only).
pub fn umaskGet() u32 {
    const old = umaskSet(0o77);
    _ = umaskSet(old);
    return old;
}

pub const Times = struct { user: u64, system: u64, child_user: u64, child_system: u64 };

/// Process and child CPU times in microseconds (getrusage).
pub fn cpuTimes() Times {
    var t: Times = .{ .user = 0, .system = 0, .child_user = 0, .child_system = 0 };
    if (comptime !is_linux) return t;
    var ru: linux.rusage = undefined;
    if (linux.errno(linux.getrusage(0, &ru)) == .SUCCESS) {
        t.user = @as(u64, @intCast(ru.utime.sec)) * 1_000_000 + @as(u64, @intCast(ru.utime.usec));
        t.system = @as(u64, @intCast(ru.stime.sec)) * 1_000_000 + @as(u64, @intCast(ru.stime.usec));
    }
    if (linux.errno(linux.getrusage(-1, &ru)) == .SUCCESS) {
        t.child_user = @as(u64, @intCast(ru.utime.sec)) * 1_000_000 + @as(u64, @intCast(ru.utime.usec));
        t.child_system = @as(u64, @intCast(ru.stime.sec)) * 1_000_000 + @as(u64, @intCast(ru.stime.usec));
    }
    return t;
}

pub const Rlimit = struct { soft: u64, hard: u64 };
pub const infinity: u64 = std.math.maxInt(u64);

/// Resource numbers as in <sys/resource.h> on Linux.
pub fn getrlimit(resource: u32) Error!Rlimit {
    if (comptime !is_linux) return nosys();
    var rl: linux.rlimit = undefined;
    _ = try check(linux.getrlimit(@fromBackingInt(@intCast(resource)), &rl));
    return .{ .soft = rl.cur, .hard = rl.max };
}

pub fn setrlimit(resource: u32, l: Rlimit) Error!void {
    if (comptime !is_linux) return nosys();
    const rl: linux.rlimit = .{ .cur = l.soft, .max = l.hard };
    _ = try check(linux.setrlimit(@fromBackingInt(@intCast(resource)), &rl));
}

// --- signals for the shell's traps -----------------------------------------

pub const nsig = 65;
var pending_flags: [nsig]bool = @splat(false);
var any_pending: bool = false;

fn trapHandler(sig: linux.SIG) callconv(.c) void {
    const n: usize = @backingInt(sig);
    if (n < nsig) {
        pending_flags[n] = true;
        any_pending = true;
    }
}

pub const SignalAction = enum { default, ignore, catch_flag };

/// Set the disposition of signal `sig`. `catch_flag` installs a handler that
/// only sets a flag read back with `takePending` (no allocation, async-signal
/// safe). SIGKILL and SIGSTOP are refused. No SA_RESTART, so blocking calls
/// return EINTR and the shell can run the trap promptly.
pub fn setSignal(sig: u8, action: SignalAction) bool {
    if (comptime !is_linux) return false;
    if (sig == 0 or sig >= nsig or sig == 9 or sig == 19) return false;
    const act: linux.Sigaction = .{
        .handler = .{ .handler = switch (action) {
            .default => @ptrFromInt(0),
            .ignore => @ptrFromInt(1),
            .catch_flag => @ptrCast(&trapHandler),
        } },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    return linux.errno(linux.sigaction(@fromBackingInt(@intCast(sig)), &act, null)) == .SUCCESS;
}

/// The current disposition of `sig` (default when unknown).
pub fn getSignal(sig: u8) SignalAction {
    if (comptime !is_linux) return .default;
    if (sig == 0 or sig >= nsig or sig == 9 or sig == 19) return .default;
    var old: linux.Sigaction = undefined;
    if (linux.errno(linux.sigaction(@fromBackingInt(@intCast(sig)), null, &old)) != .SUCCESS) return .default;
    const h = @intFromPtr(old.handler.handler);
    if (h == 0) return .default;
    if (h == 1) return .ignore;
    return .catch_flag;
}

/// True when some caught signal arrived since the flags were last cleared.
pub fn signalsPending() bool {
    return any_pending;
}

/// Fetch-and-clear the flag of `sig`.
pub fn takePending(sig: u8) bool {
    if (sig >= nsig or !pending_flags[sig]) return false;
    pending_flags[sig] = false;
    return true;
}

pub fn clearPendingAny() void {
    any_pending = false;
}

pub const SIGCHLD: u8 = 17;

pub const signal_names = [_][]const u8{
    "EXIT",   "HUP",  "INT",    "QUIT", "ILL",   "TRAP", "ABRT", "BUS",
    "FPE",    "KILL", "USR1",   "SEGV", "USR2",  "PIPE", "ALRM", "TERM",
    "STKFLT", "CHLD", "CONT",   "STOP", "TSTP",  "TTIN", "TTOU", "URG",
    "XCPU",   "XFSZ", "VTALRM", "PROF", "WINCH", "IO",   "PWR",  "SYS",
};

/// Signal number for a name ("INT", "SIGINT", case-insensitive) or a decimal
/// number; null when unknown.
pub fn signalNumber(name: []const u8) ?u8 {
    if (name.len > 0 and std.ascii.isDigit(name[0])) {
        const n = std.fmt.parseInt(u8, name, 10) catch return null;
        return if (n < signal_names.len) n else null;
    }
    var nm = name;
    if (nm.len > 3 and std.ascii.eqlIgnoreCase(nm[0..3], "SIG")) nm = nm[3..];
    for (signal_names, 0..) |s, i| {
        if (std.ascii.eqlIgnoreCase(s, nm)) return @intCast(i);
    }
    return null;
}

// --- terminal and process groups (sh milestone 2; docs/std-io-gaps.md rows 25-29) ---

/// Kernel `struct termios` as returned by TCGETS (not glibc's).
pub const Termios = extern struct {
    iflag: u32 = 0,
    oflag: u32 = 0,
    cflag: u32 = 0,
    lflag: u32 = 0,
    line: u8 = 0,
    cc: [19]u8 = @splat(0),
};

const TCGETS = 0x5401;
const TCSETS = 0x5402;
const TCSETSW = 0x5403;
const TIOCGPGRP = 0x540F;
const TIOCSPGRP = 0x5410;
const TIOCGWINSZ_ = 0x5413;

pub fn tcgetattr(fd: i32) Error!Termios {
    if (comptime !is_linux) return nosys();
    var t: Termios = .{};
    _ = try check(linux.ioctl(fd, TCGETS, @intFromPtr(&t)));
    return t;
}

pub fn tcsetattr(fd: i32, t: *const Termios) Error!void {
    if (comptime !is_linux) return nosys();
    _ = try check(linux.ioctl(fd, TCSETSW, @intFromPtr(t)));
}

/// `t` with the modes a line editor needs: no echo, no canonical mode, no
/// signal characters, no flow control, 8-bit input, reads return after one
/// byte. Output processing is left alone so "\n" still ends a line.
pub fn termiosRaw(t: Termios) Termios {
    var r = t;
    r.iflag &= ~@as(u32, 0o000400 | 0o000100 | 0o000200 | 0o002000 | 0o000040); // ICRNL INLCR IGNCR IXON ISTRIP
    r.lflag &= ~@as(u32, 0o000002 | 0o000010 | 0o000001 | 0o100000); // ICANON ECHO ISIG IEXTEN
    r.cc[6] = 1; // VMIN
    r.cc[5] = 0; // VTIME
    return r;
}

/// The terminal's erase, kill and EOF characters (VERASE=2, VKILL=3, VEOF=4).
pub fn termiosChars(t: Termios) struct { erase: u8, kill: u8, eof: u8 } {
    return .{ .erase = t.cc[2], .kill = t.cc[3], .eof = t.cc[4] };
}

pub const WinSize = struct { rows: u16, cols: u16 };

pub fn winsize(fd: i32) ?WinSize {
    if (comptime !is_linux) return null;
    var w: [4]u16 = @splat(0);
    if (linux.errno(linux.ioctl(fd, TIOCGWINSZ_, @intFromPtr(&w))) != .SUCCESS) return null;
    if (w[1] == 0) return null;
    return .{ .rows = w[0], .cols = w[1] };
}

pub fn getpgrp() i32 {
    if (comptime !is_linux) return 0;
    return @intCast(linux.getpgid(0));
}

pub fn setpgid(pid: i32, pgid: i32) Error!void {
    if (comptime !is_linux) return nosys();
    _ = try check(linux.setpgid(pid, pgid));
}

pub fn tcgetpgrp(fd: i32) Error!i32 {
    if (comptime !is_linux) return nosys();
    var p: i32 = 0;
    _ = try check(linux.ioctl(fd, TIOCGPGRP, @intFromPtr(&p)));
    return p;
}

pub fn tcsetpgrp(fd: i32, pgid: i32) Error!void {
    if (comptime !is_linux) return nosys();
    var p: i32 = pgid;
    _ = try check(linux.ioctl(fd, TIOCSPGRP, @intFromPtr(&p)));
}

pub const WUNTRACED: u32 = 2;
pub const WNOHANG: u32 = 1;
pub const WCONTINUED: u32 = 8;

/// wait4(2) with explicit flags (`WNOHANG`, `WUNTRACED`, `WCONTINUED`); pid 0
/// in the result means nothing changed (with `WNOHANG`).
pub fn waitpidFlags(pid: i32, flags: u32) Error!WaitResult {
    if (comptime !is_linux) return nosys();
    var st: i32 = 0;
    const r = try check(linux.wait4(pid, &st, flags, null));
    return .{ .pid = @intCast(r), .status = @bitCast(st) };
}

/// Stop signal of a wait status, or 0 when the child did not stop.
pub fn statusStopSignal(status: u32) u8 {
    if (comptime !is_linux) return 0;
    if (status != 0xffff and linux.W.IFSTOPPED(status)) return @intCast((status >> 8) & 0xff);
    return 0;
}

pub fn statusContinued(status: u32) bool {
    return status == 0xffff;
}

pub fn statusCoreDumped(status: u32) bool {
    return status & 0x80 != 0 and (status & 0x7f) != 0;
}

/// True when `fd` has input within `timeout_ms` (-1 forever). EINTR gives false
/// with errno E_INTR.
pub fn pollIn(fd: i32, timeout_ms: i32) bool {
    if (comptime !is_linux) return false;
    var p = [1]linux.pollfd{.{ .fd = fd, .events = 1, .revents = 0 }};
    const r = linux.poll(&p, 1, timeout_ms);
    if (linux.errno(r) != .SUCCESS) {
        last_errno = @intFromEnum(linux.errno(r));
        return false;
    }
    return r > 0;
}

/// Send `sig` to every process of group `pgid`.
pub fn killpg(pgid: i32, sig: u8) Error!void {
    return kill(-pgid, sig);
}

pub const SIGWINCH: u8 = 28;

/// True when `sig` was caught since its flag was last taken (does not clear it).
pub fn peekPending(sig: u8) bool {
    return sig < nsig and pending_flags[sig];
}
