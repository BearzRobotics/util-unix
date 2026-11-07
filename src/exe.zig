//! Individual-executable entry point: one binary per command. The command is
//! fixed at build time through the `build_options.command` option.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const cli = @import("cli.zig");
const sys = @import("sys.zig");
const commands = @import("commands.zig");

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
    return commands.get(options.command)(.{
        .name = options.command,
        .args = args[1..],
        .io = init.io,
        .gpa = init.gpa,
        .environ = init.environ_map,
    });
}
