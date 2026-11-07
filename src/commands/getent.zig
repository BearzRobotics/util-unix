//! getent: thin wrapper over `util_unix.getent` (src/lib/getent.zig).
//!
//! Parses glibc/argp-style options, runs one query per key, and maps outcomes
//! to getent's exit statuses: 0 all keys found, 1 usage error or unknown
//! database, 2 a key was not found, 3 enumeration not supported, 64 bad option.
//!
//! Reference: getent(1), Linux man-pages; glibc 2.43 getent behaviour on the
//! development machine. POSIX does not specify getent.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix").getent;
const cli = @import("../cli.zig");

const long_names = [_][]const u8{ "no-addrconfig", "no-idn", "service", "help", "usage", "version" };

const try_help = "Try `getent --help' or `getent --usage' for more information.";

pub fn main(ctx: cli.Context) u8 {
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    var service: ?[]const u8 = null;

    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
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
                .ambiguous => return badOption(ctx, "option '{s}' is ambiguous", .{a}),
                .none => return badOption(ctx, "unrecognized option '{s}'", .{a}),
            };
            switch (idx) {
                0, 1 => if (eq != null) return badOption(ctx, "option '--{s}' doesn't allow an argument", .{long_names[idx]}),
                2 => {
                    if (eq) |e| {
                        service = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) return badOption(ctx, "option '--service' requires an argument", .{});
                        service = args[i];
                    }
                },
                3 => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
                4 => return if (cli.writeStdout(ctx.io, usage_text)) 0 else 1,
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'A', 'i' => {},
            '?' => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
            'V' => return if (cli.printVersion(ctx)) 0 else 1,
            's' => {
                var value: []const u8 = a[j + 1 ..];
                if (value.len == 0) {
                    i += 1;
                    if (i >= args.len) return badOption(ctx, "option requires an argument -- 's'", .{});
                    value = args[i];
                }
                service = value;
                break;
            },
            else => return badOption(ctx, "invalid option -- '{c}'", .{a[j]}),
        };
    }

    if (operands.items.len == 0) {
        cli.warn(ctx, "wrong number of arguments", .{});
        _ = cli.writeStdout(ctx.io, try_help ++ "\n");
        return 1;
    }
    const db_name = operands.items[0];
    const db = uu.Database.parse(db_name) orelse {
        // glibc prints this one without the program-name prefix.
        // (the hint goes to standard output, the complaint to standard error).
        var msg: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&msg, "Unknown database: {s}\n", .{db_name}) catch return 1;
        Io.File.stderr().writeStreamingAll(ctx.io, text) catch {};
        _ = cli.writeStdout(ctx.io, try_help ++ "\n");
        return 1;
    };

    // -s [DATABASE:]SERVICE. Only the files service exists here; any other
    // service answers nothing, as a service with no entries would.
    var files_ok = true;
    if (service) |s| {
        var svc = s;
        if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
            if (uu.Database.parse(s[0..colon]) == null) {
                cli.warn(ctx, "Unknown database name", .{});
                return 1;
            }
            // A setting for another database does not affect this one.
            if (uu.Database.parse(s[0..colon]).? != db) svc = "files";
            if (uu.Database.parse(s[0..colon]).? == db) svc = s[colon + 1 ..];
        }
        files_ok = std.mem.eql(u8, svc, "files");
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;

    const keys = operands.items[1..];
    var status: u8 = 0;
    if (keys.len == 0) {
        const outcome = if (files_ok) query(ctx, db, null, w) else uu.Outcome.not_found;
        switch (outcome) {
            .found => {},
            .not_found => status = 2,
            .enumeration_unsupported => {
                w.flush() catch {};
                var msg: [256]u8 = undefined;
                const text = std.fmt.bufPrint(&msg, "Enumeration not supported on {s}\n", .{db_name}) catch "";
                Io.File.stderr().writeStreamingAll(ctx.io, text) catch {};
                status = 3;
            },
        }
    } else for (keys) |key| {
        const outcome = if (files_ok) query(ctx, db, key, w) else uu.Outcome.not_found;
        if (outcome == .not_found) status = 2;
    }
    w.flush() catch return 1;
    return status;
}

fn query(ctx: cli.Context, db: uu.Database, key: ?[]const u8, w: *Io.Writer) uu.Outcome {
    return uu.query(ctx.io, ctx.gpa, db, key, .{}, w) catch |e| {
        w.flush() catch {};
        cli.warn(ctx, "{s}", .{cli.errText(e)});
        std.process.exit(1);
    };
}

fn badOption(ctx: cli.Context, comptime fmt: []const u8, args: anytype) u8 {
    cli.warn(ctx, fmt ++ "\n" ++ try_help, args);
    return 64;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

const usage_text = "Usage: getent [-Ai?V] [-s CONFIG] [--no-addrconfig] [--no-idn]\n" ++
    "            [--service=CONFIG] [--help] [--usage] [--version]\n" ++
    "            database [key ...]\n";

const help_text = "Usage: getent [OPTION...] database [key ...]\n" ++
    "Get entries from administrative database.\n\n" ++
    "  -A, --no-addrconfig        do not filter out unsupported IPv4/IPv6 addresses\n" ++
    "                             (with ahosts*)\n" ++
    "  -i, --no-idn               disable IDN encoding\n" ++
    "  -s, --service=CONFIG       Service configuration to be used\n" ++
    "  -?, --help                 Give this help list\n" ++
    "      --usage                Give a short usage message\n" ++
    "  -V, --version              Print program version\n\n" ++
    "Mandatory or optional arguments to long options are also mandatory or optional\n" ++
    "for any corresponding short options.\n\n" ++
    "Supported databases:\n" ++
    "ahosts ahostsv4 ahostsv6 aliases ethers group gshadow hosts initgroups\n" ++
    "netgroup networks passwd protocols rpc services shadow\n";
