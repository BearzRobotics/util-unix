// SPDX-License-Identifier: GPL-2.0-or-later
//! Our fuzz engine (decision 0010). Zig 0.17.1's built-in fuzzer does not run here (a
//! 20-line project reproduces "corrupted coverage file" without instrumentation and a
//! segfault in fuzzer_start_test with it), so targets are driven by this mutation-based
//! engine instead. Targets keep the standard shape `fn (ctx, *std.testing.Smith) !void`,
//! so they can move to Zig's fuzzer unchanged once it works: only the call
//! `std.testing.fuzz(...)` is replaced by `engine.fuzz(...)`.
//!
//! Two modes, chosen by the environment:
//!   regression (default, `zig build test`): each corpus entry once, then a short
//!     deterministic burst of mutations (FUZZ_REGRESSION, default 64) so every target
//!     gets some exploration and the run stays fast.
//!   campaign (`tools/fuzz.sh`): FUZZ_ITERATIONS mutations per target from FUZZ_SEED.
//!
//! A target that returns an error has found a bug: the input is saved to
//! `$FUZZ_FINDINGS/<target>-<hash>.bin` (default `fuzz-findings/`) and the test fails. A
//! crash or hang cannot be caught in-process, so before every run the input is written
//! to `$FUZZ_CURRENT` (when set), which is then the reproducer. The target itself must
//! allocate through `limits.Capped` so no input can exhaust the machine.

const std = @import("std");
const limits = @import("limits.zig");

pub const Options = struct {
    corpus: []const []const u8 = &.{},
    /// Longest generated input.
    max_len: usize = 2048,
    /// Names the target in saved findings (default: "target"); also salts the mutation seed.
    name: []const u8 = "target",
    /// Do not print the "saved failing input" line (for the engine's own tests).
    quiet: bool = false,
    /// Where a failing input is saved, instead of $FUZZ_FINDINGS or ./fuzz-findings
    /// (for the engine's own tests, which must leave real findings alone).
    findings_dir: ?[]const u8 = null,
};

const dictionary = [_][]const u8{
    "0", "-1", "255", "256", "65535", "2147483647", "4294967296", "18446744073709551615",
    "-", "--", "%", "%s", "%d", "%*d", "%99999999d", "*", "?", "[", "]", "(", ")", "{", "}",
    "\\", "\"", "'", "`", "$", "$(", "${", "\n", "\r\n", "\t", " ", "\x00", "\xff", "\xc3\x28",
    "..", "/", "=", ":", ";", "|", "&", "<", ">", "e+99", "1e400", "0x", "0b", "NaN", "inf",
};

fn envStr(name: []const u8) ?[]u8 {
    return std.testing.environ.getAlloc(std.heap.page_allocator, name) catch null;
}

fn envInt(name: []const u8, default: u64) u64 {
    const v = envStr(name) orelse return default;
    defer std.heap.page_allocator.free(v);
    return std.fmt.parseInt(u64, v, 10) catch default;
}

fn mutate(rng: std.Random, gpa: std.mem.Allocator, corpus: []const []const u8, buf: *std.ArrayList(u8), max_len: usize) !void {
    buf.clearRetainingCapacity();
    if (corpus.len > 0 and rng.uintLessThan(u8, 10) != 0) {
        try buf.appendSlice(gpa, corpus[rng.uintLessThan(usize, corpus.len)]);
    } else {
        const n = rng.uintLessThan(usize, 48);
        for (0..n) |_| try buf.append(gpa, rng.int(u8));
    }
    const rounds = 1 + rng.uintLessThan(u8, 6);
    for (0..rounds) |_| {
        switch (rng.uintLessThan(u8, 9)) {
            0 => if (buf.items.len > 0) { // flip a bit
                buf.items[rng.uintLessThan(usize, buf.items.len)] ^= @as(u8, 1) << rng.int(u3);
            },
            1 => if (buf.items.len > 0) { // random byte
                buf.items[rng.uintLessThan(usize, buf.items.len)] = rng.int(u8);
            },
            2 => if (buf.items.len > 0) { // small arithmetic
                const i = rng.uintLessThan(usize, buf.items.len);
                buf.items[i] +%= @as(u8, @intCast(rng.uintLessThan(u8, 35))) -% 17;
            },
            3 => { // insert a dictionary token
                const t = dictionary[rng.uintLessThan(usize, dictionary.len)];
                const at = rng.uintAtMost(usize, buf.items.len);
                try buf.insertSlice(gpa, at, t);
            },
            4 => if (buf.items.len > 1) { // delete a chunk
                const a = rng.uintLessThan(usize, buf.items.len);
                const l = 1 + rng.uintLessThan(usize, @min(buf.items.len - a, 16));
                buf.replaceRangeAssumeCapacity(a, l, &.{});
            },
            5 => if (buf.items.len > 0) { // duplicate a chunk
                const a = rng.uintLessThan(usize, buf.items.len);
                const l = 1 + rng.uintLessThan(usize, @min(buf.items.len - a, 16));
                const copy = try gpa.dupe(u8, buf.items[a .. a + l]);
                defer gpa.free(copy);
                try buf.insertSlice(gpa, rng.uintAtMost(usize, buf.items.len), copy);
            },
            6 => if (corpus.len > 0) { // splice with another entry
                const o = corpus[rng.uintLessThan(usize, corpus.len)];
                if (o.len > 0) {
                    const a = rng.uintLessThan(usize, o.len);
                    try buf.appendSlice(gpa, o[a..@min(o.len, a + 32)]);
                }
            },
            7 => { // a run of one byte (long runs expose width/length bugs)
                const b = rng.int(u8);
                const n = rng.uintLessThan(usize, 64);
                for (0..n) |_| try buf.append(gpa, b);
            },
            else => try buf.append(gpa, rng.int(u8)),
        }
    }
    if (buf.items.len > max_len) buf.shrinkRetainingCapacity(max_len);
}

fn save(options: Options, input: []const u8) void {
    const env = if (options.findings_dir == null) envStr("FUZZ_FINDINGS") else null;
    defer if (env) |e| std.heap.page_allocator.free(e);
    const dir = options.findings_dir orelse env orelse "fuzz-findings";
    var path: [512]u8 = undefined;
    const h = std.hash.Wyhash.hash(0, input);
    const p = std.fmt.bufPrint(&path, "{s}/{s}-{x}.bin", .{ dir, options.name, h }) catch return;
    const io = std.testing.io;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = input }) catch {};
    if (!options.quiet) std.debug.print("fuzz: saved failing input ({d} bytes) to {s}\n", .{ input.len, p });
}

fn publishCurrent(input: []const u8) void {
    const path = envStr("FUZZ_CURRENT") orelse return;
    defer std.heap.page_allocator.free(path);
    std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = input }) catch {};
}

/// Drop-in for `std.testing.fuzz`: `testOne(ctx, smith)` must not crash, hang, leak or
/// return an error for any input.
pub fn fuzz(
    ctx: anytype,
    comptime testOne: fn (@TypeOf(ctx), *std.testing.Smith) anyerror!void,
    options: Options,
) anyerror!void {
    const gpa = std.heap.page_allocator;
    const campaign = envInt("FUZZ_ITERATIONS", 0);
    const iterations = if (campaign > 0) campaign else envInt("FUZZ_REGRESSION", 64);
    const seed = envInt("FUZZ_SEED", 0x5eed_c0de);
    const publish = envStr("FUZZ_CURRENT");
    defer if (publish) |p| gpa.free(p);

    // Corpus entries first, exactly once each.
    for (options.corpus) |entry| {
        if (publish != null) publishCurrent(entry);
        var smith: std.testing.Smith = .{ .in = entry };
        testOne(ctx, &smith) catch |e| {
            save(options, entry);
            return e;
        };
    }
    if (options.corpus.len == 0) {
        var smith: std.testing.Smith = .{ .in = "" };
        try testOne(ctx, &smith);
    }

    var prng = std.Random.DefaultPrng.init(seed ^ std.hash.Wyhash.hash(0, options.name));
    const rng = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        try mutate(rng, gpa, options.corpus, &buf, options.max_len);
        if (publish != null) publishCurrent(buf.items);
        var smith: std.testing.Smith = .{ .in = buf.items };
        testOne(ctx, &smith) catch |e| {
            save(options, buf.items);
            return e;
        };
    }
}

fn exampleTarget(_: void, smith: *std.testing.Smith) anyerror!void {
    var c: limits.Capped = .{};
    const a = c.allocator();
    var raw: [64]u8 = undefined;
    const n = smith.slice(&raw);
    // A "width" taken from the input: a huge value must be refused, not allocated.
    const want: usize = if (n >= 2) @as(usize, raw[0]) << 40 | raw[1] else n;
    const out = a.alloc(u8, want) catch return;
    defer a.free(out);
}

test "engine: runs corpus and mutations, and the cap turns a memory bomb into an error" {
    try fuzz({}, exampleTarget, .{ .corpus = &.{ "", "ab", "\xff\xff\xff" } });
}

test "engine: a failing target saves its input and reports the error" {
    const failing = struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var raw: [8]u8 = undefined;
            const n = smith.slice(&raw);
            if (n >= 3 and std.mem.eql(u8, raw[0..3], "bug")) return error.Found;
        }
    }.run;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try std.testing.expectError(error.Found, fuzz({}, failing, .{ .corpus = &.{"bugs"}, .quiet = true, .findings_dir = dir }));
    var it = tmp.dir.iterate();
    try std.testing.expect(try it.next(std.testing.io) != null); // the input was saved
}
