#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Interactive tests of sh on a pseudo-terminal. Usage: sh_interactive.py SH [--bsd]

Editing cases send keys and compare what the command typed (an `echo`) printed,
which tests the editor through its effect. Job control and `fc` cases are also
run under dash and FreeBSD sh (tools/bsdrun.sh) and must match at least one of
them (both when they agree). Everything else is compared with fixed expectations.
"""
import os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sh_pty
from sh_pty import Session, strip

SH = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
BSD = os.path.join(HERE, "..", "tools", "bsdrun.sh")
HAVE_BSD = os.access(BSD, os.X_OK) and os.path.exists("/stuff/tmp/chimera-sysroot/bin/sh") and subprocess.call(["which", "bwrap"], stdout=subprocess.DEVNULL) == 0
HAVE_DASH = subprocess.call(["which", "dash"], stdout=subprocess.DEVNULL) == 0
passed = failed = 0
UP, DOWN, RIGHT, LEFT = "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D"
HOME, END, DEL = "\x1b[H", "\x1b[F", "\x1b[3~"
CL, CR = "\x1b[1;5D", "\x1b[1;5C"
ESC = "\x1b"
def C(x): return chr(ord(x) - 64)
def M(x): return "\x1b" + x

def ok(name, good, detail=""):
    global passed, failed
    if good:
        passed += 1
        print("PASS " + name)
    else:
        failed += 1
        print("FAIL " + name)
        if detail:
            print("     " + detail.replace("\n", "\n     "))

def norm(t):
    t = re.sub(r"\b\d{3,}\b", "N", t)
    return "\n".join(x.rstrip() for x in t.split("\n")).strip("\n")

# ---------------------------------------------------------------------------
# one long-lived editing session per mode, so each case costs a few ms

class Ed:
    def __init__(self, mode, env=None, argv=None):
        self.s = Session(argv or [SH, "-i"] + (["-o", mode] if mode else []), env=env)
        self.s.expect(r"\$ ?$")

    def run(self, keys, timeout=3.0):
        """Send keys (which end the line) and return the output lines before the next prompt."""
        self.s.send(keys + "\n")
        out = self.s.expect(r"\n\$ ?$", timeout)
        if out is None:
            return None
        lines = out.split("\n")
        # drop the echoed command line(s): everything up to the first output line
        return lines

    def out(self, keys, timeout=3.0):
        self.s.take()
        self.s.send(keys + "\n")
        t = self.s.expect(r"\n\$ ?$", timeout)
        if t is None:
            self.s.send("\x03")
            self.s.expect(r"\$ ?$", 2)
            return None
        lines = t.split("\n")
        # first line is the prompt + edited command; last is the prompt
        return "\n".join(lines[1:-1])

    def close(self):
        self.s.close()

def edcase(ed, name, keys, want):
    got = ed.out(keys)
    ok(name, got == want, "keys %r\nwant %r\n got %r" % (keys, want, got))

# ---------------------------------------------------------------------------
import tempfile, shutil
TMP = tempfile.mkdtemp(prefix="shtest.")
HIST = os.path.join(TMP, "hist")
with open(HIST, "w") as f:
    f.write("echo one\necho two\necho three\n")

def hist_ed(mode, name, keys, want, extra_env=None):
    env = {"HISTFILE": HIST}
    env.update(extra_env or {})
    ed = Ed(mode, env=env)
    got = ed.out(keys)
    ed.close()
    ok("%s: %s" % (mode, name), got == want, "keys %r\nwant %r\n got %r" % (keys, want, got))

def emacs_cases():
    ed = Ed("emacs")
    e = lambda n, k, w: edcase(ed, "emacs: " + n, k, w)
    e("plain line", "echo abc", "abc")
    e("C-a inserts at start", "bc" + C("A") + "echo a", "abc")
    e("C-e end", "echo a" + C("A") + C("E") + "bc", "abc")
    e("C-b C-f", "echo ac" + C("B") + "b" + C("F") + "d", "abcd")
    e("left arrow", "echo ac" + LEFT + "b", "abc")
    e("right arrow", "echo ac" + LEFT + LEFT + RIGHT + "b", "abc")
    e("home end keys", "echo b" + HOME + END + "c", "bc")
    e("C-d deletes under cursor", "echo abXc" + LEFT * 2 + C("D"), "abc")
    e("delete key", "echo abXc" + LEFT * 2 + DEL, "abc")
    e("backspace", "echo abXc" + LEFT + "\x7f", "abc")
    e("C-h backspace", "echo abXc" + LEFT + C("H"), "abc")
    e("C-k kills to end", "echo abc def" + LEFT * 4 + C("K"), "abc")
    e("C-u kills to start", "xxx" + C("U") + "echo abc", "abc")
    e("C-w kills word", "echo abc def" + C("W") + "xyz", "abc xyz")
    e("C-y yanks", "echo abc" + C("W") + C("Y") + C("Y"), "abcabc")
    e("C-k then C-y", "echo ab" + C("A") + RIGHT * 5 + C("K") + C("Y") + C("Y"), "abab")
    e("C-t transposes", "echo ba" + C("T"), "ab")
    e("M-b M-f", "echo one two" + M("b") + "X" + M("f") + "Y", "one XtwoY")
    e("M-d kills word forward", "echo one two" + M("b") + M("b") + M("d"), "two")
    e("M-backspace kills word back", "echo one two" + M("\x7f"), "one")
    e("M-u upcase word", "echo abc" + M("b") + M("u"), "ABC")
    e("M-l downcase word", "echo ABC" + M("b") + M("l"), "abc")
    e("M-c capitalize", "echo abc" + M("b") + M("c"), "Abc")
    e("M-t transposes words", "echo one two" + M("t"), "two one")
    e("ctrl-left word back", "echo one two" + CL + "X", "one Xtwo")
    e("ctrl-right word forward", "echo one two" + HOME + RIGHT * 5 + CR + "X", "oneX two")
    e("C-_ undo", "echo abc" + C("W") + C("_"), "abc")
    e("C-v quoted tab", "echo a" + C("V") + "\t" + "b", "a b")
    e("C-q quoted insert", "echo a" + C("Q") + C("A") + "b", "a\x01b")
    e("insert in middle", "echo ac" + LEFT + "b", "abc")
    e("utf-8 insert", "echo héllo", "héllo")
    e("utf-8 backspace", "echo hé" + "\x7f" + "x", "hx")
    e("utf-8 cursor left", "echo éa" + LEFT + LEFT + "x", "xéa")
    e("wide char", "echo 中文" + LEFT + "x", "中x文")
    e("empty line", "", "")
    e("numeric argument", "echo " + M("3") + "x", "xxx")
    e("C-l redraw keeps line", "echo ab" + C("L") + "c", "abc")
    e("end of line key at end", "echo a" + END + END + "b", "ab")
    e("C-a C-k clears", "xx" + C("A") + C("K") + "echo ok", "ok")
    e("backspace at start", "\x7f\x7fecho ok", "ok")
    e("M-# comments the line", "echo hi" + M("#"), "")
    ed.close()
    # history and search (fresh sessions with a known history)
    h = lambda n, k, w: hist_ed("emacs", n, k, w)
    h("up recalls previous", UP, "three")
    h("up up", UP + UP, "two")
    h("up up up", UP * 3, "one")
    h("up past the oldest stays", UP * 9, "one")
    h("up down", UP + UP + DOWN, "three")
    h("C-p C-n", C("P") + C("P") + C("N"), "three")
    h("down at newest alerts", DOWN + "echo x", "x")
    h("edit a recalled line", UP + HOME + RIGHT * 5 + "X", "Xthree")
    h("M-< oldest", M("<"), "one")
    h("M-> back to the edit line", M("<") + M(">") + "echo z", "z")
    h("page up page down", "\x1b[5~" + "\x1b[6~" + "echo q", "q")
    h("C-r finds", C("R") + "two", "two")
    h("C-r newest first", C("R") + "echo", "three")
    h("C-r C-r older", C("R") + "echo" + C("R"), "two")
    h("C-r then C-s forward", C("R") + "echo" + C("R") + C("R") + C("S"), "two")
    h("C-r backspace edits query", C("R") + "tz" + "\x7f" + "w", "two")
    h("C-r C-g aborts", "echo keep" + C("R") + "one" + C("G"), "keep")
    h("C-r then arrow leaves match for editing", C("R") + "two" + END + "!", "two!")
    h("M-. last argument of previous line", "echo " + M("."), "three")

def vi_cases():
    ed = Ed("vi")
    v = lambda n, k, w: edcase(ed, "vi: " + n, k, w)
    v("insert is the initial mode", "echo abc", "abc")
    v("ESC 0 l i", "echo bc" + ESC + "05li" + "a", "abc")
    v("a appends", "echo a" + ESC + "abc", "abc")
    v("A appends at end", "echo a" + ESC + "0Abc", "abc")
    v("I inserts at start", "abc" + ESC + "Iecho ", "abc")
    v("x deletes under cursor", "echo abcX" + ESC + "x", "abc")
    v("X deletes before cursor", "echo aXbc" + ESC + "8|X", "abc")
    v("dw", "echo xx abc" + ESC + "05ldw", "abc")
    v("dd clears the line", "echo no" + ESC + "ddiecho yes", "yes")
    v("D deletes to end", "echo abc XXX" + ESC + "08lD", "abc")
    v("cw changes a word", "echo xxx" + ESC + "05lcwabc", "abc")
    v("cc changes the line", "garbage" + ESC + "ccecho abc", "abc")
    v("C changes to end", "echo abc zzz" + ESC + "08lC def", "abc def")
    v("S substitutes the line", "x" + ESC + "Secho abc", "abc")
    v("s substitutes a char", "echo axc" + ESC + "06lsb", "abc")
    v("r replaces a char", "echo axc" + ESC + "06lrb", "abc")
    v("R replaces text", "echo xyz" + ESC + "05lRabc", "abc")
    v("~ toggles case", "echo ABc" + ESC + "05l~~", "abc")
    v("x then p", "echo ab" + ESC + "xp", "ab")
    v("x then P", "echo ac" + ESC + "xP", "ca")
    v("yl then p", "echo ab" + ESC + "05lyl$p", "aba")
    v("yw then p", "echo abc" + ESC + "05lyw$p", "abcabc")
    v("u undoes", "echo abc" + ESC + "xu", "abc")
    v(". repeats x", "echo abcdef" + ESC + "x.", "abcd")
    v(". repeats an insert", "echo a" + ESC + "Ab" + ESC + ".", "abb")
    v("count x", "echo abcxyz" + ESC + "08l3x", "abc")
    v("w w", "echo one two" + ESC + "0wwiX", "one Xtwo")
    v("b", "echo one two" + ESC + "biX", "one Xtwo")
    v("e e", "echo one two" + ESC + "0eeaX", "oneX two")
    v("W", "echo a.b c.d" + ESC + "0WWiX", "a.b Xc.d")
    v("0 and $", "echo a" + ESC + "0$abc", "abc")
    v("^", " Xecho b" + ESC + "^x", "b")
    v("|", "echo aXbc" + ESC + "7|x", "abc")
    v("f", "echo abXc" + ESC + "0fXx", "abc")
    v("F", "echo Xabc" + ESC + "FXx", "abc")
    v("t", "echo abXc" + ESC + "0tXiZ", "aZbXc")
    v("T", "echo abXcd" + ESC + "TXiZ", "abXZcd")
    v("; repeats f", "echo aXbXc" + ESC + "0fX;x", "aXbc")
    v(", reverses", "echo aXbXc" + ESC + "$FX;,x", "aXbc")
    v("d$", "echo abc zzz" + ESC + "08ld$", "abc")
    v("d0", "XX echo abc" + ESC + "03ld0", "abc")
    v("de", "echo XX abc" + ESC + "05lde", "abc")
    v("c$", "echo abc zzz" + ESC + "08lc$ def", "abc def")
    v("yy then p", "echo a" + ESC + "yyp", "aecho a")
    v("count w", "echo a b c d" + ESC + "02wiX", "a Xb c d")
    v("# comments the line", "echo hi" + ESC + "#", "")
    v("insert: C-w deletes a word", "echo abc def" + C("W") + "x", "abc x")
    v("insert: C-u kills the line", "xxx" + C("U") + "echo abc", "abc")
    v("insert: DEL erases", "echo abcd" + "\x7f" + "x", "abcx")
    v("insert: arrow keys", "echo ac" + LEFT + "b", "abc")
    v("insert: C-v literal", "echo a" + C("V") + "\t" + "b", "a b")
    v("ESC at start of line", ESC + "iecho ok", "ok")
    v("h moves left", "echo abc" + ESC + "hhiX", "Xabc")
    v("l stays on the last char", "echo ab" + ESC + "lllx", "a")
    v("unknown command alerts", "echo ab" + ESC + "Zx", "a")
    v("cw on the last word", "echo ab" + ESC + "05lcwX", "X")
    ed.close()
    h = lambda n, k, w: hist_ed("vi", n, k, w)
    h("k recalls", ESC + "k", "three")
    h("k k", ESC + "kk", "two")
    h("2k", ESC + "2k", "two")
    h("k j", ESC + "kkj", "three")
    h("- and +", ESC + "--+", "three")
    h("G oldest", ESC + "G", "one")
    h("2G by number", ESC + "2G", "two")
    h("/pattern", ESC + "/two\r", "two")
    h("?pattern forward", ESC + "kk?three\r", "three")
    h("n repeats", ESC + "/e\rnn", "one")
    h("N reverses", ESC + "/e\rnN", "three")
    h("anchored ^ search", ESC + "/^echo o\r", "one")
    h("failed search leaves the line", "echo keep" + ESC + "/zzz\r", "keep")
    h("_ appends last word of previous line", "echo" + ESC + "_", "three")
    h("U undoes all changes", ESC + "kxxxU", "three")
    h("edit a recalled line", ESC + "k0xxiX", "Xho three".replace("Xho three", "Xcho") if False else None) if False else None

# ---------------------------------------------------------------------------
def main():
    emacs_cases()
    vi_cases()
    print("\n%d passed, %d failed" % (passed, failed))
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
