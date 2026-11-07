//! Shared command-line facilities for the executable wrappers: the
//! per-invocation context handed to every command frontend, option-matching
//! helpers that follow getopt_long, and diagnostics.
//!
//! This file is wrapper-side only; the reusable logic is in `util_unix`
//! (src/root.zig). Nothing here owns process-wide state: commands receive
//! everything through `Context`, so one implementation serves the individual
//! and multicall executables (SPEC §8).

const std = @import("std");
const Io = std.Io;

pub const version = "0.0.0-dev";

/// Everything a command frontend needs for one invocation.
pub const Context = struct {
    /// Command name as the user invoked it (used in diagnostics).
    name: []const u8,
    /// Arguments after the command name. Borrowed; valid for the whole run.
    args: []const [:0]const u8,
    io: Io,
    /// General-purpose allocator for temporary allocations.
    gpa: std.mem.Allocator,
    /// Environment variables; null when the host provides none (tests).
    environ: ?*const std.process.Environ.Map = null,
};

/// A command frontend: returns the process exit status.
pub const CommandFn = *const fn (ctx: Context) u8;

/// Value of an environment variable, or null when unset or unavailable.
pub fn getenv(ctx: Context, key: []const u8) ?[]const u8 {
    const map = ctx.environ orelse return null;
    return map.get(key);
}

/// Result of matching a "--name" against a command's long options, following
/// getopt_long: an exact match wins, otherwise a unique prefix is accepted.
pub const LongMatch = union(enum) { found: usize, none, ambiguous };

/// `name` is the option text after "--" and before any "=value".
pub fn matchLong(name: []const u8, names: []const []const u8) LongMatch {
    var found: ?usize = null;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return .{ .found = i };
        if (name.len > 0 and std.mem.startsWith(u8, n, name)) {
            if (found != null) return .ambiguous;
            found = i;
        }
    }
    return if (found) |i| .{ .found = i } else .none;
}

/// Print the standard "invalid option" diagnostic for a short option.
pub fn invalidShort(ctx: Context, c: u8) void {
    warn(ctx, "invalid option -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
}

/// Diagnostic for an unknown long option.
pub fn unrecognizedLong(ctx: Context, arg: []const u8) void {
    warn(ctx, "unrecognized option '{s}'\nTry '{s} --help' for more information.", .{ arg, ctx.name });
}

/// Diagnostic for an ambiguous abbreviation, listing the candidates the way
/// glibc's getopt_long does.
pub fn ambiguousLong(ctx: Context, arg: []const u8, names: []const []const u8) void {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
    const typed = arg[2..eq];
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    w.print("option '{s}' is ambiguous; possibilities:", .{arg}) catch {};
    for (names) |n| {
        if (std.mem.startsWith(u8, n, typed)) w.print(" '--{s}'", .{n}) catch {};
    }
    warn(ctx, "{s}\nTry '{s} --help' for more information.", .{ w.buffered(), ctx.name });
}

/// Write `text` to stdout. Returns false on write failure (e.g. closed pipe);
/// callers decide the exit status.
pub fn writeStdout(io: Io, text: []const u8) bool {
    Io.File.stdout().writeStreamingAll(io, text) catch return false;
    return true;
}

/// Print `<name> (util-unix) <version>` to stdout.
pub fn printVersion(ctx: Context) bool {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} (util-unix) {s}\n", .{ ctx.name, version }) catch unreachable;
    return writeStdout(ctx.io, line);
}

/// Print a diagnostic `<name>: <message>\n` to stderr. Best effort.
pub fn warn(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: " ++ fmt ++ "\n", .{ctx.name} ++ args) catch return;
    Io.File.stderr().writeStreamingAll(ctx.io, msg) catch {};
}

/// Human-readable text for common file errors, matching the strerror()
/// wording GNU tools print. Falls back to the Zig error name.
pub fn errText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.PermissionDenied => "Operation not permitted",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.BrokenPipe => "Broken pipe",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.PathAlreadyExists => "File exists",
        error.DirNotEmpty => "Directory not empty",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.NoSpaceLeft => "No space left on device",
        error.DiskQuota => "Disk quota exceeded",
        error.FileBusy => "Device or resource busy",
        error.LinkQuotaExceeded => "Too many links",
        error.SystemResources => "Cannot allocate memory",
        error.ProcessFdQuotaExceeded => "Too many open files",
        error.SystemFdQuotaExceeded => "Too many open files in system",
        error.InputOutput => "Input/output error",
        error.FileTooBig => "File too large",
        error.InvalidArgument => "Invalid argument",
        error.Unsupported => "Operation not supported",
        else => @errorName(err),
    };
}

/// A file name formatted the way GNU's quotef()/quoteaf() show it in the C
/// locale: `quotef` quotes only when needed, `quoteaf` always. Use with `{f}`.
pub const Quoted = struct {
    text: []const u8,
    always: bool,

    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        var plain = !q.always;
        if (plain) {
            if (q.text.len == 0) plain = false;
            for (q.text, 0..) |c, i| {
                const special = switch (c) {
                    ' ', '\t', '\n', '|', '&', ';', '<', '>', '(', ')', '$', '`', '\\', '"', '\'', '*', '?', '[', ']', '{', '}', '!', '^' => true,
                    '~', '#' => i == 0,
                    else => c < 0x20 or c == 0x7f,
                };
                if (special) plain = false;
            }
        }
        if (plain) return w.writeAll(q.text);
        var control = false;
        for (q.text) |c| if (c < 0x20 or c == 0x7f) {
            control = true;
        };
        if (control) {
            try w.writeAll("$'");
            for (q.text) |c| switch (c) {
                '\n' => try w.writeAll("\\n"),
                '\t' => try w.writeAll("\\t"),
                '\'' => try w.writeAll("\\'"),
                '\\' => try w.writeAll("\\\\"),
                else => if (c < 0x20 or c == 0x7f) try w.print("\\{o:0>3}", .{c}) else try w.writeByte(c),
            };
            return w.writeByte('\'');
        }
        try w.writeByte('\'');
        for (q.text) |c| {
            if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
        }
        try w.writeByte('\'');
    }
};

/// Quote only if the shell would need it (GNU `quotef`).
pub fn quotef(text: []const u8) Quoted {
    return .{ .text = text, .always = false };
}

/// Always quote (GNU `quoteaf`, also GNU `quote` for non-file text).
pub fn quoteaf(text: []const u8) Quoted {
    return .{ .text = text, .always = true };
}

test "quotef/quoteaf follow GNU C-locale quoting" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("xaa", try std.fmt.bufPrint(&buf, "{f}", .{quotef("xaa")}));
    try t.expectEqualStrings("'xaa'", try std.fmt.bufPrint(&buf, "{f}", .{quoteaf("xaa")}));
    try t.expectEqualStrings("'p qaa'", try std.fmt.bufPrint(&buf, "{f}", .{quotef("p qaa")}));
    try t.expectEqualStrings("'it'\\''s'", try std.fmt.bufPrint(&buf, "{f}", .{quotef("it's")}));
    try t.expectEqualStrings("$'a\\nb'", try std.fmt.bufPrint(&buf, "{f}", .{quotef("a\nb")}));
}
