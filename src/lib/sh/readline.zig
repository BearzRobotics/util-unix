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
const Allocator = std.mem.Allocator;
const pattern = @import("pattern.zig");

/// How far `.` and `@` may nest.
const max_vi_depth = 16;

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

// --- terminal abstraction ---------------------------------------------------------

pub const ReadResult = union(enum) {
    /// This many bytes were stored in the buffer.
    bytes: usize,
    eof,
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
    fn push(self: *Parser, b: u8) ?Key {
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
                return .{ .cp = 0xfffd };
            },
            .utf8 => {
                if (b & 0xc0 != 0x80) {
                    self.state = .normal;
                    return self.push(b);
                }
                self.utf[self.utf_len] = b;
                self.utf_len += 1;
                if (self.utf_len < self.utf_need) return null;
                self.state = .normal;
                const cp = std.unicode.utf8Decode(self.utf[0..self.utf_len]) catch 0xfffd;
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

pub fn cpWidth(cp: u21) u2 {
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7f and cp < 0xa0)) return 2; // shown as ^X
    if (cp < 0x300) return 1;
    // combining marks and zero-width
    if ((cp >= 0x300 and cp <= 0x36f) or (cp >= 0x483 and cp <= 0x489) or (cp >= 0x591 and cp <= 0x5bd) or
        (cp >= 0x610 and cp <= 0x61a) or (cp >= 0x64b and cp <= 0x65f) or (cp >= 0x200b and cp <= 0x200f) or
        (cp >= 0x20d0 and cp <= 0x20ff) or (cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0xfe20 and cp <= 0xfe2f) or cp == 0xfeff) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2e80 and cp <= 0x303e) or (cp >= 0x3041 and cp <= 0x33ff) or
        (cp >= 0x3400 and cp <= 0x4dbf) or (cp >= 0x4e00 and cp <= 0x9fff) or (cp >= 0xa000 and cp <= 0xa4cf) or
        (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x1f300 and cp <= 0x1f64f) or
        (cp >= 0x1f900 and cp <= 0x1f9ff) or (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn isWordByte(c: u8) bool {
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

const ViPending = enum { none, d, c, y, f, F, t, T, r, @"@" };

/// The largest repeat count a key can be given. Repeating a command that many
/// times is already more than any line needs; without a limit a few more
/// digits overflow or hang the editor.
const max_count = 99_999;

/// The lower limit where each repeat makes the line longer: drawing the line
/// costs more the longer it is.
const max_copies = 4096;

/// The repeat count `cur` with another digit typed after it.
fn addDigit(cur: ?usize, digit: usize) usize {
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
            if (self.parser.push(b)) |k| {
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
            if (cp < 32 and cp != '\n') {
                self.advance(&p, 'x');
                self.advance(&p, 'x');
            } else if (cp == 0x7f) {
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

    fn emitBuffer(self: *Editor) void {
        const s = self.buf.items;
        var p = self.layoutPrompt(self.displayPrompt());
        var i: usize = 0;
        while (i < s.len) {
            const ch = charAt(s, i);
            const cp = ch.cp;
            const before = p.row;
            if (cp == '\n') {
                self.out.appendSlice(self.gpa, "\r\n") catch return;
                p.row += 1;
                p.col = 0;
            } else if (cp < 32 or cp == 0x7f) {
                const vis: [2]u8 = .{ '^', if (cp == 0x7f) '?' else @as(u8, @intCast(cp)) + 64 };
                self.advance(&p, 'x');
                self.out.appendSlice(self.gpa, &vis) catch return;
                self.advance(&p, 'x');
            } else {
                // The cell may wrap before it is written (wide character).
                self.out.appendSlice(self.gpa, if (ch.valid) s[i..][0..ch.len] else "\u{fffd}") catch return;
                self.advance(&p, cp);
            }
            if (p.row > before and cp != '\n') self.out.appendSlice(self.gpa, "\r\n") catch return;
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
        if (cp < 32 or cp == 0x7f) return false;
        const end = self.layout(self.displayPrompt(), self.buf.items.len);
        // `bytes` is already appended; the old end is the position before it.
        _ = end;
        const w: usize = cpWidth(cp);
        const before = self.layout(self.displayPrompt(), self.buf.items.len - bytes.len);
        if (before.col + w >= self.cols) return false;
        self.term.write(self.term.ctx, bytes);
        return true;
    }

    fn alert(self: *Editor) void {
        self.term.write(self.term.ctx, "\x07");
    }

    // --- buffer primitives ------------------------------------------------------------

    fn prevBoundary(self: *const Editor, pos: usize) usize {
        if (pos == 0) return 0;
        var p = pos - 1;
        while (p > 0 and pos - p < 4 and (self.buf.items[p] & 0xc0) == 0x80) p -= 1;
        // bytes that are not one character are stepped over singly, as
        // `nextBoundary` does
        return if (charAt(self.buf.items, p).len == pos - p) p else pos - 1;
    }

    fn nextBoundary(self: *const Editor, pos: usize) usize {
        if (pos >= self.buf.items.len) return self.buf.items.len;
        return pos + charAt(self.buf.items, pos).len;
    }

    fn pushUndo(self: *Editor) void {
        const copy = self.gpa.dupe(u8, self.buf.items) catch return;
        self.undo.append(self.gpa, .{ .text = copy, .cursor = self.cur }) catch {
            self.gpa.free(copy);
            return;
        };
        if (self.undo.items.len > 100) {
            self.gpa.free(self.undo.orderedRemove(0).text);
        }
    }

    fn setText(self: *Editor, s: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.gpa, s) catch {};
    }

    fn insertBytes(self: *Editor, bytes: []const u8) void {
        self.buf.insertSlice(self.gpa, self.cur, bytes) catch return;
        self.cur += bytes.len;
    }

    fn deleteRange(self: *Editor, from: usize, to: usize) void {
        if (to <= from) return;
        self.buf.replaceRange(self.gpa, from, to - from, "") catch return;
        if (self.cur > from) self.cur = if (self.cur >= to) self.cur - (to - from) else from;
    }

    fn killText(self: *Editor, s: []const u8, append: bool, prepend: bool) void {
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

    fn wordBack(self: *const Editor, from: usize) usize {
        var p = from;
        const s = self.buf.items;
        while (p > 0 and !isWordByte(s[p - 1])) p -= 1;
        while (p > 0 and isWordByte(s[p - 1])) p -= 1;
        return p;
    }

    fn wordFwd(self: *const Editor, from: usize) usize {
        var p = from;
        const s = self.buf.items;
        while (p < s.len and !isWordByte(s[p])) p += 1;
        while (p < s.len and isWordByte(s[p])) p += 1;
        return p;
    }

    fn historyLoad(self: *Editor, idx: usize) void {
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

    fn insertCp(self: *Editor, cp: u21) void {
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

    fn emacsKey(self: *Editor, k: Key) void {
        const n = self.arg orelse 1;
        var keep_kill = false;
        var keep_yank = false;
        var keep_insert = false;
        var dirty = true;
        switch (k.kind) {
            .up => self.historyMove(-@as(isize, @intCast(n))),
            .down => self.historyMove(@intCast(n)),
            .left => for (0..n) |_| {
                self.cur = self.prevBoundary(self.cur);
            },
            .right => for (0..n) |_| {
                self.cur = self.nextBoundary(self.cur);
            },
            .home => self.cur = 0,
            .end => self.cur = self.buf.items.len,
            .delete => {
                self.pushUndo();
                for (0..n) |_| self.deleteRange(self.cur, self.nextBoundary(self.cur));
            },
            .ctrl_left => self.cur = self.wordBack(self.cur),
            .ctrl_right => self.cur = self.wordFwd(self.cur),
            .page_up => self.historyLoad(0),
            .page_down => self.historyLoad(self.history.len),
            .insert, .none, .paste_begin, .paste_end => dirty = false,
            .char => {
                if (k.alt) {
                    if (k.cp >= '0' and k.cp <= '9') {
                        self.arg = addDigit(self.arg, k.cp - '0');
                        return;
                    }
                    self.emacsMeta(k.cp, &keep_kill);
                } else switch (k.cp) {
                    1 => self.cur = 0, // C-a
                    2 => for (0..n) |_| {
                        self.cur = self.prevBoundary(self.cur);
                    },
                    3 => { // C-c
                        self.status = .interrupted;
                        return;
                    },
                    4 => { // C-d
                        if (self.buf.items.len == 0) {
                            self.status = .eof;
                            return;
                        }
                        self.pushUndo();
                        for (0..n) |_| self.deleteRange(self.cur, self.nextBoundary(self.cur));
                    },
                    5 => self.cur = self.buf.items.len,
                    6 => for (0..n) |_| {
                        self.cur = self.nextBoundary(self.cur);
                    },
                    7 => dirty = false,
                    8, 127 => {
                        self.pushUndo();
                        for (0..n) |_| {
                            const p = self.prevBoundary(self.cur);
                            self.deleteRange(p, self.cur);
                        }
                    },
                    9 => {
                        self.complete();
                        keep_insert = false;
                    },
                    10, 13 => {
                        self.status = .accepted;
                        return;
                    },
                    11 => { // C-k
                        self.pushUndo();
                        const s = self.gpa.dupe(u8, self.buf.items[self.cur..]) catch return;
                        defer self.gpa.free(s);
                        self.killText(s, true, false);
                        self.buf.shrinkRetainingCapacity(self.cur);
                        keep_kill = true;
                    },
                    12 => { // C-l
                        self.term.write(self.term.ctx, "\x1b[H\x1b[2J");
                        self.rendered = false;
                        self.cur_row = 0;
                    },
                    14 => self.historyMove(@intCast(n)),
                    16 => self.historyMove(-@as(isize, @intCast(n))),
                    17, 22 => { // C-q, C-v
                        self.quoted_next = true;
                        dirty = false;
                    },
                    18 => self.startSearch(false),
                    19 => self.startSearch(true),
                    20 => { // C-t
                        self.pushUndo();
                        self.transpose();
                    },
                    21 => { // C-u
                        self.pushUndo();
                        const s = self.gpa.dupe(u8, self.buf.items[0..self.cur]) catch return;
                        defer self.gpa.free(s);
                        self.killText(s, false, true);
                        self.deleteRange(0, self.cur);
                        self.cur = 0;
                        keep_kill = true;
                    },
                    23 => { // C-w: previous blank-delimited word
                        self.pushUndo();
                        var p = self.cur;
                        const s = self.buf.items;
                        while (p > 0 and isBlank(s[p - 1])) p -= 1;
                        while (p > 0 and !isBlank(s[p - 1])) p -= 1;
                        const t = self.gpa.dupe(u8, s[p..self.cur]) catch return;
                        defer self.gpa.free(t);
                        self.killText(t, false, true);
                        self.deleteRange(p, self.cur);
                        keep_kill = true;
                    },
                    24 => dirty = false, // C-x prefix (ignored)
                    25 => { // C-y
                        if (self.kills.items.len > 0) {
                            self.pushUndo();
                            const y = self.kills.items[self.yank_idx];
                            self.insertBytes(y);
                            self.yank_len = y.len;
                            keep_yank = true;
                        }
                    },
                    31 => { // C-_ undo
                        self.undoOne();
                    },
                    27 => dirty = false,
                    else => if (k.cp >= 32) {
                        if (self.arg != null) {
                            for (0..@min(n, max_copies)) |_| self.insertCp(k.cp);
                        } else self.insertCp(k.cp);
                        keep_insert = true;
                        self.arg = null;
                        self.last_was_kill = false;
                        self.last_was_yank = false;
                        self.last_was_insert = true;
                        return;
                    } else {
                        self.alert();
                        dirty = false;
                    },
                }
            },
        }
        self.arg = null;
        self.last_was_kill = keep_kill;
        self.last_was_yank = keep_yank;
        self.last_was_insert = keep_insert;
        if (dirty and self.status == .more) self.redraw();
    }

    fn emacsMeta(self: *Editor, c: u21, keep_kill: *bool) void {
        const n = self.arg orelse 1;
        if (c >= '0' and c <= '9') {
            self.arg = addDigit(self.arg, c - '0');
            return;
        }
        switch (c) {
            'b' => for (0..n) |_| {
                self.cur = self.wordBack(self.cur);
            },
            'f' => for (0..n) |_| {
                self.cur = self.wordFwd(self.cur);
            },
            'd' => {
                self.pushUndo();
                const e = self.wordFwd(self.cur);
                const t = self.gpa.dupe(u8, self.buf.items[self.cur..e]) catch return;
                defer self.gpa.free(t);
                self.killText(t, true, false);
                self.deleteRange(self.cur, e);
                keep_kill.* = true;
            },
            127, 8 => {
                self.pushUndo();
                const b = self.wordBack(self.cur);
                const t = self.gpa.dupe(u8, self.buf.items[b..self.cur]) catch return;
                defer self.gpa.free(t);
                self.killText(t, false, true);
                self.deleteRange(b, self.cur);
                keep_kill.* = true;
            },
            'y' => if (self.last_was_yank and self.kills.items.len > 1) {
                const start = self.cur - self.yank_len;
                self.deleteRange(start, self.cur);
                self.yank_idx = if (self.yank_idx == 0) self.kills.items.len - 1 else self.yank_idx - 1;
                const y = self.kills.items[self.yank_idx];
                self.insertBytes(y);
                self.yank_len = y.len;
            },
            'u', 'l', 'c' => {
                self.pushUndo();
                const e = self.wordFwd(self.cur);
                var p = self.cur;
                var first = true;
                while (p < e) : (p += 1) {
                    const ch = self.buf.items[p];
                    if (!std.ascii.isAlphabetic(ch)) continue;
                    self.buf.items[p] = switch (c) {
                        'u' => std.ascii.toUpper(ch),
                        'l' => std.ascii.toLower(ch),
                        else => if (first) std.ascii.toUpper(ch) else std.ascii.toLower(ch),
                    };
                    first = false;
                }
                self.cur = e;
            },
            't' => {
                self.pushUndo();
                self.transposeWords();
            },
            '<' => self.historyLoad(0),
            '>' => self.historyLoad(self.history.len),
            '.', '_' => {
                if (self.history.len > 0) {
                    const last = self.history[self.history.len - 1];
                    const t = std.mem.trimEnd(u8, last, " \t\n");
                    const st = if (std.mem.lastIndexOfAny(u8, t, " \t")) |i| i + 1 else 0;
                    self.pushUndo();
                    self.insertBytes(t[st..]);
                }
            },
            '?' => self.listCompletions(),
            '#' => {
                self.pushUndo();
                self.insertBytesAt(0, "#");
                self.status = .accepted;
            },
            '\\' => {},
            else => self.alert(),
        }
    }

    fn insertBytesAt(self: *Editor, at: usize, bytes: []const u8) void {
        self.buf.insertSlice(self.gpa, at, bytes) catch return;
        if (self.cur >= at) self.cur += bytes.len;
    }

    fn transpose(self: *Editor) void {
        const s = self.buf.items;
        if (s.len < 2) return;
        var pos = self.cur;
        if (pos >= s.len) pos = self.prevBoundary(s.len);
        if (pos == 0) return;
        const a0 = self.prevBoundary(pos);
        const b1 = self.nextBoundary(pos);
        const ta = self.gpa.dupe(u8, s[a0..pos]) catch return;
        defer self.gpa.free(ta);
        const tb = self.gpa.dupe(u8, s[pos..b1]) catch return;
        defer self.gpa.free(tb);
        @memcpy(self.buf.items[a0 .. a0 + tb.len], tb);
        @memcpy(self.buf.items[a0 + tb.len .. b1], ta);
        self.cur = b1;
    }

    fn transposeWords(self: *Editor) void {
        const s = self.buf.items;
        const b2 = self.wordFwd(self.cur);
        const a2 = self.wordBack(b2);
        const a1 = self.wordBack(a2);
        if (a1 == a2 or a2 >= b2) return;
        const e1 = self.wordFwd(a1);
        // with nothing but blanks or punctuation before the word, `a1` leads
        // forward into that same word: there is nothing to swap it with
        if (e1 > a2) return;
        const w1 = self.gpa.dupe(u8, s[a1..e1]) catch return;
        defer self.gpa.free(w1);
        const mid = self.gpa.dupe(u8, s[e1..a2]) catch return;
        defer self.gpa.free(mid);
        const w2 = self.gpa.dupe(u8, s[a2..b2]) catch return;
        defer self.gpa.free(w2);
        const joined = std.mem.concat(self.gpa, u8, &.{ w2, mid, w1 }) catch return;
        defer self.gpa.free(joined);
        @memcpy(self.buf.items[a1..b2], joined);
        self.cur = b2;
    }

    fn undoOne(self: *Editor) void {
        const u = self.undo.pop() orelse {
            self.alert();
            return;
        };
        defer self.gpa.free(u.text);
        self.setText(u.text);
        self.cur = @min(u.cursor, self.buf.items.len);
    }

    fn historyMove(self: *Editor, delta: isize) void {
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

    fn startSearch(self: *Editor, fwd: bool) void {
        self.searching = true;
        self.search_fwd = fwd;
        self.search_buf.clearRetainingCapacity();
        self.search_saved.clearRetainingCapacity();
        self.search_saved.appendSlice(self.gpa, self.buf.items) catch {};
        self.search_saved_cur = self.cur;
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

    fn commonPrefix(cands: []const []const u8) []const u8 {
        if (cands.len == 0) return "";
        var n = cands[0].len;
        for (cands[1..]) |c| {
            var i: usize = 0;
            while (i < n and i < c.len and c[i] == cands[0][i]) i += 1;
            n = i;
        }
        // do not cut a UTF-8 sequence
        while (n > 0 and n < cands[0].len and (cands[0][n] & 0xc0) == 0x80) n -= 1;
        return cands[0][0..n];
    }

    fn complete(self: *Editor) void {
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

    fn showCandidates(self: *Editor, cands: []const []const u8) void {
        // Finish the edit line, list in columns, redraw below.
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
        self.rendered = false;
        self.cur_row = 0;
        // back to the cursor position needs a redraw from the top of the line
        self.redrawFresh();
    }

    fn redrawFresh(self: *Editor) void {
        self.rendered = false;
        self.cur_row = 0;
        self.redraw();
    }

    fn listCompletions(self: *Editor) void {
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

    // --- vi mode ----------------------------------------------------------------------------------

    fn viMoveTo(self: *Editor, pos: usize) void {
        self.cur = pos;
    }

    /// In command mode the cursor sits on a character, not past the last.
    fn viClamp(self: *Editor) void {
        if (self.vi_insert) return;
        if (self.buf.items.len == 0) {
            self.cur = 0;
            return;
        }
        if (self.cur >= self.buf.items.len) self.cur = self.prevBoundary(self.buf.items.len);
    }

    fn lastCharPos(self: *const Editor) usize {
        if (self.buf.items.len == 0) return 0;
        return self.prevBoundary(self.buf.items.len);
    }

    const WordKind = enum { word, big };

    fn classOf(c: u8, kind: WordKind) u2 {
        if (isBlank(c)) return 0;
        if (kind == .big) return 1;
        return if (isWordByte(c)) 1 else 2;
    }

    fn viNextWord(self: *const Editor, from: usize, kind: WordKind) usize {
        const s = self.buf.items;
        var p = from;
        if (p >= s.len) return s.len;
        const cl = classOf(s[p], kind);
        if (cl != 0) while (p < s.len and classOf(s[p], kind) == cl) {
            p += 1;
        };
        while (p < s.len and classOf(s[p], kind) == 0) p += 1;
        return p;
    }

    fn viPrevWord(self: *const Editor, from: usize, kind: WordKind) usize {
        const s = self.buf.items;
        var p = from;
        if (p == 0) return 0;
        p -= 1;
        while (p > 0 and classOf(s[p], kind) == 0) p -= 1;
        const cl = classOf(s[p], kind);
        while (p > 0 and classOf(s[p - 1], kind) == cl) p -= 1;
        return p;
    }

    fn viEndWord(self: *const Editor, from: usize, kind: WordKind) usize {
        const s = self.buf.items;
        var p = from;
        if (p + 1 >= s.len) return if (s.len == 0) 0 else s.len - 1;
        p += 1;
        while (p < s.len and classOf(s[p], kind) == 0) p += 1;
        if (p >= s.len) return s.len - 1;
        const cl = classOf(s[p], kind);
        while (p + 1 < s.len and classOf(s[p + 1], kind) == cl) p += 1;
        return p;
    }

    const Target = struct { pos: usize, inclusive: bool };

    /// The cursor position a motion key leads to, or null when it is not a
    /// motion or fails.
    fn viMotion(self: *Editor, c: u21, count: usize, have_count: bool, find_ch: ?u21) ?Target {
        const s = self.buf.items;
        switch (c) {
            'h', 8, 127 => {
                var p = self.cur;
                for (0..count) |_| p = self.prevBoundary(p);
                if (p == self.cur) return null;
                return .{ .pos = p, .inclusive = false };
            },
            'l', ' ' => {
                var p = self.cur;
                for (0..count) |_| p = self.nextBoundary(p);
                if (self.cur >= s.len or (p == self.cur)) return null;
                return .{ .pos = p, .inclusive = false };
            },
            '0' => return .{ .pos = 0, .inclusive = false },
            '^' => {
                var p: usize = 0;
                while (p < s.len and isBlank(s[p])) p += 1;
                return .{ .pos = p, .inclusive = false };
            },
            '$' => return .{ .pos = self.lastCharPos(), .inclusive = true },
            '|' => {
                var p: usize = 0;
                var n: usize = 1;
                while (n < count and p < s.len) : (n += 1) p = self.nextBoundary(p);
                return .{ .pos = @min(p, self.lastCharPos()), .inclusive = false };
            },
            'w', 'W' => {
                var p = self.cur;
                const kind: WordKind = if (c == 'w') .word else .big;
                for (0..count) |_| p = self.viNextWord(p, kind);
                if (p == self.cur and self.cur >= self.lastCharPos()) return null;
                return .{ .pos = p, .inclusive = false };
            },
            'b', 'B' => {
                if (self.cur == 0) return null;
                var p = self.cur;
                const kind: WordKind = if (c == 'b') .word else .big;
                for (0..count) |_| p = self.viPrevWord(p, kind);
                return .{ .pos = p, .inclusive = false };
            },
            'e', 'E' => {
                var p = self.cur;
                const kind: WordKind = if (c == 'e') .word else .big;
                for (0..count) |_| p = self.viEndWord(p, kind);
                if (p == self.cur) return null;
                return .{ .pos = p, .inclusive = true };
            },
            'f', 'F', 't', 'T' => {
                const ch = find_ch orelse return null;
                return self.viFind(@intCast(c), ch, count);
            },
            ';', ',' => {
                const f = self.vi_find orelse return null;
                var kind = f.kind;
                if (c == ',') kind = switch (kind) {
                    'f' => 'F',
                    'F' => 'f',
                    't' => 'T',
                    else => 't',
                };
                return self.viFindRepeat(kind, f.ch, count);
            },
            else => {
                _ = have_count;
                return null;
            },
        }
    }

    fn viFind(self: *Editor, kind: u8, ch: u21, count: usize) ?Target {
        self.vi_find = .{ .kind = kind, .ch = ch };
        return self.viFindRepeat(kind, ch, count);
    }

    fn viFindRepeat(self: *Editor, kind: u8, ch: u21, count: usize) ?Target {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &tmp) catch return null;
        const needle = tmp[0..n];
        const s = self.buf.items;
        var p = self.cur;
        var left = count;
        switch (kind) {
            'f', 't' => {
                var search_from = self.nextBoundary(p);
                // a repeated `t` must not stay in place
                if (kind == 't' and count == 1 and search_from < s.len and std.mem.startsWith(u8, s[search_from..], needle) and false) search_from = self.nextBoundary(search_from);
                var q = search_from;
                while (left > 0) {
                    const idx = std.mem.indexOfPos(u8, s, q, needle) orelse return null;
                    p = idx;
                    q = idx + n;
                    left -= 1;
                }
                if (kind == 't') {
                    p = self.prevBoundary(p);
                    if (p <= self.cur and true) {
                        // `t` next to the cursor does not move
                        if (p == self.cur) return null;
                    }
                }
                return .{ .pos = p, .inclusive = true };
            },
            else => {
                var q = p;
                while (left > 0) {
                    if (q == 0) return null;
                    const idx = std.mem.lastIndexOf(u8, s[0..q], needle) orelse return null;
                    p = idx;
                    q = idx;
                    left -= 1;
                }
                if (kind == 'T') {
                    p = self.nextBoundary(p);
                    if (p >= self.cur) return null;
                }
                return .{ .pos = p, .inclusive = false };
            },
        }
    }

    fn viSaveUndo(self: *Editor) void {
        self.vi_undo_text.clearRetainingCapacity();
        self.vi_undo_text.appendSlice(self.gpa, self.buf.items) catch {};
        self.vi_undo_cur = self.cur;
        self.vi_changed = true;
        self.vi_changed_ever = true;
    }

    fn viDelete(self: *Editor, from: usize, to: usize, save: bool) void {
        if (to <= from) return;
        if (save) {
            self.vi_reg.clearRetainingCapacity();
            self.vi_reg.appendSlice(self.gpa, self.buf.items[from..to]) catch {};
        }
        self.buf.replaceRange(self.gpa, from, to - from, "") catch return;
        self.cur = from;
    }

    fn viOperate(self: *Editor, op: ViPending, from_in: usize, tgt: Target) void {
        var from = self.cur;
        var to = tgt.pos;
        _ = from_in;
        if (to < from) {
            std.mem.swap(usize, &from, &to);
        } else if (tgt.inclusive) to = self.nextBoundary(to);
        if (to > self.buf.items.len) to = self.buf.items.len;
        switch (op) {
            .y => {
                self.vi_reg.clearRetainingCapacity();
                self.vi_reg.appendSlice(self.gpa, self.buf.items[from..to]) catch {};
                self.cur = from;
            },
            .d => {
                self.viSaveUndo();
                self.viDelete(from, to, true);
            },
            .c => {
                self.viSaveUndo();
                self.viDelete(from, to, true);
                self.vi_insert = true;
            },
            else => {},
        }
    }

    fn viKey(self: *Editor, k: Key) void {
        // record for `.`
        if (!self.vi_replaying and !(self.vi_insert and self.vi_rec.items.len == 0 and false)) {
            self.vi_rec.append(self.gpa, k) catch {};
        }
        if (self.vi_insert) {
            self.viInsertKey(k);
        } else self.viCommandKey(k);
        if (self.status != .more) return;
        self.viClamp();
        if (self.vi_insert == false and self.vi_pend == .none and self.vi_count == null) {
            // a command finished: remember it for `.` when it changed text
            if (self.vi_changed and !self.vi_replaying) {
                self.vi_last.clearRetainingCapacity();
                self.vi_last.appendSlice(self.gpa, self.vi_rec.items) catch {};
                self.vi_last_count = self.vi_op_count;
                self.vi_changed = false;
            }
            if (!self.vi_replaying) self.vi_rec.clearRetainingCapacity();
        }
        if (self.status == .more and !self.vi_search_mode) self.redraw();
    }

    fn viInsertKey(self: *Editor, k: Key) void {
        if (k.kind != .char or k.alt) {
            switch (k.kind) {
                .left => self.cur = self.prevBoundary(self.cur),
                .right => self.cur = self.nextBoundary(self.cur),
                .home => self.cur = 0,
                .end => self.cur = self.buf.items.len,
                .up => self.historyMove(-1),
                .down => self.historyMove(1),
                .delete => self.deleteRange(self.cur, self.nextBoundary(self.cur)),
                else => {},
            }
            if (k.alt and k.kind == .char and k.cp == 'b') self.cur = self.wordBack(self.cur);
            if (k.alt and k.kind == .char and k.cp == 'f') self.cur = self.wordFwd(self.cur);
            return;
        }
        const c = k.cp;
        if (self.vi_search_mode) {
            self.viSearchInput(c);
            return;
        }
        if (c == 27) {
            self.vi_insert = false;
            self.vi_replace = false;
            if (self.cur > 0) self.cur = self.prevBoundary(self.cur);
            self.last_was_insert = false;
            return;
        }
        if (c == 10 or c == 13) {
            self.status = .accepted;
            return;
        }
        if (c == self.erase_char or c == 8 or c == 127) {
            const p = self.prevBoundary(self.cur);
            self.deleteRange(p, self.cur);
            return;
        }
        if (c == self.kill_char) {
            self.buf.clearRetainingCapacity();
            self.cur = 0;
            return;
        }
        if (c == 3) {
            self.status = .interrupted;
            return;
        }
        if (c == self.eof_char) {
            if (self.buf.items.len == 0) self.status = .eof;
            return;
        }
        switch (c) {
            22 => {
                self.quoted_next = true;
                return;
            },
            23 => { // C-w
                var p = self.cur;
                const s = self.buf.items;
                while (p > 0 and !isWordByte(s[p - 1]) and !isBlank(s[p - 1])) p -= 1;
                while (p > 0 and isBlank(s[p - 1])) p -= 1;
                while (p > 0 and isWordByte(s[p - 1])) p -= 1;
                self.deleteRange(p, self.cur);
                return;
            },
            9 => {
                self.complete();
                return;
            },
            12 => {
                self.redrawFresh();
                return;
            },
            else => {},
        }
        if (c >= 32) {
            if (!self.vi_changed) {
                // first inserted character of an `i`-like command already marked
            }
            self.insertCp(c);
            return;
        }
        self.alert();
    }

    fn viSearchInput(self: *Editor, c: u21) void {
        if (c == 27) {
            // cancel
            self.setText(self.vi_orig.items);
            self.cur = self.vi_undo_cur;
            self.vi_search_mode = false;
            self.vi_insert = false;
            self.viClamp();
            self.redrawFresh();
            return;
        }
        if (c == 10 or c == 13) {
            const pat = self.gpa.dupe(u8, self.buf.items[1..]) catch return;
            defer self.gpa.free(pat);
            self.setText(self.vi_orig.items);
            self.cur = self.vi_undo_cur;
            self.vi_search_mode = false;
            self.vi_insert = false;
            self.viRunSearch(pat, self.vi_search_fwd);
            self.redrawFresh();
            return;
        }
        if (c == 8 or c == 127) {
            if (self.buf.items.len > 1) {
                const p = self.prevBoundary(self.buf.items.len);
                self.buf.shrinkRetainingCapacity(p);
                self.cur = self.buf.items.len;
            }
            self.redraw();
            return;
        }
        if (c >= 32) {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &tmp) catch return;
            self.buf.appendSlice(self.gpa, tmp[0..n]) catch return;
            self.cur = self.buf.items.len;
            self.redraw();
        }
    }

    fn viRunSearch(self: *Editor, pat_in: []const u8, fwd: bool) void {
        var pat = pat_in;
        if (pat.len == 0) {
            if (self.vi_search) |s| {
                pat = s.pat;
            } else {
                self.alert();
                return;
            }
        }
        const stored = self.gpa.dupe(u8, pat) catch return;
        if (self.vi_search) |s| self.gpa.free(s.pat);
        self.vi_search = .{ .pat = stored, .fwd = fwd };
        var anchored = false;
        var body: []const u8 = stored;
        if (body.len > 0 and body[0] == '^') {
            anchored = true;
            body = body[1..];
        }
        const glob = if (anchored) std.fmt.allocPrint(self.gpa, "{s}*", .{body}) else std.fmt.allocPrint(self.gpa, "*{s}*", .{body});
        const g = glob catch return;
        defer self.gpa.free(g);
        var i: isize = @intCast(self.hist_pos);
        const step: isize = if (fwd) 1 else -1;
        i += step;
        while (i >= 0 and i < @as(isize, @intCast(self.history.len))) : (i += step) {
            if (pattern.match(g, self.history[@intCast(i)])) {
                self.historyLoad(@intCast(i));
                self.cur = 0;
                return;
            }
        }
        self.alert();
    }

    fn viCommandKey(self: *Editor, k: Key) void {
        if (k.kind != .char or k.alt) {
            switch (k.kind) {
                .left => self.cur = self.prevBoundary(self.cur),
                .right => self.cur = self.nextBoundary(self.cur),
                .up => self.viHistory(-1, 1),
                .down => self.viHistory(1, 1),
                .home => self.cur = 0,
                .end => self.cur = self.lastCharPos(),
                .delete => {
                    self.viSaveUndo();
                    self.viDelete(self.cur, self.nextBoundary(self.cur), true);
                },
                else => {},
            }
            return;
        }
        const c = k.cp;
        // pending argument of f/F/t/T/r/@
        switch (self.vi_pend) {
            .f, .F, .t, .T => {
                const kind: u8 = switch (self.vi_pend) {
                    .f => 'f',
                    .F => 'F',
                    .t => 't',
                    else => 'T',
                };
                self.vi_pend = .none;
                const count = self.vi_count orelse 1;
                self.vi_count = null;
                if (self.viFind(kind, c, count)) |t| {
                    self.cur = t.pos;
                } else self.alert();
                return;
            },
            .r => {
                self.vi_pend = .none;
                const count = self.vi_count orelse 1;
                self.vi_count = null;
                self.viReplaceChars(c, count);
                return;
            },
            .@"@" => {
                self.vi_pend = .none;
                self.vi_count = null;
                // an alias that runs itself must not recurse without end
                if (self.vi_depth < max_vi_depth) if (self.alias_fn) |af| if (c < 128) if (af(self.cb_ctx, @intCast(c))) |txt| {
                    const copy = self.gpa.dupe(u8, txt) catch return;
                    defer self.gpa.free(copy);
                    const saved = self.vi_replaying;
                    self.vi_replaying = true;
                    self.vi_depth += 1;
                    defer self.vi_depth -= 1;
                    for (copy) |b| {
                        if (self.parser.push(b)) |kk| self.viKey(kk);
                    }
                    self.vi_replaying = saved;
                    return;
                };
                self.alert();
                return;
            },
            else => {},
        }
        // counts
        if (c >= '1' and c <= '9' or (c == '0' and self.vi_count != null)) {
            self.vi_count = addDigit(self.vi_count, c - '0');
            return;
        }
        const have_count = self.vi_count != null;
        const count = self.vi_count orelse 1;
        // pending operator: this key is its motion
        if (self.vi_pend == .d or self.vi_pend == .c or self.vi_pend == .y) {
            const op = self.vi_pend;
            const opc: u21 = switch (op) {
                .d => 'd',
                .c => 'c',
                else => 'y',
            };
            if (c == opc) { // dd cc yy
                self.vi_pend = .none;
                self.vi_count = null;
                self.vi_op_count = null;
                switch (op) {
                    .y => {
                        self.vi_reg.clearRetainingCapacity();
                        self.vi_reg.appendSlice(self.gpa, self.buf.items) catch {};
                    },
                    .d => {
                        self.viSaveUndo();
                        self.vi_reg.clearRetainingCapacity();
                        self.vi_reg.appendSlice(self.gpa, self.buf.items) catch {};
                        self.buf.clearRetainingCapacity();
                        self.cur = 0;
                    },
                    else => {
                        self.viSaveUndo();
                        self.vi_reg.clearRetainingCapacity();
                        self.vi_reg.appendSlice(self.gpa, self.buf.items) catch {};
                        self.buf.clearRetainingCapacity();
                        self.cur = 0;
                        self.vi_insert = true;
                    },
                }
                return;
            }
            if (c == 'f' or c == 'F' or c == 't' or c == 'T') {
                // need one more key
                self.vi_op_find = @intCast(c);
                self.vi_pend = .none;
                self.vi_op_pending = op;
                self.vi_count = if (have_count) count else null;
                return;
            }
            var mcount = count;
            if (self.vi_op_count) |oc| if (!have_count) {
                mcount = oc;
            } else {
                mcount = @min(oc * count, max_count);
            };
            self.vi_pend = .none;
            self.vi_count = null;
            var motion_c = c;
            if (op == .c and (c == 'w' or c == 'W')) motion_c = if (c == 'w') 'e' else 'E';
            var tgt = self.viMotion(motion_c, mcount, true, null) orelse {
                // `cw` on the last character or ` ` still works: treat as end
                if (op == .c and (c == 'w' or c == 'W') and self.cur < self.buf.items.len) {
                    self.viOperate(op, self.cur, .{ .pos = self.cur, .inclusive = true });
                    return;
                }
                self.alert();
                return;
            };
            if (op == .c and (c == 'w' or c == 'W') and isBlank(self.buf.items[self.cur])) {
                tgt = self.viMotion(c, mcount, true, null) orelse tgt;
                tgt.inclusive = false;
            }
            // `dw` on the last word deletes to the end of the line
            if ((c == 'w' or c == 'W') and op != .c and tgt.pos == self.cur) tgt.pos = self.buf.items.len;
            if ((c == 'w' or c == 'W') and op != .c and tgt.pos >= self.lastCharPos() and tgt.pos < self.buf.items.len and self.viNextWord(self.cur, if (c == 'w') .word else .big) >= self.buf.items.len) tgt.pos = self.buf.items.len;
            self.viOperate(op, self.cur, tgt);
            return;
        }
        if (self.vi_op_pending != .none) {
            const op = self.vi_op_pending;
            self.vi_op_pending = .none;
            const cnt = self.vi_count orelse 1;
            self.vi_count = null;
            if (self.viFind(self.vi_op_find, c, cnt)) |t| {
                self.viOperate(op, self.cur, t);
            } else self.alert();
            return;
        }
        self.vi_count = null;
        switch (c) {
            10, 13 => {
                self.status = .accepted;
                return;
            },
            12 => { // C-l
                self.redrawFresh();
                return;
            },
            '#' => {
                self.insertBytesAt(0, "#");
                self.status = .accepted;
                return;
            },
            'i' => {
                self.viSaveUndo();
                self.vi_insert = true;
                self.last_was_insert = false;
            },
            'a' => {
                self.viSaveUndo();
                self.vi_insert = true;
                self.cur = self.nextBoundary(self.cur);
                self.last_was_insert = false;
            },
            'I' => {
                self.viSaveUndo();
                self.vi_insert = true;
                self.cur = 0;
                self.last_was_insert = false;
            },
            'A' => {
                self.viSaveUndo();
                self.vi_insert = true;
                self.cur = self.buf.items.len;
                self.last_was_insert = false;
            },
            'R' => {
                self.viSaveUndo();
                self.vi_insert = true;
                self.vi_replace = true;
                self.last_was_insert = false;
            },
            'd' => {
                self.vi_pend = .d;
                self.vi_op_count = if (have_count) count else null;
                self.vi_count = null;
                return;
            },
            'c' => {
                self.vi_pend = .c;
                self.vi_op_count = if (have_count) count else null;
                return;
            },
            'y' => {
                self.vi_pend = .y;
                self.vi_op_count = if (have_count) count else null;
                return;
            },
            'D' => {
                self.viSaveUndo();
                self.viDelete(self.cur, self.buf.items.len, true);
            },
            'C' => {
                self.viSaveUndo();
                self.viDelete(self.cur, self.buf.items.len, true);
                self.vi_insert = true;
            },
            'S' => {
                self.viSaveUndo();
                self.vi_reg.clearRetainingCapacity();
                self.vi_reg.appendSlice(self.gpa, self.buf.items) catch {};
                self.buf.clearRetainingCapacity();
                self.cur = 0;
                self.vi_insert = true;
            },
            's' => {
                self.viSaveUndo();
                var e = self.cur;
                for (0..count) |_| e = self.nextBoundary(e);
                self.viDelete(self.cur, e, true);
                self.vi_insert = true;
            },
            'Y' => {
                self.vi_reg.clearRetainingCapacity();
                self.vi_reg.appendSlice(self.gpa, self.buf.items[self.cur..]) catch {};
            },
            'x' => {
                if (self.buf.items.len == 0) {
                    self.alert();
                } else {
                    self.viSaveUndo();
                    var e = self.cur;
                    for (0..count) |_| e = self.nextBoundary(e);
                    self.viDelete(self.cur, e, true);
                }
            },
            'X' => {
                if (self.cur == 0) {
                    self.alert();
                } else {
                    self.viSaveUndo();
                    var s0 = self.cur;
                    for (0..count) |_| s0 = self.prevBoundary(s0);
                    self.viDelete(s0, self.cur, true);
                }
            },
            'r' => {
                self.vi_pend = .r;
                self.vi_count = if (have_count) count else null;
                return;
            },
            'f' => {
                self.vi_pend = .f;
                self.vi_count = if (have_count) count else null;
                return;
            },
            'F' => {
                self.vi_pend = .F;
                self.vi_count = if (have_count) count else null;
                return;
            },
            't' => {
                self.vi_pend = .t;
                self.vi_count = if (have_count) count else null;
                return;
            },
            'T' => {
                self.vi_pend = .T;
                self.vi_count = if (have_count) count else null;
                return;
            },
            '@' => {
                self.vi_pend = .@"@";
                return;
            },
            'p', 'P' => {
                if (self.vi_reg.items.len == 0) {
                    self.alert();
                } else {
                    self.viSaveUndo();
                    const at = if (c == 'p' and self.buf.items.len > 0) self.nextBoundary(self.cur) else self.cur;
                    var last = at;
                    for (0..@min(count, max_copies)) |_| {
                        self.buf.insertSlice(self.gpa, last, self.vi_reg.items) catch return;
                        last += self.vi_reg.items.len;
                    }
                    self.cur = self.prevBoundary(last);
                }
            },
            '~' => {
                if (self.buf.items.len == 0) {
                    self.alert();
                } else {
                    self.viSaveUndo();
                    var p = self.cur;
                    for (0..count) |_| {
                        if (p >= self.buf.items.len) break;
                        const ch = self.buf.items[p];
                        self.buf.items[p] = if (std.ascii.isLower(ch)) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
                        p = self.nextBoundary(p);
                    }
                    self.cur = if (p >= self.buf.items.len) self.lastCharPos() else p;
                }
            },
            '_' => {
                if (self.history.len > 0) {
                    const prev = std.mem.trimEnd(u8, self.history[self.history.len - 1], " \t\n");
                    var words: std.ArrayList([]const u8) = .empty;
                    defer words.deinit(self.gpa);
                    var it = std.mem.tokenizeAny(u8, prev, " \t");
                    while (it.next()) |w| words.append(self.gpa, w) catch return;
                    if (words.items.len > 0) {
                        const w = if (have_count) (if (count <= words.items.len) words.items[count - 1] else {
                            self.alert();
                            return;
                        }) else words.items[words.items.len - 1];
                        self.viSaveUndo();
                        self.cur = if (self.buf.items.len == 0) 0 else self.nextBoundary(self.cur);
                        self.insertBytes(" ");
                        self.insertBytes(w);
                        self.vi_insert = true;
                    } else self.alert();
                } else self.alert();
            },
            'u' => {
                const saved_text = self.gpa.dupe(u8, self.buf.items) catch return;
                defer self.gpa.free(saved_text);
                const saved_cur = self.cur;
                if (self.vi_undo_text.items.len == 0 and !self.vi_changed_ever) {
                    self.alert();
                } else {
                    self.setText(self.vi_undo_text.items);
                    self.cur = @min(self.vi_undo_cur, self.buf.items.len);
                    self.vi_undo_text.clearRetainingCapacity();
                    self.vi_undo_text.appendSlice(self.gpa, saved_text) catch {};
                    self.vi_undo_cur = saved_cur;
                }
            },
            'U' => {
                {
                    self.viSaveUndo();
                    self.setText(self.vi_start.items);
                    self.cur = 0;
                }
            },
            '.' => {
                if (self.vi_last.items.len == 0 or self.vi_depth >= max_vi_depth) {
                    self.alert();
                    return;
                }
                const keys = self.gpa.dupe(Key, self.vi_last.items) catch return;
                defer self.gpa.free(keys);
                const cnt = if (have_count) count else (self.vi_last_count orelse 1);
                if (have_count) self.vi_last_count = count;
                const saved = self.vi_replaying;
                self.vi_replaying = true;
                self.vi_depth += 1;
                defer {
                    self.vi_depth -= 1;
                    self.vi_replaying = saved;
                    // what was replayed is not a new change: `.` must never
                    // become the command that `.` repeats
                    self.vi_changed = false;
                    self.vi_rec.clearRetainingCapacity();
                }
                if (cnt > 1 or have_count) {
                    // the recorded count digits were kept out; apply as prefix
                    var tmp: [24]u8 = undefined;
                    const digits = std.fmt.bufPrint(&tmp, "{d}", .{cnt}) catch "";
                    for (digits) |dch| self.viKey(.{ .cp = dch });
                }
                for (keys) |kk| self.viKey(kk);
                if (!self.vi_insert) self.viClamp();
                return;
            },
            'k', '-' => self.viHistory(-1, count),
            'j', '+' => self.viHistory(1, count),
            'G' => {
                if (have_count) {
                    if (count >= self.history_first and count - self.history_first < self.history.len) {
                        self.historyLoad(count - self.history_first);
                        self.cur = 0;
                    } else self.alert();
                } else if (self.history.len > 0) {
                    self.historyLoad(0);
                    self.cur = 0;
                } else self.alert();
            },
            '/', '?' => {
                self.vi_orig.clearRetainingCapacity();
                self.vi_orig.appendSlice(self.gpa, self.buf.items) catch {};
                self.vi_undo_cur = self.cur;
                self.vi_search_fwd = c == '?';
                self.vi_search_mode = true;
                self.vi_insert = true;
                self.setText(if (c == '/') "/" else "?");
                self.cur = 1;
                // the leading character is the search direction; stored in buf[0]
                self.redraw();
            },
            'n', 'N' => {
                if (self.vi_search) |s| {
                    const fwd = if (c == 'n') s.fwd else !s.fwd;
                    const pat = self.gpa.dupe(u8, s.pat) catch return;
                    defer self.gpa.free(pat);
                    const was = s.fwd;
                    self.viRunSearch(pat, fwd);
                    if (self.vi_search) |*ns| ns.fwd = was;
                } else self.alert();
            },
            'v' => {
                self.status = .external_edit;
                return;
            },
            '=' => {
                self.listCompletions();
            },
            '\\' => {
                self.viCompleteUnique();
            },
            '*' => {
                self.viExpandAll();
            },
            27 => {},
            else => {
                if (self.viMotion(c, count, have_count, null)) |t| {
                    self.cur = t.pos;
                } else {
                    // unknown commands and failed motions alert
                    self.alert();
                }
            },
        }
        self.vi_op_count = null;
    }

    fn viReplaceChars(self: *Editor, c: u21, count: usize) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &tmp) catch return;
        if (self.buf.items.len == 0) {
            self.alert();
            return;
        }
        self.viSaveUndo();
        var p = self.cur;
        var last = p;
        for (0..count) |_| {
            if (p >= self.buf.items.len) break;
            const e = self.nextBoundary(p);
            self.buf.replaceRange(self.gpa, p, e - p, tmp[0..n]) catch return;
            last = p;
            p += n;
        }
        self.cur = last;
    }

    fn viHistory(self: *Editor, dir: isize, count: usize) void {
        const cur: isize = @intCast(self.hist_pos);
        const t = cur + dir * @as(isize, @intCast(count));
        if (t < 0 or t > @as(isize, @intCast(self.history.len))) {
            self.alert();
            return;
        }
        self.historyLoad(@intCast(t));
        self.cur = 0;
    }

    fn viWordStart(self: *const Editor) usize {
        var p = self.cur;
        const s = self.buf.items;
        while (p > 0 and !isBlank(s[p - 1])) p -= 1;
        return p;
    }

    fn viCompleteUnique(self: *Editor) void {
        const f = self.complete_fn orelse {
            self.alert();
            return;
        };
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var end = self.nextBoundary(self.cur);
        _ = &end;
        const comp = f(self.cb_ctx, arena.allocator(), self.buf.items, self.nextBoundary(self.cur)) catch return;
        if (comp.candidates.len == 0) {
            self.alert();
            return;
        }
        self.viSaveUndo();
        const stop = self.nextBoundary(self.cur);
        const common = commonPrefix(comp.candidates);
        const rep = if (comp.candidates.len == 1) comp.candidates[0] else common;
        self.buf.replaceRange(self.gpa, comp.start, stop - comp.start, rep) catch return;
        self.cur = comp.start + rep.len;
        if (comp.candidates.len == 1 and (rep.len == 0 or rep[rep.len - 1] != '/')) {
            self.insertBytes(" ");
        }
        self.vi_insert = true;
    }

    fn viExpandAll(self: *Editor) void {
        const f = self.complete_fn orelse {
            self.alert();
            return;
        };
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const stop = self.nextBoundary(self.cur);
        const comp = f(self.cb_ctx, arena.allocator(), self.buf.items, stop) catch return;
        if (comp.candidates.len == 0) {
            self.alert();
            return;
        }
        self.viSaveUndo();
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(self.gpa);
        for (comp.candidates, 0..) |cnd, i| {
            if (i > 0) joined.append(self.gpa, ' ') catch return;
            joined.appendSlice(self.gpa, cnd) catch return;
        }
        joined.append(self.gpa, ' ') catch return;
        self.buf.replaceRange(self.gpa, comp.start, stop - comp.start, joined.items) catch return;
        self.cur = comp.start + joined.items.len;
        self.vi_insert = true;
    }
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
