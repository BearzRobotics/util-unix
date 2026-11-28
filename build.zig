// SPDX-License-Identifier: GPL-2.0-or-later
//! util-unix build script. See ai/SPECS.md §8 for the packaging modes.
//!
//! Layout (decision 0002): every command's logic lives in the reusable Zig
//! library module `util_unix` (src/root.zig, src/lib/); the executables are
//! thin wrappers (src/commands/, src/cli.zig) that parse arguments, call the
//! library, and format diagnostics. Other projects (e.g. DKDE) depend on the
//! library through the package system:
//!
//!     const uu = b.dependency("util_unix", .{ .target = t, .optimize = o });
//!     exe.root_module.addImport("util_unix", uu.module("util_unix"));
//!
//! Options:
//!   -Dcommands=a,b,c   build only these commands (default: all)
//!   -Dmode=standalone|multicall|all
//!                      what to install (default: all)
//!   -Dman=bool         install the manual pages (default: on)
//!   -Dstrip=bool       strip debug info (default: on unless -Doptimize=Debug)
//!
//! Outputs (zig-out/bin; manual pages in zig-out/share/man/man1 as NAME.1.md, which
//! dkman and dkde-help read):
//!   <command>   one executable per selected command   (-Dmode=standalone, all)
//!   util-unix   multicall binary; `util-unix <command> ...` or invoked
//!               through a link named after a command  (-Dmode=multicall, all)

const std = @import("std");
const commands = @import("src/commands.zig");
const manifest = @import("build.zig.zon");

/// Which executables `zig build` installs.
const Mode = enum {
    /// One executable per command, no multicall binary.
    standalone,
    /// Only the `util-unix` multicall binary.
    multicall,
    /// Both.
    all,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from command executables (default: on unless Debug)") orelse (optimize != .debug);
    const mode = b.option(Mode, "mode", "What to build: standalone (one binary per command), multicall (util-unix only) or all (default)") orelse .all;
    const install_man = b.option(bool, "man", "Install the manual pages as share/man/man1/NAME.1.md (default: on)") orelse true;
    const selected = selectCommands(b);

    // The reusable library. Exported to dependents as "util_unix".
    const lib_mod = b.addModule("util_unix", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run Zig unit tests");

    // The version printed by --version comes from build.zig.zon, the single
    // place it is written down. It reaches the wrappers as "build_options".
    const version_opts = b.addOptions();
    version_opts.addOption([]const u8, "version", manifest.version);

    // Individual executables.
    if (mode != .multicall) for (selected) |name| {
        const opts = b.addOptions();
        opts.addOption([]const u8, "command", name);
        opts.addOption([]const u8, "version", manifest.version);
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/exe.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
                .imports = &.{.{ .name = "util_unix", .module = lib_mod }},
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        b.installArtifact(exe);
    };

    // Multicall executable.
    if (mode != .standalone) {
        const opts = b.addOptions();
        opts.addOption([]const []const u8, "commands", selected);
        opts.addOption([]const u8, "version", manifest.version);
        const exe = b.addExecutable(.{
            .name = "util-unix",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/multicall.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
                .imports = &.{.{ .name = "util_unix", .module = lib_mod }},
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        b.installArtifact(exe);
    }

    // Manual pages (Markdown, rendered by dkman and dkde-help; see docs/manpages/README.md).
    if (install_man) {
        for (selected) |name| {
            // `[` is documented on the `test` page.
            const page = if (std.mem.eql(u8, name, "[")) "test" else name;
            const src = b.fmt("docs/manpages/{s}.md", .{page});
            const dest = b.fmt("{s}.1.md", .{name});
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(src), .{ .custom = "share/man/man1" }, dest).step);
        }
        if (mode != .standalone) {
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("docs/manpages/util-unix.md"), .{ .custom = "share/man/man1" }, "util-unix.1.md").step);
        }
    }

    // Unit tests: the library on its own, then the wrappers.
    const lib_unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&runUnitTest(b, lib_unit, target).step);

    const cli_unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util_unix", .module = lib_mod },
            .{ .name = "build_options", .module = version_opts.createModule() },
        },
    }) });
    test_step.dependOn(&runUnitTest(b, cli_unit, target).step);

    // Fuzz tests (src/fuzz/, decision 0010): ordinary tests driven by our own mutation
    // engine (src/fuzz/engine.zig; Zig 0.17.1's built-in fuzzer does not run). `zig build
    // test` runs them as short regression tests, memory-capped like the others;
    // `zig build fuzz` is the campaign and is meant to be started through tools/fuzz.sh,
    // which sets the iteration count and caps memory and time. Never pass --fuzz.
    {
        const fuzz_t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "util_unix", .module = lib_mod }},
            }),
        });
        test_step.dependOn(&runUnitTest(b, fuzz_t, target).step);
        const campaign = b.addRunArtifact(fuzz_t);
        campaign.has_side_effects = true; // never cached: every campaign really runs
        b.step("fuzz", "Run the fuzz campaign (use tools/fuzz.sh)").dependOn(&campaign.step);
    }
}

/// Some unit tests run shell scripts in the test process. On a systemd host,
/// run them through test/contain.sh: a runaway one must not get the caller's
/// whole terminal stopped by the OOM killer.
fn runUnitTest(b: *std.Build, unit: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) *std.Build.Step.Run {
    const here = @import("builtin");
    if (here.os.tag != .linux or target.result.os.tag != .linux or target.result.cpu.arch != here.cpu.arch or
        b.findProgram(.{ .names = &.{"systemd-run"} }) == null) return b.addRunArtifact(unit);
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(b.path("test/contain.sh"));
    run.addArtifactArg(unit);
    // not the test runner protocol: the binary runs the tests and exits non-zero on failure
    run.expectExitCode(0);
    return run;
}

fn selectCommands(b: *std.Build) []const []const u8 {
    const requested = b.option([]const u8, "commands", "Comma-separated commands to build (default: all)") orelse
        return &commands.all;

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, requested, ',');
    while (it.next()) |name| {
        const known = for (commands.all) |k| {
            if (std.mem.eql(u8, k, name)) break true;
        } else false;
        if (!known) std.debug.panic("unknown command '{s}' in -Dcommands", .{name});
        list.append(b.allocator, name) catch @panic("OOM");
    }
    return list.items;
}
