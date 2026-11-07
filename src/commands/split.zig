//! split: command-line wrapper over the `util_unix` library (src/lib/split.zig).
//!
//! This file only parses arguments, validates them in the order GNU split
//! does (so diagnostics match), calls `util_unix.split.run`, and formats the
//! library's `Diagnostic`. The splitting itself lives in the library.
//!
//! References: POSIX.1-2024 `split`
//! (https://pubs.opengroup.org/onlinepubs/9799919799/utilities/split.html);
//! GNU coreutils 9.7 manual, "split invocation"; GNU coreutils 9.7 split.c
//! for option-handling order and diagnostic wording.
//!
//! POSIX options: -a, -b (k and m suffixes), -l; operands file and name.
//! Everything else is a GNU extension: -C, -n, -d, -x, -e, -t, -u,
//! --additional-suffix, --filter, --verbose, size suffixes, obsolete -NUM.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix").split;
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");

const long_names = [_][]const u8{
    "bytes",             "lines",        "line-bytes",    "number",
    "elide-empty-files", "unbuffered",   "suffix-length", "additional-suffix",
    "numeric-suffixes",  "hex-suffixes", "filter",        "verbose",
    "separator",         "help",         "version",
};

/// What an option is, independent of how it was spelled.
const Opt = enum { bytes, lines, line_bytes, number, elide, unbuffered, suffix_length, additional_suffix, numeric, hex, filter, verbose, separator, help, version, digit };

/// Option id and whether it takes an argument ("required", "optional", none).
const ArgKind = enum { none, required, optional };

const long_opts = [_]struct { Opt, ArgKind }{
    .{ .bytes, .required },         .{ .lines, .required },             .{ .line_bytes, .required },
    .{ .number, .required },        .{ .elide, .none },                 .{ .unbuffered, .none },
    .{ .suffix_length, .required }, .{ .additional_suffix, .required }, .{ .numeric, .optional },
    .{ .hex, .optional },           .{ .filter, .required },            .{ .verbose, .none },
    .{ .separator, .required },     .{ .help, .none },                  .{ .version, .none },
};

/// Short options: letter -> option and argument kind. Digits are separate.
fn shortOpt(c: u8) ?struct { Opt, ArgKind } {
    return switch (c) {
        'b' => .{ .bytes, .required },
        'l' => .{ .lines, .required },
        'C' => .{ .line_bytes, .required },
        'n' => .{ .number, .required },
        'e' => .{ .elide, .none },
        'u' => .{ .unbuffered, .none },
        'a' => .{ .suffix_length, .required },
        'd' => .{ .numeric, .none },
        'x' => .{ .hex, .none },
        't' => .{ .separator, .required },
        '0'...'9' => .{ .digit, .none },
        else => null,
    };
}

const SplitKind = enum { undef, bytes, line_bytes, lines, digits, chunk_bytes, chunk_lines, rr };

/// Parsed command line, before conversion to library options.
const Config = struct {
    kind: SplitKind = .undef,
    n_units: u64 = 0,
    k_units: u64 = 0,
    separator: ?u8 = null,
    suffix_length: usize = 0,
    additional_suffix: []const u8 = "",
    alphabet: uu.Alphabet = .lower,
    start: ?[]const u8 = null,
    elide: bool = false,
    unbuffered: bool = false,
    filter: ?[]const u8 = null,
    verbose: bool = false,
    /// argv index where the last obsolete -NUM digit was seen.
    digits_arg: usize = 0,
};

/// Early termination of option parsing with an exit status.
const Stop = struct { status: u8 };

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);

    const stop = parseArgs(ctx, &cfg, &operands) catch {
        cli.warn(ctx, "memory exhausted", .{});
        return 1;
    };
    return if (stop) |s| s.status else 0;
}

const ParseError = error{OutOfMemory};

/// Returns a Stop for help/version/errors, null when the command should run.
fn parseArgs(ctx: cli.Context, cfg: *Config, operands: *std.ArrayList([]const u8)) ParseError!?Stop {
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
            const k = switch (cli.matchLong(a[2 .. eq orelse a.len], &long_names)) {
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
            const opt, const kind = long_opts[k];
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            switch (kind) {
                .none => if (value != null) {
                    cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                    return .{ .status = 1 };
                },
                .required => if (value == null) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                        return .{ .status = 1 };
                    }
                    value = args[i];
                },
                .optional => {},
            }
            if (try apply(ctx, cfg, opt, value, i)) |stop| return stop;
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            const opt, const kind = shortOpt(c) orelse {
                cli.invalidShort(ctx, c);
                return .{ .status = 1 };
            };
            if (kind == .required) {
                var value: []const u8 = a[j + 1 ..];
                if (value.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
                        return .{ .status = 1 };
                    }
                    value = args[i];
                }
                if (try apply(ctx, cfg, opt, value, i)) |stop| return stop;
                break;
            }
            if (opt == .digit) {
                if (try applyDigit(ctx, cfg, c, i)) |stop| return stop;
            } else if (try apply(ctx, cfg, opt, null, i)) |stop| return stop;
        }
    }
    return run(ctx, cfg, operands.items);
}

/// Print a diagnostic followed by the "Try --help" hint, as GNU's
/// `error (0, 0, ...); usage (EXIT_FAILURE)` does.
fn usageError(ctx: cli.Context, comptime fmt: []const u8, args: anytype) Stop {
    cli.warn(ctx, fmt ++ "\nTry '{s} --help' for more information.", args ++ .{ctx.name});
    return .{ .status = 1 };
}

fn fatal(ctx: cli.Context, comptime fmt: []const u8, args: anytype) Stop {
    cli.warn(ctx, fmt, args);
    return .{ .status = 1 };
}

fn onlyOneWay(ctx: cli.Context) Stop {
    return usageError(ctx, "cannot split in more than one way", .{});
}

fn applyDigit(ctx: cli.Context, cfg: *Config, c: u8, arg_index: usize) ParseError!?Stop {
    if (cfg.kind == .undef) {
        cfg.kind = .digits;
        cfg.n_units = 0;
    }
    if (cfg.kind != .digits) return onlyOneWay(ctx);
    // A digit in a different argument than the previous digits starts over.
    if (cfg.digits_arg != 0 and cfg.digits_arg != arg_index + 1) cfg.n_units = 0;
    cfg.digits_arg = arg_index + 1;
    cfg.n_units = std.math.mul(u64, cfg.n_units, 10) catch std.math.maxInt(i64);
    cfg.n_units = std.math.add(u64, cfg.n_units, c - '0') catch std.math.maxInt(i64);
    cfg.n_units = @min(cfg.n_units, std.math.maxInt(i64));
    return null;
}

fn apply(ctx: cli.Context, cfg: *Config, opt: Opt, value: ?[]const u8, arg_index: usize) ParseError!?Stop {
    switch (opt) {
        .help => return .{ .status = if (help(ctx)) 0 else 1 },
        .version => return .{ .status = if (cli.printVersion(ctx)) 0 else 1 },
        .digit => unreachable,
        .elide => cfg.elide = true,
        .unbuffered => cfg.unbuffered = true,
        .verbose => cfg.verbose = true,
        .filter => cfg.filter = value.?,
        .suffix_length => {
            const text = value.?;
            const n = parseSuffixLength(text) catch |e| switch (e) {
                error.Invalid => return fatal(ctx, "invalid suffix length: {f}", .{cli.quoteaf(text)}),
                error.Range => return fatal(ctx, "invalid suffix length: {f}: Value too large for defined data type", .{cli.quoteaf(text)}),
            };
            cfg.suffix_length = n;
        },
        .additional_suffix => {
            const text = value.?;
            if (std.mem.indexOfScalar(u8, text, '/') != null)
                return usageError(ctx, "invalid suffix {f}, contains directory separator", .{cli.quoteaf(text)});
            cfg.additional_suffix = text;
        },
        .bytes, .line_bytes, .lines => {
            if (cfg.kind != .undef) return onlyOneWay(ctx);
            const text = value.?;
            const sk: uu.SizeKind = if (opt == .lines) .plain else .bytes;
            cfg.kind = switch (opt) {
                .bytes => .bytes,
                .line_bytes => .line_bytes,
                else => .lines,
            };
            // GNU words the -C diagnostic as "lines".
            const what = if (opt == .bytes) "bytes" else "lines";
            const n = uu.parseSize(text, sk) orelse return fatal(ctx, "invalid number of {s}: {f}", .{ what, cli.quoteaf(text) });
            if (n < 1) return fatal(ctx, "invalid number of {s}: {f}", .{ what, cli.quoteaf(text) });
            cfg.n_units = n;
        },
        .number => {
            if (cfg.kind != .undef) return onlyOneWay(ctx);
            var text = std.mem.trimStart(u8, value.?, " \t\n\r\x0b\x0c");
            if (std.mem.startsWith(u8, text, "r/")) {
                cfg.kind = .rr;
                text = text[2..];
            } else if (std.mem.startsWith(u8, text, "l/")) {
                cfg.kind = .chunk_lines;
                text = text[2..];
            } else cfg.kind = .chunk_bytes;
            return parseChunk(ctx, cfg, text);
        },
        .separator => {
            const text = value.?;
            if (text.len == 0) return fatal(ctx, "empty record separator", .{});
            var sep = text[0];
            if (text.len > 1) {
                if (std.mem.eql(u8, text, "\\0")) sep = 0 else return fatal(ctx, "multi-character separator {f}", .{cli.quoteaf(text)});
            }
            if (cfg.separator) |old| if (old != sep) return fatal(ctx, "multiple separator characters specified", .{});
            cfg.separator = sep;
        },
        .numeric, .hex => {
            cfg.alphabet = if (opt == .numeric) .decimal else .hex;
            if (value) |v| {
                const chars = cfg.alphabet.chars();
                for (v) |c| if (std.mem.indexOfScalar(u8, chars, c) == null) {
                    return usageError(ctx, "{f}: invalid start value for {s} suffix", .{ cli.quoteaf(v), if (opt == .numeric) "numerical" else "hexadecimal" });
                };
                cfg.start = v;
            }
        },
    }
    _ = arg_index;
    return null;
}

const SuffixLengthError = error{ Invalid, Range };

/// GNU xdectoimax(arg, 0, IDX_MAX, ...): a decimal number in range.
fn parseSuffixLength(text: []const u8) SuffixLengthError!usize {
    var s = std.mem.trimStart(u8, text, " \t\n\r\x0b\x0c");
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return error.Invalid;
    var v: u64 = 0;
    var overflow = false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return error.Invalid;
        v = std.math.mul(u64, v, 10) catch {
            overflow = true;
            break;
        };
        v = std.math.add(u64, v, c - '0') catch {
            overflow = true;
            break;
        };
    }
    if (overflow) {
        for (s) |c| if (!std.ascii.isDigit(c)) return error.Invalid;
        return error.Range;
    }
    if (neg and v != 0) return error.Range;
    if (v > std.math.maxInt(i64)) return error.Range;
    return @intCast(v);
}

fn badChunkCount(ctx: cli.Context, text: []const u8) Stop {
    return fatal(ctx, "invalid number of chunks: {f}", .{cli.quoteaf(text)});
}

/// Parse the part of `-n` after any `r/` or `l/`: `N` or `K/N` (GNU
/// parse_chunk).
fn parseChunk(ctx: cli.Context, cfg: *Config, text: []const u8) ?Stop {
    var s = std.mem.trimStart(u8, text, " \t\n\r\x0b\x0c");
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    var end: usize = 0;
    var v: u64 = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) : (end += 1) {
        v = std.math.mul(u64, v, 10) catch std.math.maxInt(i64);
        v = std.math.add(u64, v, s[end] - '0') catch std.math.maxInt(i64);
        v = @min(v, std.math.maxInt(i64));
    }
    if (end == 0) return badChunkCount(ctx, text);
    const rest = s[end..];
    if (rest.len > 0 and rest[0] == '/') {
        const k = v;
        const n = uu.parseSize(rest[1..], .plain) orelse
            return fatal(ctx, "invalid number of chunks: {f}", .{cli.quoteaf(rest[1..])});
        if (n < 1) return fatal(ctx, "invalid number of chunks: {f}", .{cli.quoteaf(rest[1..])});
        if (neg or k == 0 or k > n)
            return fatal(ctx, "invalid chunk number: {f}", .{cli.quoteaf(text[0 .. text.len - rest.len])});
        cfg.k_units = k;
        cfg.n_units = n;
        return null;
    }
    if (rest.len != 0 or neg or v == 0) return badChunkCount(ctx, text);
    cfg.n_units = v;
    return null;
}

/// Everything after option parsing: GNU's validation order, then the split.
fn run(ctx: cli.Context, cfg: *Config, operands: []const []const u8) ?Stop {
    if (cfg.k_units != 0 and cfg.filter != null)
        return usageError(ctx, "--filter does not process a chunk extracted to stdout", .{});

    if (cfg.kind == .undef) {
        cfg.kind = .lines;
        cfg.n_units = 1000;
    }
    if (cfg.n_units == 0) return usageError(ctx, "invalid number of lines: '0'", .{});

    var opts: uu.Options = .{
        .mode = switch (cfg.kind) {
            .bytes => .{ .bytes = cfg.n_units },
            .line_bytes => .{ .line_bytes = cfg.n_units },
            .lines, .digits => .{ .lines = cfg.n_units },
            .chunk_bytes => .{ .chunks = .{ .n = cfg.n_units, .k = cfg.k_units } },
            .chunk_lines => .{ .line_chunks = .{ .n = cfg.n_units, .k = cfg.k_units } },
            .rr => .{ .round_robin = .{ .n = cfg.n_units, .k = cfg.k_units } },
            .undef => unreachable,
        },
        .separator = cfg.separator orelse '\n',
        .additional_suffix = cfg.additional_suffix,
        .alphabet = cfg.alphabet,
        .suffix_length = cfg.suffix_length,
        .start = cfg.start,
        .elide_empty = cfg.elide,
        .unbuffered = cfg.unbuffered,
        .filter = cfg.filter,
        .shell = cli.getenv(ctx, "SHELL") orelse "/bin/sh",
        .environ = ctx.environ,
    };

    var needed: usize = 0;
    const plan = uu.planSuffix(opts, &needed) catch
        return fatal(ctx, "the suffix length needs to be at least {d}", .{needed});

    if (operands.len > 2)
        return usageError(ctx, "extra operand {f}", .{cli.quoteaf(operands[2])});
    const infile: []const u8 = if (operands.len > 0) operands[0] else "-";
    opts.prefix = if (operands.len > 1) operands[1] else "x";
    opts.input_name = infile;

    uu.checkStart(opts, plan) catch |e| switch (e) {
        error.StartTooLarge => return usageError(ctx, "numerical suffix start value is too large for the suffix length", .{}),
        error.InvalidStart => unreachable, // rejected while parsing
    };

    const input: Io.File = if (std.mem.eql(u8, infile, "-")) Io.File.stdin() else Io.Dir.cwd().openFile(ctx.io, infile, .{ .allow_directory = true }) catch |e|
        return fatal(ctx, "cannot open {f} for reading: {s}", .{ cli.quoteaf(infile), cli.errText(e) });
    defer if (!std.mem.eql(u8, infile, "-")) input.close(ctx.io);

    // With a filter, a reader that exits early must produce EPIPE, not kill us.
    if (cfg.filter != null) sys.ignoreSignal(.pipe);

    var verbose_ctx: Verbose = .{ .ctx = ctx };
    if (cfg.verbose) opts.observer = .{ .context = &verbose_ctx, .on_event = Verbose.onEvent };

    var diag: uu.Diagnostic = .{};
    uu.run(ctx.io, ctx.gpa, opts, input, Io.File.stdout(), &diag) catch return .{ .status = report(ctx, cfg, &diag) };
    return .{ .status = 0 };
}

/// `--verbose` messages go to standard output, like GNU's.
const Verbose = struct {
    ctx: cli.Context,

    fn onEvent(context: ?*anyopaque, ev: uu.Event) void {
        const self: *Verbose = @ptrCast(@alignCast(context.?));
        var buf: [1200]u8 = undefined;
        const line = switch (ev) {
            .creating => |n| std.fmt.bufPrint(&buf, "creating file {f}\n", .{cli.quoteaf(n)}),
            .executing => |n| std.fmt.bufPrint(&buf, "executing with FILE={f}\n", .{cli.quotef(n)}),
        } catch return;
        _ = cli.writeStdout(self.ctx.io, line);
    }
};

/// Print the library's failure the way GNU split does; returns the exit status.
fn report(ctx: cli.Context, cfg: *const Config, d: *const uu.Diagnostic) u8 {
    const cause = if (d.cause) |c| cli.errText(c) else "";
    switch (d.kind) {
        .none => {},
        .invalid_options => cli.warn(ctx, "invalid options: {s}", .{cause}),
        .read_input, .create_output, .write_output => cli.warn(ctx, "{f}: {s}", .{ cli.quotef(d.name()), cause }),
        .write_stdout => cli.warn(ctx, "write error: {s}", .{cause}),
        .overwrite_input => cli.warn(ctx, "{f} would overwrite input; aborting", .{cli.quoteaf(d.name())}),
        .suffixes_exhausted => cli.warn(ctx, "output file suffixes exhausted", .{}),
        .size_unknown => cli.warn(ctx, "{f}: cannot determine file size", .{cli.quotef(d.name())}),
        .filter_spawn => cli.warn(ctx, "failed to run command: \"{s} -c {s}\": {s}", .{ cli.getenv(ctx, "SHELL") orelse "/bin/sh", cfg.filter.?, cause }),
        .filter_exit => cli.warn(ctx, "with FILE={f}, exit {d} from command: {s}", .{ cli.quotef(d.name()), d.exit_status, cfg.filter.? }),
        .filter_signal => cli.warn(ctx, "with FILE={f}, signal {s} from command: {s}", .{ cli.quotef(d.name()), signalName(d.signal), cfg.filter.? }),
        .filter_wait => cli.warn(ctx, "waiting for child process: {s}", .{cause}),
        .out_of_memory => cli.warn(ctx, "memory exhausted", .{}),
    }
    return d.exit_status;
}

fn signalName(num: u32) []const u8 {
    const names = [_]struct { u32, []const u8 }{
        .{ 1, "HUP" },   .{ 2, "INT" },   .{ 3, "QUIT" },  .{ 4, "ILL" },
        .{ 6, "ABRT" },  .{ 7, "BUS" },   .{ 8, "FPE" },   .{ 9, "KILL" },
        .{ 10, "USR1" }, .{ 11, "SEGV" }, .{ 12, "USR2" }, .{ 14, "ALRM" },
        .{ 15, "TERM" },
    };
    for (names) |n| if (n[0] == num) return n[1];
    return "?";
}

fn help(ctx: cli.Context) bool {
    return cli.writeStdout(ctx.io, "Usage: split [OPTION]... [FILE [PREFIX]]\n" ++
        "Output pieces of FILE to PREFIXaa, PREFIXab, ...;\n" ++
        "default size is 1000 lines, and default PREFIX is 'x'.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "Mandatory arguments to long options are mandatory for short options too.\n" ++
        "  -a, --suffix-length=N   generate suffixes of length N (default 2)\n" ++
        "      --additional-suffix=SUFFIX  append an additional SUFFIX to file names\n" ++
        "  -b, --bytes=SIZE        put SIZE bytes per output file\n" ++
        "  -C, --line-bytes=SIZE   put at most SIZE bytes of records per output file\n" ++
        "  -d                      use numeric suffixes starting at 0, not alphabetic\n" ++
        "      --numeric-suffixes[=FROM]  same as -d, but allow setting the start value\n" ++
        "  -x                      use hex suffixes starting at 0, not alphabetic\n" ++
        "      --hex-suffixes[=FROM]  same as -x, but allow setting the start value\n" ++
        "  -e, --elide-empty-files  do not generate empty output files with '-n'\n" ++
        "      --filter=COMMAND    write to shell COMMAND; file name is $FILE\n" ++
        "  -l, --lines=NUMBER      put NUMBER lines/records per output file\n" ++
        "  -n, --number=CHUNKS     generate CHUNKS output files; see explanation below\n" ++
        "  -t, --separator=SEP     use SEP instead of newline as the record separator;\n" ++
        "                            '\\0' (zero) specifies the NUL character\n" ++
        "  -u, --unbuffered        immediately copy input to output with '-n r/...'\n" ++
        "      --verbose           print a diagnostic just before each\n" ++
        "                            output file is opened\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n\n" ++
        "The SIZE argument is an integer and optional unit (example: 10K is 10*1024).\n" ++
        "Units are K,M,G,T,P,E,Z,Y,R,Q (powers of 1024) or KB,MB,... (powers of 1000).\n" ++
        "Binary prefixes can be used, too: KiB=K, MiB=M, and so on.\n\n" ++
        "CHUNKS may be:\n" ++
        "  N       split into N files based on size of input\n" ++
        "  K/N     output Kth of N to stdout\n" ++
        "  l/N     split into N files without splitting lines/records\n" ++
        "  l/K/N   output Kth of N to stdout without splitting lines/records\n" ++
        "  r/N     like 'l' but use round robin distribution\n" ++
        "  r/K/N   likewise but only output Kth of N to stdout\n");
}

test "parseSuffixLength" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), try parseSuffixLength("3"));
    try t.expectEqual(@as(usize, 0), try parseSuffixLength("0"));
    try t.expectError(error.Invalid, parseSuffixLength("x"));
    try t.expectError(error.Invalid, parseSuffixLength(""));
    try t.expectError(error.Invalid, parseSuffixLength("1k"));
    try t.expectError(error.Range, parseSuffixLength("-1"));
    try t.expectError(error.Range, parseSuffixLength("99999999999999999999"));
}
