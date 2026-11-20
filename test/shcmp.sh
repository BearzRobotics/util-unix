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

PASS=0
FAIL=0
SKIP=0
VARIES=0
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

# Normalise a diagnostic: program name and "line N" forms.
shcmp_norm() {
    sed -e 's#^\(/[^ :]*/\)\{0,1\}\(dash\|sh\|bash\|busybox\|ash\|yash\|mksh\)\(: line\)\{0,1\}: \([0-9]*: \)\{0,1\}#sh: #' \
        -e 's#^sh: \([0-9]*\): #sh: #'
}

# shcmp_run NAME CMD ARGS... -- snippet : run one shell, leaves $W.out .err .rc
shcmp_exec() {
    prefix="$1"; snippet="$2"; w="$3"
    rm -rf "$w"; mkdir -p "$w"
    (cd "$w" && SH_DIAGNOSTICS=posix timeout 20 $prefix -c "$snippet" < /dev/null > "$w.out" 2> "$w.err"; echo $? > "$w.rc")
}

shcmp_bsd() {
    snippet="$1"; w="$2"
    rm -rf "$w"; mkdir -p "$w"
    (cd "$w" && timeout 30 sh "$SHCMP_HERE/../tools/bsdrun.sh" sh -c "$snippet" < /dev/null > "$w.out" 2> "$w.err"; echo $? > "$w.rc")
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
    n=0; agree=0; matrix=""; dash_sig=""; dash_err=""; same_as_dash=0; same_as_any_main=0
    for spec in $REF_SHELLS; do
        name="${spec%%|*}"; rest="${spec#*|}"
        cmd="${rest%%|*}"; arg=""; case "$rest" in *\|*) arg="${rest#*|}";; esac
        shcmp_exec "$cmd $arg" "$snippet" "$base.$name"
        sig="$(cat "$base.$name.out"; echo "rc=$(cat "$base.$name.rc")")"
        n=$((n + 1))
        if [ "$sig" = "$ours_sig" ]; then agree=$((agree + 1)); mark="="; else mark="!"; fi
        matrix="$matrix $name$mark"
        if [ "$name" = dash ]; then
            dash_sig="$sig"; dash_err="$(shcmp_norm < "$base.dash.err")"
            [ "$sig" = "$ours_sig" ] && same_as_dash=1
        fi
    done
    bsd_same=0
    if [ -n "$BSD" ] && case "$flags" in *B*) true;; *) false;; esac; then
        shcmp_bsd "$snippet" "$base.bsd"
        bsig="$(cat "$base.bsd.out"; echo "rc=$(cat "$base.bsd.rc")")"
        if [ "$bsig" = "$ours_sig" ]; then bsd_same=1; matrix="$matrix freebsd="; else matrix="$matrix freebsd!"; fi
    fi
    # stderr vs dash
    err_ok=1
    case "$flags" in *e*) ;; *) [ -n "$dash_sig" ] && [ "$dash_err" != "$ours_err" ] && err_ok=0;; esac
    verdict=PASS; kind=AGREE
    if [ "$agree" -ne "$n" ]; then kind=VARIES; fi
    if [ "$kind" = AGREE ] && [ $bsd_same = 0 ] && [ -n "$BSD" ] && case "$flags" in *B*) true;; *) false;; esac; then
        kind=VARIES
    fi
    if [ "$kind" = VARIES ]; then
        if [ $same_as_dash = 1 ] || [ $bsd_same = 1 ] || [ -z "$dash_sig" ]; then VARIES=$((VARIES + 1)); else verdict=FAIL; fi
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
            [ $bsd_same != 0 ] && printf ' freebsd: same |' || printf ' freebsd: - |'
            printf ' ours: `%s` | %s |\n' "$(printf '%s' "$ours_sig" | tr '\n' '~' | sed 's/|/\\|/g')" "$note"
        } >> "$SH_DOC_OUT"
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
    if [ "$FAIL" -gt 0 ]; then printf ' %d test(s) failed\n' "$FAIL"; else printf ' All tests passed!\n'; fi
    printf '======================================\n'
}
