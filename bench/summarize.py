#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Read one poop report (two benchmarks) on stdin; print tab-separated
ratios ours/GNU: wall cycles instructions rss."""
import re, sys

UNIT = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1.0, "ks": 1e3,
        "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
        "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "": 1}
line_re = re.compile(r"^\s+(wall_time|peak_rss|cpu_cycles|instructions)\s+([\d.]+)\s*(ks|ms|us|ns|KB|MB|GB|TB|s|B|K|M|G|T)?")

bench = 0
vals = [{}, {}]
for line in sys.stdin:
    if line.startswith("Benchmark "):
        bench += 1
        continue
    m = line_re.match(line)
    if m and 1 <= bench <= 2:
        vals[bench - 1][m.group(1)] = float(m.group(2)) * UNIT[m.group(3) or ""]

def ratio(k):
    a, b = vals[0].get(k), vals[1].get(k)
    return "n/a" if not a or b is None else "%.2f" % (b / a)

print("\t".join(ratio(k) for k in ("wall_time", "cpu_cycles", "instructions", "peak_rss")))
