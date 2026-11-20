#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""sh-gold.py - compare the behaviour of our sh with the other shells on a set
of snippets, and classify every snippet by the maintainer's gold-standard rule
(docs/decisions/0009-posix-sh.md).

Shells run per snippet (each in its own sandbox, see below):
  dash, freebsd (tools/bsdrun.sh, Chimera sysroot), bash-posix (bash --posix),
  bash-as-sh (bash invoked as sh), busybox-ash, yash-posix (yash --posix), ours.

Classification (stdout and exit status are compared; stderr is informative):
  GOLD_AGREE    dash == FreeBSD sh: that behaviour is the standard.
                ours: MATCH, or MISMATCH (an OUR-BUG candidate).
  POSIX_DECIDES dash != FreeBSD sh: POSIX decides; ours: MATCH-dash, MATCH-bsd
                or MISMATCH (needs a POSIX citation, or a fix).
  NONDET        dash gave different results on two runs (pids, times): ignored.
  UNUSABLE      dash and FreeBSD both timed out or are missing.

Sources (--source, repeatable):
  test_sh            every case of test/test_sh.sh (run with -c, like the suite)
  yash               yash tests/*-p.tst (script on stdin, setup prefixed)
  freebsd            freebsd bin/sh/tests/*/NAME.N (script file)
  oils               oils spec/*.test.sh (script file; argv.py helpers are POSIX sh)
  dir:PATH           every *.sh file in PATH (script file); PATH/*.c for -c mode
Corpora come from tools/fetch-sh-corpora.sh (SH_CORPORA_DIR).

Sandbox per case: setsid, bwrap --unshare-pid --unshare-ipc --unshare-net
--die-with-parent, read-only root, a fresh writable working directory, a
private /tmp, per-case timeout 5 s. The whole run is meant to be started
through tools/sh-gold.sh, which wraps it in a systemd scope (memory/time cap).

usage: sh-gold.py [--source S]... [--out DIR] [--jobs N] [--ours PATH]
                  [--limit N] [--filter SUBSTR] [--list]
Writes DIR/results.jsonl (one record per snippet) and prints the statistics.
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORPORA = os.environ.get("SH_CORPORA_DIR") or os.path.join(os.path.expanduser("~"), ".cache/util-unix/sh-corpora")
CHIMERA = os.environ.get("CHIMERA_ROOT", "/stuff/tmp/chimera-sysroot")
TIMEOUT = 5

# ---------------------------------------------------------------- helpers
ARGV_PY = r'''#!/bin/sh
# argv.py stand-in (python repr of sys.argv[1:]) in POSIX sh, so that the
# FreeBSD sysroot (no python) can run the Oils cases too.
out=; sep=
for a in "$@"; do
  r=; s=$a
  case $s in *\'*) case $s in *\"*) q=\' ;; *) q=\" ;; esac ;; *) q=\' ;; esac
  while [ -n "$s" ]; do
    rest=${s#?}; c=${s%"$rest"}; s=$rest
    case $c in
      \\) r=$r'\\' ;;
      "$q") r=$r"\\$c" ;;
      "	") r=$r'\t' ;;
      "
") r=$r'\n' ;;
      *) r=$r$c ;;
    esac
  done
  out=$out$sep$q$r$q; sep=', '
done
printf '[%s]\n' "$out"
'''
PRINTENV_PY = '''#!/bin/sh
for n in "$@"; do
  if eval "[ \\"\\${$n+set}\\" = set ]"; then eval "printf '%s\\n' \\"\\$$n\\""; else echo None; fi
done
'''
STDOUT_STDERR_PY = '''#!/bin/sh
echo STDOUT; echo STDERR >&2
'''

HELPERS = {"argv.py": ARGV_PY, "printenv.py": PRINTENV_PY, "stdout_stderr.py": STDOUT_STDERR_PY}

YASH_DEFAULTS = """_empty= _sp=' ' _tab='	' _nl='
'
echoraw() {
    printf '%s\\n' "$*"
}
bracket() {
    if [ $# -gt 0 ]; then printf '[%s]' "$@"; fi
    echo
}
"""

SHELLS = [
    # name, symlink name, target, flags
    ("dash", "sh", "/usr/bin/dash", []),
    ("bash-posix", "bash", "/usr/bin/bash", ["--posix"]),
    ("bash-as-sh", "sh", "/usr/bin/bash", []),
    ("busybox-ash", "sh", "/usr/bin/busybox", []),
    ("yash-posix", "yash", "/usr/bin/yash", ["--posix"]),
]


def mkdirs(base, ours):
    d = {}
    for name, link, target, flags in SHELLS:
        if not os.path.exists(target):
            continue
        sd = os.path.join(base, "shells", name)
        os.makedirs(sd, exist_ok=True)
        os.symlink(target, os.path.join(sd, link))
        d[name] = (sd, link, flags)
    sd = os.path.join(base, "shells", "ours")
    os.makedirs(sd, exist_ok=True)
    os.symlink(os.path.abspath(ours), os.path.join(sd, "sh"))
    d["ours"] = (sd, "sh", [])
    if os.path.exists(os.path.join(CHIMERA, "bin/sh")):
        d["freebsd"] = (None, "sh", [])
    return d


def norm_out(s, w):
    return s.replace(w, "$W")


def norm_err(s, w):
    s = s.replace(w, "$W")
    s = re.sub(r"(?m)^(?:/\S*/)?(?:sh|dash|bash|yash|busybox|ash)(?:: line \d+|: \d+)?: ", "sh: ", s)
    s = re.sub(r"(?m)^sh: (?:line )?\d+: ", "sh: ", s)
    return s


# ---------------------------------------------------------------- running
def run_one(shells, name, case, base):
    """Run CASE under shell NAME in a fresh sandbox; returns dict."""
    sd, link, flags = shells[name]
    w = tempfile.mkdtemp(prefix="w", dir=os.path.join(base, "work"))
    try:
        # helpers and the script live in the working directory (the FreeBSD
        # sysroot sees only that); dot names keep them out of globs and ls
        hd = os.path.join(w, ".h")
        os.mkdir(hd)
        for hn, body in HELPERS.items():
            with open(os.path.join(hd, hn), "w") as f:
                f.write(body)
            os.chmod(os.path.join(hd, hn), 0o755)
        mode = case["mode"]
        text = case["text"]
        stdin_data = b""
        if mode == "stdin":
            stdin_data = text.encode("utf-8", "surrogateescape")
            argv_tail = case.get("args", [])
        elif mode == "c":
            argv_tail = ["-c", text]
        else:
            with open(os.path.join(w, ".case.sh"), "wb") as f:
                f.write(text.encode("utf-8", "surrogateescape"))
            argv_tail = [".case.sh"]
        if name == "freebsd":
            cmd = ["sh", os.path.join(ROOT, "tools/bsdrun.sh"), "timeout", "-s", "KILL", str(TIMEOUT), "sh"] + argv_tail
            env = {"PATH": "/mnt/work/.h:/usr/bin:/bin", "SH": "sh", "TMP": "/tmp", "TMPDIR": "/tmp",
                   "HOME": "/mnt/work", "LC_ALL": "C", "LANG": "C", "REPO_ROOT": "/mnt/work"}
            full = cmd
            wr = "/mnt/work"
        else:
            exe = os.path.join(sd, link)
            sh_cmd = exe + (" " + " ".join(flags) if flags else "")
            env = {"PATH": "%s:%s/.h:/usr/local/bin:/usr/bin:/bin" % (sd, w), "SH": sh_cmd, "TMP": "/tmp",
                   "TMPDIR": "/tmp", "HOME": w, "LC_ALL": "C", "LANG": "C", "REPO_ROOT": w}
            full = ["bwrap", "--unshare-pid", "--unshare-ipc", "--unshare-net", "--die-with-parent",
                    "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
                    "--bind", w, w, "--chdir", w,
                    "timeout", "-s", "KILL", str(TIMEOUT), exe] + flags + argv_tail
            wr = w
        try:
            p = subprocess.Popen(full, cwd=w, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
            try:
                out, err = p.communicate(stdin_data, timeout=TIMEOUT + 6)
                rc = p.returncode
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, 9)
                except OSError:
                    pass
                out, err = p.communicate()
                rc = 124
        except OSError as e:
            return {"out": "", "err": str(e), "rc": 125}
        o = out.decode("utf-8", "replace")
        e = err.decode("utf-8", "replace")
        if rc == 137:
            rc = 124  # timeout -s KILL
        return {"out": norm_out(o, wr)[:20000], "err": norm_err(e, wr)[:2000], "rc": rc}
    finally:
        shutil.rmtree(w, ignore_errors=True)


ORDER = ["dash", "freebsd", "bash-posix", "bash-as-sh", "busybox-ash", "yash-posix", "ours"]


def run_case(shells, base, case):
    res = {}
    for n in ORDER:
        if n in shells:
            res[n] = run_one(shells, n, case, base)
    if "dash" in shells:
        again = run_one(shells, "dash", case, base)
        res["_dash2"] = {"out": again["out"], "rc": again["rc"]}
    return classify(case, res)


def sig(r):
    return (r["out"], r["rc"])


def classify(case, res):
    rec = {"id": case["id"], "source": case["source"], "name": case.get("name", ""), "mode": case["mode"],
           "text": case["text"], "args": case.get("args", [])}
    d, b, o = res.get("dash"), res.get("freebsd"), res.get("ours")
    nd = "_dash2" in res and sig(res["_dash2"]) != sig(d)
    rec["res"] = {k: v for k, v in res.items() if k != "_dash2"}
    if nd:
        rec["class"] = "NONDET"
        rec["ours"] = "-"
        return rec
    if d is None or b is None or (d["rc"] == 124 and b["rc"] == 124):
        rec["class"] = "UNUSABLE"
        rec["ours"] = "-"
        return rec
    if sig(d) == sig(b):
        rec["class"] = "GOLD_AGREE"
        rec["ours"] = "MATCH" if sig(o) == sig(d) else "MISMATCH"
    else:
        rec["class"] = "POSIX_DECIDES"
        if sig(o) == sig(d):
            rec["ours"] = "MATCH-dash"
        elif sig(o) == sig(b):
            rec["ours"] = "MATCH-bsd"
        else:
            rec["ours"] = "MISMATCH"
    others = [n for n in ("bash-posix", "bash-as-sh", "busybox-ash", "yash-posix") if n in res]
    rec["agree_with_dash"] = [n for n in others if sig(res[n]) == sig(d)]
    return rec


# ---------------------------------------------------------------- sources
def src_test_sh(args):
    d = tempfile.mkdtemp(prefix="dump")
    env = dict(os.environ, SHCMP_DUMP=d)
    subprocess.run(["sh", os.path.join(ROOT, "test/test_sh.sh")], env=env, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    cases = []
    for f in sorted(os.listdir(d), key=lambda s: int(re.search(r"(\d+)", s).group(1))):
        text = open(os.path.join(d, f), encoding="utf-8", errors="surrogateescape").read()
        if text.endswith("\n"):
            text = text[:-1]  # the dump adds a newline after the snippet
        cases.append({"id": "test_sh/" + f[:-3], "source": "test_sh", "name": f[:-3], "mode": "c", "text": text})
    shutil.rmtree(d, ignore_errors=True)
    return cases


def src_dir(path):
    cases = []
    for f in sorted(os.listdir(path)):
        p = os.path.join(path, f)
        if f.endswith(".sh"):
            cases.append({"id": "dir/" + f, "source": "dir", "name": f, "mode": "file",
                          "text": open(p, encoding="utf-8", errors="surrogateescape").read()})
        elif f.endswith(".c"):
            cases.append({"id": "dir/" + f, "source": "dir", "name": f, "mode": "c",
                          "text": open(p, encoding="utf-8", errors="surrogateescape").read().rstrip("\n")})
    return cases


def src_freebsd(args):
    base = os.path.join(CORPORA, "freebsd/bin/sh/tests")
    cases = []
    for dp, _dn, fn in sorted(os.walk(base)):
        for f in sorted(fn):
            if f.endswith((".stdout", ".stderr")) or f.startswith("Makefile") or f == "functional_test.sh":
                continue
            if not f.rsplit(".", 1)[-1].isdigit():
                continue
            text = open(os.path.join(dp, f), encoding="utf-8", errors="surrogateescape").read()
            rel = os.path.relpath(os.path.join(dp, f), base)
            if re.search(r"/dev/tty|set -m|\bjobs\b|dirname", text):
                continue  # interactive or needs the corpus directory
            cases.append({"id": "freebsd/" + rel, "source": "freebsd", "name": rel, "mode": "file", "text": text})
    return cases


OILS_SKIP_FILES = re.compile(r"^(interactive|interactive-parse|builtin-completion|builtin-history|history-expand|"
                             r"builtin-bind|prompt|ble-.*|hay.*|nix-idioms)\.test\.sh$")


def src_oils(args):
    sys.path.insert(0, os.path.join(ROOT, "test/sh_corpora"))
    import run_oils
    base = os.path.join(CORPORA, "oils/spec")
    cases = []
    for f in sorted(os.listdir(base)):
        if not f.endswith(".test.sh") or OILS_SKIP_FILES.match(f):
            continue
        for idx, (name, code, _exp) in enumerate(run_oils.parse_file(os.path.join(base, f))):
            if re.search(r"\$SH\s+-[a-z]*i\b|set -m|/dev/tty|\bpty\b|\binteractive\b", code):
                continue
            cases.append({"id": "oils/%s:%d" % (f[:-8], idx), "source": "oils", "name": f[:-8] + ": " + name,
                          "mode": "file", "text": code})
    return cases


def src_yash(args):
    base = os.path.join(CORPORA, "yash/tests")
    cases = []
    for f in sorted(os.listdir(base)):
        if not f.endswith("-p.tst") or f.startswith("sig"):
            continue
        text = open(os.path.join(base, f), encoding="utf-8", errors="surrogateescape").read()
        if "%REQUIRETTY%" in text:
            continue
        lines = text.split("\n")
        setup = ""
        i = 0
        while i < len(lines):
            ln = lines[i]
            m = re.match(r"^setup (-d|<<\\(\S+)|'(.*)'|\"(.*)\")\s*$", ln)
            if m:
                if m.group(1) == "-d":
                    setup += YASH_DEFAULTS
                elif m.group(2):
                    i += 1
                    body = []
                    while lines[i] != m.group(2):
                        body.append(lines[i])
                        i += 1
                    setup += "\n".join(body) + "\n"
                else:
                    setup += (m.group(3) if m.group(3) is not None else m.group(4)) + "\n"
                i += 1
                continue
            m = re.match(r"^test_([oOeExX]+)\s+(.*)$", ln)
            if not m:
                i += 1
                continue
            lineno = i + 1
            try:
                toks = shlex.split(m.group(2))
            except ValueError:
                i += 1
                continue
            k = 0
            while k < len(toks) and toks[k] in ("-d", "-f", "-e"):
                k += 2 if toks[k] == "-e" else 1
            name = toks[k] if k < len(toks) else "?"
            targs = toks[k + 1:]
            i += 1
            body = []
            while i < len(lines) and lines[i] != "__IN__":
                body.append(lines[i])
                i += 1
            i += 1
            if "-i" in targs or "-m" in targs:
                continue
            cases.append({"id": "yash/%s:%d" % (f[:-4], lineno), "source": "yash", "name": f[:-4] + ": " + name,
                          "mode": "stdin", "args": targs, "text": setup + "\n".join(body) + "\n"})
    return cases


SOURCES = {"test_sh": src_test_sh, "yash": src_yash, "freebsd": src_freebsd, "oils": src_oils}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", action="append")
    ap.add_argument("--out", default=None)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--ours", default=os.path.join(ROOT, "zig-out/bin/sh"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--filter", default="")
    ap.add_argument("--list", action="store_true", help="only extract and count the snippets")
    a = ap.parse_args()
    srcs = a.source or ["test_sh", "yash", "freebsd", "oils"]
    cases = []
    for s in srcs:
        cases += src_dir(s[4:]) if s.startswith("dir:") else SOURCES[s](a)
    if a.filter:
        cases = [c for c in cases if a.filter in c["id"] or a.filter in c.get("name", "")]
    if a.limit:
        cases = cases[:a.limit]
    print("snippets: %d (%s)" % (len(cases), ", ".join("%s %d" % (s, sum(1 for c in cases if c["source"] == s))
                                                         for s in sorted({c["source"] for c in cases}))))
    if a.list:
        return
    out = a.out or tempfile.mkdtemp(prefix="sh-gold-")
    os.makedirs(out, exist_ok=True)
    base = tempfile.mkdtemp(prefix="sh-gold-run-", dir=os.environ.get("SH_GOLD_TMP", "/var/tmp"))
    os.makedirs(os.path.join(base, "work"))
    shells = mkdirs(base, a.ours)
    print("shells:", " ".join(n for n in ORDER if n in shells))
    recs = []
    try:
        with ThreadPoolExecutor(a.jobs) as ex:
            for n, rec in enumerate(ex.map(lambda c: run_case(shells, base, c), cases)):
                recs.append(rec)
                if n % 200 == 199:
                    print("  %d/%d" % (n + 1, len(cases)), file=sys.stderr)
    finally:
        shutil.rmtree(base, ignore_errors=True)
    with open(os.path.join(out, "results.jsonl"), "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
    stats(recs)
    print("results:", os.path.join(out, "results.jsonl"))


def stats(recs):
    print("\n%-10s %6s %6s %6s %6s %6s | ours on gold: match miss | ours on posix-decides: match miss" % (
        "source", "n", "gold", "posix", "nondet", "unus"))
    for s in sorted({r["source"] for r in recs}) + ["ALL"]:
        rs = [r for r in recs if s == "ALL" or r["source"] == s]
        g = [r for r in rs if r["class"] == "GOLD_AGREE"]
        p = [r for r in rs if r["class"] == "POSIX_DECIDES"]
        print("%-10s %6d %6d %6d %6d %6d | %6d %6d | %6d %6d" % (
            s, len(rs), len(g), len(p), sum(r["class"] == "NONDET" for r in rs),
            sum(r["class"] == "UNUSABLE" for r in rs), sum(r["ours"] == "MATCH" for r in g),
            sum(r["ours"] == "MISMATCH" for r in g), sum(r["ours"].startswith("MATCH") for r in p),
            sum(r["ours"] == "MISMATCH" for r in p)))


if __name__ == "__main__":
    main()
