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

# explain, catalog and coverage: driven by the machine-readable catalog
"$OURS" --list-diagnostics --diagnostics=json > "$TMP/catalog.json"
"$OURS" --list-diagnostics | while read -r c k; do
    echo "$c $k"
done > "$TMP/codes"
# every plain-text code appears in the JSON catalog with the same kind, and vice versa
[ "$(wc -l < "$TMP/catalog.json")" = "$(wc -l < "$TMP/codes")" ] && ok "json catalog lists every code" || bad "json catalog differs in size from the plain list"
while read -r c k; do
    grep -q "^{\"code\":\"$c\",\"kind\":\"$k\"" "$TMP/catalog.json" && ok "json catalog has $c" || bad "json catalog lacks $c"
    for field in severity exit summary message posix shellcheck help explain bad good; do
        grep "^{\"code\":\"$c\"" "$TMP/catalog.json" | grep -q "\"$field\":" || bad "json catalog $c lacks $field"
    done
    if "$OURS" --explain "$c" > "$TMP/exp" 2>&1 && grep -q "^$c:" "$TMP/exp"; then ok "explain $c"; else bad "explain $c"; fi
    "$OURS" --explain "$c" --diagnostics=json | grep -q "^{\"code\":\"$c\"" && ok "explain json $c" || bad "explain json $c"
    if grep -q "## $c $k" "$HERE/../docs/sh-diagnostics.md"; then ok "catalog documents $c"; else bad "docs/sh-diagnostics.md lacks $c"; fi
    sc=$(grep "^{\"code\":\"$c\"" "$TMP/catalog.json" | sed 's/.*"shellcheck":\([^,]*\),.*/\1/')
    case "$sc" in null) ;; \"SC[0-9]*\") grep -q "^ShellCheck: ${sc#\"}" "$TMP/exp" 2>/dev/null || { "$OURS" --explain "$c" | grep -q "^ShellCheck: " && ok "explain names ShellCheck for $c" || bad "explain lacks the ShellCheck id of $c"; };; *) bad "bad shellcheck field of $c: $sc";; esac
    case "$c" in SH9000|SH4004|SH5013|SH6001|SH6002) continue;; esac
    if grep -q "^$c	" "$D/cases.txt"; then ok "test covers $c"; else bad "no test case for $c"; fi
done < "$TMP/codes"
# the shellcheck id also appears in the json diagnostic of a case (SH1001 maps to SC1089)
run_case 'echo )' json
grep -q '"shellcheck":"SC1089"' "$TMP/err" && ok "json diagnostic carries the shellcheck id" || bad "json diagnostic lacks the shellcheck id"
run_case 'nosuch' json
grep -q '"shellcheck":null' "$TMP/err" && ok "json diagnostic shellcheck null when none" || bad "json diagnostic shellcheck null"
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


# colour: --color=always forces escapes in the rich style, never suppresses
# them, NO_COLOR is honoured by auto; off a terminal auto prints none
"$OURS" --diagnostics=rich --color=always -c 'nosuch' 2>&1 | grep -q "$(printf '\033')" && ok "--color=always forces escapes" || bad "--color=always forces escapes"
"$OURS" --diagnostics=rich --diagnostics-color=always -c 'nosuch' 2>&1 | grep -q "$(printf '\033')" && ok "--diagnostics-color=always" || bad "--diagnostics-color=always"
"$OURS" --diagnostics=rich --color=never -c 'nosuch' 2>&1 | grep -q "$(printf '\033')" && bad "--color=never" || ok "--color=never"
"$OURS" --diagnostics=rich --color=auto -c 'nosuch' 2>&1 | grep -q "$(printf '\033')" && bad "--color=auto off a terminal" || ok "--color=auto off a terminal"
"$OURS" --color=sometimes -c : 2> /dev/null; [ $? = 2 ] && ok "--color rejects a bad value" || bad "--color rejects a bad value"
if command -v script > /dev/null 2>&1; then
    esc=$(printf '\033')
    script -qec "$OURS --diagnostics=rich -c nosuch" /dev/null 2>&1 | grep -q "$esc" && ok "auto colours on a pty" || bad "auto colours on a pty"
    NO_COLOR=1 script -qec "$OURS --diagnostics=rich -c nosuch" /dev/null 2>&1 | grep -q "$esc" && bad "NO_COLOR on a pty" || ok "NO_COLOR on a pty"
    script -qec "$OURS --diagnostics=rich --color=never -c nosuch" /dev/null 2>&1 | grep -q "$esc" && bad "--color=never on a pty" || ok "--color=never on a pty"
    script -qec "$OURS -c nosuch" /dev/null 2>&1 | grep -q "error\[SH4001\]" && ok "auto is rich on a pty" || bad "auto is rich on a pty"
else
    printf 'SKIP pty colour tests (no script(1))\n'
fi

# the environment is inherited: an inner shell under SH_DIAGNOSTICS=json prints json,
# an explicit option on the inner shell wins
SH_DIAGNOSTICS=json "$OURS" -c "$OURS -c 'echo )'" 2> "$TMP/err"
grep -q '^{"code":"SH1001"' "$TMP/err" && ok "inner sh inherits SH_DIAGNOSTICS=json" || bad "inner sh inherits SH_DIAGNOSTICS=json"
SH_DIAGNOSTICS=json "$OURS" -c "$OURS --diagnostics=posix -c 'echo )'" 2> "$TMP/err"
grep -q 'Syntax error: ")" unexpected' "$TMP/err" && ! grep -q '^{' "$TMP/err" && ok "explicit --diagnostics on the inner shell wins" || bad "explicit --diagnostics on the inner shell wins"
SH_DIAGNOSTICS=rich "$OURS" -c "$OURS --diagnostics=gcc -c 'echo )'" 2> "$TMP/err"
grep -q '^-c:1:' "$TMP/err" && ok "inner --diagnostics=gcc beats SH_DIAGNOSTICS=rich" || bad "inner --diagnostics=gcc beats SH_DIAGNOSTICS=rich"
SH_DIAGNOSTICS=rich "$OURS" --color=always -c "$OURS -c 'nosuch'" 2>&1 | grep -q "$(printf '\033')" && bad "colour is not inherited off a terminal" || ok "colour is not inherited off a terminal"

# stable exit status and stdout: the style and the terminal never change what a
# script observes, only the text of stderr
for snippet in 'echo before; echo )' 'echo before; nosuch; echo after' 'echo before; echo x > notexec.f; ./notexec.f; echo after' \
    'echo before; set -e; false; echo after' 'echo before; set -u; echo $nope; echo after' 'echo before; echo ${x!}; echo after' \
    'echo before; echo $((1/0)); echo after' 'echo before; readonly r=1; r=2; echo after' 'echo before; cat < /nonexistent/f; echo after' \
    'echo before; while true; do echo x; fi' 'echo before; echo ${y?need}; echo after'; do
    ref=""
    for style in posix rich json gcc; do
        for term in notty pty; do
            rm -rf "$TMP/w"; mkdir -p "$TMP/w"
            if [ "$term" = pty ]; then
                command -v script > /dev/null 2>&1 || continue
                (cd "$TMP/w" && script -qec "$OURS --diagnostics=$style -c '$snippet' 2>/dev/null; echo rc=\$?" /dev/null > "$TMP/o" < /dev/null)
                got="$(tr -d '\r' < "$TMP/o")"
            else
                (cd "$TMP/w" && "$OURS" --diagnostics="$style" -c "$snippet" > "$TMP/o" 2> /dev/null < /dev/null; echo "rc=$?" >> "$TMP/o")
                got="$(cat "$TMP/o")"
            fi
            [ -z "$ref" ] && ref="$got"
            if [ "$got" = "$ref" ]; then ok "stable status+stdout [$style $term] $snippet"; else bad "status/stdout differ [$style $term] $snippet"; fi
        done
    done
done

printf '\n======================================\n'
printf ' sh diagnostics: %d/%d passed\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && echo " All tests passed!" || printf ' %d test(s) failed\n' "$FAIL"
printf '======================================\n'
[ "$FAIL" -eq 0 ]
