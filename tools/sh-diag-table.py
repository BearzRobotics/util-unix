#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""sh-diag-table.py - write the catalog table of docs/manpages/sh.md from the
shell's own catalog, so that the two cannot drift apart.

usage: python3 -I tools/sh-diag-table.py SH [--check]
With --check the manual is left alone and the exit status says whether its
table is current.
"""
import json, os, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
manual = os.path.join(root, "docs/manpages/sh.md")
out = subprocess.run([sys.argv[1], "--list-diagnostics", "--diagnostics=json"], capture_output=True, text=True, check=True).stdout

def cell(text):
    if not text:
        return "-"
    text = text.replace("\n", " ; ").replace("|", "\\|")
    return "`` %s ``" % text if "`" in text else "`%s`" % text

rows = ["| Code | Kind | Status | Example | dash says |", "|------|------|--------|---------|-----------|"]
for line in out.splitlines():
    e = json.loads(line)
    rows.append("| %s | %s | %s | %s | %s |" % (e["code"], e["kind"], e["exit"] or "-", cell(e["bad"]), cell(e["posix"])))

lines = open(manual, encoding="utf-8").read().split("\n")
first = next(i for i, l in enumerate(lines) if l.startswith("| Code | Kind | Status | Example |"))
last = first
while last < len(lines) and lines[last].startswith("|"):
    last += 1
new = lines[:first] + rows + lines[last:]
if "--check" in sys.argv:
    sys.exit(0 if new == lines else 1)
open(manual, "w", encoding="utf-8").write("\n".join(new))
