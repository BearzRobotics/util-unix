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
    text = re.sub(r"Try '[^']*'", "Try 'PROG'", text)
    return text

def run_steps(prog, steps, env, rows, cols):
    m, s = pty.openpty()
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    results = []
    for step in steps:
        p = subprocess.run(prog + step, stdin=s, capture_output=True, env=env)
        results.append((p.stdout.decode(errors="replace"), norm(p.stderr.decode(errors="replace"), prog[0]), p.returncode))
    final = []
    for extra in (["-g"], ["-a"]):
        p = subprocess.run([GNU] + extra, stdin=s, capture_output=True, env={"LC_ALL": "C", "COLUMNS": "200"})
        final.append(p.stdout.decode(errors="replace"))
    os.close(m); os.close(s)
    return results, final

def case(desc, *steps, columns=None, rows=24, cols=80, lc="C"):
    global passed, failed
    env = {"LC_ALL": lc, "PATH": os.environ.get("PATH", "")}
    if columns:
        env["COLUMNS"] = str(columns)
    steps = [list(x) for x in steps]
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
case("no arguments")
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
# the actual restore is done in the shell wrapper (needs the saved string)

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
