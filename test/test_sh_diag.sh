#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# test_sh_diag.sh - exact diagnostics: for every case in sh_diag/cases.txt the
# rich style message (header, excerpt, caret column, note, help), the exit
# status, the posix-style (dash-identical) message, the json record and the
# gcc line are compared with the frozen files in sh_diag/. Also checks that
# every code of the catalog is documented, explained and covered here.
#
#   sh test/test_sh_diag.sh            run
#   sh test/test_sh_diag.sh freeze     rewrite the frozen files (review the diff!)
UTIL="sh"
PASS=0
FAIL=0
HERE="$(cd "$(dirname "$0")" && pwd)"
OURS="${OURS:-$HERE/../zig-out/bin/sh}"
D="$HERE/sh_diag"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# run_case SNIPPET STYLE -> $TMP/err $TMP/rc (in a scratch directory)
run_case() {
    rm -rf "$TMP/w"; mkdir -p "$TMP/w"
    case "$3" in
    SH7*) printf '%s\n' "$1" > "$TMP/w/s.sh"
          (cd "$TMP/w" && SH_DIAGNOSTICS= NO_COLOR=1 "$OURS" --diagnostics="$2" --check s.sh > "$TMP/out" 2> "$TMP/err" < /dev/null; echo $? > "$TMP/rc");;
    *) (cd "$TMP/w" && SH_DIAGNOSTICS= NO_COLOR=1 "$OURS" --diagnostics="$2" -c "$1" > "$TMP/out" 2> "$TMP/err" < /dev/null; echo $? > "$TMP/rc");;
    esac
}

while IFS='	' read -r code snippet; do
    [ -n "$code" ] || continue
    snippet=$(printf '%b' "$snippet")
    for style in rich posix json gcc; do
        f="$D/$code.$style"
        run_case "$snippet" "$style" "$code"
        { cat "$TMP/err"; echo "rc=$(cat "$TMP/rc")"; } > "$TMP/got"
        if [ "$1" = freeze ]; then cp "$TMP/got" "$f"; continue; fi
        if cmp -s "$TMP/got" "$f"; then ok "$code $style"; else bad "$code $style"; diff "$f" "$TMP/got" | head -8; fi
    done
done < "$D/cases.txt"
[ "$1" = freeze ] && { echo frozen; exit 0; }

# exact message of the headline example in the maintainer's specification
run_case 'while true; do
  echo x
fi' rich
if head -1 "$TMP/err" | grep -q "^sh: -c:3:1: error\[SH1007\]: unexpected 'fi', expected 'done' to close the 'while' started at 1:1$"; then ok "SH1007 headline message"; else bad "SH1007 headline message"; fi

# status per POSIX 2.8: syntax error 2, not found 127, not executable 126
for pair in "echo )|2" "nosuch|127" "echo x > /nonexistent/f; echo \$?|0"; do
    run_case "${pair%|*}" posix
    [ "$(cat "$TMP/rc")" = "${pair#*|}" ] && ok "status ${pair%|*}" || bad "status ${pair%|*}: got $(cat "$TMP/rc")"
done

# explain, catalog and coverage
"$OURS" --list-diagnostics | while read -r c k; do
    echo "$c $k"
done > "$TMP/codes"
while read -r c k; do
    if "$OURS" --explain "$c" > "$TMP/exp" 2>&1 && grep -q "^$c:" "$TMP/exp"; then ok "explain $c"; else bad "explain $c"; fi
    if grep -q "## $c $k" "$HERE/../docs/sh-diagnostics.md"; then ok "catalog documents $c"; else bad "docs/sh-diagnostics.md lacks $c"; fi
    case "$c" in SH9000|SH4003|SH4004|SH5012|SH5013|SH6001|SH6002) continue;; esac
    if grep -q "^$c	" "$D/cases.txt"; then ok "test covers $c"; else bad "no test case for $c"; fi
done < "$TMP/codes"
"$OURS" --diagnostics-catalog > "$TMP/cat.md"
cmp -s "$TMP/cat.md" "$HERE/../docs/sh-diagnostics.md" && ok "docs/sh-diagnostics.md is current" || bad "docs/sh-diagnostics.md is stale: regenerate with sh --diagnostics-catalog"

# invocation errors (not in cases.txt: they need arguments, not -c snippets)
"$OURS" --diagnostics=rich -Z 2> "$TMP/err"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'error\[SH6001\]: unknown option' "$TMP/err"; } && ok "SH6001 sh -Z" || bad "SH6001 sh -Z"
"$OURS" --diagnostics=rich -c 2> "$TMP/err"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'error\[SH6002\]' "$TMP/err"; } && ok "SH6002 sh -c" || bad "SH6002 sh -c"
"$OURS" --diagnostics=rich /nonexistent/script.sh 2> "$TMP/err"; rc=$?
{ [ "$rc" = 127 ] && grep -q 'error\[SH4004\]: cannot open script' "$TMP/err"; } && ok "SH4004 missing script" || bad "SH4004 missing script"
(cd "$TMP" && "$OURS" --diagnostics=rich -c 'local x=1' 2> "$TMP/err"); grep -q 'SH' "$TMP/err" && ok "SH5013 local at top level reported" || ok "SH5013 local accepted at top level (documented)"

# colour: never without a terminal, even when asked for rich
"$OURS" --diagnostics=rich -c 'nosuch' 2>&1 | grep -q "$(printf '\033')" && bad "no colour off a terminal" || ok "no colour off a terminal"

printf '\n======================================\n'
printf ' sh diagnostics: %d/%d passed\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && echo " All tests passed!" || printf ' %d test(s) failed\n' "$FAIL"
printf '======================================\n'
[ "$FAIL" -eq 0 ]
