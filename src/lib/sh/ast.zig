// SPDX-License-Identifier: GPL-2.0-or-later
//! Syntax tree of the POSIX shell command language (decision 0009).
//!
//! References: POSIX.1-2024 Shell Command Language, section 2.10 "Shell
//! Grammar". All nodes are allocated from the arena given to the parser and
//! live as long as that arena does.

const std = @import("std");

/// A word is a sequence of parts; the expander turns it into fields.
pub const Word = []const Part;

pub const Part = union(enum) {
    /// Unquoted literal text. Glob characters in it are active.
    text: []const u8,
    /// Literal text that was quoted (single quotes, double quotes, a
    /// backslash, or here-document text): never split, never a pattern.
    quoted: []const u8,
    /// `~` or `~user` at the start of a word (or after `=`/`:` in an
    /// assignment). The text is the user name, possibly empty.
    tilde: []const u8,
    /// A tilde-prefix after `=` or `:` of an assignment-looking word; only
    /// expanded in real assignments and `export`/`readonly` operands.
    atilde: []const u8,
    param: *const Param,
    cmdsub: CmdSub,
    arith: Arith,
};

pub const CmdSub = struct {
    body: ?*const Node,
    quoted: bool,
};

pub const Arith = struct {
    /// The expression, itself subject to expansion before evaluation.
    expr: Word,
    quoted: bool,
};

pub const ParamOp = enum {
    /// `$x`, `${x}`
    plain,
    /// `${#x}`
    length,
    /// `${x-w}` / `${x:-w}`
    use_default,
    /// `${x=w}` / `${x:=w}`
    assign_default,
    /// `${x?w}` / `${x:?w}`
    error_if_unset,
    /// `${x+w}` / `${x:+w}`
    use_alternate,
    /// `${x#p}`
    trim_prefix_small,
    /// `${x##p}`
    trim_prefix_large,
    /// `${x%p}`
    trim_suffix_small,
    /// `${x%%p}`
    trim_suffix_large,
    /// An unknown `${...}` form; like dash the error is raised when the word
    /// is expanded, not when it is parsed (`sh -n` accepts it).
    bad_subst,
};

pub const Param = struct {
    name: []const u8,
    op: ParamOp = .plain,
    /// True for the `:` forms: unset and empty both count as missing.
    colon: bool = false,
    /// The operand word (empty for `plain` and `length`).
    arg: Word = &.{},
    /// Inside double quotes: results are not split and `$@` keeps fields.
    quoted: bool = false,
};

pub const RedirOp = enum { in, out, append, clobber, dup_in, dup_out, read_write, heredoc };

pub const Redirect = struct {
    /// Explicit descriptor number, or null for the operator's default.
    fd: ?i32,
    op: RedirOp,
    /// File name, descriptor number or `-`; empty for here-documents.
    target: Word,
    /// Here-document body (already parsed; one `quoted` part when the
    /// delimiter was quoted).
    body: Word = &.{},
    line: u32 = 0,
};

pub const Assign = struct {
    name: []const u8,
    value: Word,
};

pub const Simple = struct {
    assigns: []const Assign,
    words: []const Word,
    redirs: []const *Redirect,
};

pub const ListItem = struct {
    node: *const Node,
    /// Terminated by `&`.
    background: bool,
};

pub const AndOrOp = enum { and_if, or_if };

pub const CaseItem = struct {
    patterns: []const Word,
    body: ?*const Node,
};

pub const Kind = union(enum) {
    simple: Simple,
    pipeline: struct { negate: bool, commands: []const *const Node },
    and_or: struct { left: *const Node, op: AndOrOp, right: *const Node },
    list: []const ListItem,
    subshell: ?*const Node,
    group: ?*const Node,
    redirected: struct { body: *const Node, redirs: []const *Redirect },
    if_clause: struct { cond: *const Node, then: ?*const Node, otherwise: ?*const Node },
    loop: struct { until: bool, cond: *const Node, body: ?*const Node },
    for_clause: struct { name: []const u8, words: ?[]const Word, body: ?*const Node },
    case_clause: struct { word: Word, items: []const CaseItem },
    function: struct { name: []const u8, body: *const Node },
};

pub const Node = struct {
    /// Line of the first token, for diagnostics.
    line: u32,
    kind: Kind,
    /// 1-based columns of the command word of a simple command (0 = unknown).
    col: u32 = 0,
    end_col: u32 = 0,
};

/// Result of parsing a whole source text.
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    /// Complete commands in order (each a `list` node).
    commands: []const *const Node,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }
};
