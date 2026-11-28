#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Differential stty tests on a pseudo-terminal.

Every case is a list of stty invocations run one after the other on a fresh pty
(window size 24x80), once with GNU stty and once with ours. Each invocation's
standard output, standard error and exit status must match, and so must the
state of the pty after the last one (read back with GNU stty -g and -a).
Usage: stty_pty.py OURS_COMMAND...   (e.g. zig-out/bin/stty, or util-unix stty)
"""
import fcntl, os, pty, re, struct, subprocess, sys, termios

GNU = "/usr/bin/stty"
OURS = sys.argv[1:]
passed = failed = 0

def norm(text, prog):
    text = text.replace(prog, "stty")
    # musl words two errors differently; ours uses glibc's wording
    text = text.replace(": Not a tty\n", ": Inappropriate ioctl for device\n")
    text = text.replace(": Value too large for data type\n", ": Value too large for defined data type\n")
    text = re.sub(r"Try '[^']*'", "Try 'PROG'", text)
    return text

# glibc 2.42 and later also record the input speed in c_cflag (CIBAUD) when it is
# the output speed, which the same kernel setting; ours does as they do. A GNU
# stty built on musl does not, so against one that field is dropped from both.
def fresh_cflag():
    m, s = pty.openpty()
    out = subprocess.run([GNU, "-g"], stdin=s, capture_output=True).stdout.decode()
    os.close(m); os.close(s)
    return int(out.split(":")[2], 16)

REF_OMITS_ISPEED = fresh_cflag() & 0x100f0000 == 0

def same_speed_dropped(text):
    if not REF_OMITS_ISPEED:
        return text
    def one(m):
        cflag = int(m.group(2), 16)
        if (cflag >> 16) & 0x100f == cflag & 0x100f:
            cflag &= ~0x100f0000
        return m.group(1) + "%x" % cflag + ":"
    return re.sub(r"(?m)^([0-9a-f]+:[0-9a-f]+:)([0-9a-f]+):(?=(?:[0-9a-f]+:){3})", one, text)

def run_steps(prog, steps, env, rows, cols):
    m, s = pty.openpty()
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    results = []
    for step in steps:
        p = subprocess.run(prog + step, stdin=s, capture_output=True, env=env)
        results.append((same_speed_dropped(p.stdout.decode(errors="replace")), norm(p.stderr.decode(errors="replace"), prog[0]), p.returncode))
    final = []
    for extra in (["-g"], ["-a"]):
        p = subprocess.run([GNU] + extra, stdin=s, capture_output=True, env={"LC_ALL": "C", "COLUMNS": "200"})
        final.append(same_speed_dropped(p.stdout.decode(errors="replace")))
    os.close(m); os.close(s)
    return results, final

def case(desc, *steps, columns=None, rows=24, cols=80, lc="C"):
    global passed, failed
    env = {"LC_ALL": lc, "PATH": os.environ.get("PATH", "")}
    if columns:
        env["COLUMNS"] = str(columns)
    steps = [list(x) for x in steps]
    # with no step neither program would run, and nothing could differ
    assert steps, "case %r has no step" % desc
    g, gf = run_steps([GNU], steps, env, rows, cols)
    o, of = run_steps(OURS, steps, env, rows, cols)
    # A pseudo-terminal keeps 8 data bits, no parity and the receiver on. When a
    # request asks otherwise, both programs fail with status 1 but GNU's glibc
    # reports "Invalid argument" in some of these cases and "unable to perform
    # all requested operations" in others; compare only the output and status.
    pty_limited = {"parenb", "-cread", "cs5", "cs6", "cs7", "evenp", "parity", "oddp", "-pass8", "-litout", "-evenp", "-parity"}
    limited = any(x in pty_limited for st in steps for x in st)
    ok = True
    for (a, b) in zip(g, o):
        if limited:
            if a[0] != b[0] or a[2] != b[2]:
                ok = False
        elif a != b:
            ok = False
    if gf != of:
        ok = False
    if ok:
        passed += 1
        print("PASS " + desc)
    else:
        failed += 1
        print("FAIL " + desc)
        for step, a, b in zip(steps, g, o):
            if a != b and not (limited and a[0] == b[0] and a[2] == b[2]):
                print("     step %r" % (step,))
                print("     GNU : %r" % (a,))
                print("     OURS: %r" % (b,))
        if gf != of:
            print("     final state differs")
            for x, y in zip(gf, of):
                if x != y:
                    print("     GNU : %r" % x[:300]); print("     OURS: %r" % y[:300])

flags = """parenb parodd cmspar hupcl hup cstopb cread clocal crtscts
ignbrk brkint ignpar parmrk inpck istrip inlcr igncr icrnl ixon ixoff tandem iuclc ixany imaxbel iutf8
opost olcuc ocrnl onlcr onocr onlret ofill ofdel
isig icanon iexten echo echoe crterase echok echonl noflsh xcase tostop echoprt prterase echoctl ctlecho echoke crtkill flusho extproc
decctlq lcase LCASE tabs""".split()
values = "cs8 nl0 nl1 cr0 cr1 cr2 cr3 tab0 tab1 tab2 tab3 bs0 bs1 vt0 vt1 ff0 ff1".split()
chars = "intr quit erase kill eof eol eol2 swtch start stop susp rprnt werase lnext discard".split()
combos = "evenp parity oddp nl ek sane cooked raw pass8 litout cbreak decctlq crt dec".split()

# Plain display and all-settings display, in the pristine state.
case("no arguments", [])
case("-a", ["-a"])
case("--all", ["--all"])
case("-g", ["-g"])
case("--save", ["--save"])
case("size", ["size"])
case("speed", ["speed"])
case("size and speed in either order", ["size", "speed"], ["speed", "size"])

for f in flags:
    case("set " + f, [f], [], ["-a"])
    case("unset -" + f, ["-" + f], [], ["-a"])
for v in values:
    case("value " + v, [v], [], ["-a"])
for c in combos:
    case("combination " + c, [c], [], ["-a"])
    if c not in ("ek", "sane", "crt", "dec", "cbreak", "decctlq"):
        case("combination -" + c, ["-" + c], [], ["-a"])
case("-cbreak", ["-cbreak"], [], ["-a"])
case("sane after raw", ["raw"], ["sane"], [], ["-a"])
case("sane after many", ["raw", "iutf8", "hupcl", "clocal", "crtscts", "xcase", "ixany", "echonl", "tostop"], ["sane"], [], ["-a"])
case("cooked after raw", ["raw"], ["cooked"], [], ["-a"])
case("-raw after raw", ["raw"], ["-raw"], [], ["-a"])
# the combinations from a terminal that is not in its default state: what they
# leave alone only shows there
other = ["intr", "^X", "eof", "^Y", "eol", "^Z", "min", "5", "time", "7", "iutf8", "ixany", "-brkint", "inlcr", "-echo"]
for c in combos + ["-" + x for x in ("raw", "cooked", "cbreak", "nl", "evenp", "pass8", "litout", "decctlq", "lcase")] + ["lcase"]:
    case("custom settings, then " + c, other, [c], [], ["-a"])
for words in (["rows", "40", "size"], ["cols", "100", "size"], ["size", "rows", "40", "size"], ["rows", "30", "size", "cols", "90", "size"]):
    case(" ".join(words), words)
for words in (["cols", "4294967296"], ["rows", "4294967295"], ["rows", "2147483648"], ["rows", "2147483647", "size"], ["cols", "65537", "size"], ["+9600"], ["ispeed", "+9600"], ["ospeed", "96_00"], ["96_00"]):
    case(" ".join(words), words)
for words in (["cols", "+5"], ["cols", " 5"], ["cols", "5 "], ["rows", "1b"], ["rows", "1B"], ["rows", "2k"], ["rows", "1c"], ["rows", "0x10"],
              ["rows", "010"], ["rows", "++1"], ["rows", " +0x1b"], ["min", "+1"], ["min", "1b"], ["time", " 1"], ["line", "+0"], ["intr", "+10"],
              ["intr", ""], ["intr", "^ab"], ["intr", " 10"], ["intr", "10b"], ["intr", "^-x"], ["intr", "^1"], ["intr", "^["], ["intr", "^a"],
              ["exta"], ["extb"], ["--all=x"], ["--save=1"], ["--all=x", "-echo"]):
    case("argument forms: " + repr(words), words, [], ["-a"])
# musl has one speed for both directions, so a GNU stty built on it cannot show
# an input speed of its own
if not REF_OMITS_ISPEED:
    case("argument forms: ispeed exta", ["ispeed", "exta"], [], ["-a"])
case("custom settings, raw and back", other, ["raw"], ["-raw"], [], ["-a"])
case("eof undef, then cooked", ["eof", "undef"], ["cooked"], [], ["-a"])
for c in chars:
    for v in ("^A", "^?", "^-", "undef", "x", "0x41", "0101", "101", "^z", "0x80", "255"):
        case("char %s %s" % (c, v), [c, v], [], ["-a"])
case("min/time with -icanon", ["-icanon", "min", "3", "time", "5"], [], ["-a"])
case("min/time with icanon", ["min", "3", "time", "5"], [], ["-a"])
case("min 0", ["-icanon", "min", "0"], [])
case("time 255", ["time", "255", "-icanon"], [])
case("several in one invocation", ["-echo", "intr", "^A", "cs8", "-icanon", "min", "2"], [], ["-a"])
case("two invocations", ["-echo"], ["-icanon"], ["-a"])

# Speeds.
for sp in "0 50 75 110 134 134.5 150 200 300 600 1200 1800 2400 4800 9600 19200 38400 57600 115200 230400 460800 500000 576000 921600 1000000 1152000 1500000 2000000 2500000 3000000 3500000 4000000".split():
    case("speed " + sp, [sp], ["speed"], [], ["-a"], ["-g"])
# musl cannot set the two speeds apart (its cfsetispeed sets both), so a GNU
# stty built on it is no reference for these
if REF_OMITS_ISPEED:
    for name in ("ispeed", "ospeed"):
        print("SKIP %s (the reference cannot set input and output speeds apart)" % name)
else:
    case("ispeed", ["ispeed", "9600"], [], ["speed"], ["-a"], ["-g"])
    case("ospeed", ["ospeed", "19200"], [], ["speed"], ["-a"], ["-g"])
case("ispeed then both", ["ispeed", "9600"], ["19200"], ["-a"])
case("bad speed", ["12345"])
case("bad ispeed", ["ispeed", "12345"])
case("ispeed without value", ["ispeed"])
case("ospeed without value", ["ospeed"])

# Window size and line discipline.
case("rows cols", ["rows", "30", "cols", "100"], ["size"], ["-a"])
case("columns", ["columns", "50"], ["size"])
case("rows 0", ["rows", "0"], ["size"])
case("rows 65535", ["rows", "65535"], ["size"])
case("rows 65536", ["rows", "65536"], ["size"])
case("rows bad", ["rows", "x"])
case("rows missing", ["rows"])
case("cols hex", ["cols", "0x20"], ["size"])
case("line 1", ["line", "1"], ["-a"])
case("line 255", ["line", "255"], ["-a"])
case("line 256", ["line", "256"])
case("line bad", ["line", "x"])
case("line missing", ["line"])

# Save and restore.
case("restore from -g", ["raw", "intr", "^A", "-echo"], ["-g"])
case("-g string round trip", ["sane"], ["-g"])

def restore_case(desc, changes):
    """`stty "$(stty -g)"`: save a changed state, leave it, restore it. Both
    programs must succeed, and the terminal must be back in the saved state
    (which differs from the one restored from, or nothing is shown)."""
    global passed, failed
    env = {"LC_ALL": "C", "PATH": os.environ.get("PATH", "")}
    problems = []
    for name, prog in (("GNU", [GNU]), ("OURS", OURS)):
        m, s = pty.openpty()
        def run(cmd, args):
            return subprocess.run(cmd + args, stdin=s, capture_output=True, env=env)
        run([GNU], changes)
        saved = run(prog, ["-g"]).stdout.decode().strip()
        run([GNU], ["sane", "-echo" if "echo" in changes else "echo", "intr", "^K"])
        other = run([GNU], ["-g"]).stdout.decode().strip()
        p = run(prog, [saved])
        back = run([GNU], ["-g"]).stdout.decode().strip()
        if same_speed_dropped(saved + "\n") == same_speed_dropped(other + "\n"):
            problems.append("%s: the case does not leave the saved state" % name)
        if p.returncode != 0 or p.stdout or p.stderr:
            problems.append("%s: restore gave status %d, %r %r" % (name, p.returncode, p.stdout, p.stderr))
        if same_speed_dropped(back + "\n") != same_speed_dropped(saved + "\n"):
            problems.append("%s: saved %s\n     but now %s" % (name, saved, back))
        os.close(m); os.close(s)
    if problems:
        failed += 1
        print("FAIL " + desc)
        for line in problems:
            print("     " + line)
    else:
        passed += 1
        print("PASS " + desc)

restore_case("restore: flags and a control character", ["raw", "intr", "^A", "-echo"])
restore_case("restore: min, time and line settings", ["-icanon", "min", "3", "time", "7", "echo", "tostop", "ixany"])
restore_case("restore: speed and output delays", ["9600", "cr3", "tab3", "ocrnl", "quit", "undef"])

# strings that are not a saved state are rejected, and change nothing
_m, _s = pty.openpty()
_saved = subprocess.run([GNU, "-g"], stdin=_s, capture_output=True).stdout.decode().strip()
os.close(_m); os.close(_s)
for desc, bad in (("one field short", _saved.rsplit(":", 1)[0]), ("one field extra", _saved + ":0"),
                  ("not hexadecimal", _saved.rsplit(":", 1)[0] + ":zz"), ("flag too large", "1ffffffff:" + _saved.split(":", 1)[1]),
                  ("character too large", _saved.rsplit(":", 1)[0] + ":100"), ("only colons", ":::")):
    case("restore rejects: " + desc, ["-echo"], [bad], ["-g"])

# Errors and option parsing.
case("bad setting", ["foo"])
case("bad negated setting", ["-foo"])
case("negated value setting", ["-cs8"])
case("negated char", ["-intr", "^A"])
case("missing char argument", ["intr"])
case("bad char", ["intr", "abc"])
case("char too large", ["intr", "300"])
case("min too large", ["min", "300"])
case("min bad", ["min", "x"])
case("min missing", ["min"])
case("empty argument", [""])
case("dash", ["-"])
case("-- ends options", ["--"])
case("-a -g", ["-a", "-g"])
case("-ag", ["-ag"])
case("-ga", ["-ga"])
case("-a with setting", ["-a", "intr", "^A"])
case("-g with setting", ["-g", "raw"])
case("-a size", ["-a", "size"])
case("-F missing", ["-F"])
case("--file missing", ["--file"])
case("--bogus", ["--bogus"])
case("-x", ["-x"])
case("-F /dev/null", ["-F", "/dev/null"])
case("-F/dev/null", ["-F/dev/null"])
case("--file=/dev/null", ["--file=/dev/null"])
case("--file /dev/null", ["--file", "/dev/null"])
case("-F nonexistent", ["-F", "/nonexistent"])
case("-aF /dev/null", ["-aF", "/dev/null"])
case("-F /dev/null -a", ["-F", "/dev/null", "-a"])
case("--al abbreviation", ["--al"])
case("--sa abbreviation", ["--sa"])
case("drain", ["drain"], ["-drain"])
case("drain with other", ["drain", "-echo"], ["-a"])
case("bad argument after size prints nothing", ["size", "foo"])
case("bad argument after rows applies nothing", ["rows", "5", "foo"], ["size"])
case("-a drain", ["-a", "drain"])
case("-g -drain", ["-g", "-drain"])
case("failing arg leaves state alone", ["-echo", "foo"], ["-a"])

# Wrapping at different widths.
for w in list(range(10, 121)) + [150, 200]:
    case("-a at COLUMNS=%d" % w, ["-a"], columns=w)
    case("changed at COLUMNS=%d" % w, ["raw", "-echo", "ixoff", "intr", "^A", "quit", "^B", "kill", "^K", "erase", "^H", "eof", "^E"], [], columns=w)
case("COLUMNS=0", ["-a"], columns=0)
case("COLUMNS=junk", ["-a"], columns="junk")
case("-a on a 50 column terminal without COLUMNS", ["-a"], cols=50)

# Combination of everything non-default.
case("kitchen sink", ["-ignbrk", "ignbrk", "ixoff", "ixany", "iuclc", "olcuc", "ocrnl", "xcase", "tostop", "echoprt", "-echoctl", "-echoke", "flusho", "extproc", "nl1", "cr3", "tab3", "bs1", "vt1", "ff1", "noflsh", "echonl", "-icrnl", "-onlcr", "-opost", "hupcl", "clocal", "crtscts", "cmspar", "cstopb", "parodd"], [], ["-a"], ["-g"])

print("\n======================================")
print(" stty: %d/%d passed" % (passed, passed + failed))
if failed:
    print(" %d test(s) failed" % failed)
else:
    print(" All tests passed!")
print("======================================")
sys.exit(1 if failed else 0)
