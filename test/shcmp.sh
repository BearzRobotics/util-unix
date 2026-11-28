#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shcmp.sh - generic multi-shell comparison runner (sourced by test_sh*.sh).
#
# Every case is a shell snippet run with `-c` by each installed reference
# shell and by our `sh`, in a fresh empty working directory. Compared:
# stdout and exit status against every reference; stderr (program name and
# "line N" normalised) against dash only, because the wording of
# diagnostics is not specified by POSIX (only that they go to stderr).
#
# Classification per case (decision 0009 and the maintainer's rule):
#   AGREE   all installed references agree with each other: ours must match.
#   VARIES  references disagree: ours must match dash or FreeBSD sh; the case
#           is recorded (SH_DOC_OUT gets a markdown table row).
#   FAIL    ours matches none (hard failure).
#
# To add a shell, append "name|command" to REF_SHELLS in `shcmp_detect`; the
# runner skips shells that are not installed.
# a memory-limited scope of its own, so a runaway case cannot take the caller down
[ "${TEST_CONTAINED:-}" = "cg:$(cat /proc/self/cgroup 2>/dev/null)" ] || exec sh "$(dirname "$0")/contain.sh" sh "$0" "$@"

PASS=0
FAIL=0
SKIP=0
VARIES=0
BSD_SAME=0
BSD_DIFF=0
SHCMP_HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SHCMP_HERE/../zig-out/bin" 2>/dev/null && pwd)"
OURS="${OURS:-$BIN_DIR/sh}"
TEST_TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TEST_TMP" 2>/dev/null; rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
# bash invoked under the name `sh` (distro /bin/sh -> bash)
[ -x /usr/bin/bash ] && ln -sf /usr/bin/bash "$TEST_TMP/bin/sh"

shcmp_detect() {
    REF_SHELLS=""
    [ -x /usr/bin/dash ] && REF_SHELLS="$REF_SHELLS dash|/usr/bin/dash"
    [ -x /usr/bin/bash ] && REF_SHELLS="$REF_SHELLS bash-posix|/usr/bin/bash|--posix"
    [ -x "$TEST_TMP/bin/sh" ] && REF_SHELLS="$REF_SHELLS bash-as-sh|$TEST_TMP/bin/sh"
    [ -x /usr/bin/busybox ] && REF_SHELLS="$REF_SHELLS busybox-ash|/usr/bin/busybox|ash"
    [ -x /usr/bin/yash ] && REF_SHELLS="$REF_SHELLS yash-posix|/usr/bin/yash|--posix"
    [ -x /usr/bin/yash ] && REF_SHELLS="$REF_SHELLS yash|/usr/bin/yash"
    [ -n "${SHCMP_ONLY:-}" ] && REF_SHELLS=$(printf '%s\n' $REF_SHELLS | grep -E "^($SHCMP_ONLY)\|" | tr '\n' ' ')
    BSD=""
    if [ -z "${SHCMP_NO_BSD:-}" ] && [ -x "${CHIMERA_ROOT:-/stuff/tmp/chimera-sysroot}/bin/sh" ] && command -v bwrap >/dev/null 2>&1; then
        BSD=1
    fi
}
shcmp_detect

# With nothing to compare with, everything would agree: dash decides where the
# others differ, and both it and the shell under test must be there.
case " $REF_SHELLS " in
    *" dash|"*) ;;
    *) echo "FATAL: no dash among the reference shells (REF_SHELLS='$REF_SHELLS'; see SHCMP_ONLY)" >&2; exit 2 ;;
esac
[ -x "$OURS" ] || { echo "FATAL: the shell under test, '$OURS', is not an executable" >&2; exit 2; }

# Normalise a diagnostic: program name and "line N" forms. The number stays: it
# is part of what a diagnostic says.
shcmp_norm() {
    sed -e 's#^\(/[^ :]*/\)\{0,1\}\(dash\|sh\|bash\|busybox\|ash\|yash\|mksh\)\(: line\)\{0,1\}: \([0-9]*: \)\{0,1\}#sh: \4#'
}

# No file a case writes may grow past 10 MB (512-byte blocks), and it dumps no
# core. The output is read into a variable below: a shell that let a producer
# write straight into the capture file would take this script's memory with it.
shcmp_limits() {
    ulimit -S -f 20000 2>/dev/null
    ulimit -S -c 0 2>/dev/null
}

# shcmp_run NAME CMD ARGS... -- snippet : run one shell, leaves $W.out .err .rc
shcmp_exec() {
    prefix="$1"; snippet="$2"; w="$3"
    rm -rf "$w"; mkdir -p "$w"
    shcmp_inner_sh $prefix
    (shcmp_limits; cd "$w" && PATH="$TEST_TMP/inner:$PATH" SH_DIAGNOSTICS=posix timeout 20 $prefix -c "$snippet" < /dev/null > "$w.out" 2> "$w.err"; echo $? > "$w.rc")
}

# A snippet that runs `sh` must get the shell being compared, not the system's:
# a directory holding `sh -> that shell` goes first on PATH. It is the same
# directory for every shell, so a snippet that prints the path prints the same.
shcmp_inner_sh() {
    case $1 in /*) inner=$1 ;; *) inner=$PWD/$1 ;; esac
    mkdir -p "$TEST_TMP/inner" && rm -f "$TEST_TMP/inner/sh" && ln -s "$inner" "$TEST_TMP/inner/sh"
}

# Self-check: inside a case, `sh` must be our shell when our shell runs the case.
shcmp_exec "$OURS" 'command -v sh' "$TEST_TMP/selfcheck"
if [ "$(cat "$TEST_TMP/selfcheck.out")" != "$TEST_TMP/inner/sh" ] || ! [ "$TEST_TMP/inner/sh" -ef "$OURS" ]; then
    echo "FATAL: inside a case, 'sh' is not the shell under test ($OURS)" >&2
    exit 2
fi

shcmp_bsd() {
    snippet="$1"; w="$2"
    rm -rf "$w"; mkdir -p "$w"
    (shcmp_limits; cd "$w" && timeout 30 sh "$SHCMP_HERE/../tools/bsdrun.sh" sh -c "$snippet" < /dev/null > "$w.out" 2> "$w.err"; echo $? > "$w.rc")
}

# c DESCRIPTION SNIPPET [FLAGS] [NOTE]
#   FLAGS: any of  B (also compare FreeBSD sh)  E (compare stderr with dash;
#   default on)  e (do NOT compare stderr)  M (only stdout+status vs ours,
#   skip dash stderr)
c() {
    desc="$1"; snippet="$2"; flags="${3:-}"; note="${4:-}"
    base="$TEST_TMP/case"
    shcmp_exec "$OURS" "$snippet" "$base.ours"
    ours_sig="$(cat "$base.ours.out"; echo "rc=$(cat "$base.ours.rc")")"
    ours_err="$(shcmp_norm < "$base.ours.err")"
    n=0; agree=0; matrix=""; dash_sig=""; dash_err=""; same_as_dash=0; posix_same=0
    for spec in $REF_SHELLS; do
        name="${spec%%|*}"; rest="${spec#*|}"
        cmd="${rest%%|*}"; arg=""; case "$rest" in *\|*) arg="${rest#*|}";; esac
        shcmp_exec "$cmd $arg" "$snippet" "$base.$name"
        sig="$(cat "$base.$name.out"; echo "rc=$(cat "$base.$name.rc")")"
        n=$((n + 1))
        if [ "$sig" = "$ours_sig" ]; then agree=$((agree + 1)); mark="="; case "$name" in bash-posix|yash-posix) posix_same=1;; esac; else mark="!"; fi
        matrix="$matrix $name$mark"
        if [ "$name" = dash ]; then
            dash_sig="$sig"; dash_err="$(shcmp_norm < "$base.dash.err")"
            [ "$sig" = "$ours_sig" ] && same_as_dash=1
        fi
    done
    bsd_same=0
    bsig=""
    if [ -n "$BSD" ] && case "$flags" in *B*) true;; *) false;; esac; then
        shcmp_bsd "$snippet" "$base.bsd"
        bsig="$(cat "$base.bsd.out"; echo "rc=$(cat "$base.bsd.rc")")"
        if [ "$bsig" = "$ours_sig" ]; then bsd_same=1; BSD_SAME=$((BSD_SAME + 1)); matrix="$matrix freebsd="; else BSD_DIFF=$((BSD_DIFF + 1)); matrix="$matrix freebsd!"; fi
    fi
    # stderr vs dash
    err_ok=1
    case "$flags" in
    # the wording is not compared, but where dash fails as we do and says why,
    # we must not fail in silence (where it fails otherwise, say for want of
    # `pipefail`, its message is about something else)
    *e*) [ -n "$dash_err" ] && [ -z "$ours_err" ] && [ "$dash_sig" = "$ours_sig" ] && [ "$(cat "$base.ours.rc")" != 0 ] && err_ok=0 ;;
    *) [ -n "$dash_sig" ] && [ "$dash_err" != "$ours_err" ] && err_ok=0 ;;
    esac
    verdict=PASS; kind=AGREE
    if [ "$agree" -ne "$n" ]; then kind=VARIES; fi
    if [ "$kind" = AGREE ] && [ $bsd_same = 0 ] && [ -n "$BSD" ] && case "$flags" in *B*) true;; *) false;; esac; then
        kind=VARIES
    fi
    if [ "$kind" = VARIES ]; then
        if [ $same_as_dash = 1 ] || [ $bsd_same = 1 ] || { [ $posix_same = 1 ] && case "$flags" in *P*) true;; *) false;; esac; }; then VARIES=$((VARIES + 1)); else verdict=FAIL; fi
    elif [ $err_ok = 0 ]; then
        verdict=FAIL
    fi
    if [ "$verdict" = PASS ] && [ $err_ok = 0 ] && [ "$kind" = VARIES ]; then verdict=FAIL; fi
    if [ "$verdict" = PASS ]; then
        PASS=$((PASS + 1))
        printf 'PASS %s\n' "$desc"
        [ -n "${SHCMP_MATRIX:-}" ] && printf '     [%s] %s\n' "$kind" "$matrix"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n' "$desc"
        printf '     snippet: %s\n' "$snippet"
        printf '     [%s] %s\n' "$kind" "$matrix"
        printf '     OURS  : %s | err: %s\n' "$(printf '%s' "$ours_sig" | tr '\n' '~')" "$(printf '%s' "$ours_err" | tr '\n' '~')"
        [ -n "$dash_sig" ] && printf '     DASH  : %s | err: %s\n' "$(printf '%s' "$dash_sig" | tr '\n' '~')" "$(printf '%s' "$dash_err" | tr '\n' '~')"
    fi
    if [ "$kind" = VARIES ] && [ -n "${SH_DOC_OUT:-}" ]; then
        {
            printf '| %s |' "$(printf '%s' "$snippet" | sed 's/|/\\|/g' | tr '\n' ' ')"
            for spec in $REF_SHELLS; do
                name="${spec%%|*}"
                printf ' %s: `%s` |' "$name" "$(printf '%s' "$(cat "$base.$name.out"; echo "rc=$(cat "$base.$name.rc")")" | tr '\n' '~' | sed 's/|/\\|/g')"
            done
            if [ -n "$bsig" ]; then printf ' freebsd: `%s` |' "$(printf '%s' "$bsig" | tr '\n' '~' | sed 's/|/\\|/g')"; else printf ' freebsd: - |'; fi
            printf ' ours: `%s` | %s |\n' "$(printf '%s' "$ours_sig" | tr '\n' '~' | sed 's/|/\\|/g')" "$note"
        } >> "$SH_DOC_OUT"
    fi
}

# must DESCRIPTION SNIPPET EXPECTED: our output and status ("...rc=N") must be
# exactly EXPECTED. For behaviour dash does not have: `c` accepts whatever
# agrees with dash, a failure like dash's included.
must() {
    base="$TEST_TMP/case"
    shcmp_exec "$OURS" "$2" "$base.ours"
    got="$(cat "$base.ours.out"; echo "rc=$(cat "$base.ours.rc")")"
    if [ "$got" = "$3" ]; then
        PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s\n     snippet: %s\n     OURS  : %s\n     WANT  : %s\n' "$1" "$2" "$(printf '%s' "$got" | tr '\n' '~')" "$(printf '%s' "$3" | tr '\n' '~')"
    fi
}

skip_case() {
    SKIP=$((SKIP + 1)); printf 'SKIP %s\n' "$1"
}

print_summary() {
    TOTAL=$((PASS + FAIL + SKIP))
    printf '\n======================================\n'
    printf ' %s: %d/%d passed' "${UTIL:-sh}" "$PASS" "$TOTAL"
    [ "$SKIP" -gt 0 ] && printf ' (%d skipped)' "$SKIP"
    printf ' (%d recorded as shells-differ)\n' "$VARIES"
    if [ -n "$BSD" ]; then
        printf ' FreeBSD sh cross-check: %d same as ours, %d different (of %d run)\n' "$BSD_SAME" "$BSD_DIFF" "$((BSD_SAME + BSD_DIFF))"
    else
        printf ' FreeBSD sh cross-check: NOT RUN (needs bwrap and a sysroot in CHIMERA_ROOT; see tools/bsdrun.sh)\n'
    fi
    if [ "$FAIL" -gt 0 ]; then printf ' %d test(s) failed\n' "$FAIL"; else printf ' All tests passed!\n'; fi
    printf '======================================\n'
    [ "$FAIL" -eq 0 ]
}
