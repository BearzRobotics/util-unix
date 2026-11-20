#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""sh-gold-report.py - print the interesting records of a sh-gold results.jsonl.

usage: sh-gold-report.py DIR_OR_FILE [--only bug|posix|all] [--source S] [--filter SUBSTR] [--full]
  bug    GOLD_AGREE and ours MISMATCH (our-bug candidates)    [default]
  posix  POSIX_DECIDES and ours MISMATCH (needs a POSIX decision)
"""
import json
import os
import sys

args = sys.argv[1:]
path = args.pop(0)
if os.path.isdir(path):
    path = os.path.join(path, "results.jsonl")
only, source, filt, full = "bug", None, "", False
while args:
    a = args.pop(0)
    if a == "--only":
        only = args.pop(0)
    elif a == "--source":
        source = args.pop(0)
    elif a == "--filter":
        filt = args.pop(0)
    elif a == "--full":
        full = True
n = 0
for line in open(path):
    r = json.loads(line)
    if source and r["source"] != source:
        continue
    if filt and filt not in r["id"] and filt not in r["name"]:
        continue
    if only == "bug" and not (r["class"] == "GOLD_AGREE" and r["ours"] == "MISMATCH"):
        continue
    if only == "posix" and not (r["class"] == "POSIX_DECIDES" and r["ours"] == "MISMATCH"):
        continue
    n += 1
    print("=== %s  %s" % (r["id"], r["name"]))
    txt = r["text"] if full else r["text"][:600]
    print(txt)
    for k, v in r["res"].items():
        o = v["out"] if full else v["out"][:300]
        print("--- %-12s rc=%-3s out=%r  err=%r" % (k, v["rc"], o, v["err"][:200] if not full else v["err"]))
print("\n%d records" % n)
