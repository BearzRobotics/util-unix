//! Multicall entry point. Dispatch order (SPEC.md §7):
//!   1. basename of argv[0] names an enabled command  -> run it;
//!   2. otherwise argv[0] is the multicall binary itself and argv[1] is the
//!      command name: `util-unix <command> [args...]`.
//! Unknown commands exit 127 (matching shell "command not found"); a bare
//! invocation or `--help` lists the enabled commands.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const cli = @import("cli.zig");
const sys = @import("sys.zig");
const commands = @import("commands.zig");

const enabled = options.commands;

// Release builds drop the stack-trace machinery (about 6 KB per binary) and
// keep the panic message; Debug builds keep the full std behaviour.
pub const std_options: std.Options = .{
    .enable_segfault_handler = builtin.mode == .debug,
    .signal_stack_size = if (builtin.mode == .debug) 1 << 18 else null,
    .allow_stack_tracing = builtin.mode == .debug,
};
pub const panic = if (builtin.mode == .debug) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.simple_panic;

pub fn main(init: std.process.Init) !u8 {
    sys.restoreSigpipe();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var ctx: cli.Context = .{
        .name = "",
        .args = args[1..],
        .io = init.io,
        .gpa = init.gpa,
        .environ = init.environ_map,
    };

    const invoked = baseName(args[0]);
    if (commands.find(enabled, invoked)) |run| {
        ctx.name = invoked;
        return run(ctx);
    }

    // Subcommand mode.
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) return usage(ctx, args.len >= 2);
    if (std.mem.eql(u8, args[1], "--list")) return list(ctx);
    ctx.name = args[1];
    ctx.args = args[2..];
    if (commands.find(enabled, args[1])) |run| return run(ctx);

    cli.warn(.{ .name = invoked, .args = &.{}, .io = init.io, .gpa = init.gpa }, "unknown command '{s}'", .{args[1]});
    return 127;
}

fn baseName(path: []const u8) []const u8 {
    var name = path;
    if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| name = name[i + 1 ..];
    // Windows executables carry an extension.
    if (std.ascii.endsWithIgnoreCase(name, ".exe")) name = name[0 .. name.len - 4];
    return name;
}

fn list(ctx: cli.Context) u8 {
    inline for (enabled) |e| {
        if (!cli.writeStdout(ctx.io, e ++ "\n")) return 1;
    }
    return 0;
}

fn usage(ctx: cli.Context, explicit: bool) u8 {
    const text = "Usage: util-unix <command> [arguments...]\n" ++
        "   or: <command> [arguments...]  (when invoked through a link named after a command)\n\n" ++
        "Use 'util-unix --list' to list the available commands.\n";
    if (explicit) return if (cli.writeStdout(ctx.io, text)) 0 else 1;
    std.Io.File.stderr().writeStreamingAll(ctx.io, text) catch {};
    return 2;
}
