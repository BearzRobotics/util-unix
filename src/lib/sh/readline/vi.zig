// SPDX-License-Identifier: GPL-2.0-or-later
//! The vi mode of the line editor. Part of readline.zig: these are
//! methods of `Editor`, which declares each under its own name.

const std = @import("std");
const rl = @import("../readline.zig");
const Editor = rl.Editor;
const Allocator = std.mem.Allocator;
const Key = rl.Key;
const ViPending = rl.ViPending;
const addDigit = rl.addDigit;
const commonPrefix = Editor.commonPrefix;
const isBlank = rl.isBlank;
const isWordByte = rl.isWordByte;
const max_copies = rl.max_copies;
const max_count = rl.max_count;
const max_vi_depth = rl.max_vi_depth;
const pattern = @import("../pattern.zig");

// --- vi mode ----------------------------------------------------------------------------------
pub fn viMoveTo(self: *Editor, pos: usize) void {
    self.cur = pos;
}

/// In command mode the cursor sits on a character, not past the last.
pub fn viClamp(self: *Editor) void {
    if (self.vi_insert) return;
    if (self.buf.items.len == 0) {
        self.cur = 0;
        return;
    }
    if (self.cur >= self.buf.items.len) self.cur = self.prevBoundary(self.buf.items.len);
}

pub fn lastCharPos(self: *const Editor) usize {
    if (self.buf.items.len == 0) return 0;
    return self.prevBoundary(self.buf.items.len);
}

pub const WordKind = enum { word, big };

pub fn classOf(c: u8, kind: WordKind) u2 {
    if (isBlank(c)) return 0;
    if (kind == .big) return 1;
    return if (isWordByte(c)) 1 else 2;
}

pub fn viNextWord(self: *const Editor, from: usize, kind: WordKind) usize {
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

pub fn viPrevWord(self: *const Editor, from: usize, kind: WordKind) usize {
    const s = self.buf.items;
    var p = from;
    if (p == 0) return 0;
    p -= 1;
    while (p > 0 and classOf(s[p], kind) == 0) p -= 1;
    const cl = classOf(s[p], kind);
    while (p > 0 and classOf(s[p - 1], kind) == cl) p -= 1;
    return p;
}

pub fn viEndWord(self: *const Editor, from: usize, kind: WordKind) usize {
    const s = self.buf.items;
    var p = from;
    if (self.nextBoundary(p) >= s.len) return self.lastCharPos();
    p = self.nextBoundary(p);
    while (p < s.len and classOf(s[p], kind) == 0) p += 1;
    if (p >= s.len) return self.lastCharPos();
    const cl = classOf(s[p], kind);
    while (p + 1 < s.len and classOf(s[p + 1], kind) == cl) p += 1;
    // the last byte of the word: the cursor goes on its character's first
    return self.prevBoundary(p + 1);
}

pub const Target = struct { pos: usize, inclusive: bool };

/// The cursor position a motion key leads to, or null when it is not a
/// motion or fails.
pub fn viMotion(self: *Editor, c: u21, count: usize, have_count: bool, find_ch: ?u21) ?Target {
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

pub fn viFind(self: *Editor, kind: u8, ch: u21, count: usize) ?Target {
    self.vi_find = .{ .kind = kind, .ch = ch };
    return self.viFindRepeat(kind, ch, count);
}

pub fn viFindRepeat(self: *Editor, kind: u8, ch: u21, count: usize) ?Target {
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

pub fn viSaveUndo(self: *Editor) void {
    self.vi_undo_text.clearRetainingCapacity();
    self.vi_undo_text.appendSlice(self.gpa, self.buf.items) catch {};
    self.vi_undo_cur = self.cur;
    self.vi_changed = true;
    self.vi_changed_ever = true;
}

pub fn viDelete(self: *Editor, from: usize, to: usize, save: bool) void {
    if (to <= from) return;
    if (save) {
        self.vi_reg.clearRetainingCapacity();
        self.vi_reg.appendSlice(self.gpa, self.buf.items[from..to]) catch {};
    }
    self.buf.replaceRange(self.gpa, from, to - from, "") catch return;
    self.cur = from;
}

pub fn viOperate(self: *Editor, op: ViPending, from_in: usize, tgt: Target) void {
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

pub fn viKey(self: *Editor, k: Key) void {
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

pub fn viInsertKey(self: *Editor, k: Key) void {
    // The line being typed is a search pattern behind its `/` or `?`: keys
    // that would move in it, delete the `/` or fetch a history line do not apply.
    if (self.vi_search_mode) {
        if (k.kind == .char and !k.alt) self.viSearchInput(k.cp);
        return;
    }
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

pub fn viSearchInput(self: *Editor, c: u21) void {
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

pub fn viRunSearch(self: *Editor, pat_in: []const u8, fwd: bool) void {
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

pub fn viCommandKey(self: *Editor, k: Key) void {
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
            // ESC, ^C and Enter give the command up
            if (c != 27 and c != 3 and c != 13 and c != 10) self.viReplaceChars(c, count);
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

pub fn viReplaceChars(self: *Editor, c: u21, count: usize) void {
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

pub fn viHistory(self: *Editor, dir: isize, count: usize) void {
    const cur: isize = @intCast(self.hist_pos);
    const t = cur + dir * @as(isize, @intCast(count));
    if (t < 0 or t > @as(isize, @intCast(self.history.len))) {
        self.alert();
        return;
    }
    self.historyLoad(@intCast(t));
    self.cur = 0;
}

pub fn viWordStart(self: *const Editor) usize {
    var p = self.cur;
    const s = self.buf.items;
    while (p > 0 and !isBlank(s[p - 1])) p -= 1;
    return p;
}

pub fn viCompleteUnique(self: *Editor) void {
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

pub fn viExpandAll(self: *Editor) void {
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
