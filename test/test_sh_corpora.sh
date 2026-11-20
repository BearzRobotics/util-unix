#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# test_sh_corpora.sh - run `sh` against the third-party POSIX shell test
# corpora fetched by tools/fetch-sh-corpora.sh (never committed):
#
#   yash     tests/*-p.tst, through our runner test/sh_corpora/yash-runner.sh
#            (the documented .tst format: stdin script, expected stdout/stderr/status)
#   freebsd  bin/sh/tests: every file NAME.N is a script that must exit N (0 for
#            success) and print NAME.N.stdout if that file exists
#   oils     spec/*.test.sh through test/sh_corpora/run_oils.py (annotations of the
#            dash column are the expectation)
#
# A corpus that is not downloaded is skipped. Every failing case is classified
# against dash (the gold standard rule of decision 0009):
#   BUG      dash meets the expectation and we do not: a bug of ours
#   DASH     we differ from the expectation exactly as dash does (the corpus
#            encodes another shell, or a non-POSIX feature, or a dash quirk)
#   OTHER    neither dash nor we meet it (shell-specific or non-POSIX)
# The suite fails on a BUG that is not listed in test/sh_corpora/known-bugs.txt
# (the record of what is still open, also written into docs/compatibility/sh.md).
#
#   sh test/test_sh_corpora.sh                 run all downloaded corpora
#   sh test/test_sh_corpora.sh yash oils       only these
#   REPORT=file sh test/test_sh_corpora.sh     write every non-passing case to FILE
#   SH_CORPORA_DIR=...  OURS=...  JOBS=8       configuration
HERE="$(cd "$(dirname "$0")" && pwd)"
# Containment: corpus cases send signals (kill 0, kill -1, process groups).
# The whole run is capped (memory, time) in a systemd scope when available and
# every case runs in its own session and PID namespace (bwrap), so a stray
# signal cannot reach the host. Without bwrap the corpora are not run.
if [ -z "${SH_CORPORA_CONTAINED:-}" ] && command -v systemd-run > /dev/null 2>&1 \
    && systemd-run --user --scope -q true > /dev/null 2>&1; then
    SH_CORPORA_CONTAINED=1 exec systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -p RuntimeMaxSec=1800 sh "$0" "$@"
fi
if command -v bwrap > /dev/null 2>&1 && bwrap --unshare-pid --die-with-parent --dev-bind / / true > /dev/null 2>&1; then
    SANDBOX="setsid -w bwrap --unshare-pid --unshare-ipc --die-with-parent --dev-bind / / --proc /proc"
else
    echo "SKIP corpora: bwrap is needed to contain the signals the cases send (install bubblewrap)"
    exit 0
fi
export SANDBOX
OURS="${OURS:-$HERE/../zig-out/bin/sh}"
CORPORA="${SH_CORPORA_DIR:-${HOME:-/tmp}/.cache/util-unix/sh-corpora}"
JOBS="${JOBS:-8}"
KNOWN="$HERE/sh_corpora/known-bugs.txt"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
REPORT="${REPORT:-$TMP/report.txt}"
: > "$REPORT"
FAIL=0
RUNNER_SH=""
for c in "bash --posix" yash "busybox ash"; do
    command -v "${c%% *}" > /dev/null 2>&1 && { RUNNER_SH="$c"; break; }
done

[ -x "$OURS" ] || { echo "no sh at $OURS (build with zig build -Doptimize=ReleaseSafe -Dcommands=sh -Dmode=standalone)"; exit 1; }
WANT="$*"
want_corpus() { [ -z "$WANT" ] || case " $WANT " in *" $1 "*) return 0;; esac; return 1; }

# ---- yash ------------------------------------------------------------------
corpus_yash() {
    d="$CORPORA/yash/tests"
    if [ ! -d "$d" ]; then echo "SKIP yash: not downloaded (tools/fetch-sh-corpora.sh)"; return; fi
    if [ -z "$RUNNER_SH" ]; then echo "SKIP yash: needs bash, yash or busybox to run the runner"; return; fi
    mkdir -p "$TMP/yash/ours" "$TMP/yash/dash"
    # Skipped: the signal-disposition files (sig*-p) start the shell through yash's
    # compiled `resetsig` helper and the %REQUIRETTY% files need a controlling
    # terminal (ptwrap/checkfg); neither helper is built here.
    for f in "$d"/*-p.tst; do
        case "$(basename "$f")" in sig*) continue;; esac
        grep -q '%REQUIRETTY%' "$f" && continue
        echo "$f"
    done > "$TMP/yash/list"
    cat > "$TMP/run1.sh" <<RUN1
#!/bin/sh
# run1.sh TESTEE OUTDIR FILE
b="\$(basename "\$3" .tst)"
exec $SANDBOX $RUNNER_SH "$HERE/sh_corpora/yash-runner.sh" "\$1" "\$3" "\$2/\$b.res" > /dev/null 2>&1
RUN1
    chmod +x "$TMP/run1.sh"
    while read -r f; do printf '%s\n' "$f"; done < "$TMP/yash/list" |
        xargs -P "$JOBS" -I '{}' "$TMP/run1.sh" "$OURS" "$TMP/yash/ours" '{}'
    if [ -x /usr/bin/dash ]; then
        while read -r f; do printf '%s\n' "$f"; done < "$TMP/yash/list" |
            xargs -P "$JOBS" -I '{}' "$TMP/run1.sh" /usr/bin/dash "$TMP/yash/dash" '{}'
    fi
    pass=0; fail=0; skip=0; bug=0; dsh=0; oth=0; xf=0
    for r in "$TMP"/yash/ours/*.res; do
        b="$(basename "$r" .res)"
        pend=""
        while IFS= read -r line; do
            case "$line" in
            "  "*) [ -n "$pend" ] && { printf '%s\t%s\n' "$pend" "$(printf '%s' "$line" | sed 's/^ *//')" >> "$REPORT"; pend=""; };;
            *) [ -n "$pend" ] && { printf '%s\n' "$pend" >> "$REPORT"; pend=""; }
               case "$line" in
            PASS*) pass=$((pass + 1));;
            SKIP*|XFAIL*|XPASS*) skip=$((skip + 1));;
            RUNNER-ERROR*) printf 'RUNNER-ERROR\tyash\t%s\t%s\n' "$b" "$line" >> "$REPORT";;
            FAIL*)
                fail=$((fail + 1))
                id="${line#FAIL }"
                key="$(printf '%s' "$id" | sed 's/[][\\.*^$/]/\\&/g')"
                if [ -f "$TMP/yash/dash/$b.res" ] && grep -q "^FAIL $key\$" "$TMP/yash/dash/$b.res"; then
                    cat="OTHER"; oth=$((oth + 1))
                else cat="BUG"; bug=$((bug + 1)); fi
                pend="$(printf '%s\tyash\t%s\t%s' "$cat" "$b" "$id")";;
               esac;;
            esac
        done < "$r"
        [ -n "$pend" ] && printf '%s\n' "$pend" >> "$REPORT"
    done
    echo "yash: $pass passed, $fail failed ($bug bug, $oth other-shell), $skip skipped/expected-failures"
}

# ---- freebsd ---------------------------------------------------------------
corpus_freebsd() {
    d="$CORPORA/freebsd/bin/sh/tests"
    if [ ! -d "$d" ]; then echo "SKIP freebsd: not downloaded (tools/fetch-sh-corpora.sh)"; return; fi
    pass=0; fail=0; bug=0; oth=0
    find "$d" -type f | sort | while read -r f; do
        case "$f" in *.stdout|*.stderr|*/Makefile*|*/functional_test.sh) continue;; esac
        n="${f##*.}"
        case "$n" in *[!0-9]*|'') continue;; esac
        echo "$f"
    done > "$TMP/fb.list"
    runfb() { # runfb SHELL FILE -> prints "rc" and leaves $TMP/fb.out
        w="$TMP/fbw.$$"; rm -rf "$w"; mkdir -p "$w"
        (cd "$w" && SH="$1" $SANDBOX timeout 30 "$1" "$2" > "$TMP/fb.out.$$" 2> /dev/null < /dev/null; echo $? > "$TMP/fb.rc.$$")
        rm -rf "$w"
    }
    judge() { # judge SHELL FILE -> 0 when the case passes
        runfb "$1" "$2"
        want="${2##*.}"
        [ "$(cat "$TMP/fb.rc.$$")" = "$want" ] || return 1
        if [ -f "$2.stdout" ]; then cmp -s "$TMP/fb.out.$$" "$2.stdout" || return 1; fi
        return 0
    }
    while read -r f; do
        rel="${f#"$d"/}"
        if judge "$OURS" "$f"; then pass=$((pass + 1)); continue; fi
        fail=$((fail + 1))
        if [ -x /usr/bin/dash ] && judge /usr/bin/dash "$f"; then cat="BUG"; bug=$((bug + 1)); else cat="OTHER"; oth=$((oth + 1)); fi
        printf '%s\tfreebsd\t%s\t(exit %s, wanted %s)\n' "$cat" "$rel" "$(cat "$TMP/fb.rc.$$")" "${f##*.}" >> "$REPORT"
    done < "$TMP/fb.list"
    echo "freebsd: $pass passed, $fail failed ($bug bug, $oth other-shell)"
}

# ---- oils ------------------------------------------------------------------
corpus_oils() {
    d="$CORPORA/oils/spec"
    if [ ! -d "$d" ]; then echo "SKIP oils: not downloaded (tools/fetch-sh-corpora.sh)"; return; fi
    command -v python3 > /dev/null 2>&1 || { echo "SKIP oils: needs python3"; return; }
    python3 -I "$HERE/sh_corpora/run_oils.py" "$d" "$OURS" --jobs "$JOBS" --sandbox "$SANDBOX" --out "$TMP/oils.out" > /dev/null 2>&1
    grep -v '^SUMMARY' "$TMP/oils.out" | awk -F'\t' '{ c = ($1 == "BASH") ? "OTHER" : $1; printf "%s\toils\t%s\t%s\n", c, $2, $3 }' >> "$REPORT"
    echo "oils: $(grep '^SUMMARY' "$TMP/oils.out" | cut -f2,3 | tr '\t' ' ') (BUG = ours differs from the dash column that dash meets; DASH = ours equals dash)"
}

want_corpus yash && corpus_yash
want_corpus freebsd && corpus_freebsd
want_corpus oils && corpus_oils

# ---- verdict ---------------------------------------------------------------
grep -c '^BUG	' "$REPORT" | sed 's/^/open bugs: /'
if [ -f "$KNOWN" ]; then
    grep '^BUG	' "$REPORT" | cut -f1-4 | sort > "$TMP/bugs.now"
    sort "$KNOWN" > "$TMP/bugs.known"
    new="$(comm -23 "$TMP/bugs.now" "$TMP/bugs.known")"
    if [ -n "$new" ]; then
        FAIL=1
        printf 'FAIL: bugs not in %s:\n%s\n' "$KNOWN" "$new"
    fi
    fixed="$(comm -13 "$TMP/bugs.now" "$TMP/bugs.known" | wc -l)"
    [ "$fixed" -gt 0 ] && echo "note: $fixed recorded bugs no longer fail; refresh the list"
fi
[ "$REPORT" != "$TMP/report.txt" ] || true
[ "$FAIL" -eq 0 ] && echo "All corpus checks passed (no new bugs)" || echo "corpus check failed"
[ "$FAIL" -eq 0 ]
