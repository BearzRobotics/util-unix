// SPDX-License-Identifier: GPL-2.0-or-later
//! Line editor for interactive shells: an emacs-style mode and the vi mode of
//! POSIX.1-2024 sh "Command Line Editing (vi-mode)".
//!
//! The module touches nothing outside its arguments: all terminal I/O goes
//! through a `Terminal` (a context pointer and three functions), history is a
//! slice handed in by the caller and completion is a callback, so it runs the
//! same in a test with a memory terminal as on a real tty. Host programs
//! (the shell, DKDE) reuse it as is.
//!
//! Typical use:
//!
//!     var ed = Editor.init(gpa, term);          // once
//!     ed.mode = .emacs;                         // or .vi
//!     const r = try ed.readLine(prompt, history_lines);
//!
//! Tests feed bytes with `begin` + `feed` and read `text()`, `cursor()` and
//! the terminal output.
//!
//! Terminal model: a VT100/xterm compatible terminal. Output is full-line
//! redraws (carriage return, erase below, text, cursor placement) so wrapped
//! and multi-line buffers work and nothing depends on terminal-specific
//! capabilities other than ESC [ A/C/J. Width of characters is computed from
//! UTF-8 (combining marks zero, East Asian wide two columns).

const std = @import("std");
const completion = @import("completion.zig");
const widths = @import("width_table.zig");
const Allocator = std.mem.Allocator;
const pattern = @import("pattern.zig");

/// How far `.` and `@` may nest.
pub const max_vi_depth = 16;

/// The character at byte `i`. History lines and file names are raw bytes: one
/// that does not start a whole, valid UTF-8 character counts as a character of
/// its own, drawn as U+FFFD.
const Char = struct { len: usize, cp: u21, valid: bool };

fn charAt(s: []const u8, i: usize) Char {
    const bad: Char = .{ .len = 1, .cp = 0xfffd, .valid = false };
    const n: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch return bad;
    if (n > s.len - i) return bad;
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return bad;
    return .{ .len = n, .cp = cp, .valid = true };
}

/// How a control character is shown, in two columns; null for any other. A
/// file name or a history line may hold one, and written as it is it would
/// command the terminal. C0 and DEL are "^X"; C1 (U+0080 to U+009F), which a
/// terminal obeys too, are "~X".
fn controlPicture(cp: u21) ?[2]u8 {
    if (cp < 32) return .{ '^', @intCast(cp + '@') };
    if (cp == 0x7f) return .{ '^', '?' };
    if (cp >= 0x80 and cp < 0xa0) return .{ '~', @intCast(cp - 0x80 + '@') };
    return null;
}

/// `s` as it may be written to a terminal: control characters made visible,
/// bytes that are not UTF-8 replaced.
fn showable(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const ch = charAt(s, i);
        if (controlPicture(ch.cp)) |picture| {
            try out.appendSlice(a, &picture);
        } else try out.appendSlice(a, if (ch.valid) s[i..][0..ch.len] else "\u{fffd}");
        i += ch.len;
    }
    return out.items;
}

test "control characters are shown, not sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try showable(arena.allocator(), "a\x1b]0;t\x07\u{9b}2J\x7f\n\xc3\xa9\xff");
    try std.testing.expectEqualStrings("a^[]0;t^G~[2J^?^J\xc3\xa9\u{fffd}", got);
}

// --- terminal abstraction ---------------------------------------------------------

pub const ReadResult = union(enum) {
    /// This many bytes were stored in the buffer.
    bytes: usize,
    eof,
    /// A signal abandons the line, as ^C does.
    abort,
    /// Something else wrote to the terminal: the line is drawn anew below it.
    wrote,
    timeout,
    /// A signal arrived (for example SIGWINCH); the editor re-reads the size
    /// and redraws.
    interrupted,
};

pub const Size = struct { cols: u16 = 80, rows: u16 = 24 };

pub const Terminal = struct {
    ctx: ?*anyopaque = null,
    /// Read bytes; `timeout_ms` < 0 blocks.
    read: *const fn (ctx: ?*anyopaque, buf: []u8, timeout_ms: i32) ReadResult,
    write: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
    size: *const fn (ctx: ?*anyopaque) Size,
    /// Enter (true) or leave (false) raw mode; may be a no-op.
    setRaw: *const fn (ctx: ?*anyopaque, on: bool) void,
};

pub const Mode = enum { emacs, vi };

pub const Completion = struct {
    /// Byte offset where the word being completed starts.
    start: usize = 0,
    /// Full replacements for the word, owned by the arena the callback was
    /// given. A directory ends in "/".
    candidates: []const []const u8 = &.{},
};

pub const CompleteFn = *const fn (ctx: ?*anyopaque, a: Allocator, line: []const u8, cursor: usize) Allocator.Error!Completion;
pub const AliasFn = *const fn (ctx: ?*anyopaque, letter: u8) ?[]const u8;

pub const Result = union(enum) {
    /// A complete line including its newline.
    line: []const u8,
    eof,
    /// Interrupted with the interrupt character: the line is abandoned.
    interrupted,
    /// vi `v`: the caller should edit this text with an external editor and
    /// run the result.
    external_edit: []const u8,
};

pub const Status = enum { more, accepted, eof, interrupted, external_edit };

// --- keys ---------------------------------------------------------------------------

pub const KeyKind = enum { char, up, down, left, right, home, end, delete, insert, page_up, page_down, ctrl_left, ctrl_right, paste_begin, paste_end, none };

pub const Key = struct {
    kind: KeyKind = .char,
    cp: u21 = 0,
    alt: bool = false,
};

const Parser = struct {
    state: enum { normal, esc, csi, ss3, utf8 } = .normal,
    params: [3]u32 = .{ 0, 0, 0 },
    nparams: usize = 0,
    have_digit: bool = false,
    utf: [4]u8 = undefined,
    utf_len: u3 = 0,
    utf_need: u3 = 0,
    /// Bytes just found not to be UTF-8, to go into the line as they are,
    /// before the key `push` returned.
    broken: [4]u8 = undefined,
    broken_len: u3 = 0,

    fn pendingEsc(self: *const Parser) bool {
        return self.state == .esc;
    }

    fn flushEsc(self: *Parser) ?Key {
        if (self.state != .esc) return null;
        self.state = .normal;
        return .{ .cp = 27 };
    }

    fn csiFinal(self: *Parser, f: u8) Key {
        self.state = .normal;
        const p0 = self.params[0];
        const mod = if (self.nparams >= 2) self.params[1] else 0;
        const ctrl = mod == 5;
        return switch (f) {
            'A' => .{ .kind = .up },
            'B' => .{ .kind = .down },
            'C' => .{ .kind = if (ctrl) .ctrl_right else .right, .alt = mod == 3 },
            'D' => .{ .kind = if (ctrl) .ctrl_left else .left, .alt = mod == 3 },
            'H' => .{ .kind = .home },
            'F' => .{ .kind = .end },
            '~' => switch (p0) {
                1, 7 => .{ .kind = .home },
                2 => .{ .kind = .insert },
                3 => .{ .kind = .delete },
                4, 8 => .{ .kind = .end },
                5 => .{ .kind = .page_up },
                6 => .{ .kind = .page_down },
                200 => .{ .kind = .paste_begin },
                201 => .{ .kind = .paste_end },
                else => .{ .kind = .none },
            },
            else => .{ .kind = .none },
        };
    }

    /// Feed one byte; returns a key when one is complete.
    pub fn push(self: *Parser, b: u8) ?Key {
        switch (self.state) {
            .normal => {
                if (b == 0x1b) {
                    self.state = .esc;
                    return null;
                }
                if (b < 0x80) return .{ .cp = b };
                if (b >= 0xc0) {
                    self.utf[0] = b;
                    self.utf_len = 1;
                    self.utf_need = if (b >= 0xf0) 4 else if (b >= 0xe0) 3 else 2;
                    self.state = .utf8;
                    return null;
                }
                self.broken[0] = b;
                self.broken_len = 1;
                return null;
            },
            .utf8 => {
                if (b & 0xc0 != 0x80) {
                    self.state = .normal;
                    @memcpy(self.broken[0..self.utf_len], self.utf[0..self.utf_len]);
                    self.broken_len = self.utf_len;
                    return self.push(b);
                }
                self.utf[self.utf_len] = b;
                self.utf_len += 1;
                if (self.utf_len < self.utf_need) return null;
                self.state = .normal;
                const cp = std.unicode.utf8Decode(self.utf[0..self.utf_len]) catch {
                    @memcpy(self.broken[0..self.utf_len], self.utf[0..self.utf_len]);
                    self.broken_len = self.utf_len;
                    return null;
                };
                return .{ .cp = cp };
            },
            .esc => {
                switch (b) {
                    '[' => {
                        self.state = .csi;
                        self.params = .{ 0, 0, 0 };
                        self.nparams = 0;
                        self.have_digit = false;
                        return null;
                    },
                    'O' => {
                        self.state = .ss3;
                        return null;
                    },
                    0x1b => return .{ .cp = 27 },
                    else => {
                        self.state = .normal;
                        if (b >= 0xc0) {
                            // alt + multibyte: keep simple, drop the alt
                            return self.push(b);
                        }
                        return .{ .cp = b, .alt = true };
                    },
                }
            },
            .ss3 => return self.csiFinal(b),
            .csi => {
                if (b >= '0' and b <= '9') {
                    if (self.nparams == 0) self.nparams = 1;
                    if (self.nparams <= 3) self.params[self.nparams - 1] = self.params[self.nparams - 1] *| 10 +| (b - '0');
                    self.have_digit = true;
                    return null;
                }
                if (b == ';') {
                    if (self.nparams == 0) self.nparams = 1;
                    if (self.nparams < 3) self.nparams += 1;
                    return null;
                }
                if (b >= 0x40 and b <= 0x7e) return self.csiFinal(b);
                if (b >= 0x20 and b <= 0x3f) return null; // intermediate/private
                self.state = .normal;
                return .{ .kind = .none };
            },
        }
    }
};

// --- character classes and width ----------------------------------------------------

fn inRanges(ranges: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) hi = mid else if (cp > ranges[mid][1]) lo = mid + 1 else return true;
    }
    return false;
}

pub fn cpWidth(cp: u21) u2 {
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7f and cp < 0xa0)) return 2; // shown as ^X
    if (cp < 0x300) return 1;
    if (inRanges(&widths.zero_width, cp)) return 0;
    if (inRanges(&widths.wide, cp)) return 2;
    return 1;
}

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

pub fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Display width of text, skipping escape sequences and the \x01 \x02 markers
/// (zero-width) the way a prompt may use them.
pub fn textWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 1 or c == 2) {
            i += 1;
            continue;
        }
        if (c == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
            i += 1;
            continue;
        }
        if (c == '\n') {
            w = 0;
            i += 1;
            continue;
        }
        const ch = charAt(s, i);
        w += cpWidth(ch.cp);
        i += ch.len;
    }
    return w;
}

// --- the editor ---------------------------------------------------------------------

const Snapshot = struct { text: []u8, cursor: usize };

pub const ViPending = enum { none, d, c, y, f, F, t, T, r, @"@" };

/// The largest repeat count a key can be given. Repeating a command that many
/// times is already more than any line needs; without a limit a few more
/// digits overflow or hang the editor.
pub const max_count = 99_999;

/// The lower limit where each repeat makes the line longer: drawing the line
/// costs more the longer it is.
pub const max_copies = 4096;

/// The repeat count `cur` with another digit typed after it.
pub fn addDigit(cur: ?usize, digit: usize) usize {
    return @min((cur orelse 0) * 10 + digit, max_count);
}

pub const Editor = struct {
    gpa: Allocator,
    term: Terminal,
    mode: Mode = .emacs,
    complete_fn: ?CompleteFn = null,
    alias_fn: ?AliasFn = null,
    cb_ctx: ?*anyopaque = null,
    /// Emit bracketed-paste enable/disable around `readLine`.
    bracketed_paste: bool = true,
    /// Erase / kill / EOF characters of the tty (defaults: DEL, ^U, ^D).
    erase_char: u8 = 0x7f,
    kill_char: u8 = 0x15,
    eof_char: u8 = 0x04,
    /// The number of history entry 0 (for vi `G`).
    history_first: u64 = 1,

    buf: std.ArrayList(u8) = .empty,
    cur: usize = 0,
    prompt: []const u8 = "",
    history: []const []u8 = &.{},
    hist_pos: usize = 0,
    saved_line: std.ArrayList(u8) = .empty,
    parser: Parser = .{},
    cols: u16 = 80,
    // rendering state: the row of the cursor relative to the first prompt row
    cur_row: usize = 0,
    rendered: bool = false,
    out: std.ArrayList(u8) = .empty,
    // kill ring, undo
    kills: std.ArrayList([]u8) = .empty,
    last_was_kill: bool = false,
    last_was_yank: bool = false,
    yank_len: usize = 0,
    yank_idx: usize = 0,
    undo: std.ArrayList(Snapshot) = .empty,
    last_was_insert: bool = false,
    // modes
    in_paste: bool = false,
    quoted_next: bool = false,
    // incremental search
    searching: bool = false,
    search_fwd: bool = false,
    search_buf: std.ArrayList(u8) = .empty,
    search_saved: std.ArrayList(u8) = .empty,
    search_saved_cur: usize = 0,
    search_match: ?usize = null,
    // emacs numeric argument (M-digits)
    arg: ?usize = null,
    // vi state
    vi_insert: bool = true,
    vi_replace: bool = false,
    vi_count: ?usize = null,
    vi_pend: ViPending = .none,
    vi_op_count: ?usize = null,
    vi_reg: std.ArrayList(u8) = .empty,
    vi_find: ?struct { kind: u8, ch: u21 } = null,
    vi_search: ?struct { pat: []u8, fwd: bool } = null,
    vi_search_mode: bool = false,
    vi_search_fwd: bool = false,
    vi_orig: std.ArrayList(u8) = .empty,
    vi_start: std.ArrayList(u8) = .empty,
    vi_op_find: u8 = 0,
    vi_op_pending: ViPending = .none,
    vi_changed_ever: bool = false,
    vi_rec: std.ArrayList(Key) = .empty,
    vi_last: std.ArrayList(Key) = .empty,
    vi_last_count: ?usize = null,
    vi_changed: bool = false,
    vi_replaying: bool = false,
    /// How deep `.` and `@` are inside one another.
    vi_depth: u8 = 0,
    vi_undo_text: std.ArrayList(u8) = .empty,
    vi_undo_cur: usize = 0,
    result_line: std.ArrayList(u8) = .empty,
    last_line_words: ?[]const u8 = null,
    // completion list state (second TAB)
    comp_pending: bool = false,
    show_ctrl_c: bool = false,
    status: Status = .more,

    pub fn init(gpa: Allocator, term: Terminal) Editor {
        return .{ .gpa = gpa, .term = term };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.gpa);
        self.saved_line.deinit(self.gpa);
        self.out.deinit(self.gpa);
        for (self.kills.items) |k| self.gpa.free(k);
        self.kills.deinit(self.gpa);
        for (self.undo.items) |u| self.gpa.free(u.text);
        self.undo.deinit(self.gpa);
        self.search_buf.deinit(self.gpa);
        self.search_saved.deinit(self.gpa);
        self.vi_reg.deinit(self.gpa);
        if (self.vi_search) |s| self.gpa.free(s.pat);
        self.vi_orig.deinit(self.gpa);
        self.vi_start.deinit(self.gpa);
        self.vi_rec.deinit(self.gpa);
        self.vi_last.deinit(self.gpa);
        self.vi_undo_text.deinit(self.gpa);
        self.result_line.deinit(self.gpa);
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn cursor(self: *const Editor) usize {
        return self.cur;
    }

    pub fn viInsertMode(self: *const Editor) bool {
        return self.vi_insert;
    }

    // --- driving ---------------------------------------------------------------------

    /// Start editing a line: reset state, draw the prompt.
    pub fn begin(self: *Editor, prompt: []const u8, history: []const []u8) void {
        self.buf.clearRetainingCapacity();
        self.cur = 0;
        self.prompt = prompt;
        self.history = history;
        self.hist_pos = history.len;
        self.saved_line.clearRetainingCapacity();
        self.parser = .{};
        self.cur_row = 0;
        self.rendered = false;
        self.last_was_kill = false;
        self.last_was_yank = false;
        self.last_was_insert = false;
        for (self.undo.items) |u| self.gpa.free(u.text);
        self.undo.clearRetainingCapacity();
        self.in_paste = false;
        self.quoted_next = false;
        self.searching = false;
        self.arg = null;
        self.vi_insert = true;
        self.vi_replace = false;
        self.vi_count = null;
        self.vi_pend = .none;
        self.vi_search_mode = false;
        self.vi_orig.clearRetainingCapacity();
        self.vi_start.clearRetainingCapacity();
        self.vi_op_pending = .none;
        self.vi_changed_ever = false;
        self.vi_rec.clearRetainingCapacity();
        self.vi_changed = false;
        self.vi_undo_text.clearRetainingCapacity();
        self.comp_pending = false;
        self.status = .more;
        self.cols = @max(self.term.size(self.term.ctx).cols, 4);
        self.redraw();
    }

    /// Feed input bytes; returns the status after the last byte (stops at
    /// the first byte that finishes the line).
    pub fn feed(self: *Editor, bytes: []const u8) Status {
        for (bytes) |b| {
            const pushed = self.parser.push(b);
            if (self.parser.broken_len > 0) {
                self.insertRaw(self.parser.broken[0..self.parser.broken_len]);
                self.parser.broken_len = 0;
            }
            if (pushed) |k| {
                self.key(k);
                if (self.status != .more) return self.status;
            }
        }
        return self.status;
    }

    /// The escape timeout elapsed: a lone ESC was meant.
    pub fn feedTimeout(self: *Editor) Status {
        if (self.parser.flushEsc()) |k| self.key(k);
        return self.status;
    }

    pub fn resize(self: *Editor, cols: u16) void {
        self.cols = @max(cols, 4);
        self.redraw();
    }

    /// Edit one line from the terminal. The returned slice is valid until the
    /// next call.
    pub fn readLine(self: *Editor, prompt: []const u8, history: []const []u8) Allocator.Error!Result {
        self.term.setRaw(self.term.ctx, true);
        defer self.term.setRaw(self.term.ctx, false);
        if (self.bracketed_paste) self.term.write(self.term.ctx, "\x1b[?2004h");
        defer if (self.bracketed_paste) self.term.write(self.term.ctx, "\x1b[?2004l");
        self.begin(prompt, history);
        // One byte at a time: whatever follows the line stays in the
        // terminal's queue, for the next line or for the command that reads it.
        var chunk: [1]u8 = undefined;
        while (true) {
            const r = self.term.read(self.term.ctx, &chunk, if (self.parser.pendingEsc()) 40 else -1);
            switch (r) {
                .bytes => |n| _ = self.feed(chunk[0..n]),
                .eof => {
                    self.status = .eof;
                },
                .timeout => _ = self.feedTimeout(),
                .abort => self.status = .interrupted,
                .wrote => {
                    self.cols = @max(self.term.size(self.term.ctx).cols, 4);
                    self.redrawFresh();
                },
                .interrupted => {
                    self.cols = @max(self.term.size(self.term.ctx).cols, 4);
                    self.redraw();
                },
            }
            switch (self.status) {
                .more => {},
                .accepted => {
                    self.finishLine();
                    self.result_line.clearRetainingCapacity();
                    try self.result_line.appendSlice(self.gpa, self.buf.items);
                    try self.result_line.append(self.gpa, '\n');
                    return .{ .line = self.result_line.items };
                },
                .eof => {
                    self.finishLine();
                    return .eof;
                },
                .interrupted => {
                    self.show_ctrl_c = true;
                    self.finishLine();
                    return .interrupted;
                },
                .external_edit => {
                    self.finishLine();
                    self.result_line.clearRetainingCapacity();
                    try self.result_line.appendSlice(self.gpa, self.buf.items);
                    return .{ .external_edit = self.result_line.items };
                },
            }
        }
    }

    /// Move to the end of the line and start a fresh row.
    fn finishLine(self: *Editor) void {
        self.cur = self.buf.items.len;
        self.searching = false;
        self.redraw();
        if (self.show_ctrl_c) self.term.write(self.term.ctx, "^C");
        self.show_ctrl_c = false;
        self.term.write(self.term.ctx, "\r\n");
        self.rendered = false;
        self.cur_row = 0;
    }

    // --- rendering ---------------------------------------------------------------------

    const Pos = struct { row: usize, col: usize };

    fn advance(self: *const Editor, p: *Pos, cp: u21) void {
        if (cp == '\n') {
            p.row += 1;
            p.col = 0;
            return;
        }
        const w: usize = cpWidth(cp);
        if (w == 0) return;
        if (p.col + w > self.cols) {
            p.row += 1;
            p.col = 0;
        }
        p.col += w;
        if (p.col >= self.cols) {
            p.row += 1;
            p.col = 0;
        }
    }

    fn layoutPrompt(self: *const Editor, prompt: []const u8) Pos {
        var p: Pos = .{ .row = 0, .col = 0 };
        var i: usize = 0;
        while (i < prompt.len) {
            const c = prompt[i];
            if (c == 1 or c == 2) {
                i += 1;
                continue;
            }
            if (c == 0x1b and i + 1 < prompt.len and prompt[i + 1] == '[') {
                i += 2;
                while (i < prompt.len and !(prompt[i] >= 0x40 and prompt[i] <= 0x7e)) i += 1;
                i += 1;
                continue;
            }
            if (c == '\r') {
                p.col = 0;
                i += 1;
                continue;
            }
            const ch = charAt(prompt, i);
            self.advance(&p, ch.cp);
            i += ch.len;
        }
        return p;
    }

    /// Where byte offset `upto` of the buffer is, with the prompt before it.
    fn layout(self: *const Editor, prompt: []const u8, upto: usize) Pos {
        var p = self.layoutPrompt(prompt);
        const s = self.buf.items;
        var i: usize = 0;
        while (i < upto and i < s.len) {
            const ch = charAt(s, i);
            const cp = ch.cp;
            if (cp != '\n' and controlPicture(cp) != null) {
                self.advance(&p, 'x');
                self.advance(&p, 'x');
            } else self.advance(&p, cp);
            i += ch.len;
        }
        return p;
    }

    fn emitPrompt(self: *Editor, prompt: []const u8) void {
        for (prompt) |c| {
            if (c == 1 or c == 2) continue;
            if (c == '\n') {
                self.out.appendSlice(self.gpa, "\r\n") catch return;
            } else self.out.append(self.gpa, c) catch return;
        }
    }

    /// Write one cell, `width` columns wide, at `p`. A line break goes out just
    /// where `advance` counts one: before a cell that does not fit, and after
    /// one that ends at the margin, where the terminal would otherwise stay on
    /// the same row until something more is written.
    fn emitCell(self: *Editor, p: *Pos, bytes: []const u8, width: usize) void {
        if (width > 0 and p.col + width > self.cols) {
            self.out.appendSlice(self.gpa, "\r\n") catch return;
            p.row += 1;
            p.col = 0;
        }
        self.out.appendSlice(self.gpa, bytes) catch return;
        p.col += width;
        if (width > 0 and p.col >= self.cols) {
            self.out.appendSlice(self.gpa, "\r\n") catch return;
            p.row += 1;
            p.col = 0;
        }
    }

    fn emitBuffer(self: *Editor) void {
        const s = self.buf.items;
        const prompt = self.displayPrompt();
        var p = self.layoutPrompt(prompt);
        // a prompt that ends at the margin
        if (p.col == 0 and p.row > 0 and !std.mem.endsWith(u8, prompt, "\n") and !std.mem.endsWith(u8, prompt, "\r")) {
            self.out.appendSlice(self.gpa, "\r\n") catch return;
        }
        var i: usize = 0;
        while (i < s.len) {
            const ch = charAt(s, i);
            const cp = ch.cp;
            if (cp == '\n') {
                self.out.appendSlice(self.gpa, "\r\n") catch return;
                p.row += 1;
                p.col = 0;
            } else if (controlPicture(cp)) |vis| {
                self.emitCell(&p, vis[0..1], 1);
                self.emitCell(&p, vis[1..2], 1);
            } else {
                self.emitCell(&p, if (ch.valid) s[i..][0..ch.len] else "\u{fffd}", cpWidth(cp));
            }
            i += ch.len;
        }
    }

    fn displayPrompt(self: *const Editor) []const u8 {
        return self.prompt;
    }

    pub fn redraw(self: *Editor) void {
        self.out.clearRetainingCapacity();
        const o = &self.out;
        if (self.rendered and self.cur_row > 0) o.print(self.gpa, "\x1b[{d}A", .{self.cur_row}) catch return;
        o.appendSlice(self.gpa, "\r\x1b[J") catch return;
        self.emitPrompt(self.displayPrompt());
        self.emitBuffer();
        // Cursor is at the end of the text; move it to the cursor position.
        const end = self.layout(self.displayPrompt(), self.buf.items.len);
        const target = self.layout(self.displayPrompt(), self.cur);
        if (end.row > target.row) o.print(self.gpa, "\x1b[{d}A", .{end.row - target.row}) catch return;
        o.append(self.gpa, '\r') catch return;
        if (target.col > 0) o.print(self.gpa, "\x1b[{d}C", .{target.col}) catch return;
        self.cur_row = target.row;
        self.rendered = true;
        self.term.write(self.term.ctx, o.items);
    }

    /// Cheap path for typing at the end of the line.
    fn appendedAtEnd(self: *Editor, bytes: []const u8, cp: u21) bool {
        if (self.cur != self.buf.items.len or self.searching or self.vi_search_mode) return false;
        if (controlPicture(cp) != null) return false;
        const end = self.layout(self.displayPrompt(), self.buf.items.len);
        // `bytes` is already appended; the old end is the position before it.
        _ = end;
        const w: usize = cpWidth(cp);
        const before = self.layout(self.displayPrompt(), self.buf.items.len - bytes.len);
        if (before.col + w >= self.cols) return false;
        self.term.write(self.term.ctx, bytes);
        return true;
    }

    pub fn alert(self: *Editor) void {
        self.term.write(self.term.ctx, "\x07");
    }

    // --- buffer primitives ------------------------------------------------------------

    pub fn prevBoundary(self: *const Editor, pos: usize) usize {
        if (pos == 0) return 0;
        var p = pos - 1;
        while (p > 0 and pos - p < 4 and (self.buf.items[p] & 0xc0) == 0x80) p -= 1;
        // bytes that are not one character are stepped over singly, as
        // `nextBoundary` does
        return if (charAt(self.buf.items, p).len == pos - p) p else pos - 1;
    }

    pub fn nextBoundary(self: *const Editor, pos: usize) usize {
        if (pos >= self.buf.items.len) return self.buf.items.len;
        return pos + charAt(self.buf.items, pos).len;
    }

    pub fn pushUndo(self: *Editor) void {
        const copy = self.gpa.dupe(u8, self.buf.items) catch return;
        self.undo.append(self.gpa, .{ .text = copy, .cursor = self.cur }) catch {
            self.gpa.free(copy);
            return;
        };
        if (self.undo.items.len > 100) {
            self.gpa.free(self.undo.orderedRemove(0).text);
        }
    }

    pub fn setText(self: *Editor, s: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.gpa, s) catch {};
    }

    pub fn insertBytes(self: *Editor, bytes: []const u8) void {
        self.buf.insertSlice(self.gpa, self.cur, bytes) catch return;
        self.cur += bytes.len;
    }

    pub fn deleteRange(self: *Editor, from: usize, to: usize) void {
        if (to <= from) return;
        self.buf.replaceRange(self.gpa, from, to - from, "") catch return;
        if (self.cur > from) self.cur = if (self.cur >= to) self.cur - (to - from) else from;
    }

    pub fn killText(self: *Editor, s: []const u8, append: bool, prepend: bool) void {
        if (s.len == 0) return;
        if (self.last_was_kill and self.kills.items.len > 0 and (append or prepend)) {
            const last = &self.kills.items[self.kills.items.len - 1];
            const joined = if (prepend) std.mem.concat(self.gpa, u8, &.{ s, last.* }) else std.mem.concat(self.gpa, u8, &.{ last.*, s });
            if (joined) |j| {
                self.gpa.free(last.*);
                last.* = j;
                return;
            } else |_| {}
        }
        const copy = self.gpa.dupe(u8, s) catch return;
        self.kills.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return;
        };
        if (self.kills.items.len > 16) self.gpa.free(self.kills.orderedRemove(0));
        self.yank_idx = self.kills.items.len - 1;
    }

    // --- emacs mode ---------------------------------------------------------------------

    pub fn wordBack(self: *const Editor, from: usize) usize {
        var p = from;
        const s = self.buf.items;
        while (p > 0 and !isWordByte(s[p - 1])) p -= 1;
        while (p > 0 and isWordByte(s[p - 1])) p -= 1;
        return p;
    }

    pub fn wordFwd(self: *const Editor, from: usize) usize {
        var p = from;
        const s = self.buf.items;
        while (p < s.len and !isWordByte(s[p])) p += 1;
        while (p < s.len and isWordByte(s[p])) p += 1;
        return p;
    }

    pub fn historyLoad(self: *Editor, idx: usize) void {
        if (self.hist_pos == self.history.len and idx != self.history.len) {
            self.saved_line.clearRetainingCapacity();
            self.saved_line.appendSlice(self.gpa, self.buf.items) catch {};
        }
        self.hist_pos = idx;
        if (idx == self.history.len) {
            self.setText(self.saved_line.items);
        } else self.setText(self.history[idx]);
        self.cur = self.buf.items.len;
        self.vi_start.clearRetainingCapacity();
        self.vi_start.appendSlice(self.gpa, self.buf.items) catch {};
    }

    /// Input that is not UTF-8 (a Latin-1 file name, say) is part of the line
    /// as it came: dropped or replaced, it would name something else.
    fn insertRaw(self: *Editor, bytes: []const u8) void {
        if (self.mode == .vi and !self.vi_insert) {
            self.alert();
            return;
        }
        self.pushUndo();
        self.insertBytes(bytes);
        self.redraw();
    }

    pub fn insertCp(self: *Editor, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (!self.last_was_insert) self.pushUndo();
        if (self.vi_replace and self.cur < self.buf.items.len) {
            const e = self.nextBoundary(self.cur);
            self.buf.replaceRange(self.gpa, self.cur, e - self.cur, tmp[0..n]) catch return;
            self.cur += n;
            self.redraw();
            return;
        }
        self.insertBytes(tmp[0..n]);
        if (!self.appendedAtEnd(tmp[0..n], cp)) self.redraw();
    }

    pub fn insertBytesAt(self: *Editor, at: usize, bytes: []const u8) void {
        self.buf.insertSlice(self.gpa, at, bytes) catch return;
        if (self.cur >= at) self.cur += bytes.len;
    }

    pub fn undoOne(self: *Editor) void {
        const u = self.undo.pop() orelse {
            self.alert();
            return;
        };
        defer self.gpa.free(u.text);
        self.setText(u.text);
        self.cur = @min(u.cursor, self.buf.items.len);
    }

    pub fn historyMove(self: *Editor, delta: isize) void {
        const cur: isize = @intCast(self.hist_pos);
        var target = cur + delta;
        if (target < 0) {
            if (cur == 0) {
                self.alert();
                return;
            }
            target = 0;
        }
        const max: isize = @intCast(self.history.len);
        if (target > max) {
            if (cur == max) {
                self.alert();
                return;
            }
            target = max;
        }
        self.historyLoad(@intCast(target));
    }

    // --- incremental search (emacs) -----------------------------------------------------------

    pub fn startSearch(self: *Editor, fwd: bool) void {
        self.searching = true;
        self.search_fwd = fwd;
        self.search_buf.clearRetainingCapacity();
        self.search_saved.clearRetainingCapacity();
        self.search_saved.appendSlice(self.gpa, self.buf.items) catch {};
        self.search_saved_cur = self.cur;
        // the line being typed, for history movement to come back to
        if (self.hist_pos == self.history.len) {
            self.saved_line.clearRetainingCapacity();
            self.saved_line.appendSlice(self.gpa, self.buf.items) catch {};
        }
        self.search_match = null;
        self.drawSearch();
    }

    fn searchStep(self: *Editor, from_next: bool) void {
        const q = self.search_buf.items;
        if (q.len == 0) return;
        const hl: isize = @intCast(self.history.len);
        var i: isize = if (self.search_match) |m| @intCast(m) else if (self.search_fwd) 0 else hl - 1;
        if (self.search_match != null and from_next) i += if (self.search_fwd) 1 else -1;
        // Searching stays on the current entry when the query changed.
        while (i >= 0 and i < @as(isize, @intCast(self.history.len))) : (i += if (self.search_fwd) @as(isize, 1) else -1) {
            if (std.mem.indexOf(u8, self.history[@intCast(i)], q)) |pos| {
                self.search_match = @intCast(i);
                self.setText(self.history[@intCast(i)]);
                self.cur = pos;
                return;
            }
            if (!self.search_fwd and i == 0) break;
        }
        self.alert();
    }

    fn drawSearch(self: *Editor) void {
        const saved = self.prompt;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(self.gpa);
        tmp.print(self.gpa, "({s}search)`{s}': ", .{ if (self.search_fwd) "i-" else "reverse-i-", self.search_buf.items }) catch return;
        self.prompt = tmp.items;
        self.redraw();
        self.prompt = saved;
    }

    fn searchKey(self: *Editor, k: Key) void {
        if (k.kind == .char and !k.alt) {
            switch (k.cp) {
                18, 19 => {
                    self.search_fwd = k.cp == 19;
                    self.searchStep(true);
                    self.drawSearch();
                    return;
                },
                7 => { // C-g: abort
                    self.setText(self.search_saved.items);
                    self.cur = self.search_saved_cur;
                    self.searching = false;
                    self.redraw();
                    return;
                },
                8, 127 => {
                    if (self.search_buf.items.len > 0) {
                        var n = self.search_buf.items.len - 1;
                        while (n > 0 and (self.search_buf.items[n] & 0xc0) == 0x80) n -= 1;
                        self.search_buf.shrinkRetainingCapacity(n);
                    }
                    self.search_match = null;
                    self.searchStep(false);
                    self.drawSearch();
                    return;
                },
                else => if (k.cp >= 32) {
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(k.cp, &tmp) catch return;
                    self.search_buf.appendSlice(self.gpa, tmp[0..n]) catch return;
                    // Keep the current match if it still contains the query.
                    if (self.search_match) |m| {
                        if (std.mem.indexOf(u8, self.history[m], self.search_buf.items)) |pos| {
                            self.cur = pos;
                            self.drawSearch();
                            return;
                        }
                    }
                    self.searchStep(false);
                    self.drawSearch();
                    return;
                },
            }
        }
        // Any other key leaves the search with the match in the buffer.
        self.searching = false;
        if (self.search_match) |m| self.hist_pos = m;
        self.redraw();
        if (k.kind == .char and !k.alt and (k.cp == 10 or k.cp == 13)) {
            self.status = .accepted;
            return;
        }
        if (k.kind == .char and !k.alt and k.cp == 27) return;
        self.key(k);
    }

    // --- completion --------------------------------------------------------------------------

    pub fn commonPrefix(cands: []const []const u8) []const u8 {
        if (cands.len == 0) return "";
        var n = cands[0].len;
        for (cands[1..]) |c| {
            var i: usize = 0;
            while (i < n and i < c.len and c[i] == cands[0][i]) i += 1;
            n = i;
        }
        // do not cut a UTF-8 sequence
        while (n > 0 and n < cands[0].len and (cands[0][n] & 0xc0) == 0x80) n -= 1;
        // nor an escape, unless there is only the one candidate, which is whole
        if (cands.len > 1) n = completion.wholePrefix(cands[0][0..n]);
        return cands[0][0..n];
    }

    pub fn complete(self: *Editor) void {
        const f = self.complete_fn orelse {
            self.insertCp('\t');
            self.redraw();
            return;
        };
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const comp = f(self.cb_ctx, arena.allocator(), self.buf.items, self.cur) catch return;
        if (comp.candidates.len == 0) {
            self.alert();
            self.comp_pending = false;
            return;
        }
        const word = self.buf.items[comp.start..self.cur];
        const common = commonPrefix(comp.candidates);
        self.pushUndo();
        if (comp.candidates.len == 1) {
            const c = comp.candidates[0];
            self.buf.replaceRange(self.gpa, comp.start, self.cur - comp.start, c) catch return;
            self.cur = comp.start + c.len;
            if (c.len == 0 or c[c.len - 1] != '/') self.insertBytes(" ");
            self.comp_pending = false;
            return;
        }
        if (common.len > word.len) {
            self.buf.replaceRange(self.gpa, comp.start, self.cur - comp.start, common) catch return;
            self.cur = comp.start + common.len;
            self.comp_pending = true;
            return;
        }
        if (!self.comp_pending) {
            self.comp_pending = true;
            self.alert();
            return;
        }
        self.comp_pending = false;
        self.showCandidates(comp.candidates);
    }

    fn showCandidates(self: *Editor, names: []const []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const cands = arena.allocator().alloc([]const u8, names.len) catch return;
        for (cands, names) |*c, name| c.* = showable(arena.allocator(), name) catch return;
        // Finish the edit line, list in columns, redraw below.
        const at = self.cur;
        self.cur = self.buf.items.len;
        self.redraw();
        var o: std.ArrayList(u8) = .empty;
        defer o.deinit(self.gpa);
        o.appendSlice(self.gpa, "\r\n") catch return;
        var maxw: usize = 0;
        for (cands) |c| maxw = @max(maxw, textWidth(c));
        const colw = maxw + 2;
        const per = @max(@as(usize, self.cols) / colw, 1);
        for (cands, 0..) |c, i| {
            o.appendSlice(self.gpa, c) catch return;
            if ((i + 1) % per == 0 or i + 1 == cands.len) {
                o.appendSlice(self.gpa, "\r\n") catch return;
            } else {
                var pad = colw - textWidth(c);
                while (pad > 0) : (pad -= 1) o.append(self.gpa, ' ') catch return;
            }
        }
        self.term.write(self.term.ctx, o.items);
        self.cur = at;
        // back to the cursor position needs a redraw from the top of the line
        self.redrawFresh();
    }

    pub fn redrawFresh(self: *Editor) void {
        self.rendered = false;
        self.cur_row = 0;
        self.redraw();
    }

    pub fn listCompletions(self: *Editor) void {
        const f = self.complete_fn orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const comp = f(self.cb_ctx, arena.allocator(), self.buf.items, self.cur) catch return;
        if (comp.candidates.len == 0) {
            self.alert();
            return;
        }
        self.showCandidates(comp.candidates);
    }

    // --- key dispatch ---------------------------------------------------------------------------

    fn key(self: *Editor, k: Key) void {
        if (!(k.kind == .char and !k.alt and k.cp == 9)) self.comp_pending = false;
        if (self.in_paste) {
            if (k.kind == .paste_end) {
                self.in_paste = false;
                self.redraw();
                return;
            }
            if (k.kind == .char and !k.alt) {
                const cp: u21 = if (k.cp == 13) '\n' else k.cp;
                if (cp >= 32 or cp == '\n' or cp == '\t') {
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &tmp) catch return;
                    if (!self.last_was_insert) self.pushUndo();
                    self.last_was_insert = true;
                    self.insertBytes(tmp[0..n]);
                }
            }
            return;
        }
        if (k.kind == .paste_begin) {
            if (self.mode == .vi and !self.vi_insert) self.vi_insert = true;
            self.in_paste = true;
            return;
        }
        if (self.quoted_next) {
            self.quoted_next = false;
            if (k.kind == .char) {
                self.insertCp(k.cp);
                self.redraw();
            }
            return;
        }
        if (k.kind == .char and !k.alt) {
            // The interrupt character abandons the line whatever the editor is
            // in the middle of (raw mode: no signal comes from the terminal).
            if (k.cp == 3) {
                self.status = .interrupted;
                return;
            }
            if (self.mode == .vi and !self.vi_insert and k.cp == self.eof_char and self.buf.items.len == 0) {
                self.status = .eof;
                return;
            }
        }
        if (self.searching) {
            self.searchKey(k);
            return;
        }
        if (self.mode == .vi) {
            // ESC followed at once by a character is ESC then that character
            // (terminals cannot tell an Alt key from a fast typist).
            if (k.kind == .char and k.alt) {
                self.viKey(.{ .cp = 27 });
                if (self.status == .more) self.viKey(.{ .cp = k.cp });
                return;
            }
            self.viKey(k);
        } else self.emacsKey(k);
    }

    // --- the key handling of each mode (readline/) -------------------------------

    const viMoveTo = @import("readline/vi.zig").viMoveTo;
    pub const viClamp = @import("readline/vi.zig").viClamp;
    pub const lastCharPos = @import("readline/vi.zig").lastCharPos;
    const WordKind = @import("readline/vi.zig").WordKind;
    const classOf = @import("readline/vi.zig").classOf;
    pub const viNextWord = @import("readline/vi.zig").viNextWord;
    pub const viPrevWord = @import("readline/vi.zig").viPrevWord;
    pub const viEndWord = @import("readline/vi.zig").viEndWord;
    const Target = @import("readline/vi.zig").Target;
    pub const viMotion = @import("readline/vi.zig").viMotion;
    pub const viFind = @import("readline/vi.zig").viFind;
    pub const viFindRepeat = @import("readline/vi.zig").viFindRepeat;
    pub const viSaveUndo = @import("readline/vi.zig").viSaveUndo;
    pub const viDelete = @import("readline/vi.zig").viDelete;
    pub const viOperate = @import("readline/vi.zig").viOperate;
    pub const viKey = @import("readline/vi.zig").viKey;
    pub const viInsertKey = @import("readline/vi.zig").viInsertKey;
    pub const viSearchInput = @import("readline/vi.zig").viSearchInput;
    pub const viRunSearch = @import("readline/vi.zig").viRunSearch;
    pub const viCommandKey = @import("readline/vi.zig").viCommandKey;
    pub const viReplaceChars = @import("readline/vi.zig").viReplaceChars;
    pub const viHistory = @import("readline/vi.zig").viHistory;
    const viWordStart = @import("readline/vi.zig").viWordStart;
    pub const viCompleteUnique = @import("readline/vi.zig").viCompleteUnique;
    pub const viExpandAll = @import("readline/vi.zig").viExpandAll;
    const emacsKey = @import("readline/emacs.zig").emacsKey;
    pub const emacsMeta = @import("readline/emacs.zig").emacsMeta;
    pub const transpose = @import("readline/emacs.zig").transpose;
    pub const transposeWords = @import("readline/emacs.zig").transposeWords;
};

// --- tests: key sequences to buffer states, with a memory terminal --------------------

const MemTerm = struct {
    out: std.ArrayList(u8) = .empty,
    input: []const u8 = "",
    pos: usize = 0,
    cols: u16 = 80,

    fn term(self: *MemTerm) Terminal {
        return .{ .ctx = self, .read = rd, .write = wr, .size = sz, .setRaw = raw };
    }
    fn rd(ctx: ?*anyopaque, buf: []u8, _: i32) ReadResult {
        const t: *MemTerm = @ptrCast(@alignCast(ctx.?));
        if (t.pos >= t.input.len) return .eof;
        const n = @min(buf.len, t.input.len - t.pos);
        @memcpy(buf[0..n], t.input[t.pos .. t.pos + n]);
        t.pos += n;
        return .{ .bytes = n };
    }
    fn wr(ctx: ?*anyopaque, bytes: []const u8) void {
        const t: *MemTerm = @ptrCast(@alignCast(ctx.?));
        t.out.appendSlice(std.testing.allocator, bytes) catch {};
    }
    fn sz(ctx: ?*anyopaque) Size {
        const t: *MemTerm = @ptrCast(@alignCast(ctx.?));
        return .{ .cols = t.cols };
    }
    fn raw(_: ?*anyopaque, _: bool) void {}
};

const hist3 = [_][]u8{ @constCast("echo one"), @constCast("echo two"), @constCast("echo three") };

/// Run `keys` through an editor in `mode`; returns the buffer text and cursor.
fn drive(mode: Mode, keys: []const u8, hist: []const []u8, out_text: *[256]u8, out_len: *usize, cur: *usize) !Status {
    var mt: MemTerm = .{};
    defer mt.out.deinit(std.testing.allocator);
    var ed = Editor.init(std.testing.allocator, mt.term());
    defer ed.deinit();
    ed.mode = mode;
    ed.begin("$ ", hist);
    var st = ed.feed(keys);
    if (st == .more) st = ed.feedTimeout();
    out_len.* = ed.text().len;
    @memcpy(out_text[0..ed.text().len], ed.text());
    cur.* = ed.cursor();
    return st;
}

fn expectBuf(mode: Mode, keys: []const u8, hist: []const []u8, want: []const u8, want_cur: usize) !void {
    var t: [256]u8 = undefined;
    var n: usize = 0;
    var c: usize = 0;
    _ = try drive(mode, keys, hist, &t, &n, &c);
    try std.testing.expectEqualStrings(want, t[0..n]);
    try std.testing.expectEqual(want_cur, c);
}

test "vi: '.' can be repeated" {
    try expectBuf(.vi, "abcdef\x1bx.....", &.{}, "", 0);
    try expectBuf(.vi, "abcdef\x1b0x..2.", &.{}, "f", 0);
}

test "vi: an alias macro that runs itself stops" {
    var mt: MemTerm = .{};
    defer mt.out.deinit(std.testing.allocator);
    var ed = Editor.init(std.testing.allocator, mt.term());
    defer ed.deinit();
    ed.mode = .vi;
    ed.alias_fn = struct {
        fn get(_: ?*anyopaque, letter: u8) ?[]const u8 {
            return switch (letter) {
                'a' => "@a",
                'b' => "x.@b",
                else => null,
            };
        }
    }.get;
    ed.begin("$ ", &.{});
    try std.testing.expectEqual(Status.more, ed.feed("abcdef\x1b@a@b"));
}

test "emacs: M-t with no word before the first one does nothing" {
    for ([_][]const u8{ " a\x1bt", "  abc\x1bt", ";;x\x1bt", " \x1bt", "\x1bt" }) |keys| {
        var t: [256]u8 = undefined;
        var n: usize = 0;
        var c: usize = 0;
        _ = try drive(.emacs, keys, &.{}, &t, &n, &c);
        try std.testing.expectEqualStrings(keys[0 .. keys.len - 2], t[0..n]);
    }
}

test "a line with bytes that are not UTF-8 can be shown and edited" {
    // Latin-1, a lone continuation byte, truncated and overlong sequences
    for ([_][]const u8{ "caf\xe9", "\xe9x", "a\x80\x80\x80\x80\x80b", "\xf0\x9f", "\xc0\xafz", "ok\xff" }) |line| {
        var history = [_][]u8{@constCast(line)};
        // recall it, walk to the start and back over it, then delete all of it
        var keys: std.ArrayList(u8) = .empty;
        defer keys.deinit(std.testing.allocator);
        try keys.appendSlice(std.testing.allocator, "\x10\x01");
        for (0..line.len) |_| try keys.appendSlice(std.testing.allocator, "\x06");
        for (0..line.len) |_| try keys.appendSlice(std.testing.allocator, "\x02");
        try keys.appendSlice(std.testing.allocator, "\x05");
        for (0..line.len) |_| try keys.appendSlice(std.testing.allocator, "\x7f");
        try expectBuf(.emacs, keys.items, &history, "", 0);
        try expectBuf(.emacs, "\x10", &history, line, line.len);
    }
}

test "emacs: insertion and cursor movement" {
    try expectBuf(.emacs, "abc", &.{}, "abc", 3);
    try expectBuf(.emacs, "abc\x01", &.{}, "abc", 0);
    try expectBuf(.emacs, "abc\x01\x05", &.{}, "abc", 3);
    try expectBuf(.emacs, "abc\x02\x02", &.{}, "abc", 1);
    try expectBuf(.emacs, "abc\x1b[D\x1b[D\x1b[C", &.{}, "abc", 2);
    try expectBuf(.emacs, "ac\x02b", &.{}, "abc", 2);
}

test "emacs: deleting, killing and yanking" {
    try expectBuf(.emacs, "abc\x7f", &.{}, "ab", 2);
    try expectBuf(.emacs, "abc\x01\x04", &.{}, "bc", 0);
    try expectBuf(.emacs, "abc def\x17", &.{}, "abc ", 4);
    try expectBuf(.emacs, "abc def\x15", &.{}, "", 0);
    try expectBuf(.emacs, "abc def\x02\x02\x02\x0b", &.{}, "abc ", 4);
    try expectBuf(.emacs, "abc\x17\x19\x19", &.{}, "abcabc", 6);
    try expectBuf(.emacs, "ab\x14", &.{}, "ba", 2);
    try expectBuf(.emacs, "one two\x1bb\x1bd", &.{}, "one ", 4);
}

test "emacs: words and case" {
    try expectBuf(.emacs, "one two\x1bb", &.{}, "one two", 4);
    try expectBuf(.emacs, "one two\x1bb\x1bb\x1bf", &.{}, "one two", 3);
    try expectBuf(.emacs, "abc\x1bb\x1bu", &.{}, "ABC", 3);
    try expectBuf(.emacs, "one two\x1bt", &.{}, "two one", 7);
}

test "emacs: numeric argument and undo" {
    try expectBuf(.emacs, "\x1b3x", &.{}, "xxx", 3);
    try expectBuf(.emacs, "abc\x17\x1f", &.{}, "abc", 3);
}

test "emacs: utf-8 cursor and erase work on characters" {
    try expectBuf(.emacs, "h\xc3\xa9", &.{}, "h\xc3\xa9", 3);
    try expectBuf(.emacs, "h\xc3\xa9\x7f", &.{}, "h", 1);
    try expectBuf(.emacs, "h\xc3\xa9\x02", &.{}, "h\xc3\xa9", 1);
}

test "emacs: history" {
    try expectBuf(.emacs, "\x1b[A", &hist3, "echo three", 10);
    try expectBuf(.emacs, "\x1b[A\x1b[A", &hist3, "echo two", 8);
    try expectBuf(.emacs, "\x1b[A\x1b[A\x1b[B", &hist3, "echo three", 10);
    try expectBuf(.emacs, "x\x1b[A\x1b[B", &hist3, "x", 1);
    try expectBuf(.emacs, "\x1b<", &hist3, "echo one", 8);
    try expectBuf(.emacs, "\x1b<\x1b>", &hist3, "", 0);
}

test "emacs: incremental search" {
    try expectBuf(.emacs, "\x12two", &hist3, "echo two", 5);
    try expectBuf(.emacs, "\x12echo\x12", &hist3, "echo two", 0);
    try expectBuf(.emacs, "ab\x12one\x07", &hist3, "ab", 2);
}

test "emacs: accept, interrupt and end of file" {
    var t: [256]u8 = undefined;
    var n: usize = 0;
    var c: usize = 0;
    try std.testing.expectEqual(Status.accepted, try drive(.emacs, "ab\r", &.{}, &t, &n, &c));
    try std.testing.expectEqual(Status.interrupted, try drive(.emacs, "ab\x03", &.{}, &t, &n, &c));
    try std.testing.expectEqual(Status.eof, try drive(.emacs, "\x04", &.{}, &t, &n, &c));
    try std.testing.expectEqual(Status.more, try drive(.emacs, "ab\x04", &.{}, &t, &n, &c));
}

test "bracketed paste inserts newlines and tabs literally" {
    try expectBuf(.emacs, "\x1b[200~a\nb\tc\x1b[201~", &.{}, "a\nb\tc", 5);
}

test "vi: modes and basic edits" {
    try expectBuf(.vi, "abc\x1b", &.{}, "abc", 2);
    try expectBuf(.vi, "abc\x1bx", &.{}, "ab", 1);
    try expectBuf(.vi, "abc\x1b0x", &.{}, "bc", 0);
    try expectBuf(.vi, "abc\x1b0ix", &.{}, "xabc", 1);
    try expectBuf(.vi, "abc\x1b0ax", &.{}, "axbc", 2);
    try expectBuf(.vi, "abc\x1bAd", &.{}, "abcd", 4);
    try expectBuf(.vi, "abc\x1bIx", &.{}, "xabc", 1);
    try expectBuf(.vi, "abc\x1b0rx", &.{}, "xbc", 0);
    try expectBuf(.vi, "abc\x1b0~", &.{}, "Abc", 1);
    try expectBuf(.vi, "abc\x1b0Rxy", &.{}, "xyc", 2);
}

test "vi: motions and operators" {
    try expectBuf(.vi, "one two\x1b0w", &.{}, "one two", 4);
    try expectBuf(.vi, "one two\x1bb", &.{}, "one two", 4);
    try expectBuf(.vi, "one two\x1b0e", &.{}, "one two", 2);
    try expectBuf(.vi, "one two\x1b0dw", &.{}, "two", 0);
    try expectBuf(.vi, "one two\x1b0cwX", &.{}, "X two", 1);
    try expectBuf(.vi, "one two\x1bdd", &.{}, "", 0);
    try expectBuf(.vi, "abc def\x1b03lD", &.{}, "abc", 2);
    try expectBuf(.vi, "abcdef\x1b0fdx", &.{}, "abcef", 3);
    try expectBuf(.vi, "abcdef\x1b0tdx", &.{}, "abdef", 2);
    try expectBuf(.vi, "abcdef\x1b3|x", &.{}, "abdef", 2);
    try expectBuf(.vi, "abcdef\x1b03x", &.{}, "def", 0);
    try expectBuf(.vi, "abc\x1b0yl$p", &.{}, "abca", 3);
    try expectBuf(.vi, "abc\x1bxu", &.{}, "abc", 2);
    try expectBuf(.vi, "abcd\x1bx.", &.{}, "ab", 1);
}

test "vi: history" {
    try expectBuf(.vi, "\x1bk", &hist3, "echo three", 0);
    try expectBuf(.vi, "\x1bkk", &hist3, "echo two", 0);
    try expectBuf(.vi, "\x1bkkj", &hist3, "echo three", 0);
    try expectBuf(.vi, "\x1b2k", &hist3, "echo two", 0);
    try expectBuf(.vi, "\x1bG", &hist3, "echo one", 0);
    try expectBuf(.vi, "\x1b/two\r", &hist3, "echo two", 0);
    try expectBuf(.vi, "\x1b/^echo o\r", &hist3, "echo one", 0);
    try expectBuf(.vi, "echo\x1b_", &hist3, "echo three", 10);
}

test "render: redraws the prompt and the line, wraps at the width" {
    var mt: MemTerm = .{ .cols = 10 };
    defer mt.out.deinit(std.testing.allocator);
    var ed = Editor.init(std.testing.allocator, mt.term());
    defer ed.deinit();
    ed.begin("$ ", &.{});
    try std.testing.expect(std.mem.indexOf(u8, mt.out.items, "$ ") != null);
    _ = ed.feed("abcdefghij");
    // the line is 12 columns wide at a width of 10: two rows
    ed.redraw();
    try std.testing.expect(std.mem.indexOf(u8, mt.out.items, "\r\n") != null);
    try std.testing.expectEqual(@as(usize, 1), ed.cur_row);
}

test "width of text" {
    try std.testing.expectEqual(@as(usize, 3), textWidth("abc"));
    try std.testing.expectEqual(@as(usize, 4), textWidth("\xe4\xb8\xad\xe6\x96\x87"));
    try std.testing.expectEqual(@as(usize, 2), textWidth("\x1b[1m>\x1b[0m "));
    try std.testing.expectEqual(@as(usize, 1), textWidth("e\xcc\x81"));
}

test "tab completion through the callback" {
    const cb = struct {
        fn f(_: ?*anyopaque, a: Allocator, line: []const u8, cursor: usize) Allocator.Error!Completion {
            _ = line;
            const c = try a.alloc([]const u8, 1);
            c[0] = "alpha";
            return .{ .start = cursor - 2, .candidates = c };
        }
    }.f;
    var mt: MemTerm = .{};
    defer mt.out.deinit(std.testing.allocator);
    var ed = Editor.init(std.testing.allocator, mt.term());
    defer ed.deinit();
    ed.complete_fn = cb;
    ed.begin("$ ", &.{});
    _ = ed.feed("echo al\t");
    try std.testing.expectEqualStrings("echo alpha ", ed.text());
}

test "column widths follow Unicode" {
    for ([_]u21{ 'a', 0xe9, 0x905, 0xe01, 0x2713 }) |cp| try std.testing.expectEqual(@as(u2, 1), cpWidth(cp));
    for ([_]u21{ 0x4e2d, 0x1f680, 0x2705, 0x274c, 0x1fa70, 0x1f600, 0xff21 }) |cp| try std.testing.expectEqual(@as(u2, 2), cpWidth(cp));
    // combining marks (Latin, Devanagari, Thai), joiners and selectors
    for ([_]u21{ 0x301, 0x94d, 0xe34, 0x200d, 0xfe0f, 0x1160, 0xe0100 }) |cp| try std.testing.expectEqual(@as(u2, 0), cpWidth(cp));
}
