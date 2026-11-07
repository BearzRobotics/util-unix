//! split: divide an input into pieces. Library implementation.
//!
//! References:
//!   - POSIX.1-2024 (IEEE Std 1003.1-2024) `split`:
//!     https://pubs.opengroup.org/onlinepubs/9799919799/utilities/split.html
//!   - GNU coreutils 9.7 manual, node "split invocation"
//!     (info '(coreutils) split invocation').
//!   - GNU coreutils 9.7 src/split.c, read as the behavioural reference for
//!     cases the manual leaves open (suffix widening, `-n` chunk arithmetic,
//!     `-C` record packing). The code here is an independent implementation.
//!
//! POSIX covers `-a`, `-b`, `-l` and the `file`/`name` operands. Everything
//! else (`-C`, `-n`, `-d`/`-x`, `--additional-suffix`, `-e`, `-t`, `-u`,
//! `--filter`, `--verbose`, size suffixes beyond k/m) is a GNU extension. The
//! command-line wrapper documents which is which.
//!
//! API shape: `run` performs one split. It reads `input`, creates output files
//! in `Options.dir` (or the current directory), and writes `-n K/N` style
//! single-chunk extractions to `stdout`. It never prints, never parses
//! arguments and never changes signal dispositions: failures come back as
//! `error.Failed` with details in a caller-owned `Diagnostic`, and progress
//! (the `--verbose` messages) goes to an optional `Observer`.
//!
//! Signals: with `Options.filter`, writing to a filter that exited early
//! reports EPIPE only if the caller ignores SIGPIPE. The caller owns that
//! decision (the executable wrapper ignores it, as GNU does). Child filters
//! inherit that disposition; see docs/compatibility/split.md.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Characters used for generated suffixes (POSIX: lowercase letters; GNU
/// `-d` decimal, `-x` hexadecimal).
pub const Alphabet = enum {
    lower,
    decimal,
    hex,

    pub fn chars(a: Alphabet) []const u8 {
        return switch (a) {
            .lower => "abcdefghijklmnopqrstuvwxyz",
            .decimal => "0123456789",
            .hex => "0123456789abcdef",
        };
    }
};

/// `-n` specification. `n` is the number of chunks (at least 1). With
/// `k == 0` all `n` files are written; with `1 <= k <= n` only chunk `k`
/// is extracted to standard output.
pub const Chunks = struct {
    n: u64,
    k: u64 = 0,
};

pub const Mode = union(enum) {
    /// `-l N`: N records per file (POSIX: lines).
    lines: u64,
    /// `-b N`: N bytes per file (POSIX).
    bytes: u64,
    /// `-C N`: as many whole records as fit in N bytes (GNU).
    line_bytes: u64,
    /// `-n N`, `-n K/N`: N files of near-equal byte size (GNU).
    chunks: Chunks,
    /// `-n l/N`, `-n l/K/N`: N files of near-equal size, records unbroken.
    line_chunks: Chunks,
    /// `-n r/N`, `-n r/K/N`: records dealt round-robin to N files.
    round_robin: Chunks,
};

pub const Event = union(enum) {
    /// An output file is about to be created (`--verbose`).
    creating: []const u8,
    /// A filter command is about to run with `$FILE` set to this name.
    executing: []const u8,
};

/// Receives progress events. `context` is passed back unchanged. The event's
/// slices are valid only during the call.
pub const Observer = struct {
    context: ?*anyopaque = null,
    on_event: *const fn (context: ?*anyopaque, event: Event) void,
};

pub const Options = struct {
    mode: Mode = .{ .lines = 1000 },
    /// Record separator for `lines`, `line_bytes`, `line_chunks` and
    /// `round_robin` (GNU `-t`). POSIX has only newline.
    separator: u8 = '\n',
    /// Output name prefix (POSIX `name` operand).
    prefix: []const u8 = "x",
    /// Text appended after the generated suffix (GNU `--additional-suffix`).
    /// The caller validates that it contains no directory separator.
    additional_suffix: []const u8 = "",
    alphabet: Alphabet = .lower,
    /// Suffix length (`-a`); 0 means the default (2, widening automatically
    /// when no explicit length or start value is given).
    suffix_length: usize = 0,
    /// First suffix for numeric/hex suffixes (`--numeric-suffixes=FROM`):
    /// digits of `alphabet`. Disables automatic widening.
    start: ?[]const u8 = null,
    /// Do not create empty output files (`-e`).
    elide_empty: bool = false,
    /// With `round_robin`, write each record to its file immediately.
    unbuffered: bool = false,
    /// Shell command receiving each piece on stdin, with `$FILE` set to the
    /// would-be file name (`--filter`).
    filter: ?[]const u8 = null,
    /// Shell used for `filter` as `shell -c command`.
    shell: []const u8 = "/bin/sh",
    /// Base environment for filter commands (`FILE` is added). Null means an
    /// empty environment apart from `FILE`.
    environ: ?*const std.process.Environ.Map = null,
    /// Directory in which output files are created; null for the current
    /// working directory.
    dir: ?Io.Dir = null,
    /// Name of the input, used in diagnostics only.
    input_name: []const u8 = "-",
    /// For modes that must know the input size but get a pipe or terminal,
    /// the input is held in memory. Larger inputs fail (GNU spools to a
    /// temporary file instead; see docs/compatibility/split.md).
    max_spool_bytes: u64 = 1 << 30,
    observer: ?Observer = null,
};

// -- Suffix planning ----------------------------------------------------------

/// Effective suffix settings after applying GNU's rules.
pub const SuffixPlan = struct {
    /// Initial suffix length.
    length: usize,
    /// Widen automatically (`yz` -> `zaaa`) when the suffixes run out.
    auto: bool,
};

pub const PlanError = error{
    /// `start` has characters outside the alphabet.
    InvalidStart,
    /// `start` has more digits than the suffix length.
    StartTooLarge,
};

/// Work out the suffix length and widening policy for `opts` (GNU
/// `set_suffix_length`). For `-n` modes the length is chosen so that all
/// files get distinct names; on `SuffixTooShort`, `*needed` (when given)
/// receives the minimum acceptable length.
pub fn planSuffix(opts: Options, needed: ?*usize) error{SuffixTooShort}!SuffixPlan {
    var auto = opts.start == null;
    var need: usize = 0;
    const chunk_n: ?u64 = switch (opts.mode) {
        .chunks, .line_chunks, .round_robin => |c| c.n,
        else => null,
    };
    if (chunk_n) |n_units| {
        // Number of digits needed to write the largest index.
        var last: u64 = n_units -| 1;
        if (opts.start) |s| {
            // GNU adds a decimal start value (even for hex alphabets, where a
            // start such as "1f" is then not counted).
            if (parseDecimal(normalizeStart(s))) |start| {
                if (start < n_units) last = std.math.add(u64, last, start) catch std.math.maxInt(i64);
            }
        }
        const base: u64 = opts.alphabet.chars().len;
        while (true) {
            need += 1;
            last /= base;
            if (last == 0) break;
        }
        auto = false;
    }
    if (needed) |p| p.* = need;
    if (opts.suffix_length != 0) {
        if (opts.suffix_length < need) return error.SuffixTooShort;
        return .{ .length = opts.suffix_length, .auto = false };
    }
    return .{ .length = @max(2, need), .auto = auto };
}

/// Validate `opts.start` against the alphabet and the planned length.
pub fn checkStart(opts: Options, plan: SuffixPlan) PlanError!void {
    const s = opts.start orelse return;
    const chars = opts.alphabet.chars();
    for (s) |c| if (std.mem.indexOfScalar(u8, chars, c) == null) return error.InvalidStart;
    if (normalizeStart(s).len > plan.length) return error.StartTooLarge;
}

/// Drop leading zeros, keeping at least one character.
fn normalizeStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < s.len and s[i] == '0') i += 1;
    return s[i..];
}

fn parseDecimal(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = std.math.mul(u64, v, 10) catch return std.math.maxInt(i64);
        v = std.math.add(u64, v, c - '0') catch return std.math.maxInt(i64);
    }
    return v;
}

// -- File-name generator ------------------------------------------------------

/// Generates PREFIX + suffix + ADDITIONAL names in sort order. The suffix is
/// a base-|alphabet| odometer. When `auto` is set and the first position
/// reaches the last alphabet character, the generator freezes that character
/// into the prefix and starts a suffix one longer, so names sort correctly
/// forever: `xyz` is followed by `xzaaa`.
pub const Namer = struct {
    gpa: Allocator,
    alphabet: []const u8,
    /// Prefix including any characters frozen by widening.
    base: std.ArrayList(u8),
    additional: []const u8,
    index: []usize,
    name: std.ArrayList(u8),
    auto: bool,
    started: bool = false,
    start: ?[]const u8,

    pub const Error = error{ SuffixesExhausted, OutOfMemory };

    /// `opts.prefix`, `opts.additional_suffix` and `opts.start` are borrowed
    /// and must outlive the Namer.
    pub fn init(gpa: Allocator, opts: Options, plan: SuffixPlan) Allocator.Error!Namer {
        var base: std.ArrayList(u8) = .empty;
        errdefer base.deinit(gpa);
        try base.appendSlice(gpa, opts.prefix);
        const index = try gpa.alloc(usize, plan.length);
        @memset(index, 0);
        return .{
            .gpa = gpa,
            .alphabet = opts.alphabet.chars(),
            .base = base,
            .additional = opts.additional_suffix,
            .index = index,
            .name = .empty,
            .auto = plan.auto,
            .start = if (opts.start) |s| normalizeStart(s) else null,
        };
    }

    pub fn deinit(n: *Namer) void {
        n.base.deinit(n.gpa);
        n.name.deinit(n.gpa);
        n.gpa.free(n.index);
        n.* = undefined;
    }

    /// The next name. The slice is valid until the next call.
    pub fn next(n: *Namer) Error![]const u8 {
        if (!n.started) {
            n.started = true;
            if (n.start) |s| {
                // Right-align the start digits; the caller validated them.
                for (s, 0..) |c, i| {
                    n.index[n.index.len - s.len + i] = std.mem.indexOfScalar(u8, n.alphabet, c) orelse 0;
                }
            }
            try n.render();
            return n.name.items;
        }
        var i = n.index.len;
        while (i > 0) {
            i -= 1;
            n.index[i] += 1;
            if (n.auto and i == 0 and n.index[0] + 1 >= n.alphabet.len) {
                try n.widen();
                return n.name.items;
            }
            if (n.index[i] < n.alphabet.len) {
                try n.render();
                return n.name.items;
            }
            n.index[i] = 0;
        }
        return error.SuffixesExhausted;
    }

    /// Freeze the (now last) first character into the prefix and restart
    /// with a suffix one character longer.
    fn widen(n: *Namer) Error!void {
        try n.base.append(n.gpa, n.alphabet[n.index[0]]);
        const longer = try n.gpa.realloc(n.index, n.index.len + 1);
        n.index = longer;
        @memset(n.index, 0);
        try n.render();
    }

    fn render(n: *Namer) Allocator.Error!void {
        n.name.clearRetainingCapacity();
        try n.name.appendSlice(n.gpa, n.base.items);
        for (n.index) |d| try n.name.append(n.gpa, n.alphabet[d]);
        try n.name.appendSlice(n.gpa, n.additional);
    }
};

// -- Size parsing -------------------------------------------------------------

pub const SizeKind = enum {
    /// Plain count, no suffix (`-l`, `-n`).
    plain,
    /// Byte count with GNU suffixes (`-b`, `-C`).
    bytes,
};

/// Parse a GNU size: optional leading blanks and `+`, digits, and for
/// `.bytes` a suffix: `b` (512), `K`/`k`, `M`/`m`, `G`, `T`, `P`, `E`, `Z`,
/// `Y`, `R`, `Q` (powers of 1024), optionally followed by `B` (powers of 1000)
/// or `iB` (powers of 1024). A suffix without digits means 1 times the
/// suffix. Values beyond the 63-bit range saturate (GNU treats overflow as
/// "very large"). Returns null for malformed text and for negative numbers.
/// Zero is returned as 0; callers reject it where needed.
pub fn parseSize(text: []const u8, kind: SizeKind) ?u64 {
    var s = text;
    while (s.len > 0 and std.ascii.isWhitespace(s[0])) s = s[1..];
    if (s.len > 0 and s[0] == '+') s = s[1..];
    var i: usize = 0;
    var v: u128 = 0;
    const cap: u128 = std.math.maxInt(i64);
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        v = v * 10 + (s[i] - '0');
        if (v > cap) v = cap + 1; // stays overflowed
    }
    const suffix = s[i..];
    if (i == 0) {
        if (kind == .plain or suffix.len == 0) return null;
        v = 1;
    }
    var mult: u128 = 1;
    if (suffix.len != 0) {
        if (kind == .plain) return null;
        mult = suffixMultiplier(suffix) orelse return null;
    }
    const total = v *| mult;
    return @intCast(@min(total, cap));
}

fn suffixMultiplier(suffix: []const u8) ?u128 {
    if (std.mem.eql(u8, suffix, "b")) return 512;
    const power: u7 = switch (suffix[0]) {
        'k', 'K' => 1,
        'm', 'M' => 2,
        'G' => 3,
        'T' => 4,
        'P' => 5,
        'E' => 6,
        'Z' => 7,
        'Y' => 8,
        'R' => 9,
        'Q' => 10,
        else => return null,
    };
    const rest = suffix[1..];
    const base: u128 = if (rest.len == 0 or std.mem.eql(u8, rest, "iB"))
        1024
    else if (std.mem.eql(u8, rest, "B"))
        1000
    else
        return null;
    var m: u128 = 1;
    for (0..power) |_| m *|= base;
    return m;
}

// -- Diagnostics --------------------------------------------------------------

/// Details of a failed `run`, filled in before `error.Failed` is returned.
pub const Diagnostic = struct {
    kind: Kind = .none,
    /// Underlying error for the I/O kinds.
    cause: ?anyerror = null,
    /// Process exit status the caller should use (a filter's own status for
    /// the `filter_*` kinds, 1 otherwise).
    exit_status: u8 = 1,
    /// Signal number for `.filter_signal`.
    signal: u32 = 0,
    name_buf: [1024]u8 = undefined,
    name_len: usize = 0,

    pub const Kind = enum {
        none,
        /// Options rejected by `run` (n of 0, k > n, ...).
        invalid_options,
        read_input,
        /// Creating, truncating or reopening an output file; `name()` is it.
        create_output,
        write_output,
        /// Writing a chunk extracted with `-n K/N` to standard output.
        write_stdout,
        /// An output file is the same file as the input; `name()` is it.
        overwrite_input,
        suffixes_exhausted,
        /// Input size unknown and not spoolable.
        size_unknown,
        /// Could not start the filter for output `name()`.
        filter_spawn,
        /// Filter for output `name()` exited with `exit_status` != 0.
        filter_exit,
        /// Filter for output `name()` was killed by `signal` (not SIGPIPE).
        filter_signal,
        filter_wait,
        out_of_memory,
    };

    /// File name the failure concerns (truncated to 1024 bytes).
    pub fn name(d: *const Diagnostic) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    fn set(d: *Diagnostic, kind: Kind, file_name: []const u8, cause: ?anyerror) void {
        d.kind = kind;
        d.cause = cause;
        d.name_len = @min(file_name.len, d.name_buf.len);
        @memcpy(d.name_buf[0..d.name_len], file_name[0..d.name_len]);
    }
};

pub const RunError = error{Failed};

// -- The splitter -------------------------------------------------------------

const read_buffer_size = 128 * 1024;
const stdout_buffer_size = 64 * 1024;
const seq_buffer_size = 64 * 1024;
/// Total memory budget for `-n r/N` per-file buffers.
const rr_buffer_budget = 4 * 1024 * 1024;

/// One output destination: a plain file or a filter process's stdin.
const OutFile = struct {
    name: []u8 = &.{},
    file: ?Io.File = null,
    child: ?std.process.Child = null,
    /// Write-behind buffer (round-robin mode only; empty = unbuffered).
    buf: []u8 = &.{},
    buf_len: usize = 0,
    /// Bytes handed to the file so far. Used as the offset when a file closed
    /// to save descriptors is reopened and appended to.
    written: u64 = 0,
    append_at_written: bool = false,
    state: enum { new, open, closed, done } = .new,
    /// A filter stopped reading; further data for it is dropped.
    dead: bool = false,
};

const Splitter = struct {
    io: Io,
    gpa: Allocator,
    opts: Options,
    diag: *Diagnostic,
    namer: *Namer,
    dir: Io.Dir,
    input: Io.File,
    stdout: Io.File,
    /// Inode of a regular-file input, to refuse overwriting it.
    input_inode: ?Io.File.INode,
    buf: []u8,
    out_buf: []u8,
    out_len: usize = 0,
    cur: OutFile = .{},
    /// Descriptors ran out in round-robin mode: close each file after use.
    fd_pressure: bool = false,

    const Fail = RunError;

    fn fail(s: *Splitter, kind: Diagnostic.Kind, file_name: []const u8, cause: ?anyerror) Fail {
        s.diag.set(kind, file_name, cause);
        return error.Failed;
    }

    fn oom(s: *Splitter) Fail {
        return s.fail(.out_of_memory, "", error.OutOfMemory);
    }

    // -- input --

    fn readInput(s: *Splitter) Fail!usize {
        return s.input.readStreaming(s.io, &.{s.buf}) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => s.fail(.read_input, s.opts.input_name, e),
        };
    }

    // -- standard output (extracted chunks) --

    fn stdoutWrite(s: *Splitter, bytes: []const u8) Fail!void {
        if (bytes.len > s.out_buf.len - s.out_len) {
            try s.stdoutFlush();
            if (bytes.len >= s.out_buf.len) {
                s.stdout.writeStreamingAll(s.io, bytes) catch |e| return s.fail(.write_stdout, "", e);
                return;
            }
        }
        @memcpy(s.out_buf[s.out_len..][0..bytes.len], bytes);
        s.out_len += bytes.len;
    }

    fn stdoutFlush(s: *Splitter) Fail!void {
        if (s.out_len == 0) return;
        const n = s.out_len;
        s.out_len = 0;
        s.stdout.writeStreamingAll(s.io, s.out_buf[0..n]) catch |e| return s.fail(.write_stdout, "", e);
    }

    // -- output files --

    fn observe(s: *Splitter, ev: Event) void {
        if (s.opts.observer) |o| o.on_event(o.context, ev);
    }

    fn nextName(s: *Splitter) Fail![]const u8 {
        return s.namer.next() catch |e| switch (e) {
            error.SuffixesExhausted => s.fail(.suffixes_exhausted, "", null),
            error.OutOfMemory => s.oom(),
        };
    }

    fn setName(s: *Splitter, of: *OutFile, name: []const u8) Fail!void {
        const copy = s.gpa.dupe(u8, name) catch return s.oom();
        s.gpa.free(of.name);
        of.name = copy;
    }

    /// Create (or reopen for appending) the destination of `of`.
    fn openOutput(s: *Splitter, of: *OutFile) Fail!void {
        std.debug.assert(of.state == .new or of.state == .closed);
        if (s.opts.filter) |cmd| {
            std.debug.assert(of.state == .new);
            try s.spawnFilter(of, cmd);
        } else if (of.state == .new) {
            s.observe(.{ .creating = of.name });
            of.file = try s.createOutputFile(of.name);
        } else {
            // Reopened after being closed to stay under the descriptor limit.
            of.file = s.dir.openFile(s.io, of.name, .{ .mode = .write_only }) catch |e|
                return s.reopenFailure(of, e);
            of.append_at_written = true;
        }
        of.state = .open;
    }

    fn reopenFailure(s: *Splitter, of: *OutFile, e: anyerror) Fail {
        return s.fail(.create_output, of.name, e);
    }

    /// Create a new file, or truncate an existing one unless it is the input.
    fn createOutputFile(s: *Splitter, name: []const u8) Fail!Io.File {
        if (s.dir.createFile(s.io, name, .{ .truncate = false, .exclusive = true })) |f| {
            return f;
        } else |e| if (e != error.PathAlreadyExists) return s.fail(.create_output, name, e);

        const f = s.dir.createFile(s.io, name, .{ .truncate = false }) catch |e|
            return s.fail(.create_output, name, e);
        errdefer f.close(s.io);
        const st = f.stat(s.io) catch |e| return s.fail(.create_output, name, e);
        if (s.input_inode) |ino| {
            if (st.kind == .file and st.inode == ino) return s.fail(.overwrite_input, name, null);
        }
        if (st.kind == .file) {
            f.setLength(s.io, 0) catch |e| return s.fail(.create_output, name, e);
        }
        return f;
    }

    fn spawnFilter(s: *Splitter, of: *OutFile, cmd: []const u8) Fail!void {
        var env = if (s.opts.environ) |e|
            (e.clone(s.gpa) catch return s.oom())
        else
            std.process.Environ.Map.init(s.gpa);
        defer env.deinit();
        env.put("FILE", of.name) catch return s.oom();
        s.observe(.{ .executing = of.name });
        var child = std.process.spawn(s.io, .{
            .argv = &.{ s.opts.shell, "-c", cmd },
            .environ_map = &env,
            .stdin = .pipe,
        }) catch |e| return s.fail(.filter_spawn, of.name, e);
        of.file = child.stdin.?;
        child.stdin = null;
        of.child = child;
    }

    fn writeDirect(s: *Splitter, of: *OutFile, bytes: []const u8) Fail!void {
        if (of.dead or bytes.len == 0) return;
        const f = of.file.?;
        const res = if (of.append_at_written)
            f.writePositionalAll(s.io, bytes, of.written)
        else
            f.writeStreamingAll(s.io, bytes);
        res catch |e| {
            // A filter that stopped reading is not an error (GNU: ignorable).
            if (s.opts.filter != null and e == error.BrokenPipe) {
                of.dead = true;
                return;
            }
            return s.fail(.write_output, of.name, e);
        };
        of.written += bytes.len;
    }

    fn flushOut(s: *Splitter, of: *OutFile) Fail!void {
        if (of.buf_len == 0) return;
        const n = of.buf_len;
        of.buf_len = 0;
        try s.writeDirect(of, of.buf[0..n]);
    }

    fn writeOut(s: *Splitter, of: *OutFile, bytes: []const u8) Fail!void {
        if (of.buf.len == 0) return s.writeDirect(of, bytes);
        if (bytes.len > of.buf.len - of.buf_len) {
            try s.flushOut(of);
            if (bytes.len >= of.buf.len) return s.writeDirect(of, bytes);
        }
        @memcpy(of.buf[of.buf_len..][0..bytes.len], bytes);
        of.buf_len += bytes.len;
    }

    /// Release the descriptor but remember how to continue (not for filters).
    fn suspendOut(s: *Splitter, of: *OutFile) Fail!void {
        std.debug.assert(of.state == .open and s.opts.filter == null);
        try s.flushOut(of);
        of.file.?.close(s.io);
        of.file = null;
        of.state = .closed;
    }

    /// Finish `of`: flush, close, and for a filter wait for it and judge its
    /// exit status (GNU `closeout`).
    fn closeOut(s: *Splitter, of: *OutFile) Fail!void {
        if (of.state != .open) return;
        const flushed = s.flushOut(of);
        of.file.?.close(s.io);
        of.file = null;
        of.state = .done;
        if (of.child) |*child| {
            const term = child.wait(s.io) catch |e| {
                of.child = null;
                return s.fail(.filter_wait, of.name, e);
            };
            of.child = null;
            switch (term) {
                .exited => |code| if (code != 0) {
                    s.diag.exit_status = code;
                    return s.fail(.filter_exit, of.name, null);
                },
                .signal => |sig| {
                    const num: u32 = @backingInt(sig);
                    if (num != @backingInt(std.posix.SIG.PIPE)) {
                        s.diag.signal = num;
                        const st = s.fail(.filter_signal, of.name, null);
                        s.diag.exit_status = @intCast(@min(num + 128, 255));
                        return st;
                    }
                },
                else => return s.fail(.filter_wait, of.name, error.Unexpected),
            }
        }
        try flushed;
    }

    /// Sequential modes: finish the current file and start the next one.
    fn begin(s: *Splitter) Fail!void {
        try s.closeOut(&s.cur);
        const name = try s.nextName();
        try s.setName(&s.cur, name);
        s.cur.state = .new;
        s.cur.written = 0;
        s.cur.dead = false;
        try s.openOutput(&s.cur);
    }

    /// Write `bytes`, first starting a new file when `new_file` is set.
    fn emit(s: *Splitter, new_file: bool, bytes: []const u8) Fail!void {
        if (new_file) try s.begin();
        try s.writeOut(&s.cur, bytes);
    }

    /// Start an empty file unless empty files are elided.
    fn emitEmpty(s: *Splitter) Fail!void {
        if (s.opts.elide_empty) return;
        try s.begin();
    }

    // -- modes --

    /// `-l N` (and obsolete `-N`).
    fn splitLines(s: *Splitter, n_lines: u64) Fail!void {
        const sep = s.opts.separator;
        var count: u64 = 0;
        var new_file = true;
        while (true) {
            const n = try s.readInput();
            if (n == 0) return;
            const chunk = s.buf[0..n];
            var start: usize = 0;
            var pos: usize = 0;
            while (std.mem.indexOfScalarPos(u8, chunk, pos, sep)) |idx| {
                pos = idx + 1;
                count += 1;
                if (count >= n_lines) {
                    try s.emit(new_file, chunk[start..pos]);
                    start = pos;
                    new_file = true;
                    count = 0;
                }
            }
            if (start < n) {
                try s.emit(new_file, chunk[start..]);
                new_file = false;
            }
        }
    }

    /// `-b N`, and `-n N` (with `rem_bytes` leading files one byte longer and
    /// exactly `max_files` files). `max_files == 0` means unlimited.
    fn splitBytes(s: *Splitter, n_bytes: u64, rem_bytes: u64, max_files: u64) Fail!void {
        var opened: u64 = 0;
        var to_write: u64 = n_bytes + @intFromBool(rem_bytes > 0);
        var new_file = true;
        read: while (to_write > 0) {
            const n = try s.readInput();
            if (n == 0) break;
            var data = s.buf[0..n];
            while (data.len > 0) {
                if (to_write == 0) break :read; // surplus beyond the planned size
                const take: usize = @intCast(@min(to_write, data.len));
                try s.emit(new_file, data[0..take]);
                if (new_file) opened += 1;
                new_file = false;
                data = data[take..];
                to_write -= take;
                if (to_write == 0) {
                    if (max_files != 0 and opened >= max_files) break :read;
                    new_file = true;
                    to_write = n_bytes + @intFromBool(opened < rem_bytes);
                }
            }
        }
        // `-n N` always produces N files.
        while (opened < max_files) : (opened += 1) try s.emitEmpty();
    }

    /// `-C N`: whole records up to N bytes per file; a record longer than N
    /// is cut into N-byte pieces, starting in a fresh file.
    fn splitLineBytes(s: *Splitter, n_bytes: u64) Fail!void {
        const sep = s.opts.separator;
        const max: usize = @intCast(@min(n_bytes, std.math.maxInt(usize)));
        var n_out: usize = 0; // bytes in the current file; 0 = start a new one
        var hold: std.ArrayList(u8) = .empty; // unwritten start of the current record
        defer hold.deinit(s.gpa);

        while (true) {
            const n = try s.readInput();
            if (n == 0) break;
            const chunk = s.buf[0..n];
            var pos: usize = 0;
            while (pos < n) {
                if (hold.items.len == 0) {
                    // Fast path: every record that ends inside the room left in
                    // the current file goes out in one piece, found with a
                    // single backwards search instead of record by record.
                    const room = max - n_out;
                    const window = chunk[pos..][0..@min(room, n - pos)];
                    if (std.mem.lastIndexOfScalar(u8, window, sep)) |last| {
                        try s.emit(n_out == 0, window[0 .. last + 1]);
                        n_out += last + 1;
                        pos += last + 1;
                        continue;
                    }
                }
                // One record that does not fit, or an unfinished one.
                const end = if (std.mem.indexOfScalarPos(u8, chunk, pos, sep)) |i| i + 1 else n;
                const terminated = chunk[end - 1] == sep;
                const seg = chunk[pos..end];
                pos = end;
                hold.appendSlice(s.gpa, seg) catch return s.oom();
                try s.settleRecord(&hold, &n_out, max, terminated);
            }
        }
        if (hold.items.len > 0) try s.settleRecord(&hold, &n_out, max, true);
    }

    /// Write out as much of the held record as can be decided. `complete`
    /// means the record is finished (terminator seen, or end of input).
    fn settleRecord(s: *Splitter, hold: *std.ArrayList(u8), n_out: *usize, max: usize, complete: bool) Fail!void {
        // The record cannot fit in the current file: close it.
        if (n_out.* > 0 and hold.items.len > max - n_out.*) n_out.* = 0;
        // Longer than a whole file: peel off full-size pieces. An unfinished
        // record of exactly `max` bytes is already too long, since its
        // terminator has not arrived yet.
        var off: usize = 0;
        while (if (complete) hold.items.len - off > max else hold.items.len - off >= max) {
            try s.emit(true, hold.items[off..][0..max]);
            off += max;
            n_out.* = 0;
        }
        if (off > 0) {
            const rest = hold.items.len - off;
            std.mem.copyForwards(u8, hold.items[0..rest], hold.items[off..]);
            hold.shrinkRetainingCapacity(rest);
        }
        if (complete and hold.items.len > 0) {
            try s.emit(n_out.* == 0, hold.items);
            n_out.* += hold.items.len;
            hold.clearRetainingCapacity();
        }
    }

    // -- modes that need the input size --

    const Source = struct {
        file: ?Io.File,
        mem: []u8,
        size: u64,
        pos: u64 = 0,

        fn read(src: *Source, s: *Splitter, buf: []u8) Fail!usize {
            const want: usize = @intCast(@min(buf.len, src.size -| src.pos));
            if (want == 0) return 0;
            const n: usize = if (src.file) |f|
                f.readPositional(s.io, &.{buf[0..want]}, src.pos) catch |e|
                    return s.fail(.read_input, s.opts.input_name, e)
            else blk: {
                const p: usize = @intCast(src.pos);
                @memcpy(buf[0..want], src.mem[p..][0..want]);
                break :blk want;
            };
            src.pos += n;
            return n;
        }
    };

    /// A regular file is read in place with positional reads; anything else
    /// (pipe, terminal, empty-looking /proc file) is held in memory so its
    /// size is known before splitting.
    fn openSource(s: *Splitter) Fail!Source {
        const st = s.input.stat(s.io) catch |e| return s.fail(.read_input, s.opts.input_name, e);
        if (st.kind == .file and st.size > 0) return .{ .file = s.input, .mem = &.{}, .size = st.size };
        var all: std.ArrayList(u8) = .empty;
        errdefer all.deinit(s.gpa);
        while (true) {
            const n = try s.readInput();
            if (n == 0) break;
            if (all.items.len + n > s.opts.max_spool_bytes) return s.fail(.size_unknown, s.opts.input_name, error.StreamTooLong);
            all.appendSlice(s.gpa, s.buf[0..n]) catch return s.oom();
        }
        const mem = all.toOwnedSlice(s.gpa) catch return s.oom();
        return .{ .file = null, .mem = mem, .size = mem.len };
    }

    /// `-n K/N`: write chunk K of N to standard output.
    fn extractBytes(s: *Splitter, src: *Source, k: u64, n: u64) Fail!void {
        const size = src.size;
        const start = (k - 1) * (size / n) + @min(k - 1, size % n);
        const end = if (k == n) size else k * (size / n) + @min(k, size % n);
        src.pos = start;
        var left = end - start;
        while (left > 0) {
            const got = try src.read(s, s.buf[0..@intCast(@min(left, s.buf.len))]);
            if (got == 0) break;
            try s.stdoutWrite(s.buf[0..got]);
            left -= got;
        }
    }

    /// `-n l/N` and `-n l/K/N`: N chunks of about size/N bytes; a record
    /// belongs to the chunk in which it starts and is never split.
    fn splitLineChunks(s: *Splitter, src: *Source, k: u64, n: u64) Fail!void {
        const sep = s.opts.separator;
        const size = src.size;
        const rem = size % n;
        const chunk_size = size / n;
        var chunk_no: u64 = 1;
        var chunk_end: u64 = chunk_size + @intFromBool(rem > 0);
        var n_written: u64 = 0;
        var new_file = true;
        var truncated = false;

        if (k > 1 and size > 0) {
            // Begin one byte before chunk K so a record starting exactly at
            // its first byte is attributed correctly.
            const start = (k - 1) * chunk_size + @min(k - 1, rem) - 1;
            src.pos = start;
            n_written = start;
            chunk_no = k - 1;
            chunk_end = start + 1;
        }

        while (n_written < size) {
            const n_read = try src.read(s, s.buf[0..@intCast(@min(s.buf.len, size - n_written))]);
            if (n_read == 0) break;
            truncated = false;
            var bp: usize = 0;
            while (bp != n_read) {
                const left = n_read - bp;
                const skip: usize = if (chunk_end > n_written + 1)
                    @intCast(@min(left, chunk_end - 1 - n_written))
                else
                    0;
                var next = false;
                var bp_out: usize = n_read;
                if (std.mem.indexOfScalarPos(u8, s.buf[0..n_read], bp + skip, sep)) |i| {
                    bp_out = i + 1;
                    next = true;
                }
                const piece = s.buf[bp..bp_out];
                if (k == chunk_no) {
                    try s.stdoutWrite(piece);
                } else if (k == 0) {
                    try s.emit(new_file, piece);
                }
                n_written += piece.len;
                bp = bp_out;
                new_file = next;

                // A long record can skip whole chunks: they come out empty.
                while (next or chunk_end <= n_written) {
                    if (!next and bp == n_read) {
                        truncated = true; // refill the buffer before moving on
                        break;
                    }
                    if (k == chunk_no) return;
                    chunk_end += chunk_size + @intFromBool(chunk_no < rem);
                    chunk_no += 1;
                    if (chunk_end <= n_written) {
                        if (k == 0) try s.emitEmpty();
                    } else next = false;
                }
            }
        }
        if (truncated) chunk_no += 1;
        // `-n l/N` always produces N files.
        if (k == 0) while (chunk_no <= n) : (chunk_no += 1) try s.emitEmpty();
    }

    // -- round robin --

    /// `-n r/K/N`: print every N-th record, starting with the K-th.
    fn extractRoundRobin(s: *Splitter, k: u64, n: u64) Fail!void {
        const sep = s.opts.separator;
        var line_no: u64 = 1;
        while (true) {
            const got = try s.readInput();
            if (got == 0) break;
            const chunk = s.buf[0..got];
            var pos: usize = 0;
            while (pos < got) {
                const end = if (std.mem.indexOfScalarPos(u8, chunk, pos, sep)) |i| i + 1 else got;
                if (line_no == k) {
                    try s.stdoutWrite(chunk[pos..end]);
                    if (s.opts.unbuffered) try s.stdoutFlush();
                }
                if (chunk[end - 1] == sep) line_no = if (line_no == n) 1 else line_no + 1;
                pos = end;
            }
        }
    }

    /// Make `files[i]` writable, closing other files if descriptors run out.
    fn ensureOpen(s: *Splitter, files: []OutFile, i: usize) Fail!void {
        const of = &files[i];
        if (of.state == .open) return;
        var victim = if (i > 0) i - 1 else files.len - 1;
        while (true) {
            if (s.openOutput(of)) |_| return else |err| {
                // Only descriptor exhaustion is recoverable, and only by
                // closing one of our own files; any other failure stands.
                const cause = s.diag.cause orelse return err;
                const exhausted = cause == error.ProcessFdQuotaExceeded or cause == error.SystemFdQuotaExceeded;
                if (!exhausted or s.opts.filter != null) return err;
                while (files[victim].state != .open) {
                    victim = if (victim > 0) victim - 1 else files.len - 1;
                    if (victim == i) return err; // nothing left to close
                }
                s.diag.* = .{};
                s.fd_pressure = true;
                try s.suspendOut(&files[victim]);
            }
        }
    }

    /// `-n r/N`: deal records to N files in turn.
    fn roundRobin(s: *Splitter, n: u64) Fail!void {
        const sep = s.opts.separator;
        const count = std.math.cast(usize, n) orelse return s.oom();
        const files = s.gpa.alloc(OutFile, count) catch return s.oom();
        defer {
            for (files) |*f| {
                if (f.state == .open) f.file.?.close(s.io); // error path
                s.gpa.free(f.name);
                s.gpa.free(f.buf);
            }
            s.gpa.free(files);
        }
        for (files) |*f| f.* = .{};

        // All names are generated up front so they are consecutive however
        // the files end up being opened.
        const per_file = @min(4096, rr_buffer_budget / count);
        for (files) |*f| {
            try s.setName(f, try s.nextName());
            if (!s.opts.unbuffered and per_file >= 256) f.buf = s.gpa.alloc(u8, per_file) catch return s.oom();
        }

        var i_file: usize = 0;
        var wrapped = false;
        var wrote = false;
        read: while (true) {
            const got = try s.readInput();
            if (got == 0) break;
            const chunk = s.buf[0..got];
            var pos: usize = 0;
            while (pos < got) {
                const end = if (std.mem.indexOfScalarPos(u8, chunk, pos, sep)) |i| i + 1 else got;
                const of = &files[i_file];
                try s.ensureOpen(files, i_file);
                try s.writeOut(of, chunk[pos..end]);
                if (!of.dead) wrote = true;
                if (s.fd_pressure) try s.suspendOutIfOpen(of);
                if (chunk[end - 1] == sep) {
                    i_file += 1;
                    if (i_file == files.len) {
                        wrapped = true;
                        if (!wrote) break :read; // every filter has stopped reading
                        wrote = false;
                        i_file = 0;
                    }
                }
                pos = end;
            }
        }

        // Create the files that never got data (unless elided), then close.
        const ceiling = if (wrapped) files.len else i_file;
        for (files, 0..) |*f, i| {
            if (i >= ceiling and !s.opts.elide_empty) try s.ensureOpen(files, i);
            try s.closeOut(f);
        }
    }

    fn suspendOutIfOpen(s: *Splitter, of: *OutFile) Fail!void {
        if (of.state == .open and s.opts.filter == null) try s.suspendOut(of);
    }
};

/// Split `input` as `opts` says. `stdout` receives chunks extracted by
/// `-n K/N` modes. Returns `error.Failed` after filling `diag`.
///
/// `gpa` is used for scratch memory and is balanced before return. Files
/// created before a failure are left in place (POSIX: "split shall not delete
/// the files it created").
pub fn run(io: Io, gpa: Allocator, opts: Options, input: Io.File, stdout: Io.File, diag: *Diagnostic) RunError!void {
    diag.* = .{};
    const invalid = struct {
        fn f(d: *Diagnostic, why: anyerror) RunError {
            d.set(.invalid_options, "", why);
            return error.Failed;
        }
    }.f;

    const units: u64 = switch (opts.mode) {
        .lines, .bytes, .line_bytes => |n| n,
        .chunks, .line_chunks, .round_robin => |c| c.n,
    };
    if (units == 0) return invalid(diag, error.InvalidCount);
    switch (opts.mode) {
        .chunks, .line_chunks, .round_robin => |c| if (c.k > c.n) return invalid(diag, error.InvalidChunk),
        else => {},
    }
    if (opts.filter != null) switch (opts.mode) {
        .chunks, .line_chunks, .round_robin => |c| if (c.k != 0) return invalid(diag, error.FilterWithExtraction),
        else => {},
    };
    const plan = planSuffix(opts, null) catch |e| return invalid(diag, e);
    checkStart(opts, plan) catch |e| return invalid(diag, e);

    var namer = Namer.init(gpa, opts, plan) catch {
        diag.set(.out_of_memory, "", error.OutOfMemory);
        return error.Failed;
    };
    defer namer.deinit();

    const buf = gpa.alloc(u8, read_buffer_size) catch {
        diag.set(.out_of_memory, "", error.OutOfMemory);
        return error.Failed;
    };
    defer gpa.free(buf);
    const out_buf = gpa.alloc(u8, stdout_buffer_size) catch {
        diag.set(.out_of_memory, "", error.OutOfMemory);
        return error.Failed;
    };
    defer gpa.free(out_buf);

    // Write-behind buffer for the current output file: record-at-a-time
    // modes (-C) would otherwise issue one write(2) per record.
    const cur_buf = gpa.alloc(u8, seq_buffer_size) catch {
        diag.set(.out_of_memory, "", error.OutOfMemory);
        return error.Failed;
    };
    defer gpa.free(cur_buf);

    var s: Splitter = .{
        .io = io,
        .gpa = gpa,
        .opts = opts,
        .diag = diag,
        .namer = &namer,
        .dir = opts.dir orelse Io.Dir.cwd(),
        .input = input,
        .stdout = stdout,
        .input_inode = null,
        .buf = buf,
        .out_buf = out_buf,
        .cur = .{ .buf = cur_buf },
    };
    defer {
        s.gpa.free(s.cur.name);
        if (s.cur.state == .open) s.cur.file.?.close(io); // only reached on failure
    }

    if (input.stat(io)) |st| {
        if (st.kind == .file) s.input_inode = st.inode;
    } else |e| {
        s.diag.set(.read_input, opts.input_name, e);
        return error.Failed;
    }

    switch (opts.mode) {
        .lines => |n| try s.splitLines(n),
        .bytes => |n| try s.splitBytes(n, 0, 0),
        .line_bytes => |n| try s.splitLineBytes(n),
        .chunks, .line_chunks => |c| {
            var src = try s.openSource();
            defer gpa.free(src.mem);
            switch (opts.mode) {
                .chunks => if (c.k == 0)
                    try s.splitBytes(src.size / c.n, src.size % c.n, c.n)
                else
                    try s.extractBytes(&src, c.k, c.n),
                else => try s.splitLineChunks(&src, c.k, c.n),
            }
        },
        .round_robin => |c| if (c.k != 0) try s.extractRoundRobin(c.k, c.n) else try s.roundRobin(c.n),
    }
    try s.stdoutFlush();
    try s.closeOut(&s.cur);
}

// -- Tests --------------------------------------------------------------------

const testing = std.testing;

fn collectNames(gpa: Allocator, opts: Options, count: usize) ![][]u8 {
    const plan = try planSuffix(opts, null);
    var namer = try Namer.init(gpa, opts, plan);
    defer namer.deinit();
    const out = try gpa.alloc([]u8, count);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |n| gpa.free(n);
        gpa.free(out);
    }
    while (made < count) : (made += 1) out[made] = try gpa.dupe(u8, try namer.next());
    return out;
}

fn freeNames(gpa: Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

test "Namer: default sequence widens like POSIX/GNU (yz -> zaaa)" {
    const names = try collectNames(testing.allocator, .{}, 700);
    defer freeNames(testing.allocator, names);
    try testing.expectEqualStrings("xaa", names[0]);
    try testing.expectEqualStrings("xab", names[1]);
    try testing.expectEqualStrings("xaz", names[25]);
    try testing.expectEqualStrings("xba", names[26]);
    try testing.expectEqualStrings("xyz", names[649]);
    try testing.expectEqualStrings("xzaaa", names[650]);
    try testing.expectEqualStrings("xzaab", names[651]);
}

test "Namer: widening a second time freezes another character" {
    // 650 two-letter names + 26^3 - 26^2 ... names with prefix "xz" and three
    // letters until the first of them reaches 'z' again.
    const count = 650 + 25 * 26 * 26 + 1;
    const names = try collectNames(testing.allocator, .{}, count);
    defer freeNames(testing.allocator, names);
    try testing.expectEqualStrings("xzyzz", names[count - 2]);
    try testing.expectEqualStrings("xzzaaaa", names[count - 1]);
}

test "Namer: explicit length does not widen and eventually exhausts" {
    const opts: Options = .{ .suffix_length = 1, .alphabet = .decimal };
    const plan = try planSuffix(opts, null);
    var namer = try Namer.init(testing.allocator, opts, plan);
    defer namer.deinit();
    for (0..10) |_| _ = try namer.next();
    try testing.expectError(error.SuffixesExhausted, namer.next());
}

test "Namer: numeric start, additional suffix, prefix" {
    const opts: Options = .{ .alphabet = .decimal, .start = "08", .prefix = "p-", .additional_suffix = ".txt", .suffix_length = 3 };
    const plan = try planSuffix(opts, null);
    try checkStart(opts, plan);
    var namer = try Namer.init(testing.allocator, opts, plan);
    defer namer.deinit();
    try testing.expectEqualStrings("p-008.txt", try namer.next());
    try testing.expectEqualStrings("p-009.txt", try namer.next());
    try testing.expectEqualStrings("p-010.txt", try namer.next());
}

test "Namer: hex start uses alphabet positions" {
    const opts: Options = .{ .alphabet = .hex, .start = "e", .suffix_length = 2 };
    const plan = try planSuffix(opts, null);
    var namer = try Namer.init(testing.allocator, opts, plan);
    defer namer.deinit();
    try testing.expectEqualStrings("x0e", try namer.next());
    try testing.expectEqualStrings("x0f", try namer.next());
    try testing.expectEqualStrings("x10", try namer.next());
}

test "planSuffix: -n sizes the suffix and rejects a short -a" {
    var need: usize = 0;
    const p = try planSuffix(.{ .mode = .{ .chunks = .{ .n = 700 } } }, &need);
    try testing.expectEqual(@as(usize, 3), p.length);
    try testing.expect(!p.auto);
    try testing.expectError(error.SuffixTooShort, planSuffix(.{ .mode = .{ .chunks = .{ .n = 700 } }, .suffix_length = 2 }, &need));
    try testing.expectEqual(@as(usize, 3), need);
    // 26 chunks fit in two letters; 27 does not need three (indices 0..26 -> 2 digits).
    try testing.expectEqual(@as(usize, 2), (try planSuffix(.{ .mode = .{ .chunks = .{ .n = 27 } } }, null)).length);
}

test "checkStart" {
    const dec: Options = .{ .alphabet = .decimal, .start = "100" };
    try testing.expectError(error.StartTooLarge, checkStart(dec, try planSuffix(dec, null)));
    const bad: Options = .{ .alphabet = .decimal, .start = "1a" };
    try testing.expectError(error.InvalidStart, checkStart(bad, try planSuffix(bad, null)));
}

test "parseSize" {
    try testing.expectEqual(@as(?u64, 10), parseSize("10", .plain));
    try testing.expectEqual(@as(?u64, null), parseSize("1K", .plain));
    try testing.expectEqual(@as(?u64, null), parseSize("K", .plain));
    try testing.expectEqual(@as(?u64, 512), parseSize("b", .bytes));
    try testing.expectEqual(@as(?u64, 2048), parseSize("2K", .bytes));
    try testing.expectEqual(@as(?u64, 2000), parseSize("2KB", .bytes));
    try testing.expectEqual(@as(?u64, 2048), parseSize("2KiB", .bytes));
    try testing.expectEqual(@as(?u64, 1 << 20), parseSize("1m", .bytes));
    try testing.expectEqual(@as(?u64, std.math.maxInt(i64)), parseSize("99999999999999999999999", .bytes));
    try testing.expectEqual(@as(?u64, std.math.maxInt(i64)), parseSize("1Q", .bytes));
    try testing.expectEqual(@as(?u64, null), parseSize("-1", .bytes));
    try testing.expectEqual(@as(?u64, null), parseSize("1x", .bytes));
    try testing.expectEqual(@as(?u64, null), parseSize("", .bytes));
    try testing.expectEqual(@as(?u64, 0), parseSize("0", .plain));
}

/// Run a split in a fresh temporary directory and return the sorted
/// "name:content" listing, joined with '|'.
fn runInTmp(gpa: Allocator, opts_in: Options, input: []const u8) ![]u8 {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var opts = opts_in;
    opts.dir = tmp.dir;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input", .data = input });
    const in = try tmp.dir.openFile(testing.io, "input", .{});
    defer in.close(testing.io);
    var diag: Diagnostic = .{};
    try run(testing.io, gpa, opts, in, Io.File.stdout(), &diag);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |e| {
        if (std.mem.eql(u8, e.name, "input")) continue;
        try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (names.items, 0..) |n, i| {
        if (i > 0) try out.append(gpa, '|');
        const data = try tmp.dir.readFileAlloc(testing.io, n, gpa, .limited(1 << 20));
        defer gpa.free(data);
        try out.print(gpa, "{s}:{s}", .{ n, data });
    }
    return out.toOwnedSlice(gpa);
}

fn expectSplit(opts: Options, input: []const u8, expected: []const u8) !void {
    const got = try runInTmp(testing.allocator, opts, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "run: lines" {
    try expectSplit(.{ .mode = .{ .lines = 2 } }, "a\nb\nc\nd\ne", "xaa:a\nb\n|xab:c\nd\n|xac:e");
    try expectSplit(.{ .mode = .{ .lines = 2 } }, "", "");
    try expectSplit(.{ .mode = .{ .lines = 1 }, .separator = 0 }, "a\x00b\x00", "xaa:a\x00|xab:b\x00");
}

test "run: bytes" {
    try expectSplit(.{ .mode = .{ .bytes = 3 }, .prefix = "p" }, "abcdefgh", "paa:abc|pab:def|pac:gh");
    try expectSplit(.{ .mode = .{ .bytes = 4 }, .alphabet = .decimal }, "abcdefgh", "x00:abcd|x01:efgh");
}

test "run: line bytes keeps records whole, cuts overlong ones" {
    try expectSplit(.{ .mode = .{ .line_bytes = 6 } }, "ab\ncd\nef\n", "xaa:ab\ncd\n|xab:ef\n");
    try expectSplit(.{ .mode = .{ .line_bytes = 4 } }, "abcdefghij\nk\n", "xaa:abcd|xab:efgh|xac:ij\n|xad:k\n");
}

test "run: -n N distributes the remainder to the first files" {
    try expectSplit(.{ .mode = .{ .chunks = .{ .n = 3 } } }, "0123456", "xaa:012|xab:34|xac:56");
    try expectSplit(.{ .mode = .{ .chunks = .{ .n = 4 } }, .elide_empty = true }, "ab", "xaa:a|xab:b");
    try expectSplit(.{ .mode = .{ .chunks = .{ .n = 4 } } }, "ab", "xaa:a|xab:b|xac:|xad:");
}

test "run: -n l/N and r/N (GNU manual examples)" {
    const k = "06\n07\n08\n09\n10\n";
    try expectSplit(.{ .mode = .{ .line_chunks = .{ .n = 3 } } }, k, "xaa:06\n07\n|xab:08\n09\n|xac:10\n");
    try expectSplit(.{ .mode = .{ .round_robin = .{ .n = 3 } } }, k, "xaa:06\n09\n|xab:07\n10\n|xac:08\n");
}

test "run: refuses invalid options" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: Diagnostic = .{};
    try testing.expectError(error.Failed, run(testing.io, testing.allocator, .{ .mode = .{ .lines = 0 }, .dir = tmp.dir }, Io.File.stdin(), Io.File.stdout(), &diag));
    try testing.expectEqual(Diagnostic.Kind.invalid_options, diag.kind);
}

test "run: output that is the input is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "xaa", .data = "a\nb\n" });
    const in = try tmp.dir.openFile(testing.io, "xaa", .{});
    defer in.close(testing.io);
    var diag: Diagnostic = .{};
    try testing.expectError(error.Failed, run(testing.io, testing.allocator, .{ .mode = .{ .lines = 1 }, .dir = tmp.dir }, in, Io.File.stdout(), &diag));
    try testing.expectEqual(Diagnostic.Kind.overwrite_input, diag.kind);
    try testing.expectEqualStrings("xaa", diag.name());
    // The input is intact.
    const data = try tmp.dir.readFileAlloc(testing.io, "xaa", testing.allocator, .limited(100));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("a\nb\n", data);
}
