#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# yash-runner.sh - a runner for the yash `*.tst` test files, written from the
# documented test-case format (tests/README.md of yash): each case is
#
#     test_<outputs> [-d] [-e STATUS] [-f] 'name' [shell arguments...]
#     <standard input of the shell>
#     __IN__
#     <expected standard output>     (omitted by the capital-letter forms)
#     __OUT__
#     <expected standard error>
#     __ERR__
#
# `<outputs>` is o/O (check / expect empty stdout), e/E (stderr), x (none).
# `-e` checks the exit status (a number, `n` for non-zero, or a signal name), `-d`
# asks for a non-empty stderr, `-f` inverts the verdict (a documented bug).
# `setup` adds a script that runs before every case; `posix=true` runs the
# shell under test as `sh`; `skip=true` skips cases.
#
# The .tst file is read as data by this runner and executed by the shell that
# runs this script (dash), exactly as the format requires; it is never run on
# its own. The shell under test only ever gets the cases' scripts.
#
# usage: yash-runner.sh TESTEE TSTFILE RESULTFILE
# RESULTFILE gets one line per case: "PASS|FAIL|SKIP|XFAIL|XPASS file:line: name"
# and, for failures, a "  reason" line.
set -e
testee="${1:?testee}"; test_file="${2:?tst file}"; result_file="${3:?result file}"
case "$testee" in /*) ;; *) testee="$PWD/$testee";; esac
case "$test_file" in /*) ;; *) test_file="$PWD/$test_file";; esac
case "$result_file" in /*) ;; *) result_file="$PWD/$result_file";; esac

exec </dev/null 3>&- 4>&- 5>&-
: > "$result_file"
export LANG=C LC_ALL=C
unset -v ENV CDPATH IFS HOME PS1 PS2 PS4 MAIL MAILCHECK MAILPATH OLDPWD TERM HISTFILE FCEDIT
unset -v posix skip
umask 022

work="$(mktemp -d)"
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
mkdir "$work/run"
ln -s -- "$testee" "$work/run/sh"
export TESTEE="$testee"
testee_sh="$work/run/sh"
setup_script=""
name_base="$(basename "$test_file")"

setup() {
    case "${1--}" in
    -) setup "$(cat)";;
    -d)
        setup <<'END_DEFAULTS'
_empty= _sp=' ' _tab='	' _nl='
'
echoraw() {
    printf '%s\n' "$*"
}
bracket() {
    if [ $# -gt 0 ]; then printf '[%s]' "$@"; fi
    echo
}
END_DEFAULTS
        ;;
    *) setup_script="$setup_script
$1";;
    esac
}

record() { printf '%s %s:%s: %s\n' "$1" "$name_base" "$test_lineno" "$test_case_name" >> "$result_file"; }

testcase() {
    test_lineno="${1:?}"; shift
    OPTIND=1
    diag_required=false; want_status=""; should_succeed=true
    while getopts de:f opt; do
        case $opt in
        d) diag_required=true;;
        e) want_status="$OPTARG";;
        f) should_succeed=false;;
        *) return 64;;
        esac
    done
    shift "$((OPTIND - 1))"
    test_case_name="${1:?unnamed test}"; shift
    n="$test_lineno"
    in="$work/$n.in"; out="$work/$n.out"; err="$work/$n.err"
    { [ -n "$setup_script" ] && printf '%s\n' "$setup_script"; cat <&3; } > "$in"
    if [ -n "${skip-}" ]; then record SKIP; return 0; fi
    if [ "${posix:+set}" = set ]; then exe="$testee_sh"; else exe="$testee"; fi
    set +e
    (cd "$work/run" && exec timeout 20 "$exe" "$@" < "$in" > "$out" 2> "$err") 2> /dev/null
    status=$?
    set -e
    failed=false; reason=""
    case "$want_status" in
    '') ;;
    n) [ "$status" -eq 0 ] && { failed=true; reason="status 0, expected non-zero"; };;
    [A-Za-z]*)
        if [ "$status" -gt 128 ] && [ "$(kill -l "$status" 2> /dev/null)" = "$want_status" ]; then :; else failed=true; reason="status $status, expected signal $want_status"; fi;;
    *) [ "$status" -ne "$want_status" ] && { failed=true; reason="status $status, expected $want_status"; };;
    esac
    if { <&4; } 2> /dev/null; then
        cat <&4 > "$work/$n.xout"
        cmp -s "$work/$n.xout" "$out" || { failed=true; reason="$reason stdout differs: expected [$(head -c 200 "$work/$n.xout" | tr '\n' '~')] got [$(head -c 200 "$out" | tr '\n' '~')];"; }
    fi
    if $diag_required; then
        [ -s "$err" ] || { failed=true; reason="$reason stderr empty, expected a diagnostic;"; }
    elif { <&5; } 2> /dev/null; then
        cat <&5 > "$work/$n.xerr"
        cmp -s "$work/$n.xerr" "$err" || { failed=true; reason="$reason stderr differs: expected [$(head -c 200 "$work/$n.xerr" | tr '\n' '~')] got [$(head -c 200 "$err" | tr '\n' '~')];"; }
    fi
    if $should_succeed; then
        if $failed; then record FAIL; printf '  %s\n' "$reason" >> "$result_file"; else record PASS; fi
    else
        if $failed; then record XFAIL; else record XPASS; fi
    fi
    rm -f "$in" "$out" "$err"
}

alias test_x='testcase "$LINENO" 3<<\__IN__ 4<&- 5<&-'
alias test_o='testcase "$LINENO" 3<<\__IN__ 4<<\__OUT__ 5<&-'
alias test_O='testcase "$LINENO" 3<<\__IN__ 4</dev/null 5<&-'
alias test_e='testcase "$LINENO" 3<<\__IN__ 4<&- 5<<\__ERR__'
alias test_oe='testcase "$LINENO" 3<<\__IN__ 4<<\__OUT__ 5<<\__ERR__'
alias test_Oe='testcase "$LINENO" 3<<\__IN__ 4</dev/null 5<<\__ERR__'
alias test_E='testcase "$LINENO" 3<<\__IN__ 4<&- 5</dev/null'
alias test_oE='testcase "$LINENO" 3<<\__IN__ 4<<\__OUT__ 5</dev/null'
alias test_OE='testcase "$LINENO" 3<<\__IN__ 4</dev/null 5</dev/null'

set +e
(
    cd "$work/run"
    . "$test_file"
) 2> "$work/runner.err"
rc=$?
if [ $rc -ne 0 ] && [ -s "$work/runner.err" ]; then
    printf 'RUNNER-ERROR %s: rc=%s %s\n' "$name_base" "$rc" "$(head -c 300 "$work/runner.err" | tr '\n' '~')" >> "$result_file"
fi
exit 0
