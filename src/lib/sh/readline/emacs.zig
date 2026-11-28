// SPDX-License-Identifier: GPL-2.0-or-later
//! The emacs mode's keys. Part of readline.zig: these are
//! methods of `Editor`, which declares each under its own name.

const std = @import("std");
const rl = @import("../readline.zig");
const Editor = rl.Editor;
const Key = rl.Key;
const addDigit = rl.addDigit;
const isBlank = rl.isBlank;
const max_copies = rl.max_copies;

pub fn emacsKey(self: *Editor, k: Key) void {
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
                self.emacsMeta(k.cp, &keep_kill, &keep_yank);
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

pub fn emacsMeta(self: *Editor, c: u21, keep_kill: *bool, keep_yank: *bool) void {
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
            // another M-y goes further round the ring
            keep_yank.* = true;
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

pub fn transpose(self: *Editor) void {
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

pub fn transposeWords(self: *Editor) void {
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
