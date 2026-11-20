#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# test_sh_lint.sh - shellcheck as an oracle for the sh test corpus and parser.
#
# 1. Corpus hygiene: every snippet of test_sh.sh outside its EXEMPT section
#    must be free of syntax (SC1xxx) and non-POSIX (SC3xxx) findings under
#    `shellcheck -s dash`.
# 2. Syntax oracle: for the repository's own scripts and the snippets, our
#    parser accepts exactly what shellcheck parses without an SC1xxx error,
#    and `sh -n` agrees with `dash -n` on the exit status.
# Skipped, with a message, when shellcheck is missing.
UTIL="sh"
PASS=0
FAIL=0
HERE="$(cd "$(dirname "$0")" && pwd)"
OURS="${OURS:-$HERE/../zig-out/bin/sh}"

if ! command -v shellcheck > /dev/null 2>&1; then
    echo "SKIP shellcheck is not installed; lint checks not run"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/snip"
SHCMP_DUMP="$TMP/snip" sh "$HERE/test_sh.sh" > /dev/null 2>&1

ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# --- 1. hygiene ---
n=0
for f in "$TMP"/snip/case*.sh; do
    n=$((n + 1))
    out=$(shellcheck -s dash -S warning -f gcc "$f" 2>&1 | grep -E 'SC[13][0-9][0-9][0-9]')
    if [ -z "$out" ]; then ok "hygiene $(basename "$f")"; else bad "hygiene $(basename "$f"): $out"; fi
done
printf 'checked %s POSIX snippets (exempt snippets are not linted)\n' "$n"

# --- 2. syntax oracle ---
oracle() {
    f="$1"
    sc=$(shellcheck -s dash -S error -f gcc "$f" 2>&1 | grep -c 'SC1[0-9][0-9][0-9]')
    "$OURS" -n "$f" > /dev/null 2>&1; ours=$?
    dash -n "$f" > /dev/null 2>&1; d=$?
    if [ "$sc" -eq 0 ] && [ "$ours" -ne 0 ]; then
        bad "oracle $f: shellcheck parses it, ours rejects (rc=$ours; dash rc=$d)"
    elif [ "$sc" -gt 0 ] && [ "$ours" -eq 0 ]; then
        bad "oracle $f: shellcheck reports a syntax error, ours accepts (dash rc=$d)"
    elif [ "$ours" -ne "$d" ]; then
        bad "sh -n vs dash -n on $f: ours=$ours dash=$d"
    else
        ok "oracle $f"
    fi
}
for f in "$TMP"/snip/*.sh "$HERE"/*.sh "$HERE"/../tools/*.sh "$HERE"/../bench/*.sh /stuff/git/util-core/test/*.sh /stuff/git/util-core/tools/*.sh /etc/init.d/*; do
    [ -f "$f" ] || continue
    oracle "$f"
done

printf '\n======================================\n'
printf ' sh lint/oracle: %d/%d passed\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && echo " All tests passed!" || printf ' %d test(s) failed\n' "$FAIL"
printf '======================================\n'
[ "$FAIL" -eq 0 ]
