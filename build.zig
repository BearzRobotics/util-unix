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
//!   -Dstrip=bool       strip debug info (default: on unless -Doptimize=Debug)
//!
//! Outputs (zig-out/bin):
//!   <command>   one executable per selected command   (individual mode)
//!   util-unix   multicall binary; `util-unix <command> ...` or invoked
//!               through a link named after a command   (multicall modes)

const std = @import("std");
const commands = @import("src/commands.zig");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from command executables (default: on unless Debug)") orelse (optimize != .debug);
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
    for (selected) |name| {
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
    }

    // Multicall executable.
    {
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

    // Unit tests: the library on its own, then the wrappers.
    const lib_unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(lib_unit).step);

    const cli_unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util_unix", .module = lib_mod },
            .{ .name = "build_options", .module = version_opts.createModule() },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(cli_unit).step);
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
