//! Command-line wrapper shared by chown and chgrp (GNU builds both from one
//! source file; so do we). It parses arguments in GNU's order, validates them,
//! builds `util_unix.ownership.Options`, runs the engine, and formats its
//! events as GNU's messages.
//!
//! References: POSIX.1-2024 chown, chgrp; GNU coreutils 9.7 manual "chown
//! invocation", "chgrp invocation"; GNU coreutils 9.7 chown.c (option
//! handling and message wording).

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const own = uu.ownership;
const cli = @import("cli.zig");

pub const Mode = enum { chown, chgrp };

const long_names = [_][]const u8{
    "recursive",      "changes",          "dereference",   "from",
    "no-dereference", "no-preserve-root", "preserve-root", "quiet",
    "silent",         "reference",        "verbose",       "help",
    "version",
};

const Opt = enum { recursive, changes, dereference, from, no_dereference, no_preserve_root, preserve_root, quiet, silent, reference, verbose, help, version };

const Parsed = struct {
    recurse: bool = false,
    traversal: own.Traversal = .physical,
    dereference: ?bool = null,
    verbosity: own.Verbosity = .off,
    quiet: bool = false,
    preserve_root: bool = false,
    reference: ?[]const u8 = null,
    from: ?[]const u8 = null,
};

/// Exit status for parse-time termination.
const Stop = struct { status: u8 };

pub fn main(ctx: cli.Context, comptime mode: Mode) u8 {
    var p: Parsed = .{};
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    if (parseArgs(ctx, mode, &p, &operands) catch return oom(ctx)) |stop| return stop.status;
    return execute(ctx, mode, &p, operands.items) catch oom(ctx);
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn parseArgs(ctx: cli.Context, comptime mode: Mode, p: *Parsed, operands: *std.ArrayList([]const u8)) std.mem.Allocator.Error!?Stop {
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            try operands.append(ctx.gpa, a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const idx = switch (cli.matchLong(a[2 .. eq orelse a.len], &long_names)) {
                .found => |k| k,
                .ambiguous => {
                    cli.ambiguousLong(ctx, a, &long_names);
                    return .{ .status = 1 };
                },
                .none => {
                    cli.unrecognizedLong(ctx, a);
                    return .{ .status = 1 };
                },
            };
            const opt: Opt = @fromBackingInt(@intCast(idx));
            const takes_arg = opt == .from or opt == .reference;
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (!takes_arg and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[idx], ctx.name });
                return .{ .status = 1 };
            }
            if (takes_arg and value == null) {
                i += 1;
                if (i >= args.len) {
                    cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[idx], ctx.name });
                    return .{ .status = 1 };
                }
                value = args[i];
            }
            if (apply(ctx, mode, p, opt, value)) |stop| return stop;
            continue;
        }
        for (a[1..]) |c| {
            const opt: Opt = switch (c) {
                'R' => .recursive,
                'c' => .changes,
                'f' => .quiet,
                'h' => .no_dereference,
                'v' => .verbose,
                'H', 'L', 'P' => {
                    p.traversal = switch (c) {
                        'H' => .command_line,
                        'L' => .logical,
                        else => .physical,
                    };
                    continue;
                },
                else => {
                    cli.invalidShort(ctx, c);
                    return .{ .status = 1 };
                },
            };
            if (apply(ctx, mode, p, opt, null)) |stop| return stop;
        }
    }
    return null;
}

fn apply(ctx: cli.Context, comptime mode: Mode, p: *Parsed, opt: Opt, value: ?[]const u8) ?Stop {
    switch (opt) {
        .recursive => p.recurse = true,
        .changes => p.verbosity = .changes,
        .verbose => p.verbosity = .verbose,
        .quiet, .silent => p.quiet = true,
        .dereference => p.dereference = true,
        .no_dereference => p.dereference = false,
        .no_preserve_root => p.preserve_root = false,
        .preserve_root => p.preserve_root = true,
        .reference => p.reference = value.?,
        .from => p.from = value.?,
        .help => return .{ .status = if (cli.writeStdout(ctx.io, helpText(mode))) 0 else 1 },
        .version => return .{ .status = if (cli.printVersion(ctx)) 0 else 1 },
    }
    return null;
}

/// Everything after option parsing, in GNU's order.
fn execute(ctx: cli.Context, comptime mode: Mode, p: *Parsed, operands: []const []const u8) std.mem.Allocator.Error!u8 {
    var dereference = p.dereference;
    var traversal = p.traversal;
    if (p.recurse) {
        if (traversal == .physical) {
            if (dereference == true) {
                cli.warn(ctx, "-R --dereference requires either -H or -L", .{});
                return 1;
            }
            dereference = false;
        }
    } else traversal = .physical;
    const affect_referent = dereference != false;

    const need: usize = if (p.reference != null) 1 else 2;
    if (operands.len < need) {
        if (operands.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        } else {
            cli.warn(ctx, "missing operand after {f}\nTry '{s} --help' for more information.", .{ cli.quoteaf(operands[operands.len - 1]), ctx.name });
        }
        return 1;
    }

    var db = uu.userdb.Db.load(ctx.io, ctx.gpa, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        cli.warn(ctx, "cannot read the user database: {s}", .{cli.errText(e)});
        return 1;
    };
    defer db.deinit();

    var opts: own.Options = .{
        .recurse = p.recurse,
        .traversal = traversal,
        .dereference = affect_referent,
        .verbosity = p.verbosity,
        .quiet = p.quiet,
        .db = &db,
        .reporter = undefined,
    };

    // --from=CURRENT_OWNER:CURRENT_GROUP
    if (p.from) |spec| {
        if (uu.userspec.parse(&db, spec, .user_and_group)) |r| {
            if (r.warn_dot) cli.warn(ctx, "warning: '.' should be ':': {f}", .{cli.quoteaf(spec)});
            opts.required_uid = r.uid;
            opts.required_gid = r.gid;
        } else |e| {
            cli.warn(ctx, "{s}: {f}", .{ uu.userspec.errorText(e), cli.quoteaf(spec) });
            return 1;
        }
    }

    var rest = operands;
    // Names that must outlive parsing for the messages: the numeric fallback
    // text is produced by the engine, these are the user-typed forms.
    var ref_user_buf: [12]u8 = undefined;
    var ref_group_buf: [12]u8 = undefined;
    if (p.reference) |ref| {
        const st = uu.fsown.statAt(Io.Dir.cwd(), ref, true) catch |e| {
            cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteaf(ref), cli.errText(e) });
            return 1;
        };
        if (mode == .chown) {
            opts.uid = st.uid;
            opts.user_name = if (db.userById(st.uid)) |pw| pw.name else std.fmt.bufPrint(&ref_user_buf, "{d}", .{st.uid}) catch unreachable;
        }
        opts.gid = st.gid;
        opts.group_name = if (db.groupById(st.gid)) |gr| gr.name else std.fmt.bufPrint(&ref_group_buf, "{d}", .{st.gid}) catch unreachable;
    } else {
        const spec = rest[0];
        rest = rest[1..];
        const parsed = (if (mode == .chgrp) blk: {
            const joined = try std.fmt.allocPrint(ctx.gpa, ":{s}", .{spec});
            defer ctx.gpa.free(joined);
            // The result borrows from `joined` only via names that are copied below.
            const r = uu.userspec.parse(&db, joined, .user_and_group);
            if (r) |ok| {
                var owned = ok;
                if (owned.group_name) |g| {
                    // `g` may point into `joined`; re-point it at `spec`.
                    if (@intFromPtr(g.ptr) >= @intFromPtr(joined.ptr) and @intFromPtr(g.ptr) < @intFromPtr(joined.ptr) + joined.len) {
                        owned.group_name = spec[@intFromPtr(g.ptr) - @intFromPtr(joined.ptr) - 1 ..][0..g.len];
                    }
                }
                break :blk @as(uu.userspec.ParseError!uu.userspec.Parsed, owned);
            } else |e| break :blk @as(uu.userspec.ParseError!uu.userspec.Parsed, e);
        } else uu.userspec.parse(&db, spec, .user_and_group)) catch |e| {
            cli.warn(ctx, "{s}: {f}", .{ uu.userspec.errorText(e), cli.quoteaf(spec) });
            return 1;
        };
        if (parsed.warn_dot) cli.warn(ctx, "warning: '.' should be ':': {f}", .{cli.quoteaf(spec)});
        opts.uid = parsed.uid;
        opts.gid = parsed.gid;
        opts.user_name = parsed.user_name;
        opts.group_name = parsed.group_name;
        // A group without a user is described as "ownership :GROUP".
        if (mode == .chown and opts.user_name == null and opts.group_name != null) opts.user_name = "";
    }

    if (p.recurse and p.preserve_root) {
        opts.preserve_root = uu.fsown.statAt(Io.Dir.cwd(), "/", true) catch |e| {
            cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteaf("/"), cli.errText(e) });
            return 1;
        };
    }

    var rep: Reporter = .{ .ctx = ctx };
    opts.reporter = .{ .context = &rep, .on_event = Reporter.onEvent };
    const ok = try own.run(ctx.io, ctx.gpa, opts, rest);
    return if (ok) 0 else 1;
}

/// Formats engine events as GNU's messages.
const Reporter = struct {
    ctx: cli.Context,

    fn onEvent(context: ?*anyopaque, ev: own.Event) void {
        const self: *Reporter = @ptrCast(@alignCast(context.?));
        switch (ev) {
            .change => |c| self.change(c),
            .problem => |pr| self.problem(pr),
        }
    }

    fn problem(self: *Reporter, pr: own.Problem) void {
        const ctx = self.ctx;
        const cause = if (pr.cause) |c| cli.errText(c) else "";
        const path = cli.quoteaf(pr.path);
        switch (pr.kind) {
            .cannot_access => cli.warn(ctx, "cannot access {f}: {s}", .{ path, cause }),
            .cannot_read_directory => cli.warn(ctx, "cannot read directory {f}: {s}", .{ path, cause }),
            .cannot_dereference => cli.warn(ctx, "cannot dereference {f}: {s}", .{ path, cause }),
            .changing_ownership => cli.warn(ctx, "changing ownership of {f}: {s}", .{ path, cause }),
            .changing_group => cli.warn(ctx, "changing group of {f}: {s}", .{ path, cause }),
            .read_failed => cli.warn(ctx, "error reading directory {f}: {s}", .{ cli.quotef(pr.path), cause }),
            .dangerous_root => {
                const same = if (std.mem.eql(u8, pr.path, "/")) "" else " (same as '/')";
                cli.warn(ctx, "it is dangerous to operate recursively on {f}{s}", .{ path, same });
                cli.warn(ctx, "use --no-preserve-root to override this failsafe", .{});
            },
        }
    }

    /// GNU describe_change(): `user` null means the group-oriented wording.
    fn change(self: *Reporter, c: own.Change) void {
        var buf: [2048]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        const path = cli.quoteaf(c.path);
        const user = c.new_user;
        const group = c.new_group;

        if (c.status == .not_applied) {
            w.print("neither symbolic link {f} nor referent has been changed\n", .{path}) catch return;
            _ = cli.writeStdout(self.ctx.io, w.buffered());
            return;
        }

        var old_spec_buf: [512]u8 = undefined;
        var new_spec_buf: [512]u8 = undefined;
        const old_spec = specText(&old_spec_buf, if (user != null) c.old_user else null, if (group != null) c.old_group else null);
        const new_spec = specText(&new_spec_buf, user, group);

        const old = old_spec orelse "";
        const new = new_spec orelse "";
        switch (c.status) {
            .succeeded => if (user != null)
                w.print("changed ownership of {f} from {s} to {s}\n", .{ path, old, new }) catch {}
            else if (group != null)
                w.print("changed group of {f} from {s} to {s}\n", .{ path, old, new }) catch {}
            else
                w.print("no change to ownership of {f}\n", .{path}) catch {},
            .failed => if (old_spec != null) {
                if (user != null)
                    w.print("failed to change ownership of {f} from {s} to {s}\n", .{ path, old, new }) catch {}
                else if (group != null)
                    w.print("failed to change group of {f} from {s} to {s}\n", .{ path, old, new }) catch {}
                else
                    w.print("failed to change ownership of {f}\n", .{path}) catch {};
            } else {
                // No old owner known: "... of FILE to NEW".
                if (user != null)
                    w.print("failed to change ownership of {f} to {s}\n", .{ path, new }) catch {}
                else if (group != null)
                    w.print("failed to change group of {f} to {s}\n", .{ path, new }) catch {}
                else
                    w.print("failed to change ownership of {f}\n", .{path}) catch {};
            },
            .no_change_requested => if (user != null)
                w.print("ownership of {f} retained as {s}\n", .{ path, old }) catch {}
            else if (group != null)
                w.print("group of {f} retained as {s}\n", .{ path, old }) catch {}
            else
                w.print("ownership of {f} retained\n", .{path}) catch {},
            .not_applied => unreachable,
        }
        _ = cli.writeStdout(self.ctx.io, w.buffered());
    }
};

/// GNU user_group_str(): "user:group", or just one of them, or null.
fn specText(buf: []u8, user: ?[]const u8, group: ?[]const u8) ?[]const u8 {
    if (user) |u| {
        if (group) |g| return std.fmt.bufPrint(buf, "{s}:{s}", .{ u, g }) catch null;
        return u;
    }
    return group;
}

fn helpText(comptime mode: Mode) []const u8 {
    const usage = switch (mode) {
        .chown => "Usage: chown [OPTION]... [OWNER][:[GROUP]] FILE...\n" ++
            "  or:  chown [OPTION]... --reference=RFILE FILE...\n" ++
            "Change the owner and/or group of each FILE to OWNER and/or GROUP.\n" ++
            "With --reference, change the owner and group of each FILE to those of RFILE.\n\n",
        .chgrp => "Usage: chgrp [OPTION]... GROUP FILE...\n" ++
            "  or:  chgrp [OPTION]... --reference=RFILE FILE...\n" ++
            "Change the group of each FILE to GROUP.\n" ++
            "With --reference, change the group of each FILE to that of RFILE.\n\n",
    };
    const from = "      --from=CURRENT_OWNER:CURRENT_GROUP\n" ++
        "                         change the ownership of each file only if\n" ++
        "                         its current owner and/or group match those specified\n" ++
        "                         here.  Either may be omitted, in which case a match\n" ++
        "                         is not required for the omitted attribute\n";
    const tail = switch (mode) {
        .chown => "\nOwner is unchanged if missing.  Group is unchanged if missing, but changed\n" ++
            "to login group if implied by a ':' following a symbolic OWNER.\n" ++
            "OWNER and GROUP may be numeric as well as symbolic.\n\n" ++
            "Examples:\n" ++
            "  chown root /u        Change the owner of /u to \"root\".\n" ++
            "  chown root:staff /u  Likewise, but also change its group to \"staff\".\n" ++
            "  chown -hR root /u    Change the owner of /u and subfiles to \"root\".\n",
        .chgrp => "\nExamples:\n" ++
            "  chgrp staff /u      Change the group of /u to \"staff\".\n" ++
            "  chgrp -hR staff /u  Change the group of /u and subfiles to \"staff\".\n",
    };
    return usage ++
        "  -c, --changes          like verbose but report only when a change is made\n" ++
        "  -f, --silent, --quiet  suppress most error messages\n" ++
        "  -v, --verbose          output a diagnostic for every file processed\n" ++
        "      --dereference      affect the referent of each symbolic link (this is\n" ++
        "                         the default), rather than the symbolic link itself\n" ++
        "  -h, --no-dereference   affect symbolic links instead of any referenced file\n" ++
        "                         (useful only on systems that can change the\n" ++
        "                         ownership of a symlink)\n" ++ from ++
        "      --no-preserve-root  do not treat '/' specially (the default)\n" ++
        "      --preserve-root    fail to operate recursively on '/'\n" ++
        "      --reference=RFILE  use RFILE's ownership rather than specifying values.\n" ++
        "                         RFILE is always dereferenced if a symbolic link.\n" ++
        "  -R, --recursive        operate on files and directories recursively\n\n" ++
        "The following options modify how a hierarchy is traversed when the -R\n" ++
        "option is also specified.  If more than one is specified, only the final\n" ++
        "one takes effect. -P is the default.\n\n" ++
        "  -H                     if a command line argument is a symbolic link\n" ++
        "                         to a directory, traverse it\n" ++
        "  -L                     traverse every symbolic link to a directory\n" ++
        "                         encountered\n" ++
        "  -P                     do not traverse any symbolic links\n\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n" ++ tail;
}
