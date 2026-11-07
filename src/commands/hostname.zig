// SPDX-License-Identifier: GPL-2.0-or-later
//! hostname: thin wrapper over `util_unix.hostname`.
//!
//! References: hostname 3.25 (Debian), whose options, messages and exit statuses
//! this follows; gethostname(2), sethostname(2). Exit status 0, 1 on failure,
//! 255 for usage errors (the reference's values).
//!
//! Not supported: -A and -I (they enumerate network interfaces); names that
//! are not in /etc/hosts are not resolved through DNS or NSS.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const hn = uu.hostname;
const cli = @import("../cli.zig");

const Show = enum { name, alias, all_fqdns, domain, fqdn, ip, all_ips, short, yp };

const long_names = [_][]const u8{
    "alias",      "all-fqdns",        "boot",  "domain", "fqdn", "long",    "file",
    "ip-address", "all-ip-addresses", "short", "yp",     "nis",  "version", "help",
};

pub fn main(ctx: cli.Context) u8 {
    var show: ?Show = null;
    var boot = false;
    var file: ?[]const u8 = null;
    var operand: ?[]const u8 = null;
    var operands: usize = 0;

    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operand = a;
            operands += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLongPlain(ctx, a, &long_names, m);
                    return usage(ctx, true);
                },
            };
            switch (k) {
                0 => show = .alias,
                1 => show = .all_fqdns,
                2 => boot = true,
                3 => show = .domain,
                4, 5 => show = .fqdn,
                6 => {
                    file = if (eq) |e| a[e + 1 ..] else blk: {
                        i += 1;
                        if (i >= ctx.args.len) {
                            cli.warn(ctx, "option '--file' requires an argument", .{});
                            return usage(ctx, true);
                        }
                        break :blk ctx.args[i];
                    };
                },
                7 => show = .ip,
                8 => show = .all_ips,
                9 => show = .short,
                10, 11 => show = .yp,
                12 => return if (cli.printVersion(ctx)) 0 else 1,
                else => return help(ctx),
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            switch (a[j]) {
                'a' => show = .alias,
                'A' => show = .all_fqdns,
                'b' => boot = true,
                'd' => show = .domain,
                'f' => show = .fqdn,
                'i' => show = .ip,
                'I' => show = .all_ips,
                's' => show = .short,
                'y' => show = .yp,
                'V' => return if (cli.printVersion(ctx)) 0 else 1,
                'h' => return help(ctx),
                'F' => {
                    if (j + 1 < a.len) {
                        file = a[j + 1 ..];
                    } else {
                        i += 1;
                        if (i >= ctx.args.len) {
                            cli.warn(ctx, "option requires an argument -- 'F'", .{});
                            return usage(ctx, true);
                        }
                        file = ctx.args[i];
                    }
                    j = a.len;
                },
                else => {
                    cli.warn(ctx, "invalid option -- '{c}'", .{a[j]});
                    return usage(ctx, true);
                },
            }
        }
    }

    const setting = file != null or operands > 0;
    if (operands > 1 or (setting and show != null)) return usageStderr(ctx);
    if (file != null and operands > 0) return usageStderr(ctx);

    if (setting) {
        var text_buf: ?[]u8 = null;
        defer if (text_buf) |b| ctx.gpa.free(b);
        var new_name: []const u8 = operand orelse "";
        if (file) |path| {
            text_buf = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(1 << 20)) catch |e| {
                cli.warn(ctx, "{s}", .{cli.errText(e)});
                return 1;
            };
            new_name = hn.fromFileText(text_buf.?) orelse "";
        }
        return setName(ctx, new_name);
    }

    var info = uu.proc.uname();
    if (boot) {
        const cur = info.nodename();
        if (cur.len == 0 or std.mem.eql(u8, cur, "(none)")) {
            const rc = setDefault(ctx);
            if (rc != 0) return rc;
            info = uu.proc.uname();
        }
    }
    return display(ctx, show orelse .name, info.nodename(), info.domainname());
}

fn setName(ctx: cli.Context, name: []const u8) u8 {
    hn.set(name) catch |e| {
        switch (e) {
            error.PermissionDenied => cli.warn(ctx, "you must be root to change the host name", .{}),
            error.NameTooLong => cli.warn(ctx, "name too long", .{}),
            else => cli.warn(ctx, "{s}", .{cli.errText(e)}),
        }
        return 1;
    };
    return 0;
}

/// -b: use /etc/hostname when it has a name, else "localhost".
fn setDefault(ctx: cli.Context) u8 {
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, "/etc/hostname", ctx.gpa, .limited(4096)) catch null;
    defer if (text) |t| ctx.gpa.free(t);
    const name = if (text) |t| (hn.fromFileText(t) orelse "localhost") else "localhost";
    return setName(ctx, name);
}

fn display(ctx: cli.Context, show: Show, node: []const u8, nis: []const u8) u8 {
    var buf: [2048]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const out = &w.interface;
    switch (show) {
        .name => out.print("{s}\n", .{node}) catch return 1,
        .short => out.print("{s}\n", .{hn.short(node)}) catch return 1,
        .yp => out.print("{s}\n", .{nis}) catch return 1,
        .all_fqdns, .all_ips => {
            cli.warn(ctx, "{s} is not supported (it needs the network interface list)", .{if (show == .all_ips) "-I" else "-A"});
            return 1;
        },
        .alias, .domain, .fqdn, .ip => {
            const hosts = Io.Dir.cwd().readFileAlloc(ctx.io, "/etc/hosts", ctx.gpa, .limited(8 << 20)) catch |e| switch (e) {
                error.FileNotFound => ctx.gpa.alloc(u8, 0) catch return 1,
                else => {
                    cli.warn(ctx, "{s}", .{cli.errText(e)});
                    return 1;
                },
            };
            defer ctx.gpa.free(hosts);
            const found = hn.lookup(ctx.gpa, hosts, node) catch return 1;
            const m = found orelse {
                cli.warn(ctx, "Name or service not known", .{});
                return 1;
            };
            defer m.deinit(ctx.gpa);
            switch (show) {
                .alias => out.print("{s}\n", .{m.aliases}) catch return 1,
                .fqdn => out.print("{s}\n", .{m.canonical}) catch return 1,
                .domain => if (hn.domain(m.canonical)) |d| out.print("{s}\n", .{d}) catch return 1,
                else => {
                    for (m.addresses, 0..) |addr, k| {
                        if (k > 0) out.writeByte(' ') catch return 1;
                        out.writeAll(addr) catch return 1;
                    }
                    out.writeByte('\n') catch return 1;
                },
            }
        },
    }
    out.flush() catch return 1;
    return 0;
}

/// The reference prints its usage text on standard output and exits 255, for
/// -h and --help as well as for bad options.
fn usage(ctx: cli.Context, _: bool) u8 {
    _ = cli.writeStdout(ctx.io, help_text);
    return 255;
}

/// Wrong combination of operands and options: same text, on standard error.
fn usageStderr(ctx: cli.Context) u8 {
    Io.File.stderr().writeStreamingAll(ctx.io, help_text) catch {};
    return 255;
}

fn help(ctx: cli.Context) u8 {
    return usage(ctx, false);
}

const help_text = "Usage: hostname [-b] {hostname|-F file}         set host name (from file)\n" ++
    "       hostname [-a|-A|-d|-f|-i|-I|-s|-y]       display formatted name\n" ++
    "       hostname                                 display host name\n\n" ++
    "       {yp,nis,}domainname {nisdomain|-F file}  set NIS domain name (from file)\n" ++
    "       {yp,nis,}domainname                      display NIS domain name\n\n" ++
    "       dnsdomainname                            display dns domain name\n\n" ++
    "       hostname -V|--version|-h|--help          print info and exit\n\n" ++
    "Program name:\n" ++
    "       {yp,nis,}domainname=hostname -y\n" ++
    "       dnsdomainname=hostname -d\n\n" ++
    "Program options:\n" ++
    "    -a, --alias            alias names\n" ++
    "    -A, --all-fqdns        all long host names (FQDNs)\n" ++
    "    -b, --boot             set default hostname if none available\n" ++
    "    -d, --domain           DNS domain name\n" ++
    "    -f, --fqdn, --long     long host name (FQDN)\n" ++
    "    -F, --file             read host name or NIS domain name from given file\n" ++
    "    -i, --ip-address       addresses for the host name\n" ++
    "    -I, --all-ip-addresses all addresses for the host\n" ++
    "    -s, --short            short host name\n" ++
    "    -y, --yp, --nis        NIS/YP domain name\n\n" ++
    "Description:\n" ++
    "   This command can get or set the host name or the NIS domain name. You can\n" ++
    "   also get the DNS domain or the FQDN (fully qualified domain name).\n" ++
    "   Unless you are using bind or NIS for host lookups you can change the\n" ++
    "   FQDN (Fully Qualified Domain Name) and the DNS domain name (which is\n" ++
    "   part of the FQDN) in the /etc/hosts file.\n";
