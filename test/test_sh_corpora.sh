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
[ "${TEST_CONTAINED:-}" = "cg:$(cat /proc/self/cgroup 2>/dev/null)" ] || exec sh "$(dirname "$0")/contain.sh" timeout 1800 sh "$0" "$@"
if command -v bwrap > /dev/null 2>&1 && bwrap --unshare-pid --die-with-parent --dev-bind / / true > /dev/null 2>&1; then
    # Oils cases share /tmp/oil-spec-test and one removes a directory in it: each
    # case, run in parallel with others, gets its own
    # These are thousands of scripts from elsewhere, run by a shell being worked
    # on: everything is read-only to them but /tmp (and the device nodes, which
    # test -b needs; their own permissions apply), and there is no network.
    SANDBOX="setsid -w bwrap --unshare-pid --unshare-ipc --unshare-net --die-with-parent --ro-bind / / --dev-bind /dev /dev --proc /proc --bind /tmp /tmp --tmpfs /tmp/oil-spec-test"
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
# (TMPDIR may be elsewhere than /tmp)
SANDBOX="$SANDBOX --bind $TMP $TMP"
export SANDBOX
REPORT="${REPORT:-$TMP/report.txt}"
: > "$REPORT"
FAIL=0
RUNNER_SH=""
for c in "bash --posix" yash "busybox ash"; do
    command -v "${c%% *}" > /dev/null 2>&1 && { RUNNER_SH="$c"; break; }
done

[ -x "$OURS" ] || { echo "no sh at $OURS (build with zig build -Doptimize=ReleaseSafe -Dcommands=sh -Dmode=standalone)"; exit 1; }
WANT="$*"
want_corpus() { [ -z "$WANT" ] && return 0; case " $WANT " in *" $1 "*) return 0;; esac; return 1; }
RAN=0 # corpora actually run

# floor CORPUS PASSED MINIMUM: a corpus that was run must have passed about what
# it does with the pinned commits (tools/fetch-sh-corpora.sh). A crashed runner
# or a cut-short result file would otherwise just remove cases, and bugs.
floor() {
    case $2 in ''|*[!0-9]*) set -- "$1" 0 "$3" ;; esac
    [ "$2" -ge "$3" ] && return 0
    echo "FAIL $1: only $2 cases passed, expected at least $3"
    FAIL=1
}

# ---- yash ------------------------------------------------------------------
corpus_yash() {
    d="$CORPORA/yash/tests"
    if [ ! -d "$d" ]; then echo "SKIP yash: not downloaded (tools/fetch-sh-corpora.sh)"; return; fi
    if [ -z "$RUNNER_SH" ]; then echo "SKIP yash: needs bash, yash or busybox to run the runner"; return; fi
    RAN=$((RAN + 1))
    mkdir -p "$TMP/yash/ours" "$TMP/yash/dash"
    # The signal-disposition files (sig*-p) must start with every signal at its default
    # (yash starts its runner through its own compiled `resetsig`): test/sh_corpora/resetsig.c
    # is an equivalent, built here with cc or zig cc. Without a compiler those files are
    # skipped. The %REQUIRETTY% files need a controlling terminal (ptwrap/checkfg) and are
    # not run.
    RESETSIG=""
    for cc in cc gcc "zig cc"; do
        command -v "${cc%% *}" > /dev/null 2>&1 || continue
        $cc -O1 -o "$TMP/resetsig" "$HERE/sh_corpora/resetsig.c" > /dev/null 2>&1 && { RESETSIG="$TMP/resetsig"; break; }
    done
    [ -n "$RESETSIG" ] || echo "note yash: no C compiler (cc, gcc, zig cc): the sig*-p files are skipped"
    for f in "$d"/*-p.tst; do
        case "$(basename "$f")" in sig*) [ -n "$RESETSIG" ] || continue;; esac
        grep -q '%REQUIRETTY%' "$f" && continue
        echo "$f"
    done > "$TMP/yash/list"
    cat > "$TMP/run1.sh" <<RUN1
#!/bin/sh
# run1.sh TESTEE OUTDIR FILE
b="\$(basename "\$3" .tst)"
case "\$b" in sig*) pre="$RESETSIG -t 900"; export YASH_RUNNER_TIMEOUT="";; *) pre="";; esac
exec $SANDBOX \$pre $RUNNER_SH "$HERE/sh_corpora/yash-runner.sh" "\$1" "\$3" "\$2/\$b.res" > /dev/null 2>&1
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
    floor yash "$pass" 5700
    if grep -q '^RUNNER-ERROR' "$REPORT"; then echo "FAIL yash: the runner reported errors"; grep '^RUNNER-ERROR' "$REPORT" | head -5; FAIL=1; fi
}

# ---- freebsd ---------------------------------------------------------------
corpus_freebsd() {
    d="$CORPORA/freebsd/bin/sh/tests"
    if [ ! -d "$d" ]; then echo "SKIP freebsd: not downloaded (tools/fetch-sh-corpora.sh)"; return; fi
    RAN=$((RAN + 1))
    pass=0; fail=0; bug=0; oth=0
    find "$d" -type f | sort | while read -r f; do
        case "$f" in *.stdout|*.stderr|*/Makefile*|*/functional_test.sh) continue;; esac
        n="${f##*.}"
        case "$n" in *[!0-9]*|'') continue;; esac
        echo "$f"
    done > "$TMP/fb.list"
    runfb() { # runfb SHELL FILE -> prints "rc" and leaves $TMP/fb.out
        w="$TMP/fbw.$$"; rm -rf "$w"; mkdir -p "$w"
        (cd "$w" && SH="$1" $SANDBOX timeout 30 "$1" "$2" > "$TMP/fb.out.$$" 2> "$TMP/fb.err.$$" < /dev/null; echo $? > "$TMP/fb.rc.$$")
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
        judge "$OURS" "$f" # leave our run's output and status behind
        sd="stdout ok"
        if [ -f "$f.stdout" ]; then cmp -s "$TMP/fb.out.$$" "$f.stdout" || sd="stdout differs"; fi
        printf '%s\tfreebsd\t%s\texit %s, wanted %s; %s; stderr: %s\n' "$cat" "$rel" "$(cat "$TMP/fb.rc.$$")" "${f##*.}" "$sd" "$(head -c 140 "$TMP/fb.err.$$" | tr '\n\t' '~ ')" >> "$REPORT"
    done < "$TMP/fb.list"
    echo "freebsd: $pass passed, $fail failed ($bug bug, $oth other-shell)"
    floor freebsd "$pass" 430
}

# ---- oils ------------------------------------------------------------------
corpus_oils() {
    d="$CORPORA/oils/spec"
    if [ ! -d "$d" ]; then echo "SKIP oils: not downloaded (tools/fetch-sh-corpora.sh)"; return; fi
    command -v python3 > /dev/null 2>&1 || { echo "SKIP oils: needs python3"; return; }
    RAN=$((RAN + 1))
    if ! python3 -I "$HERE/sh_corpora/run_oils.py" "$d" "$OURS" --jobs "$JOBS" --sandbox "$SANDBOX" --out "$TMP/oils.out" > /dev/null 2> "$TMP/oils.err"; then
        if ! grep -q '^SUMMARY' "$TMP/oils.out" 2>/dev/null; then
            echo "FAIL oils: the adapter failed"; tail -5 "$TMP/oils.err"; FAIL=1; return
        fi
    fi
    grep -v '^SUMMARY' "$TMP/oils.out" | awk -F'\t' '{ c = ($1 == "BASH") ? "OTHER" : $1; printf "%s\toils\t%s\t%s\n", c, $2, $3 }' >> "$REPORT"
    echo "oils: $(grep '^SUMMARY' "$TMP/oils.out" | cut -f2,3 | tr '\t' ' ') (BUG = ours differs from the dash column that dash meets; DASH = ours equals dash)"
    floor oils "$(sed -n 's/^SUMMARY.*[[:blank:]]PASS=\([0-9]*\).*/\1/p' "$TMP/oils.out")" 1500
}

want_corpus yash && corpus_yash
want_corpus freebsd && corpus_freebsd
want_corpus oils && corpus_oils

# ---- verdict ---------------------------------------------------------------
grep -c '^BUG	' "$REPORT" | sed 's/^/open bugs: /'
if [ -f "$KNOWN" ]; then
    grep '^BUG	' "$REPORT" | awk -F'\t' '{ if ($2 == "freebsd") print $1 FS $2 FS $3; else print $1 FS $2 FS $3 FS $4 }' | sort -u > "$TMP/bugs.now"
    # cases recorded as shell-specific on purpose (with the reason) are not bugs
    RECLASS="$HERE/sh_corpora/reclassified.txt"
    if [ -f "$RECLASS" ]; then
        grep -v '^#' "$RECLASS" | awk -F'\t' 'NF >= 3 { if ($1 == "freebsd") print "BUG" FS $1 FS $2; else print "BUG" FS $1 FS $2 FS $3 }' | sort -u > "$TMP/bugs.reclass"
        comm -23 "$TMP/bugs.now" "$TMP/bugs.reclass" > "$TMP/bugs.now2"
        mv "$TMP/bugs.now2" "$TMP/bugs.now"
    fi
    sort -u "$KNOWN" > "$TMP/bugs.known"
    new="$(comm -23 "$TMP/bugs.now" "$TMP/bugs.known")"
    if [ -n "$new" ]; then
        FAIL=1
        printf 'FAIL: bugs not in %s:\n%s\n' "$KNOWN" "$new"
    fi
    fixed="$(comm -13 "$TMP/bugs.now" "$TMP/bugs.known" | wc -l)"
    [ "$fixed" -gt 0 ] && echo "note: $fixed recorded bugs no longer fail; refresh the list"
fi
[ "$REPORT" != "$TMP/report.txt" ] || true
# run_all_tests.sh counts PASS and FAIL lines: this verdict is the suite's result
if [ "$FAIL" -ne 0 ]; then echo "FAIL corpus check"
elif [ "$RAN" -gt 0 ]; then echo "PASS corpus check: no new bugs in $RAN corpora"
else echo "SKIP corpus check: no corpus is downloaded, nothing was checked"
fi
[ "$FAIL" -eq 0 ]
