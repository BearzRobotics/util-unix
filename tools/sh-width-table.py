#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Usage: python3 -I tools/sh-width-table.py > src/lib/sh/width_table.zig
import sys, unicodedata as u
def ranges(pred):
    out = []
    for cp in range(0x300, 0x40000 if True else 0x110000):
        if pred(cp):
            if out and out[-1][1] == cp - 1: out[-1][1] = cp
            else: out.append([cp, cp])
    return out
def zero(cp):
    c = u.category(chr(cp))
    # combining marks, format characters, and the vowels and finals of a Hangul syllable
    return c in ("Mn", "Me", "Cf") or 0x1160 <= cp <= 0x11ff
def wide(cp):
    # (unassigned code points of the ideograph planes are wide too)
    if 0x20000 <= cp <= 0x2fffd or 0x30000 <= cp <= 0x3fffd: return not zero(cp)
    return u.category(chr(cp)) != "Cn" and u.east_asian_width(chr(cp)) in ("W", "F") and not zero(cp)
def table(name, doc, r):
    s = "/// %s\npub const %s = [_][2]u21{\n" % (doc, name)
    for i in range(0, len(r), 4):
        s += "    " + " ".join(".{ 0x%04x, 0x%04x }," % tuple(x) for x in r[i:i+4]) + "\n"
    return s + "};\n"
z = ranges(zero)
# the tag and variation selector characters beyond the planes scanned
z += [[0xe0001, 0xe0001], [0xe0020, 0xe007f], [0xe0100, 0xe01ef]]
sys.stdout.write("// SPDX-License-Identifier: GPL-2.0-or-later\n//! Column widths, generated from Unicode %s (EastAsianWidth and the general\n//! categories). Do not edit by hand.\n\n" % u.unidata_version)
sys.stdout.write(table("zero_width", "Characters that take no column, from U+0300 up.", z) + "\n" + table("wide", "Characters that take two columns.", ranges(wide)))
