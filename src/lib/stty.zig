// SPDX-License-Identifier: GPL-2.0-or-later
//! stty: the terminal settings model, the table of named settings, and the three
//! output forms (changed settings, all settings, saved settings).
//!
//! References: GNU coreutils 9.7 manual, "stty invocation" and `stty --help`;
//! POSIX.1-2024 stty and termios (<termios.h>); termios(3), tty_ioctl(4),
//! ioctl_tty(2), Linux man-pages. The upstream source of GNU stty was not
//! consulted: the list of settings, what each combination setting changes and
//! the output layout were derived from the manual and by running GNU stty on a
//! pseudo-terminal beside this one (test/test_stty.sh).
//!
//! Platform: Linux on architectures that share the generic termios layout
//! (x86, arm, arm64, riscv, s390x, loongarch). The ioctl numbers and flag values
//! below are those of `asm-generic/termbits.h`; mips, powerpc, sparc, alpha and
//! parisc differ and are reported as unsupported. Only the classic `TCGETS`
//! structure is used, so speeds are limited to the Bxxx constants (up to
//! 4000000 baud) and arbitrary baud rates (BOTHER) are not available.
//!
//! The library does the ioctl calls itself (std.Io has no termios API; see
//! docs/decisions/0006-unix-commands-beyond-util-linux-and-raw-ioctl.md). It
//! never prints; writers are passed in.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const linux = std.os.linux;

pub const supported = builtin.os.tag == .linux and switch (builtin.cpu.arch) {
    .x86, .x86_64, .arm, .armeb, .aarch64, .aarch64_be, .riscv32, .riscv64, .s390x, .loongarch64 => true,
    else => false,
};

// ---------------------------------------------------------------------------
// Kernel structures and ioctl numbers (asm-generic).

pub const nccs = 19;
/// The glibc/musl `termios` has 32 control characters; `-g` prints all of them.
pub const user_nccs = 32;

pub const Termios = extern struct {
    iflag: u32 = 0,
    oflag: u32 = 0,
    cflag: u32 = 0,
    lflag: u32 = 0,
    line: u8 = 0,
    cc: [nccs]u8 = @splat(0),
};

pub const WinSize = extern struct { rows: u16 = 0, cols: u16 = 0, xpixel: u16 = 0, ypixel: u16 = 0 };

const TCGETS = 0x5401;
const TCSETS = 0x5402;
const TCSETSW = 0x5403;
const TCSETSF = 0x5404;
const TIOCGWINSZ = 0x5413;
const TIOCSWINSZ = 0x5414;

pub const IoctlError = error{ NotATerminal, Unexpected, Unsupported, AccessDenied, InvalidArgument, NoDevice, InputOutput };

fn mapErrno(e: linux.E) IoctlError {
    return switch (e) {
        .NOTTY => error.NotATerminal,
        .ACCES, .PERM => error.AccessDenied,
        .INVAL => error.InvalidArgument,
        .NXIO, .NODEV => error.NoDevice,
        .IO => error.InputOutput,
        else => error.Unexpected,
    };
}

fn ioctl(fd: i32, request: u32, arg: usize) IoctlError!void {
    if (comptime !supported) return error.Unsupported;
    const rc = linux.ioctl(fd, request, arg);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

/// The terminal's settings. As glibc's tcgetattr does, the input-speed bits
/// of `cflag` are always filled in: when the kernel leaves them zero ("same as
/// the output speed"), they are set to the output speed's code. That is what
/// `-g` prints and what separate input and output speeds are built on.
pub fn getTermios(fd: i32) IoctlError!Termios {
    var t: Termios = .{};
    try ioctl(fd, TCGETS, @intFromPtr(&t));
    if (t.cflag & CIBAUD == 0) t.cflag |= (t.cflag & CBAUD) << IBSHIFT;
    return t;
}

pub const SetWhen = enum { now, drain, flush };

pub fn setTermios(fd: i32, t: *const Termios, when: SetWhen) IoctlError!void {
    const req: u32 = switch (when) {
        .now => TCSETS,
        .drain => TCSETSW,
        .flush => TCSETSF,
    };
    try ioctl(fd, req, @intFromPtr(t));
}

pub fn getWinSize(fd: i32) IoctlError!WinSize {
    var w: WinSize = .{};
    try ioctl(fd, TIOCGWINSZ, @intFromPtr(&w));
    return w;
}

pub fn setWinSize(fd: i32, w: *const WinSize) IoctlError!void {
    try ioctl(fd, TIOCSWINSZ, @intFromPtr(w));
}

// ---------------------------------------------------------------------------
// Flag values.

const IGNBRK = 0o000001;
const BRKINT = 0o000002;
const IGNPAR = 0o000004;
const PARMRK = 0o000010;
const INPCK = 0o000020;
const ISTRIP = 0o000040;
const INLCR = 0o000100;
const IGNCR = 0o000200;
const ICRNL = 0o000400;
const IUCLC = 0o001000;
const IXON = 0o002000;
const IXANY = 0o004000;
const IXOFF = 0o010000;
const IMAXBEL = 0o020000;
const IUTF8 = 0o040000;

const OPOST = 0o000001;
const OLCUC = 0o000002;
const ONLCR = 0o000004;
const OCRNL = 0o000010;
const ONOCR = 0o000020;
const ONLRET = 0o000040;
const OFILL = 0o000100;
const OFDEL = 0o000200;
const NLDLY = 0o000400;
const NL1 = 0o000400;
const CRDLY = 0o003000;
const CR1 = 0o001000;
const CR2 = 0o002000;
const CR3 = 0o003000;
const TABDLY = 0o014000;
const TAB1 = 0o004000;
const TAB2 = 0o010000;
const TAB3 = 0o014000;
const BSDLY = 0o020000;
const BS1 = 0o020000;
const VTDLY = 0o040000;
const VT1 = 0o040000;
const FFDLY = 0o100000;
const FF1 = 0o100000;

pub const CBAUD = 0o010017;
pub const IBSHIFT = 16;
const CIBAUD: u32 = 0o10017 << IBSHIFT;
const CSIZE = 0o000060;
const CS5 = 0;
const CS6 = 0o000020;
const CS7 = 0o000040;
const CS8 = 0o000060;
const CSTOPB = 0o000100;
const CREAD = 0o000200;
const PARENB = 0o000400;
const PARODD = 0o001000;
const HUPCL = 0o002000;
const CLOCAL = 0o004000;
const CMSPAR: u32 = 0o10000000000;
const CRTSCTS: u32 = 0o20000000000;

const ISIG = 0o000001;
const ICANON = 0o000002;
const XCASE = 0o000004;
const ECHO = 0o000010;
const ECHOE = 0o000020;
const ECHOK = 0o000040;
const ECHONL = 0o000100;
const NOFLSH = 0o000200;
const TOSTOP = 0o000400;
const ECHOCTL = 0o001000;
const ECHOPRT = 0o002000;
const ECHOKE = 0o004000;
const FLUSHO = 0o010000;
const IEXTEN = 0o100000;
const EXTPROC = 0o200000;

// c_cc indexes.
const VINTR = 0;
const VQUIT = 1;
const VERASE = 2;
const VKILL = 3;
const VEOF = 4;
const VTIME = 5;
const VMIN = 6;
const VSWTC = 7;
const VSTART = 8;
const VSTOP = 9;
const VSUSP = 10;
const VEOL = 11;
const VREPRINT = 12;
const VDISCARD = 13;
const VWERASE = 14;
const VLNEXT = 15;
const VEOL2 = 16;

// ---------------------------------------------------------------------------
// Special characters.

pub const ControlChar = struct {
    name: []const u8,
    index: u8,
    /// Value `sane` sets and the default display compares against.
    default: u8,
};

/// In the order GNU prints them. `min` and `time` are listed because `sane`
/// resets them, but they are printed on their own.
pub const control_chars = [_]ControlChar{
    .{ .name = "intr", .index = VINTR, .default = 0x03 },
    .{ .name = "quit", .index = VQUIT, .default = 0x1c },
    .{ .name = "erase", .index = VERASE, .default = 0x7f },
    .{ .name = "kill", .index = VKILL, .default = 0x15 },
    .{ .name = "eof", .index = VEOF, .default = 0x04 },
    .{ .name = "eol", .index = VEOL, .default = 0 },
    .{ .name = "eol2", .index = VEOL2, .default = 0 },
    .{ .name = "swtch", .index = VSWTC, .default = 0 },
    .{ .name = "start", .index = VSTART, .default = 0x11 },
    .{ .name = "stop", .index = VSTOP, .default = 0x13 },
    .{ .name = "susp", .index = VSUSP, .default = 0x1a },
    .{ .name = "rprnt", .index = VREPRINT, .default = 0x12 },
    .{ .name = "werase", .index = VWERASE, .default = 0x17 },
    .{ .name = "lnext", .index = VLNEXT, .default = 0x16 },
    .{ .name = "discard", .index = VDISCARD, .default = 0x0f },
};

pub fn findControlChar(name: []const u8) ?ControlChar {
    for (control_chars) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

pub const CharError = error{ InvalidInteger, OutOfRange };

/// Value for a special character given as text: one literal character, `^c`
/// (control-c), `^?` (delete), `^-` or `undef` (disabled), or a number in the
/// notation of strtoul with base 0 (decimal, 0x hex, 0 octal).
pub fn parseControlChar(text: []const u8) CharError!u8 {
    if (text.len == 1) return text[0];
    if (text.len == 2 and text[0] == '^') {
        if (text[1] == '-') return 0;
        if (text[1] == '?') return 0x7f;
        return std.ascii.toUpper(text[1]) & 0x1f;
    }
    if (std.mem.eql(u8, text, "undef")) return 0;
    const n = try parseUnsigned(text);
    if (n > 255) return error.OutOfRange;
    return @intCast(n);
}

/// strtoul with base 0 on the whole text.
pub fn parseUnsigned(text: []const u8) CharError!u64 {
    if (text.len == 0) return error.InvalidInteger;
    var base: u8 = 10;
    var digits = text;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        base = 16;
        digits = text[2..];
    } else if (text.len > 1 and text[0] == '0') {
        base = 8;
        digits = text[1..];
    }
    if (digits[0] == '+' or digits[0] == '-') return error.InvalidInteger;
    return std.fmt.parseInt(u64, digits, base) catch |e| switch (e) {
        error.Overflow => error.OutOfRange,
        else => error.InvalidInteger,
    };
}

/// How a special character is shown: `^C`, `^?`, `M-x`, or `<undef>` for 0.
pub fn writeChar(w: *Io.Writer, c: u8) Io.Writer.Error!void {
    if (c == 0) return w.writeAll("<undef>");
    try writeVisible(w, c);
}

fn writeVisible(w: *Io.Writer, c0: u8) Io.Writer.Error!void {
    var c = c0;
    if (c >= 0x80) {
        try w.writeAll("M-");
        c -= 0x80;
    }
    if (c < 0x20) {
        try w.writeByte('^');
        try w.writeByte(c + 0x40);
    } else if (c == 0x7f) {
        try w.writeAll("^?");
    } else try w.writeByte(c);
}

// ---------------------------------------------------------------------------
// Speeds.

const speed_table = [_]struct { baud: u32, code: u32 }{
    .{ .baud = 0, .code = 0 },
    .{ .baud = 50, .code = 0o1 },
    .{ .baud = 75, .code = 0o2 },
    .{ .baud = 110, .code = 0o3 },
    .{ .baud = 134, .code = 0o4 },
    .{ .baud = 150, .code = 0o5 },
    .{ .baud = 200, .code = 0o6 },
    .{ .baud = 300, .code = 0o7 },
    .{ .baud = 600, .code = 0o10 },
    .{ .baud = 1200, .code = 0o11 },
    .{ .baud = 1800, .code = 0o12 },
    .{ .baud = 2400, .code = 0o13 },
    .{ .baud = 4800, .code = 0o14 },
    .{ .baud = 9600, .code = 0o15 },
    .{ .baud = 19200, .code = 0o16 },
    .{ .baud = 38400, .code = 0o17 },
    .{ .baud = 57600, .code = 0o10001 },
    .{ .baud = 115200, .code = 0o10002 },
    .{ .baud = 230400, .code = 0o10003 },
    .{ .baud = 460800, .code = 0o10004 },
    .{ .baud = 500000, .code = 0o10005 },
    .{ .baud = 576000, .code = 0o10006 },
    .{ .baud = 921600, .code = 0o10007 },
    .{ .baud = 1000000, .code = 0o10010 },
    .{ .baud = 1152000, .code = 0o10011 },
    .{ .baud = 1500000, .code = 0o10012 },
    .{ .baud = 2000000, .code = 0o10013 },
    .{ .baud = 2500000, .code = 0o10014 },
    .{ .baud = 3000000, .code = 0o10015 },
    .{ .baud = 3500000, .code = 0o10016 },
    .{ .baud = 4000000, .code = 0o10017 },
};

/// Speed code (the Bxxx bits) for a baud rate given as text, e.g. "9600" or
/// "134.5". Null when it is not a speed the kernel interface knows.
pub fn speedCode(text: []const u8) ?u32 {
    if (std.mem.eql(u8, text, "134.5")) return 0o4;
    const n = std.fmt.parseInt(u32, text, 10) catch return null;
    for (speed_table) |s| if (s.baud == n) return s.code;
    return null;
}

pub fn speedBaud(code: u32) u32 {
    for (speed_table) |s| if (s.code == code) return s.baud;
    return 0;
}

pub fn outputSpeed(t: Termios) u32 {
    return speedBaud(t.cflag & CBAUD);
}

/// Input speed; when the input-speed bits are zero the input speed equals the
/// output speed.
pub fn inputSpeed(t: Termios) u32 {
    const code = (t.cflag & CIBAUD) >> IBSHIFT;
    return if (code == 0) outputSpeed(t) else speedBaud(code);
}

test "an unset input speed follows the output speed" {
    var t: Termios = .{};
    setOutputSpeed(&t, 0o15);
    try std.testing.expectEqual(@as(u32, 9600), inputSpeed(t));
    setInputSpeed(&t, 0o17);
    try std.testing.expectEqual(@as(u32, 38400), inputSpeed(t));
    try std.testing.expectEqual(@as(u32, 9600), outputSpeed(t));
}

pub fn setOutputSpeed(t: *Termios, code: u32) void {
    t.cflag = (t.cflag & ~@as(u32, CBAUD)) | code;
}

pub fn setInputSpeed(t: *Termios, code: u32) void {
    t.cflag = (t.cflag & ~CIBAUD) | (code << IBSHIFT);
}

pub fn setSpeed(t: *Termios, code: u32) void {
    setOutputSpeed(t, code);
    setInputSpeed(t, code);
}

// ---------------------------------------------------------------------------
// Named settings.

pub const Kind = enum { control, input, output, local, combination };
pub const Sane = enum { none, set, unset };

pub const Mode = struct {
    name: []const u8,
    kind: Kind,
    /// May be negated with a leading `-`.
    rev: bool = false,
    /// Not shown by -a (a synonym).
    omit: bool = false,
    sane: Sane = .none,
    /// Bits to set. With `mask` != 0 the setting is a value within the mask.
    bits: u32 = 0,
    mask: u32 = 0,
};

fn flag(name: []const u8, kind: Kind, on_sane: Sane, bits: u32) Mode {
    return .{ .name = name, .kind = kind, .rev = true, .sane = on_sane, .bits = bits };
}
fn alias(name: []const u8, kind: Kind, bits: u32) Mode {
    return .{ .name = name, .kind = kind, .rev = true, .omit = true, .bits = bits };
}
fn value(name: []const u8, kind: Kind, on_sane: Sane, bits: u32, mask: u32) Mode {
    return .{ .name = name, .kind = kind, .sane = on_sane, .bits = bits, .mask = mask };
}
fn combo(name: []const u8, rev: bool) Mode {
    return .{ .name = name, .kind = .combination, .rev = rev };
}

pub const modes = [_]Mode{
    // control
    flag("parenb", .control, .none, PARENB),
    flag("parodd", .control, .none, PARODD),
    flag("cmspar", .control, .none, CMSPAR),
    value("cs5", .control, .none, CS5, CSIZE),
    value("cs6", .control, .none, CS6, CSIZE),
    value("cs7", .control, .none, CS7, CSIZE),
    value("cs8", .control, .none, CS8, CSIZE),
    flag("hupcl", .control, .none, HUPCL),
    alias("hup", .control, HUPCL),
    flag("cstopb", .control, .none, CSTOPB),
    flag("cread", .control, .set, CREAD),
    flag("clocal", .control, .none, CLOCAL),
    flag("crtscts", .control, .none, CRTSCTS),
    // input
    flag("ignbrk", .input, .unset, IGNBRK),
    flag("brkint", .input, .set, BRKINT),
    flag("ignpar", .input, .none, IGNPAR),
    flag("parmrk", .input, .none, PARMRK),
    flag("inpck", .input, .none, INPCK),
    flag("istrip", .input, .none, ISTRIP),
    flag("inlcr", .input, .unset, INLCR),
    flag("igncr", .input, .unset, IGNCR),
    flag("icrnl", .input, .set, ICRNL),
    flag("ixon", .input, .none, IXON),
    flag("ixoff", .input, .unset, IXOFF),
    alias("tandem", .input, IXOFF),
    flag("iuclc", .input, .unset, IUCLC),
    flag("ixany", .input, .unset, IXANY),
    flag("imaxbel", .input, .set, IMAXBEL),
    flag("iutf8", .input, .unset, IUTF8),
    // output
    flag("opost", .output, .set, OPOST),
    flag("olcuc", .output, .unset, OLCUC),
    flag("ocrnl", .output, .unset, OCRNL),
    flag("onlcr", .output, .set, ONLCR),
    flag("onocr", .output, .unset, ONOCR),
    flag("onlret", .output, .unset, ONLRET),
    flag("ofill", .output, .unset, OFILL),
    flag("ofdel", .output, .unset, OFDEL),
    value("nl1", .output, .unset, NL1, NLDLY),
    value("nl0", .output, .set, 0, NLDLY),
    value("cr3", .output, .unset, CR3, CRDLY),
    value("cr2", .output, .unset, CR2, CRDLY),
    value("cr1", .output, .unset, CR1, CRDLY),
    value("cr0", .output, .set, 0, CRDLY),
    value("tab3", .output, .unset, TAB3, TABDLY),
    value("tab2", .output, .unset, TAB2, TABDLY),
    value("tab1", .output, .unset, TAB1, TABDLY),
    value("tab0", .output, .set, 0, TABDLY),
    value("bs1", .output, .unset, BS1, BSDLY),
    value("bs0", .output, .set, 0, BSDLY),
    value("vt1", .output, .unset, VT1, VTDLY),
    value("vt0", .output, .set, 0, VTDLY),
    value("ff1", .output, .unset, FF1, FFDLY),
    value("ff0", .output, .set, 0, FFDLY),
    // local
    flag("isig", .local, .set, ISIG),
    flag("icanon", .local, .set, ICANON),
    flag("iexten", .local, .set, IEXTEN),
    flag("echo", .local, .set, ECHO),
    flag("echoe", .local, .set, ECHOE),
    alias("crterase", .local, ECHOE),
    flag("echok", .local, .set, ECHOK),
    flag("echonl", .local, .unset, ECHONL),
    flag("noflsh", .local, .unset, NOFLSH),
    flag("xcase", .local, .unset, XCASE),
    flag("tostop", .local, .unset, TOSTOP),
    flag("echoprt", .local, .unset, ECHOPRT),
    alias("prterase", .local, ECHOPRT),
    flag("echoctl", .local, .set, ECHOCTL),
    alias("ctlecho", .local, ECHOCTL),
    flag("echoke", .local, .set, ECHOKE),
    alias("crtkill", .local, ECHOKE),
    flag("flusho", .local, .unset, FLUSHO),
    flag("extproc", .local, .unset, EXTPROC),
    // combinations
    combo("evenp", true),
    combo("parity", true),
    combo("oddp", true),
    combo("nl", true),
    combo("ek", false),
    combo("sane", false),
    combo("cooked", true),
    combo("raw", true),
    combo("pass8", true),
    combo("litout", true),
    combo("cbreak", true),
    combo("decctlq", true),
    combo("tabs", true),
    combo("lcase", true),
    combo("LCASE", true),
    combo("crt", false),
    combo("dec", false),
};

pub fn findMode(name: []const u8) ?*const Mode {
    for (&modes) |*m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn bitsOf(t: *Termios, kind: Kind) *u32 {
    return switch (kind) {
        .control => &t.cflag,
        .input => &t.iflag,
        .output => &t.oflag,
        .local => &t.lflag,
        .combination => unreachable,
    };
}

fn active(t: Termios, m: Mode) bool {
    var copy = t;
    const bits = bitsOf(&copy, m.kind).*;
    return if (m.mask != 0) (bits & m.mask) == m.bits else (bits & m.bits) == m.bits;
}

/// Apply setting `m`, negated when `reversed`. The caller has checked that a
/// reversed setting is allowed (`m.rev`).
pub fn applyMode(t: *Termios, m: Mode, reversed: bool) void {
    if (m.kind == .combination) return applyCombination(t, m.name, reversed);
    const bits = bitsOf(t, m.kind);
    if (m.mask != 0) {
        bits.* = (bits.* & ~m.mask) | m.bits;
    } else if (reversed) {
        bits.* &= ~m.bits;
    } else {
        bits.* |= m.bits;
    }
}

fn setCc(t: *Termios, index: u8, v: u8) void {
    t.cc[index] = v;
}

fn applyCombination(t: *Termios, name: []const u8, reversed: bool) void {
    const eql = std.mem.eql;
    if (eql(u8, name, "evenp") or eql(u8, name, "parity")) {
        if (reversed) {
            t.cflag = (t.cflag & ~@as(u32, PARENB | CSIZE)) | CS8;
        } else {
            t.cflag = (t.cflag & ~@as(u32, PARODD | CSIZE)) | PARENB | CS7;
        }
    } else if (eql(u8, name, "oddp")) {
        if (reversed) {
            t.cflag = (t.cflag & ~@as(u32, PARENB | CSIZE)) | CS8;
        } else {
            t.cflag = (t.cflag & ~@as(u32, CSIZE)) | CS7 | PARODD | PARENB;
        }
    } else if (eql(u8, name, "nl")) {
        if (reversed) {
            t.iflag = (t.iflag | ICRNL) & ~@as(u32, INLCR | IGNCR);
            t.oflag = (t.oflag | ONLCR) & ~@as(u32, OCRNL | ONLRET);
        } else {
            t.iflag &= ~@as(u32, ICRNL);
            t.oflag &= ~@as(u32, ONLCR);
        }
    } else if (eql(u8, name, "ek")) {
        setCc(t, VERASE, 0x7f);
        setCc(t, VKILL, 0x15);
    } else if (eql(u8, name, "sane")) {
        sane(t);
    } else if (eql(u8, name, "cbreak")) {
        if (reversed) t.lflag |= ICANON else t.lflag &= ~@as(u32, ICANON);
    } else if (eql(u8, name, "pass8")) {
        if (reversed) {
            t.cflag = (t.cflag & ~@as(u32, CSIZE)) | CS7 | PARENB;
            t.iflag |= ISTRIP;
        } else {
            t.cflag = (t.cflag & ~@as(u32, PARENB | CSIZE)) | CS8;
            t.iflag &= ~@as(u32, ISTRIP);
        }
    } else if (eql(u8, name, "litout")) {
        if (reversed) {
            t.cflag = (t.cflag & ~@as(u32, CSIZE)) | CS7 | PARENB;
            t.iflag |= ISTRIP;
            t.oflag |= OPOST;
        } else {
            t.cflag = (t.cflag & ~@as(u32, PARENB | CSIZE)) | CS8;
            t.iflag &= ~@as(u32, ISTRIP);
            t.oflag &= ~@as(u32, OPOST);
        }
    } else if (eql(u8, name, "raw") or eql(u8, name, "cooked")) {
        const raw = eql(u8, name, "raw") != reversed;
        if (raw) {
            setCc(t, VMIN, 1);
            setCc(t, VTIME, 0);
            t.iflag &= ~@as(u32, IGNBRK | BRKINT | IGNPAR | PARMRK | INPCK | ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXOFF | IUCLC | IXANY | IMAXBEL);
            t.oflag &= ~@as(u32, OPOST);
            t.lflag &= ~@as(u32, ISIG | ICANON | XCASE);
        } else {
            t.iflag |= BRKINT | IGNPAR | ISTRIP | ICRNL | IXON;
            t.oflag |= OPOST;
            t.lflag |= ISIG | ICANON;
            setCc(t, VEOF, 0x04);
            setCc(t, VEOL, 0);
        }
    } else if (eql(u8, name, "decctlq")) {
        if (reversed) t.iflag |= IXANY else t.iflag &= ~@as(u32, IXANY);
    } else if (eql(u8, name, "tabs")) {
        t.oflag = (t.oflag & ~@as(u32, TABDLY)) | (if (reversed) @as(u32, TAB3) else 0);
    } else if (eql(u8, name, "lcase") or eql(u8, name, "LCASE")) {
        if (reversed) {
            t.lflag &= ~@as(u32, XCASE);
            t.iflag &= ~@as(u32, IUCLC);
            t.oflag &= ~@as(u32, OLCUC);
        } else {
            t.lflag |= XCASE;
            t.iflag |= IUCLC;
            t.oflag |= OLCUC;
        }
    } else if (eql(u8, name, "crt")) {
        t.lflag |= ECHOE | ECHOCTL | ECHOKE;
    } else if (eql(u8, name, "dec")) {
        t.lflag |= ECHOE | ECHOCTL | ECHOKE;
        t.iflag &= ~@as(u32, IXANY);
        setCc(t, VINTR, 0x03);
        setCc(t, VERASE, 0x7f);
        setCc(t, VKILL, 0x15);
    }
}

fn sane(t: *Termios) void {
    for (control_chars) |c| t.cc[c.index] = c.default;
    t.cc[VMIN] = 1;
    t.cc[VTIME] = 0;
    for (modes) |m| {
        if (m.kind == .combination or m.sane == .none) continue;
        applyMode(t, m, m.sane == .unset);
    }
}

// ---------------------------------------------------------------------------
// Output.

/// Column-tracking writer: items are separated by a space and a line is broken
/// before an item that would not fit within `max_col` columns.
pub const Wrap = struct {
    w: *Io.Writer,
    max_col: usize,
    col: usize = 0,

    pub fn item(self: *Wrap, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        return self.itemMargin(0, fmt, args);
    }

    /// Like `item`, requiring `margin` spare columns beyond the usual fit.
    pub fn itemMargin(self: *Wrap, margin: usize, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        try self.textMargin(margin, s);
    }

    pub fn text(self: *Wrap, s: []const u8) Io.Writer.Error!void {
        return self.textMargin(0, s);
    }

    pub fn textMargin(self: *Wrap, margin: usize, s: []const u8) Io.Writer.Error!void {
        if (self.col > 0) {
            if (self.max_col -| self.col < s.len + 1 + margin) {
                try self.w.writeByte('\n');
                self.col = 0;
            } else {
                try self.w.writeByte(' ');
                self.col += 1;
            }
        }
        try self.w.writeAll(s);
        self.col += s.len;
    }

    pub fn endLine(self: *Wrap) Io.Writer.Error!void {
        if (self.col > 0) try self.w.writeByte('\n');
        self.col = 0;
    }
};

fn writeSpeed(wrap: *Wrap, t: Termios) Io.Writer.Error!void {
    const i = inputSpeed(t);
    const o = outputSpeed(t);
    if (i == o) {
        try wrap.item("speed {d} baud;", .{o});
    } else {
        try wrap.item("ispeed {d} baud; ospeed {d} baud;", .{ i, o });
    }
}

fn charItem(wrap: *Wrap, name: []const u8, c: u8) Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    var f: Io.Writer = .fixed(&buf);
    f.print("{s} = ", .{name}) catch unreachable;
    writeChar(&f, c) catch unreachable;
    f.writeByte(';') catch unreachable;
    try wrap.text(f.buffered());
}

/// `stty -a`: everything, in human-readable form. `ws` adds the rows and
/// columns to the first line when known.
pub fn writeAll(w: *Io.Writer, t: Termios, ws: ?WinSize, max_col: usize) Io.Writer.Error!void {
    var wrap: Wrap = .{ .w = w, .max_col = max_col };
    try writeSpeed(&wrap, t);
    if (ws) |s| {
        try wrap.item("rows {d}; columns {d};", .{ s.rows, s.cols });
    }
    try wrap.item("line = {d};", .{t.line});
    try wrap.endLine();
    for (control_chars) |c| try charItem(&wrap, c.name, t.cc[c.index]);
    try wrap.item("min = {d}; time = {d};", .{ t.cc[VMIN], t.cc[VTIME] });
    try wrap.endLine();
    var prev: ?Kind = null;
    for (modes) |m| {
        if (m.kind == .combination or m.omit) continue;
        if (prev != null and prev.? != m.kind) try wrap.endLine();
        prev = m.kind;
        const on = active(t, m);
        if (m.mask != 0) {
            if (on) try wrap.text(m.name);
        } else if (on) {
            try wrap.text(m.name);
        } else {
            var buf: [32]u8 = undefined;
            try wrap.text(std.fmt.bufPrint(&buf, "-{s}", .{m.name}) catch m.name);
        }
    }
    try wrap.endLine();
}

/// Plain `stty`: the speed, the line discipline and whatever differs from
/// `stty sane`.
pub fn writeChanged(w: *Io.Writer, t: Termios, max_col: usize) Io.Writer.Error!void {
    var wrap: Wrap = .{ .w = w, .max_col = max_col };
    try writeSpeed(&wrap, t);
    try wrap.item("line = {d};", .{t.line});
    try wrap.endLine();
    for (control_chars) |c| {
        if (t.cc[c.index] != c.default) try charItem(&wrap, c.name, t.cc[c.index]);
    }
    if (t.lflag & ICANON == 0) {
        // GNU wraps this item one column early in this display (measured with
        // COLUMNS from 20 to 120); in -a it fits like any other item.
        try wrap.itemMargin(1, "min = {d}; time = {d};", .{ t.cc[VMIN], t.cc[VTIME] });
    }
    try wrap.endLine();
    var prev: ?Kind = null;
    for (modes) |m| {
        if (m.kind == .combination or m.omit or m.sane == .none) continue;
        const on = active(t, m);
        var shown = false;
        var buf: [32]u8 = undefined;
        var label: []const u8 = m.name;
        switch (m.sane) {
            .set => if (!on and m.rev) {
                shown = true;
                label = std.fmt.bufPrint(&buf, "-{s}", .{m.name}) catch m.name;
            },
            .unset => if (on) {
                shown = true;
            },
            .none => {},
        }
        if (!shown) continue;
        if (prev != null and prev.? != m.kind) try wrap.endLine();
        prev = m.kind;
        try wrap.text(label);
    }
    try wrap.endLine();
}

/// `stty -g`: `iflag:oflag:cflag:lflag:cc0:...:cc31` in hexadecimal.
pub fn writeSave(w: *Io.Writer, t: Termios) Io.Writer.Error!void {
    try w.print("{x}:{x}:{x}:{x}", .{ t.iflag, t.oflag, t.cflag, t.lflag });
    var i: usize = 0;
    while (i < user_nccs) : (i += 1) {
        try w.print(":{x}", .{if (i < nccs) t.cc[i] else 0});
    }
    try w.writeByte('\n');
}

/// Read the form `writeSave` prints into `base` (keeping its line discipline).
/// Null when `text` is not in that form.
pub fn parseSave(base: Termios, text: []const u8) ?Termios {
    var t = base;
    var it = std.mem.splitScalar(u8, text, ':');
    const flags = [_]*u32{ &t.iflag, &t.oflag, &t.cflag, &t.lflag };
    for (flags) |f| f.* = std.fmt.parseInt(u32, it.next() orelse return null, 16) catch return null;
    var i: usize = 0;
    while (i < user_nccs) : (i += 1) {
        const v = std.fmt.parseInt(u32, it.next() orelse return null, 16) catch return null;
        if (v > 255) return null;
        if (i < nccs) t.cc[i] = @intCast(v);
    }
    if (it.next() != null) return null;
    return t;
}

pub fn looksLikeSave(text: []const u8) bool {
    return std.mem.count(u8, text, ":") == 4 + user_nccs - 1 and parseSave(.{}, text) != null;
}

/// Are all the settings in `want` present in `got`? Used after setting: the
/// kernel may quietly ignore some (a pseudo-terminal keeps 8 data bits and no
/// parity).
pub fn sameSettings(want: Termios, got: Termios) bool {
    return want.iflag == got.iflag and want.oflag == got.oflag and want.lflag == got.lflag and
        want.cflag == got.cflag and want.line == got.line and std.mem.eql(u8, &want.cc, &got.cc);
}

pub const min_index = VMIN;
pub const time_index = VTIME;

// ---------------------------------------------------------------------------
// Tests.

fn sampleTermios() Termios {
    var t: Termios = .{};
    sane(&t);
    t.cflag |= CS8;
    t.oflag |= OPOST;
    t.iflag |= IXON;
    t.cflag |= 0o17; // 38400
    setSpeed(&t, 0o17);
    return t;
}

test "parse special characters" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 3), try parseControlChar("^C"));
    try t.expectEqual(@as(u8, 3), try parseControlChar("^c"));
    try t.expectEqual(@as(u8, 0x7f), try parseControlChar("^?"));
    try t.expectEqual(@as(u8, 0), try parseControlChar("^-"));
    try t.expectEqual(@as(u8, 0), try parseControlChar("undef"));
    try t.expectEqual(@as(u8, 'x'), try parseControlChar("x"));
    try t.expectEqual(@as(u8, 0x41), try parseControlChar("0x41"));
    try t.expectEqual(@as(u8, 65), try parseControlChar("0101"));
    try t.expectEqual(@as(u8, 101), try parseControlChar("101"));
    try t.expectError(error.InvalidInteger, parseControlChar("abc"));
    try t.expectError(error.OutOfRange, parseControlChar("300"));
}

test "characters are shown in hat notation" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeChar(&w, 3);
    try w.writeByte(' ');
    try writeChar(&w, 0x7f);
    try w.writeByte(' ');
    try writeChar(&w, 0);
    try w.writeByte(' ');
    try writeChar(&w, 0x80);
    try w.writeByte(' ');
    try writeChar(&w, 'a');
    try std.testing.expectEqualStrings("^C ^? <undef> M-^@ a", w.buffered());
}

test "the save form round-trips and a sane terminal prints no changes" {
    const t = std.testing;
    const term = sampleTermios();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeSave(&w, term);
    const text = std.mem.trimEnd(u8, w.buffered(), "\n");
    try t.expect(looksLikeSave(text));
    try t.expect(sameSettings(term, parseSave(.{}, text).?));
    try t.expect(!looksLikeSave("1:2:3"));

    var out: [256]u8 = undefined;
    var ow: Io.Writer = .fixed(&out);
    try writeChanged(&ow, term, 80);
    try t.expectEqualStrings("speed 38400 baud; line = 0;\n", ow.buffered());
}

test "combination settings" {
    const t = std.testing;
    var term = sampleTermios();
    applyMode(&term, findMode("raw").?.*, false);
    try t.expect(term.lflag & ICANON == 0);
    try t.expectEqual(@as(u8, 1), term.cc[VMIN]);
    applyMode(&term, findMode("raw").?.*, true); // -raw is cooked
    try t.expect(term.lflag & ICANON != 0);
    applyMode(&term, findMode("evenp").?.*, false);
    try t.expectEqual(@as(u32, PARENB | CS7), term.cflag & (PARENB | CSIZE | PARODD));
    applyMode(&term, findMode("cr2").?.*, false);
    try t.expectEqual(@as(u32, CR2), term.oflag & CRDLY);
}

test "wrapping breaks before an item that does not fit" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var wrap: Wrap = .{ .w = &w, .max_col = 10 };
    try wrap.text("aaaa");
    try wrap.text("bbbb");
    try wrap.text("cc");
    try wrap.endLine();
    try std.testing.expectEqualStrings("aaaa bbbb\ncc\n", w.buffered());
}
