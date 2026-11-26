// SPDX-License-Identifier: GPL-2.0-or-later
//! `util_unix.sh`: a POSIX shell as a library (decision 0009).
//!
//! `Shell.init(env, options)` builds an interpreter; `runString` parses and
//! runs text; `parse` gives the syntax tree without running; hosts register
//! extra builtins with `registerBuiltin` and read or write variables with
//! `getVar`/`setVar`. The library never exits the process and reports
//! diagnostics through `Options.reporter` (default: standard error in dash's
//! format).

pub const ast = @import("sh/ast.zig");
pub const lexer = @import("sh/lexer.zig");
pub const parser = @import("sh/parser.zig");
pub const arith = @import("sh/arith.zig");
pub const fmtfloat = @import("sh/fmtfloat.zig");
pub const pattern = @import("sh/pattern.zig");
pub const expand = @import("sh/expand.zig");
pub const exec = @import("sh/exec.zig");
pub const builtins = @import("sh/builtins.zig");
pub const shell = @import("sh/shell.zig");
pub const diag = @import("sh/diag.zig");
pub const lint = @import("sh/lint.zig");
pub const jobs = @import("sh/jobs.zig");
pub const jobcmd = @import("sh/jobcmd.zig");
pub const history = @import("sh/history.zig");
pub const completion = @import("sh/completion.zig");
pub const interactive = @import("sh/interactive.zig");
pub const readline = @import("sh/readline.zig");

pub const Shell = shell.Shell;
pub const Env = shell.Env;
pub const Options = shell.Options;
pub const Flags = shell.Flags;
pub const Diagnostic = shell.Diagnostic;
pub const HostBuiltin = shell.HostBuiltin;

test {
    _ = ast;
    _ = lexer;
    _ = parser;
    _ = arith;
    _ = fmtfloat;
    _ = pattern;
    _ = expand;
    _ = exec;
    _ = builtins;
    _ = shell;
    _ = diag;
    _ = lint;
    _ = jobs;
    _ = jobcmd;
    _ = history;
    _ = readline;
    _ = completion;
    _ = interactive;
}

test "a shell that runs out of memory keeps its tables sound" {
    const std = @import("std");
    const quiet = struct {
        fn report(_: ?*anyopaque, _: *const shell.Diagnostic) void {}
        fn builtin(_: ?*anyopaque, _: *shell.Shell, _: []const []const u8) u8 {
            return 0;
        }
    };
    // fail every allocation in turn; the testing allocator reports what is
    // leaked or freed twice, and a bad table entry crashes `deinit`
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
        run: {
            const s = shell.Shell.init(.{ .io = std.testing.io, .gpa = failing.allocator() }, .{ .reporter = quiet.report }) catch break :run;
            defer s.deinit();
            s.registerBuiltin("hosted", .{ .run = quiet.builtin }) catch {};
            _ = s.runString("export X1; readonly Y1; alias a1=b; alias a1=c a2=d; hash sh sh; f() { :; }; f() { :; }; X2=1; X2=2 :; PATH=/bin :; hosted") catch {};
        }
        if (!failing.has_induced_failure) break;
    }
}

/// Fails one allocation and lets every later one succeed, so that code which
/// carries on after a failure is seen to.
const FailOnce = struct {
    child: @import("std").mem.Allocator,
    left: usize,
    failed: bool = false,

    const std = @import("std");
    const Allocator = std.mem.Allocator;

    fn allocator(f: *FailOnce) Allocator {
        return .{ .ptr = f, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const f: *FailOnce = @ptrCast(@alignCast(ctx));
        if (!f.failed) {
            if (f.left == 0) {
                f.failed = true;
                return null;
            }
            f.left -= 1;
        }
        return f.child.rawAlloc(len, alignment, ra);
    }
    // never in place: every growth goes through `alloc`
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const f: *FailOnce = @ptrCast(@alignCast(ctx));
        f.child.rawFree(memory, alignment, ra);
    }
};

test "a command is never run with what a failed allocation left behind" {
    const std = @import("std");
    // `see TAG VALUE...` checks the values the script has built by then
    const Check = struct {
        wrong: ?[]const u8 = null,
        which: [64]u8 = undefined,

        fn report(_: ?*anyopaque, _: *const shell.Diagnostic) void {}
        fn see(ctx: ?*anyopaque, _: *shell.Shell, args: []const []const u8) u8 {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            const wanted = [_]struct { []const u8, []const u8 }{
                .{ "assign", "hellohello" }, .{ "export", "hellohello!" }, .{ "param", "one two" },
                .{ "subst", "<hellohello>" }, .{ "func", "in:arg" },       .{ "local", "inner outer" },
                .{ "prefix", "p p-q" },       .{ "getopts", "a:val" },      .{ "arith", "42" },
                .{ "for", "xyz" },            .{ "readonly", "kept" },      .{ "default", "dflt dflt" },
            };
            for (wanted) |w| if (std.mem.eql(u8, args[1], w[0])) {
                const got = std.mem.join(std.testing.allocator, " ", args[2..]) catch return 0;
                defer std.testing.allocator.free(got);
                if (!std.mem.eql(u8, got, w[1])) {
                    const text = std.fmt.bufPrint(&c.which, "{s}: '{s}'", .{ args[1], got }) catch "?";
                    c.wrong = text;
                }
            };
            return 0;
        }
    };
    const script =
        \\set -e
        \\a=hello; b=$a$a; see assign "$b"
        \\export c="$b!"; see export "$c"
        \\set -- one two; see param "$*"
        \\see subst "<${b}>"
        \\f() { see func "in:$1"; }; f arg
        \\x=outer; g() { local x=inner; y=$x; }; g; see local "$y $x"
        \\P=p Q=$P-q eval 'see prefix "$P" "$Q"'
        \\getopts a: o -a val; see getopts "$o:$OPTARG"
        \\see arith "$((6*7))"
        \\r=; for i in x y z; do r=$r$i; done; see for "$r"
        \\readonly k=kept; see readonly "$k"
        \\unset u; : "${u:=dflt}"; see default "${u}" "$u"
        \\alias al=: other=true; hash sh
    ;
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var failing: FailOnce = .{ .child = std.testing.allocator, .left = fail_at };
        var check: Check = .{};
        run: {
            const s = shell.Shell.init(.{ .io = std.testing.io, .gpa = failing.allocator() }, .{ .reporter = Check.report }) catch break :run;
            defer s.deinit();
            s.registerBuiltin("see", .{ .ctx = &check, .run = Check.see }) catch break :run;
            _ = s.runString(script) catch {};
        }
        if (check.wrong) |w| {
            std.debug.print("allocation {d} failed and the script went on with {s}\n", .{ fail_at, w });
            return error.SwallowedAllocationFailure;
        }
        if (!failing.failed) break;
    }
}

test "fc re-runs its own copy of a history line" {
    const std = @import("std");
    const Seen = struct {
        text: [64]u8 = undefined,
        len: usize = 0,
        fn report(_: ?*anyopaque, _: *const shell.Diagnostic) void {}
        fn see(ctx: ?*anyopaque, _: *shell.Shell, args: []const []const u8) u8 {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.len = @min(args[1].len, c.text.len);
            @memcpy(c.text[0..c.len], args[1][0..c.len]);
            return 0;
        }
    };
    var seen: Seen = .{};
    const s = try shell.Shell.init(.{ .io = std.testing.io, .gpa = std.testing.allocator }, .{ .reporter = Seen.report });
    defer s.deinit();
    try s.registerBuiltin("see", .{ .ctx = &seen, .run = Seen.see });
    var h = history.History.init(std.testing.allocator);
    defer h.deinit();
    h.setMax(3);
    // the line to run is the oldest: adding it again to the full history drops
    // the entry it came from (the testing allocator overwrites freed memory)
    for ([_][]const u8{ "see first-entry", ": b", ": c" }) |line| try h.add(line);
    s.history = &h;
    // `fc -s` echoes the command on descriptor 2, which the test runner shows
    _ = try s.runString("exec 3>&2 2>/dev/null; fc -s 1; exec 2>&3 3>&-");
    try std.testing.expectEqualStrings("first-entry", seen.text[0..seen.len]);
}
