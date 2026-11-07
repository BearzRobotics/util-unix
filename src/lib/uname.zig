//! uname: select and print system information fields.
//!
//! References: POSIX.1-2024 uname
//! (https://pubs.opengroup.org/onlinepubs/9799919799/utilities/uname.html:
//! -a -m -n -r -s -v); GNU coreutils 9.7 manual, "uname invocation" for -p, -i
//! and -o. POSIX leaves the output format of the individual fields open; the
//! order and the single-space separator follow GNU.
//!
//! -p and -i print the machine name, as GNU 9.7 does on Linux when it has
//! nothing better, so `-a` always includes them.
//! The operating-system name is "GNU/Linux" on Linux, which is what GNU prints
//! for -o; other systems use their kernel name.

const std = @import("std");
const Io = std.Io;
const proc = @import("proc.zig");

pub const Fields = struct {
    kernel_name: bool = false, // -s
    nodename: bool = false, // -n
    kernel_release: bool = false, // -r
    kernel_version: bool = false, // -v
    machine: bool = false, // -m
    processor: bool = false, // -p
    hardware_platform: bool = false, // -i
    operating_system: bool = false, // -o

    pub const all: Fields = .{
        .kernel_name = true,
        .nodename = true,
        .kernel_release = true,
        .kernel_version = true,
        .machine = true,
        .processor = true,
        .hardware_platform = true,
        .operating_system = true,
    };

    pub fn any(f: Fields) bool {
        return f.kernel_name or f.nodename or f.kernel_release or f.kernel_version or
            f.machine or f.processor or f.hardware_platform or f.operating_system;
    }
};

/// Write the selected fields, separated by single spaces, and a newline.
/// With nothing selected the kernel name is printed (POSIX default).
pub fn write(info: *const proc.Uname, fields: Fields, w: *Io.Writer) Io.Writer.Error!void {
    const f = if (fields.any()) fields else Fields{ .kernel_name = true };
    var first = true;
    const os_name: []const u8 = if (@import("builtin").os.tag == .linux) "GNU/Linux" else info.sysname();
    const items = [_]struct { on: bool, text: []const u8 }{
        .{ .on = f.kernel_name, .text = info.sysname() },
        .{ .on = f.nodename, .text = info.nodename() },
        .{ .on = f.kernel_release, .text = info.release() },
        .{ .on = f.kernel_version, .text = info.version() },
        .{ .on = f.machine, .text = info.machine() },
        .{ .on = f.processor, .text = info.machine() },
        .{ .on = f.hardware_platform, .text = info.machine() },
        .{ .on = f.operating_system, .text = os_name },
    };
    for (items) |item| {
        if (!item.on) continue;
        if (!first) try w.writeByte(' ');
        first = false;
        try w.writeAll(item.text);
    }
    try w.writeByte('\n');
}

test "fields print in POSIX/GNU order regardless of selection order" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const info = proc.uname();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try write(&info, .{ .machine = true, .kernel_name = true }, &w);
    var want: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(&want, "{s} {s}\n", .{ info.sysname(), info.machine() });
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "no selection prints the kernel name" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const info = proc.uname();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try write(&info, .{}, &w);
    try std.testing.expectEqualStrings("Linux\n", w.buffered());
}
