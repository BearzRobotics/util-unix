# SPDX-License-Identifier: GPL-2.0-or-later
"""Adapter that runs the Oils spec tests (spec/*.test.sh, Apache-2.0, fetched by
tools/fetch-sh-corpora.sh, never committed) against our sh.

The spec files are read as data. A case is

    #### name
    code...
    ## STDOUT:            (or `## stdout: one line`, `## stdout-json: "..."`)
    expected
    ## END
    ## status: N          (default 0)
    ## OK|BUG|N-I dash/bash STDOUT:   per-shell expectation that replaces the default

For every case we compute the expectation of the `dash` column and of the
`bash` column (the Oils annotations say what each shell really does), run the
code under our sh, and, for the failures, under dash and bash --posix to
classify them:

  PASS         our stdout and status equal the dash column's expectation
  DASH         ours differs from the expectation but equals what dash really
               does (the corpus encodes other shells' behaviour, or dash's own
               documented deviation): follows the gold standard
  BASH         ours differs from dash and equals bash --posix (a case where
               dash is the odd one out)
  BUG          ours differs from the expectation, dash meets it: our bug
  OTHER        nobody (dash, ours) meets the expectation: the corpus asks for a
               behaviour dash does not have (shell-specific or non-POSIX)

usage: python3 -I run_oils.py SPEC_DIR OURS_SH [--jobs N] [--out FILE]
Prints one line per non-PASS case:  CATEGORY<TAB>file<TAB>name<TAB>detail
and a final  SUMMARY<TAB>counts.
"""
import json
import shlex
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

TIMEOUT = 10
SHOW = []  # debugging: print code, expectation and the outputs of cases whose name contains one of these
SANDBOX = []  # command prefix that runs each case in its own session and PID namespace

HEADER = re.compile(
    r"^## (?:(OK|BUG|N-I)(?:-\d+)? ([\w/.-]+) )?"
    r"(STDOUT|stdout|status|stdout-json|STDERR|stderr|stderr-json|stdout-repr)(?::|$)(.*)$"
)


def parse_file(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    cases = []
    i = 0
    n = len(lines)
    while i < n and not lines[i].startswith("#### "):
        i += 1
    while i < n:
        name = lines[i][5:].strip()
        i += 1
        code = []
        while i < n and not lines[i].startswith("#### ") and not lines[i].startswith("## "):
            code.append(lines[i])
            i += 1
        exp = {}  # (shell or None, key) -> value
        while i < n and not lines[i].startswith("#### "):
            m = HEADER.match(lines[i])
            if not m:
                i += 1
                continue
            _kind, shells, rawkey, rest = m.groups()
            key = rawkey.lower()
            i += 1
            if rawkey in ("STDOUT", "STDERR") and rest.strip() == "":
                body = []
                while i < n and lines[i] != "## END" and not lines[i].startswith("## END"):
                    body.append(lines[i])
                    i += 1
                i += 1
                val = "".join(l + "\n" for l in body)
            elif key in ("stdout-json", "stderr-json"):
                try:
                    val = json.loads(rest.strip())
                except ValueError:
                    val = None
                key = key[:-5]
            elif key == "stdout-repr":
                val = None
            else:
                r = rest[1:] if rest.startswith(" ") else rest
                if key == "status":
                    try:
                        val = int(r.strip())
                    except ValueError:
                        val = None
                else:
                    val = r + "\n" if r != "" else ""
            if key not in ("stdout", "status") or val is None:
                continue
            for sh in (shells.split("/") if shells else [None]):
                exp[(sh, key)] = val
        cases.append((name, "\n".join(code) + "\n", exp))
    return cases


def expectation(exp, shell):
    out = {}
    for key in ("stdout", "status"):
        if (shell, key) in exp:
            out[key] = exp[(shell, key)]
        elif (None, key) in exp:
            out[key] = exp[(None, key)]
    out.setdefault("status", 0)
    return out


def run(shell_cmd, code, tmp, spec_bin):
    path = os.path.join(tmp, "case.sh")
    with open(path, "w") as f:
        f.write(code)
    env = {
        "PATH": spec_bin + ":/usr/local/bin:/usr/bin:/bin",
        "HOME": tmp, "TMP": tmp, "TMPDIR": tmp, "LC_ALL": "C", "LANG": "C",
        "REPO_ROOT": os.path.dirname(spec_bin), "SH": shell_cmd[0],
    }
    try:
        p = subprocess.run(SANDBOX + ["timeout", "-s", "KILL", str(TIMEOUT)] + shell_cmd + [path], cwd=tmp, env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
        return p.stdout.decode("utf-8", "replace"), p.returncode
    except subprocess.TimeoutExpired:
        return "<timeout>", -1


def meets(res, e):
    out, st = res
    if "stdout" in e and out != e["stdout"]:
        return False
    return st == e["status"]


def main():
    args = sys.argv[1:]
    spec_dir, ours = args[0], os.path.abspath(args[1])
    jobs = 8
    outfile = None
    k = 2
    while k < len(args):
        if args[k] == "--jobs":
            jobs = int(args[k + 1]); k += 2
        elif args[k] == "--sandbox":
            SANDBOX.extend(shlex.split(args[k + 1])); k += 2
        elif args[k] == "--show":
            SHOW.append(args[k + 1]); k += 2
        elif args[k] == "--out":
            outfile = args[k + 1]; k += 2
        else:
            k += 1
    work = tempfile.mkdtemp(prefix="oils-")
    # the helpers (argv.py ...) are python2 scripts; run copies under python3
    spec_bin = os.path.join(work, "bin")
    os.mkdir(spec_bin)
    src_bin = os.path.join(spec_dir, "bin")
    for h in os.listdir(src_bin):
        sp = os.path.join(src_bin, h)
        if not os.path.isfile(sp):
            continue
        with open(sp, "rb") as fh:
            data = fh.read()
        if data.startswith(b"#!/usr/bin/env python2"):
            data = b"#!/usr/bin/env python3" + data[len(b"#!/usr/bin/env python2"):]
        dp = os.path.join(spec_bin, h)
        with open(dp, "wb") as fh:
            fh.write(data)
        os.chmod(dp, 0o755)
    shname = os.path.join(work, "sh")
    os.symlink(ours, shname)
    dash = shutil.which("dash")
    bash = shutil.which("bash")
    files = sorted(f for f in os.listdir(spec_dir) if f.endswith(".test.sh"))
    jobs_list = []
    for f in files:
        for idx, (name, code, exp) in enumerate(parse_file(os.path.join(spec_dir, f))):
            jobs_list.append((f, idx, name, code, exp))

    def work_one(job):
        f, idx, name, code, exp = job
        tmp = tempfile.mkdtemp(prefix="c", dir=work)
        try:
            if SHOW and any(w in name or w == f + ":" + name for w in SHOW):
                ed = expectation(exp, "dash")
                sys.stdout.write("=== %s: %s\n%s--- expected(dash) %r\n--- ours %r\n--- dash %r\n--- bash %r\n" % (
                    f, name, code, ed, run([shname], code, tmp, spec_bin), run([dash], code, tmp, spec_bin) if dash else None,
                    run([bash, "--posix"], code, tmp, spec_bin) if bash else None))
            ed = expectation(exp, "dash")
            r_ours = run([shname], code, tmp, spec_bin)
            if meets(r_ours, ed):
                return ("PASS", f, name, "")
            detail = "ours=%r/%d expected=%r/%d" % (r_ours[0][:80], r_ours[1], ed.get("stdout", "<any>")[:80] if "stdout" in ed else "<any>", ed["status"])
            if dash:
                r_dash = run([dash], code, tmp, spec_bin)
                if r_dash == r_ours:
                    return ("DASH", f, name, detail)
                if bash:
                    r_bash = run([bash, "--posix"], code, tmp, spec_bin)
                else:
                    r_bash = None
                if meets(r_dash, ed):
                    return ("BUG", f, name, detail + " dash=%r/%d" % (r_dash[0][:80], r_dash[1]))
                if r_bash is not None and r_bash == r_ours:
                    return ("BASH", f, name, detail)
                return ("OTHER", f, name, detail + " dash=%r/%d" % (r_dash[0][:80], r_dash[1]))
            return ("OTHER", f, name, detail)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    counts = {}
    lines = []
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        for cat, f, name, detail in ex.map(work_one, jobs_list):
            counts[cat] = counts.get(cat, 0) + 1
            if cat != "PASS":
                lines.append("%s\t%s\t%s\t%s" % (cat, f, name.replace("\t", " "), detail.replace("\n", "~").replace("\t", " ")))
    shutil.rmtree(work, ignore_errors=True)
    text = "\n".join(lines) + ("\n" if lines else "")
    text += "SUMMARY\t" + " ".join("%s=%d" % (k, counts[k]) for k in sorted(counts)) + "\ttotal=%d\n" % len(jobs_list)
    if outfile:
        with open(outfile, "w") as o:
            o.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
