#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""sh-gold-doc.py - regenerate the DIFFERENCES table of docs/posix-shell-differences.md
and the statistics of docs/compatibility/sh.md from a tools/sh-gold.py run.

    tools/sh-gold.sh --out /tmp/gold                 (all sources)
    python3 -I tools/sh-gold-doc.py /tmp/gold [--doc docs/posix-shell-differences.md]

Every test_sh.sh case on which the shells that were run do not all agree
becomes a row: the snippet, each shell's result (shells with the same result
grouped), the rule that decided (gold-agree = dash and FreeBSD sh agree;
POSIX section = dash and FreeBSD sh differ and POSIX decides; dash fallback =
they differ and POSIX is silent), what ours does, the verdict and a category
(POSIX-defined, POSIX-undefined, implementation-defined, bug-in-other-shell).
Category and commentary written for a snippet in the previous version of the
table are kept (matched by the snippet); new rows get a category from the note
of the case in test/test_sh.sh, or POSIX-undefined.
"""
import json
import os
import re
import sys

ORDER = ["dash", "freebsd", "bash-posix", "bash-as-sh", "busybox-ash", "yash-posix", "ours"]


def short(r):
    o = r["out"].replace("\n", "~")
    if len(o) > 70:
        o = o[:67] + "..."
    return "%s rc=%d" % (o, r["rc"]) if o else "rc=%d" % r["rc"]


def esc(s):
    return s.replace("|", "\\|").replace("`", "'")


def norm(s):
    return " ".join(s.replace("\\|", "|").split())


def harvest(doc):
    old = {}
    for line in open(doc, encoding="utf-8"):
        if not line.startswith("| `"):
            continue
        cells = re.split(r"(?<!\\)\|", line.strip().strip("|"))
        if len(cells) < 4:
            continue
        snip = cells[0].strip()
        if snip.startswith("`") and snip.endswith("`"):
            snip = snip[1:-1]
        old[norm(snip)] = (cells[-2].strip(), cells[-1].strip())
    return old


def cite(note):
    m = re.search(r"(XCU|XBD) [0-9][0-9.]*(?: [A-Za-z][A-Za-z -]*)?", note)
    return m.group(0).strip() if m else ""


def category(note, rec):
    n = note.lower()
    if "bug" in n and "other" in n:
        return "bug-in-other-shell"
    if re.search(r"unspecified|undefined|leaves|not specified|silent", n):
        return "POSIX-undefined"
    if re.search(r"implementation", n):
        return "implementation-defined"
    if cite(note):
        return "POSIX-defined"
    return "POSIX-undefined"


def main():
    args = sys.argv[1:]
    res = os.path.join(args[0], "results.jsonl") if os.path.isdir(args[0]) else args[0]
    doc = "docs/posix-shell-differences.md"
    if "--doc" in args:
        doc = args[args.index("--doc") + 1]
    recs = [json.loads(l) for l in open(res)]
    old = harvest(doc)
    rows = []
    n_test = 0
    for r in recs:
        if r["source"] != "test_sh":
            continue
        n_test += 1
        sigs = {(v["out"], v["rc"]) for k, v in r["res"].items()}
        if len(sigs) <= 1 or r["class"] in ("NONDET", "UNUSABLE"):
            continue
        groups = {}
        for k in ORDER:
            if k in r["res"]:
                groups.setdefault(short(r["res"][k]), []).append(k)
        results = "; ".join("%s: `%s`" % (", ".join(v), esc(k)) for k, v in groups.items())
        note = r.get("note", "")
        oldc = old.get(norm(r["text"]))
        c = cite(note)
        if r["class"] == "GOLD_AGREE":
            rule = "gold-agree" + ("" if r["ours"] == "MATCH" else "; ours deviates (%s)" % (c or "documented below"))
        else:
            rule = ("POSIX %s" % c) if c else "dash fallback (POSIX silent)"
        verdict = {"MATCH": "agrees with gold", "MATCH-dash": "follows dash", "MATCH-bsd": "follows FreeBSD",
                   "MISMATCH": "deviates from both (documented)"}[r["ours"]]
        cat = oldc[0] if oldc else category(note, r)
        text = oldc[1] if oldc else note
        rows.append("| `%s` | %s | %s | `%s` | %s | %s | %s |" % (
            esc(r["text"].replace("\n", " ")), results, rule, esc(short(r["res"]["ours"])), verdict, cat, esc(text)))
    table = ["# DIFFERENCES", "",
             "Every case of `test/test_sh.sh` (%d snippets) on which the shells that were run disagree: %d rows. Columns: the snippet; the result of each shell (stdout with newlines shown as `~`, then the exit status; shells with the same result are grouped); the rule that decided (gold-agree: dash and FreeBSD sh agree, so that is the standard; `POSIX x.y`: they differ and POSIX decides; dash fallback: they differ and POSIX is silent); ours; the verdict; the category; the POSIX text and what ours does." % (n_test, len(rows)), "",
             "| Snippet | Results (shells that agree are grouped) | Rule | Ours | Verdict | Category | POSIX says, and what ours does |",
             "|---------|----------------------------------------|------|------|---------|----------|-------------------------------|"] + rows + [""]
    text = open(doc, encoding="utf-8").read()
    a = text.index("# DIFFERENCES\n")
    b = text.index("# DEVIATIONS FROM THE GOLD STANDARD")
    text = text[:a] + "\n".join(table) + "\n" + text[b:]
    text = re.sub(r"\d+ cases differ\.", "%d cases differ." % len(rows), text)
    open(doc, "w", encoding="utf-8").write(text)
    print("rows: %d of %d" % (len(rows), n_test))


if __name__ == "__main__":
    main()
