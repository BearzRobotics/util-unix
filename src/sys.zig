//! Operating-system facilities that std.Io (Zig 0.17.1) does not provide.
//!
//! Commands and the library do their file, stream and process I/O through
//! `std.Io` (ai/AGENTS.md §13). The only exception so far is signal
//! dispositions, for which std.Io has no API (checked 2026-11-07 against
//! `~/.zvm/0.17.1/lib/std/Io*`). It is isolated here, and only in the
//! executable wrappers: the library never changes process-wide state.
//! See docs/decisions/0003-std-io-exceptions.md.

const std = @import("std");
const builtin = @import("builtin");

const has_posix = builtin.os.tag != .windows and builtin.os.tag != .wasi;

pub const Signal = enum { pipe };

fn setDisposition(sig: Signal, handler: ?std.posix.Sigaction.handler_fn) void {
    if (comptime !has_posix) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(switch (sig) {
        .pipe => .PIPE,
    }, &act, null);
}

/// Ignore `sig` for the rest of the process.
pub fn ignoreSignal(sig: Signal) void {
    setDisposition(sig, std.posix.SIG.IGN);
}

/// Restore the default action of `sig`.
pub fn defaultSignal(sig: Signal) void {
    setDisposition(sig, std.posix.SIG.DFL);
}

/// Zig's runtime ignores SIGPIPE, which would turn `cmd | head` into a write
/// error message. The conventional behaviour is to die silently, so every
/// entry point restores the default action. A command that must see EPIPE
/// can set it back to ignore with `ignoreSignal`; none does yet.
pub fn restoreSigpipe() void {
    defaultSignal(.pipe);
}
