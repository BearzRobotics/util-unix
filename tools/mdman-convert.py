#!/usr/bin/env python3
"""Convert a template.md-style page (pandoc-ish: % title block, bare ALL-CAPS section lines,
tab tables) to the Markdown dkman renders (# SECTION headings, fenced/indented synopsis, pipe tables)."""
import re, sys
src = open(sys.argv[1]).read().split('\n')
out = []
i = 0
# drop the % title block (first lines starting with '%')
while i < len(src) and (src[i].startswith('%') or src[i].strip() == ''):
    i += 1
head = re.compile(r'^[A-Z][A-Z0-9 ,/&()-]{2,}$')
section = None
while i < len(src):
    l = src[i]
    prev_blank = (not out) or out[-1].strip() == ''
    if head.match(l) and l.strip() == l and (prev_blank or True):
        section = l
        if out and out[-1].strip() != '':
            out.append('')
        out.append('# ' + l)
        out.append('')
        i += 1
        # SYNOPSIS: indent every line as a code block
        if section == 'SYNOPSIS':
            while i < len(src) and not head.match(src[i]):
                out.append(('    ' + src[i]) if src[i].strip() else '')
                i += 1
        continue
    # tab-separated table: consecutive lines containing tabs
    if '\t' in l:
        rows = []
        while i < len(src) and '\t' in src[i]:
            rows.append([c.strip() for c in src[i].split('\t')]); i += 1
        n = max(len(r) for r in rows)
        rows = [r + [''] * (n - len(r)) for r in rows]
        out.append('| ' + ' | '.join(rows[0]) + ' |')
        out.append('|' + '---|' * n)
        for r in rows[1:]:
            out.append('| ' + ' | '.join(c.replace('|', '\\|') for c in r) + ' |')
        out.append('')
        continue
    out.append(l); i += 1
# Source pages keep one paragraph per line; Markdown would merge adjacent lines, so
# separate them, except a term followed by its ': definition' (and its continuations),
# code blocks (indented), table rows and list items.
final = []
in_code = False
for idx, l in enumerate(out):
    nxt = out[idx + 1] if idx + 1 < len(out) else ''
    final.append(l)
    if not l.strip() or nxt.strip() == '':
        continue
    if l.startswith('    ') or l.startswith('|') or l.startswith('# '):
        continue
    if nxt.startswith(': ') or nxt.startswith('    ') or nxt.startswith('|') or nxt.startswith('  '):
        continue
    if l.startswith(': ') or l.startswith('  ') or l.startswith('- ') or nxt.startswith('- '):
        continue
    final.append('')
print('\n'.join(final))
