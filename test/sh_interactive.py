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

SH = os.path.abspath(sys.argv[1])
HERE = os.path.dirname(os.path.abspath(__file__))
BSD = os.path.join(HERE, "..", "tools", "bsdrun.sh")
HAVE_BSD = os.access(BSD, os.X_OK) and os.path.exists(os.path.join(os.environ.get("CHIMERA_ROOT", "/stuff/tmp/chimera-sysroot"), "bin/sh")) and subprocess.call(["which", "bwrap"], stdout=subprocess.DEVNULL) == 0
HAVE_DASH = subprocess.call(["which", "dash"], stdout=subprocess.DEVNULL) == 0
passed = failed = 0
COLLAPSE = False
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
    t = re.sub(r"(?m)^(\S*/)?(dash|sh): (\d+: )?", "", t)
    t = re.sub(r"(?<=\S) {2,}", " ", t) if COLLAPSE else t
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

    def out(self, keys, timeout=3.0, enter="\n"):
        self.s.take()
        self.s.send(keys + enter)
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

def edcase(ed, name, keys, want, enter="\n"):
    got = ed.out(keys, enter=enter)
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
    e = lambda n, k, w, **kw: edcase(ed, "emacs: " + n, k, w, **kw)
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
    e("M-# comments the line", "echo hi" + M("#"), "", enter="")
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
    v = lambda n, k, w, **kw: edcase(ed, "vi: " + n, k, w, **kw)
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
    v("# comments the line", "echo hi" + ESC + "#", "", enter="")
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

# ---------------------------------------------------------------------------
# transcripts compared with dash and FreeBSD sh

def transcript(argv, steps, cwd=None, env=None, settle=0.35):
    out = ""
    with Session(argv, env=env, cwd=cwd) as s:
        s.expect(r"\$ ?$")
        s.take()
        for st in steps:
            if st == "^Z":
                s.send("\x1a")
            elif st == "^C":
                s.send("\x03")
            elif isinstance(st, tuple):
                time.sleep(st[1])
                continue
            else:
                s.send(st + "\n")
            s.settle(settle)
        s.settle(0.2)
        out = s.take()
    if out.startswith("$ "):
        out = out[2:]
    return norm(out)

def diffcase(name, steps, shells=("dash", "bsd"), env=None, cwd=None, must=None, collapse=False):
    """Ours must equal the transcript of dash or FreeBSD sh (when both ran and
    agree, ours must equal that one)."""
    global COLLAPSE
    COLLAPSE = collapse
    ours = transcript([SH, "-i"], steps, cwd=cwd, env=dict(env or {}, SH_DIAGNOSTICS="posix"))
    refs = {}
    if "dash" in shells and HAVE_DASH:
        refs["dash"] = transcript(["dash", "-i"], steps, cwd=cwd, env=env)
    if "bsd" in shells and HAVE_BSD:
        refs["bsd"] = transcript([BSD, "/bin/sh", "-i"], steps, cwd=cwd, env=env)
    if not refs:
        print("SKIP %s (no reference shell)" % name)
        return
    good = ours in refs.values()
    if len(set(refs.values())) == 1:
        good = ours == list(refs.values())[0]
    detail = "ours:\n%s" % ours + "".join("\n%s:\n%s" % (k, v) for k, v in refs.items())
    ok("diff: " + name, good, detail)

def job_cases():
    d = diffcase
    d("jobs with no jobs", ["jobs"])
    d("background job listed", ["sleep 30 &", "jobs", "kill %1", ("w", .4), "jobs"])
    d("jobs -l and -p", ["sleep 31 &", "jobs -l", "jobs -p", "kill %1", ("w", .4), "jobs"])
    d("current and previous markers", ["sleep 32 &", "sleep 33 &", "jobs", "kill %1 %2", ("w", .4)])
    d("fg, stop, bg, kill", ["sleep 34 &", "fg", "^Z", "jobs", "bg", "jobs", "kill %1", ("w", .4), "jobs"])
    d("job spec %%, %+, %-", ["sleep 35 &", "sleep 36 &", "jobs %%", "jobs %+", "jobs %-", "jobs %1", "kill %1 %2", ("w", .4)])
    d("job spec %string", ["sleep 37 &", "sleep 38 &", "jobs %sleep\\ 37", "jobs %?38", "kill %1 %2", ("w", .4)])
    d("fg with no job", ["fg"])
    d("bg with no job", ["bg"])
    d("fg %9", ["fg %9"])
    d("bg %9", ["bg %9"])
    d("kill %9", ["kill %9"])
    d("wait %9", ["wait %9"])
    d("jobs %9", ["jobs %9"])
    d("finished job is announced", ["true &", ("w", .4), "", "jobs"])
    d("failed job announced with status", ["false &", ("w", .4), "", "jobs"])
    d("exit status of a background job", ["(exit 3) &", "wait $!", "echo $?"])
    d("pipeline as one job", ["sleep 39 | sleep 40 &", "jobs", "jobs -l", "kill %1", ("w", .4), "jobs"])
    d("$! after &", ["sleep 41 &", "echo $! | grep -c '^[0-9][0-9]*$'", "kill %1", ("w", .4), "jobs"])
    d("status of a stopped foreground job", ["sleep 42", "^Z", "echo $?", "kill %1", ("w", .4), "jobs"])
    d("exit warns about stopped jobs", ["sleep 43", "^Z", "exit", "jobs", "kill -CONT %1", "kill %1", ("w", .4), "jobs"])
    d("wait for all", ["sleep 0.5 &", "wait", "echo done"])
    d("fg by spec", ["sleep 44 &", "sleep 45 &", "fg %1", "^Z", "jobs", "kill %1 %2", ("w", .4)])
    # dash does not notice that a stopped job was continued and still says
    # Stopped, so the expectation is fixed rather than a reference's
    has("kill -CONT resumes", ["sleep 46", "^Z", "kill -CONT %1", ("w", .3), "jobs", "kill %1"], ["+ Running"])
    d("killed by signal reported", ["sleep 47 &", "kill -9 %1", ("w", .4), "jobs"])
    d("two stops, current moves", ["sleep 48", "^Z", "sleep 49", "^Z", "jobs", "kill %1 %2", "kill -CONT %1 %2", ("w", .4)])
    d("flags show i and m", ["echo $- | grep -c i", "echo $- | grep -c m"])
    d("bg prints the job", ["sleep 50", "^Z", "bg", "kill %1", ("w", .4), "jobs"])
    d("subshell as a job", ["(sleep 51; echo x) &", "jobs", "kill %1", ("w", .4), "jobs"])
    d("set +m then background", ["set +m", "sleep 52 &", "jobs", "kill %1"], shells=("bsd",), collapse=True)

def fc_cases():
    hist = ["echo one", "echo two", "echo three"]
    def f(name, more, shells=("bsd",), env=None):
        diffcase("fc " + name, hist + more, shells=shells, env=env, cwd=TMP)
    f("-l", ["fc -l"])
    f("-ln", ["fc -ln"])
    f("-lr", ["fc -lr"])
    f("-l range", ["fc -l 1 2"])
    f("-l negative", ["fc -l -2"])
    f("-l negative range", ["fc -l -3 -1"])
    f("-l by string", ["fc -l echo"])
    f("-l reversed range", ["fc -l 3 1"])
    f("-l single", ["fc -l 2 2"])
    f("-lnr", ["fc -lnr"])
    f("-s repeats the last command", ["fc -s"])
    f("-s by prefix", ["fc -s echo"])
    f("-s old=new", ["fc -s three=drei echo"])
    f("-s number", ["fc -s 1"])
    f("-e - is -s", ["fc -e -"])
    f("-e with an editor", ["fc -e ./ed.sh 1"])
    f("FCEDIT", ["fc 2"], env={"FCEDIT": "./ed.sh"})
    f("unknown pattern", ["fc -l nosuch"])
    f("illegal option", ["fc -x"])
    f("-l after fc -s", ["fc -s", "fc -l"])
    f("HISTSIZE", ["HISTSIZE=2", "echo four", "fc -l"])
    f("history does not list fc itself", ["fc -l", "fc -l"])
    f("-r with edit range", ["fc -lr 2 3"])

# ---------------------------------------------------------------------------
# prompts, startup, signals, completion, paste, rendering: fixed expectations

def run_steps(steps, env=None, argv=None, cwd=None, rows=24, cols=80, wait=0.3):
    with Session(argv or [SH, "-i"], env=env, cwd=cwd, rows=rows, cols=cols) as s:
        s.expect(r"\$ ?$|> ?$|#.*$", 3)
        s.take()
        for st in steps:
            if st == "^Z": s.send("\x1a")
            elif st == "^C": s.send("\x03")
            elif st == "^D": s.send("\x04")
            elif st == "^\\": s.send("\x1c")
            elif isinstance(st, tuple): time.sleep(st[1]); continue
            elif st.startswith("raw:"): s.send(st[4:])
            else: s.send(st + "\n")
            s.settle(wait)
        s.settle(0.2)
        return s.take()

def has(name, steps, want=(), absent=(), **kw):
    out = run_steps(steps, **kw)
    good = all(w in out for w in want) and not any(a in out for a in absent)
    ok(name, good, "want %r absent %r\nscreen:\n%s" % (want, absent, out))

# `has` sees the echo of the typed keys too, so what a case expects must be text
# the shell has to compute: ALIVE prints "al1ve", which is never typed.
ALIVE = "echo al$((1))ve"

def exit_status(s, timeout=4.0):
    """The shell's exit status once it has left on its own, else None."""
    end = time.time() + timeout
    while time.time() < end:
        pid, st = os.waitpid(s.pid, os.WNOHANG)
        if pid == s.pid:
            return os.waitstatus_to_exitcode(st)
        s._read(0.05)
    return None

def leaves(name, keys, want_status, env=None, want=()):
    with Session([SH, "-i"], env=env) as s:
        s.expect(r"\$ ?$"); s.take()
        for k in keys:
            s.send(k); s.settle(.3)
        got = exit_status(s)
        screen = s.take()
        ok(name, got == want_status and all(w in screen for w in want), "status %r, screen:\n%s" % (got, screen))

def ignored_signals(pid):
    with open("/proc/%d/status" % pid) as f:
        for l in f:
            if l.startswith("SigIgn:"):
                return int(l.split()[1], 16)
    return 0

def input_and_history_cases():
    # SHI-02: what follows an Enter in the same write is not thrown away
    has("two commands in one write", ["raw:echo first$((1))\recho second$((2))\recho third$((3))\r"], ["first1", "second2", "third3"])
    has("typing ahead while a command runs", ["raw:sleep 1\r", "raw:echo A$((1))\recho B$((2))\recho C$((3))\r", ("sleep", 1.5)], ["A1", "B2", "C3"])
    has("typed ahead lines reach a command that reads", ["raw:read v; echo got-$v-$((1+1))\rtyped\n"], ["got-typed-2"])

    # SHI-06: ^C abandons the line in every vi state
    vi = [SH, "-i", "-o", "vi"]
    for name, keys in (("command mode", ["raw:echo no$((1))run", "raw:\x1b", "^C"]),
                       ("search mode", ["raw:echo no$((1))run", "raw:\x1b", "raw:/ab", "^C"]),
                       ("a pending operator", ["raw:echo no$((1))run", "raw:\x1bd", "^C"])):
        has("vi ^C cancels the line from " + name, keys + ["raw:\r", ALIVE], ["al1ve"], ["no1run"], argv=vi)
    leaves("vi ^D on an empty line in command mode leaves", ["set -o vi\r", "\x1b", "\x04"], 0)

    # SHI-07: a failed edit runs nothing
    for editor in ("false", "no-such-editor-here"):
        d = tempfile.mkdtemp(dir=TMP)
        mark = os.path.join(d, "EXECUTED")
        has("vi v with a failing editor runs nothing (%s)" % editor, ["raw:touch %s" % mark, "raw:\x1b", "raw:v", ("sleep", 0.5), ALIVE], ["al1ve"], argv=vi, env={"EDITOR": editor, "VISUAL": editor})
        ok("vi v with a failing editor leaves no trace (%s)" % editor, not os.path.exists(mark))

    # SHI-01: ignoreeof gives up after ten ends of input in a row
    with Session([SH, "-i", "-o", "ignoreeof"]) as s:
        s.expect(r"\$ ?$"); s.take()
        for _ in range(11):
            s.send("\x04"); s.settle(.15)
        ok("ignoreeof leaves at the eleventh ^D", exit_status(s) == 0, s.take())
    with Session([SH, "-i", "-o", "ignoreeof"]) as s:
        s.expect(r"\$ ?$"); s.take()
        for _ in range(3):
            for _ in range(7):
                s.send("\x04"); s.settle(.15)
            s.send(ALIVE + "\r"); s.settle(.3)
        ok("ignoreeof starts counting again after input", exit_status(s, .5) is None and "al1ve" in s.take())
    try:
        p = subprocess.run([SH, "-i", "-o", "ignoreeof"], input=b"", capture_output=True, timeout=20)
        ok("ignoreeof ends when input is at end of file", p.stderr.count(b'to leave shell') == 10, "%d messages" % p.stderr.count(b"to leave shell"))
    except subprocess.TimeoutExpired:
        ok("ignoreeof ends when input is at end of file", False, "still running after 20 s")

    # SHI-03: re-running the oldest entry of a full history
    has("fc -s of the oldest entry when history is full",
        ["HISTSIZE=3", "echo first$((1+1))-$((2+2))aaaaaaaaaaaaaaaaaaaaaaaa", "echo b", "echo c", "fc -s first", ALIVE],
        ["first2-4aaaaaaaaaaaaaaaaaaaaaaaa\n$", "al1ve"])

    # MEM-02: bytes that are not UTF-8, from the history file or a file name
    d = tempfile.mkdtemp(dir=TMP)
    with open(os.path.join(d, "hist"), "wb") as f:
        f.write(b"echo caf\xe9\n")
    has("recalling a history line that is not UTF-8", ["raw:\x1b[A", "raw:\x15", ALIVE], ["al1ve"], env={"HISTFILE": os.path.join(d, "hist")})
    open(os.path.join(os.fsencode(d), b"caf\xe9"), "wb").close()
    has("completing a file name that is not UTF-8", ["raw:ls caf\t", "raw:\r", ALIVE], ["al1ve"], cwd=d)

    # SHX-05: `set -m` in a script gives the terminal back
    dash = "/usr/bin/dash"
    for name, inner in (("at exit", "set -m; :"), ("at set +m", "set -m; set +m"), ("after a foreground job", "set -m; true; sleep 0")):
        with Session([dash, "-c", "%s -c '%s'; read x; echo parent-got-$x-$((1+1))" % (SH, inner)]) as s:
            s.settle(.8); s.send("hello\r")
            ok("set -m in a script gives the terminal back " + name, s.expect("parent-got-hello-2", 6) is not None, s.take())

    # JOB-05: an interactive shell started in the background waits its turn
    has("sh -i in the background does not take the terminal", ["%s -i &" % SH, ("sleep", 1), ALIVE, "jobs", "kill -KILL %1", ALIVE], ["al1ve", "Stopped"])

    # JOB-04: ^Z cannot stop what the shell could never continue. The shell
    # under test runs under another one: the system discards ^Z for the group of
    # a session leader, which has nobody outside it to continue it.
    for name, steps, want in (
        ("a command substitution", ["x=$(sleep 2; echo hi); echo got-$x-$((1+1))"], "got-hi-2"),
        ("a pipeline in a substitution", ["echo got-$(sleep 2 | cat)end-$((1+1))"], "got-end-2"),
        ("a command after set +m", ["set +m", "sleep 2; echo done-$((1+1))"], "done-2")):
        has("^Z during " + name + " does not hang the shell", ["%s -i" % SH] + steps + [("sleep", .7), "^Z", ("sleep", 2.5), ALIVE], [want, "al1ve"])

    # JOB-02: ^C abandons what the shell itself is doing
    NO = "NOT-CANCELLED-$((1+1))"
    for name, line in (("a loop of builtins", "while :; do :; done; echo " + NO),
                       ("read", "read x; echo " + NO),
                       ("wait", "sleep 7 & wait; echo " + NO),
                       ("a loop in a function", "f() { while :; do :; done; echo " + NO + "; }; f; echo " + NO),
                       ("a sourced loop in eval", "eval 'while true; do x=1; done'; echo " + NO)):
        has("^C abandons " + name, [line, ("sleep", .6), "^C", ("sleep", .4), "echo status=$?", ALIVE], ["status=130", "al1ve"], ["NOT-CANCELLED-2"])
    has("^C with an INT trap runs the trap and goes on", ["trap 'echo caught-$((1+1))' INT", "read x; echo after-$?-$((2+2))", ("sleep", .6), "^C", "typed", ALIVE], ["caught-2", "al1ve"])

    # JOB-03: ^C that kills a foreground job stops what surrounds it
    for name, line in (("the rest of the line", "sleep 5; echo " + NO),
                       ("a while loop", "while :; do sleep 1; done; echo " + NO),
                       ("a for loop", "for i in 1 2 3; do sleep 1; echo " + NO + "; done"),
                       ("an and-list", "sleep 5 || echo " + NO),
                       ("a command given a substitution", "echo " + NO + " $(sleep 5)")):
        has("^C on a job abandons " + name, [line, ("sleep", .6), "^C", ("sleep", .4), "echo status=$?", ALIVE], ["status=130", "al1ve"], ["NOT-CANCELLED-2\n"])
    has("^C on a job runs the INT trap", ["trap 'echo caught-$((1+1))' INT", "sleep 5", ("sleep", .6), "^C", ("sleep", .4), ALIVE], ["caught-2", "al1ve"])
    with Session([SH, "-c", "set -m; sleep 5; echo NOT-CANCELLED-$((1+1))"]) as s:
        s.settle(.8); s.send("\x03")
        ok("^C on a job ends a script with set -m", exit_status(s) in (-2, 130) and "CANCELLED-2" not in s.take())

    # SHI-14, SHI-29: numbers too large to repeat or to negate
    for name, keys in (("emacs motion", "\x1b9" * 21 + "\x02"),
                       ("emacs insert", "\x1b9" * 9 + "x\x15"),
                       ("emacs meta command", "\x1b9" * 21 + "\x1bf")):
        has("huge %s count" % name, ["raw:" + keys, "raw:\x15", ALIVE], ["al1ve"], ["panic"])
    for name, keys in (("motion", "9" * 21 + "l"), ("operator and motion", "9" * 9 + "d" + "9" * 12 + "l"), ("replace", "9" * 21 + "~")):
        has("huge vi %s count" % name, ["set -o vi", "raw:echo\x1b" + keys + "dd", "", ALIVE], ["\nal1ve\n"], ["panic", "not found"])
    has("huge vi put count", ["set -o vi", "raw:x\x1byy" + "9" * 9 + "pdd", "", ALIVE], ["\nal1ve\n"], ["panic", "not found"])
    has("fc -l with the smallest integer", ["fc -l -9223372036854775808", ALIVE], ["al1ve"], ["panic"])

    # SHI-13: control characters in a file name or a line are shown, not sent
    d = tempfile.mkdtemp(dir=TMP)
    for n in ("f\x1b]0;PWNED\x07x", "fz\u009d0;C1\u009c"):
        open(os.path.join(d, n), "w").close()
    with Session([SH, "-i"], cwd=d) as s:
        s.expect(r"\$ ?$"); s.take()
        s.send("ls f"); s.send("\t\t"); s.settle(.6)
        listed = s.raw
        # (completion also puts backslashes in the names it lists)
        ok("completion list shows control characters", "PWNED^G" in listed and "~]" in listed and "PWNED\x07" not in listed and "\u009d" not in listed and "\u009c" not in listed, repr(listed[-400:]))
    with Session([SH, "-i"]) as s:
        s.expect(r"\$ ?$"); s.take()
        s.send(": \u009b31m"); s.settle(.6)
        ok("the edited line shows C1 controls", "\u009b" not in s.raw and "~[" in s.raw, repr(s.raw[-200:]))

    # SHI-21: an fc that selects itself
    has("fc -s that re-runs itself stops", ["echo a", "fc -s 2", "fc -s 2", ("sleep", .5), ALIVE], ["re-runs itself", "al1ve"])

    # SHI-05: ENV may set HISTFILE and HISTSIZE without losing saved history
    def history_after(lines, env_extra, rc):
        d = tempfile.mkdtemp(dir=TMP)
        hist = os.path.join(d, "hist")
        with open(hist, "w") as f:
            f.write("".join("echo old%d\n" % i for i in range(lines)))
        rcpath = os.path.join(d, "rc")
        with open(rcpath, "w") as f:
            f.write(rc.replace("@H@", hist))
        env = {"ENV": rcpath, **{k: v.replace("@H@", hist) for k, v in env_extra.items()}}
        run_steps(["echo new", "exit"], env=env)
        with open(hist) as f:
            return f.read().split("\n")
    got = history_after(5, {}, "HISTFILE=@H@\n")
    ok("HISTFILE set in ENV keeps the saved history", "echo old0" in got and "echo new" in got, repr(got))
    got = history_after(500, {"HISTFILE": "@H@"}, "HISTSIZE=1000\n")
    ok("HISTSIZE set in ENV applies when history is loaded", "echo old0" in got and len(got) >= 502, "%d lines" % len(got))

    # INFO-16: started as "-sh", as login(1) does, it is a login shell
    d = tempfile.mkdtemp(dir=TMP)
    with open(os.path.join(d, ".profile"), "w") as f:
        f.write("echo from-$((1))-profile\n")
    for argv0, want in (("-sh", True), ("sh", False)):
        r = subprocess.run([argv0], executable=SH, input=b"echo hi\n", capture_output=True, timeout=10, env={"PATH": os.environ["PATH"], "HOME": d})
        ok("started as '%s' it %s ~/.profile" % (argv0, "reads" if want else "does not read"), (b"from-1-profile" in r.stdout) == want and b"hi" in r.stdout, repr((r.returncode, r.stdout, r.stderr)))

    # SHX-08: only ^C and trapped signals end a wait
    has("a resize does not end wait", ["sleep 2 &", "(sleep .5; kill -WINCH $$; sleep .5) & wait %1; echo st=$?-$((1+1))", ("sleep", 2.5), ALIVE], ["st=0-2", "al1ve"])
    has("a trapped signal still ends wait", ["trap 'echo got-$((1+1))' USR1", "sleep 3 & p=$!; (sleep .5; kill -USR1 $$; sleep .5) & wait $p; echo st=$?-$((1+1))", ("sleep", 1.5), ALIVE], ["got-2", "st=138-2", "al1ve"])

    # SHX-10: a failed exec leaves the traps in place
    for how in ("exec", "command exec"):
        has("a failed '%s' keeps traps" % how, ["trap 'echo got-$((1+1))' USR1", how + " /no/such/program", "kill -USR1 $$", ("sleep", .5), ALIVE], ["got-2", "al1ve"])

    # SHI-18: saving the history
    d = tempfile.mkdtemp(dir=TMP)
    real, link = os.path.join(d, "real"), os.path.join(d, "link")
    with open(real, "w") as f:
        f.write("echo old\n")
    os.chmod(real, 0o644)
    os.symlink("real", link)
    with Session([SH, "-i"], env={"HISTFILE": link}) as a, Session([SH, "-i"], env={"HISTFILE": link}) as b:
        for s_, line in ((a, "echo from-A"), (b, "echo from-B")):
            s_.expect(r"\$ ?$"); s_.send(line + "\n"); s_.settle(.3)
        a.send("exit\n"); exit_status(a)
        b.send("exit\n"); exit_status(b)
    kept = open(real).read().split("\n")
    ok("two shells keep each other's history", all(x in kept for x in ("echo old", "echo from-A", "echo from-B")) and kept.count("echo old") == 1, repr(kept))
    ok("a HISTFILE that is a link stays one, and is made private", os.path.islink(link) and os.stat(real).st_mode & 0o777 == 0o600 and sorted(os.listdir(d)) == ["link", "real"], "%o %r" % (os.stat(real).st_mode, os.listdir(d)))

    fifo = os.path.join(d, "fifo")
    os.mkfifo(fifo)
    has("a FIFO as HISTFILE does not block the shell", [ALIVE, "exit"], ["al1ve", "not a regular file"], env={"HISTFILE": fifo})
    has("a history that cannot be saved is reported", [ALIVE, "exit"], ["al1ve", "cannot save the history"], env={"HISTFILE": "/nonexistent-dir/hist"})
    has("HISTFILE=/dev/null is quiet", [ALIVE, "exit"], ["al1ve"], ["cannot save", "regular"], env={"HISTFILE": "/dev/null"})

def prompt_cases():
    has("PS1 parameter expansion", ["PS1='$((1+1))> '", "echo hi"], ["2> echo hi"])
    has("PS1 command substitution", ["PS1='$(echo X)> '", "echo hi"], ["X> echo hi"])
    has("PS1 history number", ["PS1='! '", "echo a", "echo b"], ["2 echo a"])
    has("PS1 !! is a literal !", ["PS1='!!> '", "echo a"], ["!> echo a"], ["!!> echo a"])
    has("PS1 expands variables", ["X=zz", "PS1='$X> '", "echo a"], ["zz> echo a"])
    has("PS2 continuation after a quote", ["echo 'a", "b'"], ["> b'", "a\nb"], argv=[SH, "-i"])
    has("custom PS2", ["PS2='more: '", "echo 'a", "b'"], ["more: b'"])
    has("PS2 for here-document", ["cat <<EOF", "line1", "EOF"], ["> line1", "> EOF"], absent=[])
    has("here-document body is passed", ["cat <<EOF", "line1", "EOF"], ["> EOF\nline1\n$"])
    has("PS2 after backslash", ["echo a\\", "b"], ["> b", "ab"])
    has("PS2 inside if", ["if true; then", "echo yes", "fi"], ["> echo yes", "\nyes"])
    has("PS2 inside a function definition", ["f() {", "echo in f", "}", "f"], ["> echo in f", "in f\n"])
    has("loop over lines", ["for i in 1 2; do", "echo $i", "done"], ["1\n", "2\n"])
    has("syntax error keeps the shell", ["echo )", ALIVE], ["al1ve"])
    has("special builtin error keeps the shell", ["shift 9", ALIVE], ["al1ve"])
    has("readonly assignment keeps the shell", ["readonly r=1", "r=2", ALIVE], ["al1ve"])
    has("expansion error keeps the shell", ["echo ${x?msg}", ALIVE], ["al1ve"])
    has("dot of a missing file keeps the shell", [". /nonexistent/file", ALIVE], ["al1ve"])
    has("$- has i", ["echo $-"], ["i"])
    leaves("exit status", ["exit 3\n"], 3)
    out = run_steps(["set -o"])
    ok("set -o shows monitor on", re.search(r"(?m)^monitor +on$|^set -o monitor$", out) is not None, out)
    ok("set -o emacs is the default", re.search(r"(?m)^emacs +on$|^set -o emacs$", out) is not None, out)
    has("PS4 in xtrace", ["PS4='TRACE '", "set -x", "echo hi"], ["TRACE echo hi"])
    has("ignoreeof", ["set -o ignoreeof", "^D", ALIVE], ["Use \"exit\" to leave shell.", "al1ve"])
    has("prompt for a failed command substitution", ["PS1='$(false)> '", "echo a"], ["> echo a"])
    has("$0 names the shell", ["echo zero=$0"], ["zero=" + SH])
    # ENV and HISTFILE
    envf = os.path.join(TMP, "envfile")
    open(envf, "w").write("PS1='ENV> '\nENVRAN=1\n")
    has("ENV file is run", ["echo $ENVRAN"], ["ENV> echo $ENVRAN", "1"], env={"ENV": envf})
    open(os.path.join(TMP, "envrel"), "w").write("echo hi\n")
    has("ENV that is not absolute is ignored", ['echo "[$ENVRAN]"'], ["[]"], ["ENV> "], env={"ENV": "envfile"}, cwd=TMP)
    has("ENV expands parameters", ["echo $ENVRAN"], ["ENV> "], env={"ENV": "$HOME/envfile", "HOME": TMP})
    # HISTFILE save and load
    hf = os.path.join(TMP, "histsave")
    if os.path.exists(hf): os.unlink(hf)
    with Session([SH, "-i"], env={"HISTFILE": hf}) as s:
        s.expect(r"\$ ?$")
        s.send("echo saved1\n"); s.settle(.3)
        s.send("echo saved2\n"); s.settle(.3)
        s.send("exit\n"); s.settle(.5)
    saved = open(hf).read() if os.path.exists(hf) else ""
    ok("HISTFILE is written at exit", "echo saved1\necho saved2\nexit" in saved or "echo saved1\necho saved2\n" in saved, repr(saved))
    has("HISTFILE is read at start", ["fc -l"], ["echo saved1", "echo saved2"], env={"HISTFILE": hf})
    has("up arrow recalls the file's history", ["raw:" + UP + UP + "\n"], ["saved2"], env={"HISTFILE": hf})
    has("HISTSIZE limits the history", ["fc -l"], ["echo saved2"], ["echo saved1"], env={"HISTFILE": hf, "HISTSIZE": "3"})
    # input that is not a terminal
    p = subprocess.run([SH, "-i"], input=b"echo a\necho b\nexit 4\n", capture_output=True, env={"PATH": os.environ["PATH"], "PS1": "P> ", "ENV": "/dev/null"})
    ok("-i with piped input: prompts go to stderr", p.stdout == b"a\nb\n" and b"P> " in p.stderr and p.returncode == 4, repr((p.stdout, p.stderr, p.returncode)))
    p = subprocess.run([SH, "-i"], input=b"cat <<EOF\nx\nEOF\n", capture_output=True, env={"PATH": os.environ["PATH"], "PS1": "P> ", "PS2": "C> ", "ENV": "/dev/null"})
    ok("-i with piped input: PS2 for a here-document", p.stdout == b"x\n" and p.stderr.count(b"C> ") == 2, repr(p.stderr))
    p = subprocess.run([SH, "-i"], input=b"read x\nhello\necho got $x\n", capture_output=True, env={"PATH": os.environ["PATH"], "ENV": "/dev/null"})
    ok("-i with piped input: read takes the next line", b"got hello" in p.stdout, repr(p.stdout))
    p = subprocess.run([SH, "-i", "--diagnostics=posix"], input=b"echo x\n", capture_output=True, env={"PATH": os.environ["PATH"], "ENV": "/dev/null"})
    ok("-i without a terminal says job control is off", b"job control turned off" in p.stderr, repr(p.stderr))
    p = subprocess.run([SH, "-i", "--diagnostics=rich"], input=b"echo x\n", capture_output=True, env={"PATH": os.environ["PATH"], "ENV": "/dev/null"})
    ok("-i without a terminal: rich diagnostic SH5015", b"SH5015" in p.stderr, repr(p.stderr))
    p = subprocess.run([SH, "-c", "echo flags=$-"], capture_output=True)
    ok("-c is not interactive", p.returncode == 0 and p.stdout.startswith(b"flags=") and b"i" not in p.stdout[6:], repr(p.stdout))
    p = subprocess.run([SH, "-i", "-c", "echo $-"], capture_output=True, env={"PATH": os.environ["PATH"], "ENV": "/dev/null"})
    ok("-i -c sets the i flag", b"i" in p.stdout, repr(p.stdout))
    p = subprocess.run([SH, "-c", "set -m; sleep 0.1 & jobs; wait"], capture_output=True)
    ok("set -m in a script gives job numbers", b"[1]" in p.stdout and b"sleep" in p.stdout, repr(p.stdout))
    p = subprocess.run([SH, "-c", "sleep 0.1 & jobs; wait"], capture_output=True)
    ok("jobs lists the background job without set -m", b"[1]" in p.stdout, repr(p.stdout))
    p = subprocess.run([SH, "-c", "sleep 0.1 & wait %1; echo $?"], capture_output=True)
    ok("wait %1", p.stdout == b"0\n", repr(p.stdout))
    p = subprocess.run([SH, "-c", "sleep 5 & kill %1; wait %1; echo $?"], capture_output=True)
    ok("kill %1 then wait %1 gives 143", p.stdout == b"143\n", repr(p.stdout))
    p = subprocess.run([SH, "-c", "fg"], capture_output=True)
    ok("fg without jobs fails", p.returncode == 1 and b"No current job" in p.stderr, repr(p.stderr))
    p = subprocess.run([SH, "-c", "kill %3"], capture_output=True)
    ok("kill of a missing job", p.returncode == 1 and b"No such job: %3" in p.stderr, repr(p.stderr))
    p = subprocess.run([SH, "-c", "sleep 1 & sleep 1 & kill %sl"], capture_output=True)
    ok("ambiguous job spec", p.returncode == 1 and b"Ambiguous" in p.stderr, repr(p.stderr))
    p = subprocess.run([SH, "-c", "fc -l"], capture_output=True)
    ok("fc outside an interactive shell", p.returncode == 1 and b"history not active" in p.stderr, repr(p.stderr))

def signal_cases():
    has("^C abandons the line", ["echo abc", "raw:echo xyz\x03", "echo after"], ["xyz^C", "after"])
    has("^C kills the foreground job, shell survives", ["sleep 30", ("w", .3), "^C", "echo status=$?"], ["status=130"])
    has("^\\ is ignored at the prompt", ["^\\", ALIVE], ["al1ve"])
    import signal as sg
    # SIGTSTP: this shell leads an orphaned process group, where the kernel drops
    # a default-action stop, so surviving it proves nothing: read the mask too.
    for signame, num in (("SIGTERM", sg.SIGTERM), ("SIGINT", sg.SIGINT), ("SIGTSTP", sg.SIGTSTP)):
        with Session([SH, "-i"]) as s:
            s.expect(r"\$ ?$")
            masked = signame == "SIGINT" or bool(ignored_signals(s.pid) >> (num - 1) & 1)
            os.kill(s.pid, num); s.settle(.3); s.send(ALIVE + "\n"); s.settle(.3)
            screen = s.take()
            what = "does not end the interactive shell" if signame == "SIGINT" else "is ignored by the interactive shell"
            ok("%s %s" % (signame, what), masked and "al1ve" in screen, "ignored mask ok: %r\n%s" % (masked, screen))
    has("trap on INT runs in the interactive shell", ["trap 'echo caught$((1+1))' INT", "kill -INT $$", ("w", .3), ALIVE], ["caught2", "al1ve"])
    has("sh on PATH is the shell under test", ["test \"$(command -v sh)\" -ef " + SH + " && echo inner-$((1+1))"], ["inner-2"])
    has("child gets default SIGINT", ["sh -c 'kill -INT $$; echo not-$((1+1))'", "echo st=$?"], ["st=130"], ["not-2"])
    # as dash, FreeBSD sh and bash do: a job that dies of SIGINT counts as ^C
    has("a child dying of SIGINT abandons the line", ["sh -c 'kill -INT $$'; echo not-$((1+1))", "echo st=$?"], ["st=130"], ["not-2\n"])
    has("^C interrupts wait", ["sleep 20 &", "wait", ("w", .2), "^C", "echo st=$?", "kill %1"], ["st=130"])
    has("^Z stops and the shell continues", ["sleep 30", "^Z", "echo back"], ["Stopped", "back"])
    has("stopped job warning on exit", ["sleep 31", "^Z", "exit", "jobs"], ["You have stopped jobs.", "Stopped"], env={"SH_DIAGNOSTICS": "posix"})
    has("second exit leaves", ["sleep 32", "^Z", "exit", "exit", "echo notrun"], ["You have stopped jobs."], ["\nnotrun"], env={"SH_DIAGNOSTICS": "posix"})
    leaves("EOF at the prompt exits", [ALIVE + "\n", "\x04"], 0, want=["al1ve"])
    out = run_steps(["sleep 33", "^Z", "^D", "^D", "echo notrun-$((1+1))"], env={"SH_DIAGNOSTICS": "posix"})
    ok("EOF with stopped jobs warns once, the next one leaves", out.count("You have stopped jobs.") == 1 and "notrun-2" not in out, out)
    has("read from the terminal", ["read x", "typed", "echo got $x"], ["got typed"])
    has("background job reading the terminal is stopped", ["cat &", ("w", .6), "jobs", "kill -CONT %1; kill %1"], ["Stopped(SIGTTIN)"])
    has("subshell pipeline in job control", ["echo a | cat | cat"], ["\na\n"])
    has("job finished before the prompt is announced", ["true &", ("w", .3), "echo next"], ["Done", "true"])
    leaves("trap EXIT runs when the interactive shell exits", ["trap 'echo by$((1+1))e' EXIT\n", "exit\n"], 0, want=["by2e"])
    # SIGWINCH redraw
    with Session([SH, "-i"], cols=40) as s:
        s.expect(r"\$ ?$")
        s.send("echo " + "x" * 50); s.settle(.3)
        import fcntl, termios, struct
        fcntl.ioctl(s.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 20, 0, 0))
        os.kill(s.pid, sg.SIGWINCH); s.settle(.5)
        s.take(); s.send("\x0c"); s.settle(.3)
        scr = s.take()
        s.send("\n"); s.settle(.3)
        ok("SIGWINCH reflows the line", "x" * 14 in scr and max(len(l) for l in scr.split("\n")) <= 20, scr)

def completion_cases():
    d = os.path.join(TMP, "cd")
    os.makedirs(os.path.join(d, "alpine", "inner"), exist_ok=True)
    os.makedirs(os.path.join(d, "bin"), exist_ok=True)
    for n in ("alpha.txt", "beta", "sp ace", ".hidden", "bin/zzfoo"):
        open(os.path.join(d, n), "w").close()
    os.chmod(os.path.join(d, "bin", "zzfoo"), 0o755)
    open(os.path.join(d, "bin", "zzfoo"), "w").write("#!/bin/sh\necho zzfoo ran\n")
    env = {"PATH": os.environ["PATH"] + ":" + os.path.join(d, "bin")}
    T = "\t"
    h = lambda n, st, want, absent=(), **kw: has("completion: " + n, st, want, absent, cwd=d, env=dict(env, **kw.pop("env", {})), **kw)
    h("unique file completes with a blank", ["echo be" + T + "!"], ["echo beta !"])
    h("directory gets a slash", ["echo alpi" + T + "x"], ["alpine/x"])
    h("common prefix", ["echo al" + T + "x"], ["echo alpx"])
    h("second tab lists", ["raw:echo al\t\t"], ["alpha.txt", "alpine/"])
    h("nested directory", ["echo alpine/" + T + "!"], ["alpine/inner/!"])
    h("hidden files need a dot", ["echo ." + T + "!"], ["echo .hidden !"])
    h("hidden files are not offered", ["raw:echo \t\t"], ["alpha.txt", "beta"], [".hidden"])
    h("blank in a name is escaped", ["echo sp" + T + "!"], ["sp\\ ace !"])
    h("completed escaped name works", ["echo sp" + T + "\n"], ["sp ace"])
    h("command from PATH", ["zzf" + T + "\n"], ["zzfoo ran"])
    h("builtin name", ["ech" + T + "hi"], ["echo hi", "\nhi\n"])
    h("command after a semicolon", ["true; ech" + T + "ok"], ["echo ok"])
    h("variable name", ["FOOBARBAZ=1", "echo $FOOBARB" + T + "x"], ["$FOOBARBAZ x"])
    h("braced variable", ["FOOBARBAZ=1", "echo ${FOOBARB" + T + "x"], ["${FOOBARBAZ} x"])
    h("no candidates leaves the line alone", ["echo zzzz" + T + "x"], ["echo zzzzx"])
    with Session([SH, "-i"]) as s:
        s.expect(r"\$ ?$")
        s.send("echo zzzz"); s.settle(.3)
        before = len(s.raw)
        s.send(T); s.settle(.4)
        ok("no candidates alerts", "\x07" in s.raw[before:], repr(s.raw[before:]))
    h("tab with nothing typed lists files", ["raw:\t\t"], ["alpha.txt", "beta"])
    h("after a redirection", ["echo hi > be" + T + "x"], ["> beta x"])
    h("tab inside a recalled line", ["echo hi", "raw:" + UP + HOME + RIGHT * 5 + "\x15echo be" + T + "\n"], ["beta"])
    # vi mode completion commands
    h("vi: \\ completes", ["set -o vi", "raw:echo be" + ESC + "\\\n"], ["echo beta"], absent=[])
    h("vi: * expands all", ["set -o vi", "raw:echo al" + ESC + "*\n"], ["alpha.txt alpine/"])
    h("vi: = lists", ["set -o vi", "raw:echo al" + ESC + "="], ["alpha.txt", "alpine/"])
    h("emacs: M-? lists", ["raw:echo al" + M("?")], ["alpha.txt", "alpine/"])
    os.makedirs(os.path.join(d, "uni"), exist_ok=True)
    open(os.path.join(d, "uni", "\u00fcber"), "w").close()
    h("unicode file name", ["echo uni/\u00fc" + T + "!"], ["echo uni/\u00fcber !"])

def paste_render_cases():
    P0, P1 = "\x1b[200~", "\x1b[201~"
    has("bracketed paste inserts text", ["raw:" + P0 + "echo pas$((1))ted" + P1 + "\n"], ["pas1ted"])
    has("paste keeps tabs literal (no completion)", ["raw:" + P0 + "echo a\tb" + P1 + "\n"], ["a b"])
    has("paste with a newline keeps both lines", ["raw:" + P0 + "echo 'a\nb'" + P1 + "\n"], ["\na\nb\n"])
    paste = "raw:" + P0 + "echo ran-$((40+1))\necho second" + P1
    with Session([SH, "-i"]) as s:
        s.expect(r"\$ ?$"); s.take()
        s.send(P0 + "echo ran-$((40+1))\necho second" + P1); s.settle(.5)
        before = s.take()
        s.send("\r"); s.settle(.5)
        after = s.take()
        ok("paste with a newline does not run early", "ran-41" not in before and "ran-41" in after, "before Enter:\n%s\nafter:\n%s" % (before, after))
    has("paste then edit", ["raw:" + P0 + "echo abc" + P1 + LEFT + "X\n"], ["abXc"])
    out = run_steps([], rows=24, cols=80)
    with Session([SH, "-i"]) as s:
        s.expect(r"\$ ?$")
        ok("bracketed paste is enabled while editing", "\x1b[?2004h" in s.raw)
    # rendering on the screen
    with Session([SH, "-i"], cols=20) as s:
        s.expect(r"\$ ?$"); s.take()
        s.send("echo " + "a" * 30); s.settle(.3)
        scr = s.take()
        ok("render: long line wraps at the terminal width", scr.split("\n")[0] == "$ echo " + "a" * 13 and scr.split("\n")[1] == "a" * 17, scr)
        s.send("\x7f" * 20); s.settle(.3)
        scr = s.take()
        ok("render: backspace across the wrap redraws", scr.split("\n")[-1] == "$ echo " + "a" * 10, repr(scr))
        s.send(C("A")); s.settle(.2); s.send("XY"); s.settle(.3)
        scr = s.take()
        ok("render: insert at start of a wrapped line", "$ XYecho" in scr, scr)
        s.send(C("U")); s.settle(.2)
    with Session([SH, "-i"], cols=30) as s:
        s.expect(r"\$ ?$"); s.take()
        s.send("echo 中文字"); s.settle(.3); s.take()
        # only an editor moves left over a wide character and redraws
        s.send(LEFT + "Z"); s.settle(.3)
        t = s.take()
        ok("render: wide characters", "$ echo 中文Z字" in t, repr(t))
        s.send(C("A")); s.send("\x04"); s.settle(.3)
        t = s.take()
        ok("render: C-d at line start with text deletes", "$ cho " in t and "$ echo" not in t.split("\n")[-1], t)
    with Session([SH, "-i"], env={"PS1": "line1\n$ "}) as s:
        s.expect(r"\$ ?$"); s.take()
        s.send("echo hi\n"); s.settle(.3)
        t = s.take()
        ok("render: multi-line prompt", "line1\n$ echo hi\nhi\nline1\n$" in t, t)
    with Session([SH, "-i"], env={"PS1": "\x01\x1b[1m\x02>\x01\x1b[0m\x02 "}) as s:
        s.expect(r"> ?$"); s.take()
        s.send("echo hi" + C("A") + "X"); s.settle(.3)
        t = s.take()
        ok("render: escape sequences in the prompt have no width", "> Xecho hi" in t, t)
    with Session([SH, "-i"], env={"TERM": "dumb"}) as s:
        s.expect(r"\$ ?$"); s.take()
        s.send("echo du$((1))mb\n"); s.settle(.3)
        t = s.take()
        ok("TERM=dumb uses plain line input", "du1mb" in t and "\x1b[?2004h" not in s.raw, t)
    with Session([SH, "-i"]) as s:
        s.expect(r"\$ ?$"); s.take()
        s.send("set +o emacs\n"); s.settle(.3); s.take()
        before = len(s.raw)
        s.send("echo plain\x7f\x01Z\n"); s.settle(.3)
        got = s.raw[before:]
        ok("no editing mode: the tty's own line discipline", "plai\x01Z\r\n" in got and "\x1b[?2004h" not in got, repr(got))

EXTRA = {"prompt": prompt_cases, "signals": signal_cases, "completion": completion_cases, "paste": paste_render_cases}

def setid_cases():
    """SHX-18, SHI-20: with differing ids, sh gives up the effective ones, or
    with -p keeps them and uses nothing the caller names. Needs root to make
    such a process; scripts/ci-musl.sh runs this as root."""
    if os.getuid() != 0:
        return
    ids_command = b"grep -E '^(Uid|Gid):' /proc/$$/status | tr -s '\\t ' '  '\necho new\nexit\n"
    def startup(ids, *options):
        d = tempfile.mkdtemp(dir=TMP)
        os.chmod(TMP, 0o755); os.chmod(d, 0o755)
        for name, mark in (("rc", "ran-$((1))-env"), (".profile", "ran-$((1))-profile")):
            with open(os.path.join(d, name), "w") as f:
                f.write("echo %s\n" % mark)
        hist = os.path.join(d, "hist")
        with open(hist, "w") as f:
            f.write("echo old\n")
        r = subprocess.run([SH, *options, "-l", "-i"], input=ids_command, capture_output=True, timeout=10, preexec_fn=ids,
                           env={"PATH": os.environ["PATH"], "HOME": d, "ENV": os.path.join(d, "rc"), "HISTFILE": hist})
        return r.stdout.decode(), open(hist).read()
    out, hist = startup(None)
    ok("startup files are used with matching ids", "ran-1-env" in out and "ran-1-profile" in out and "echo new" in hist, repr((out, hist)))
    cases = (("user", lambda: os.setresuid(65534, 0, 0), "Uid: 65534 65534 65534 65534", "Uid: 65534 0 0 0"),
             ("group", lambda: os.setresgid(65534, 0, 0), "Gid: 65534 65534 65534 65534", "Gid: 65534 0 0 0"))
    for what, ids, dropped, kept in cases:
        out, hist = startup(ids)
        ok("differing %s ids are given up, saved id too" % what, dropped in out and "new" in out, repr(out))
        out, hist = startup(ids, "-p")
        ok("-p keeps differing %s ids, and ENV, .profile and HISTFILE are ignored" % what,
           kept in out and "new" in out and "ran-1" not in out and hist == "echo old\n", repr((out, hist)))

def main():
    open(os.path.join(TMP, "ed.sh"), "w").write("#!/bin/sh\necho 'echo edited' > \"$1\"\n")
    os.chmod(os.path.join(TMP, "ed.sh"), 0o755)
    sections = {"emacs": emacs_cases, "vi": vi_cases, "jobs": job_cases, "fc": fc_cases}
    sections["input"] = input_and_history_cases
    sections["setid"] = setid_cases
    sections.update(EXTRA)
    want = [a for a in sys.argv[2:]] or list(sections)
    for n in want:
        sections[n]()
    shutil.rmtree(TMP, ignore_errors=True)
    print("\n%d passed, %d failed" % (passed, failed))
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
