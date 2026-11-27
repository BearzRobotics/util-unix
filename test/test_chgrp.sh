#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# chgrp: differential tests against GNU chgrp. References: POSIX.1-2024 chgrp;
# GNU coreutils manual "chgrp invocation". Runs unprivileged (see ownlib.sh).
UTIL="chgrp"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/ownlib.sh"
export LC_ALL=C

t() { desc=$1; shift; run_tree "$desc" "$SETUP" "$@"; }
g() { desc=$1; shift; need_group2 "$desc" && run_tree "$desc" "$SETUP" "$@"; }

printf "\n[ Basics ]\n"
g "change group"                         "$G2" f
g "by numeric gid"                       "$G2ID" f
g "by +gid"                              +"$G2ID" f
g "to the group it already has"          "$G1" f
t "to own primary group"                 "$G1" f
g "several files"                        "$G2" f g d/a
g "-v changed"                           -v "$G2" f
g "-v retained"                          -v "$G1" f
g "-c changed"                           -c "$G2" f
t "-c unchanged prints nothing"          -c "$G1" f
g "-c and -v: last wins (v)"             -c -v "$G2" f
g "-v then -c"                           -v -c "$G2" f
g "no-read file"                         -v "$G2" zero
g "-- ends options"                      -v -- "$G2" f
g "options after operands"               "$G2" f -v
g "abbreviated --verb? ambiguous"        --ver "$G2" f
g "--verbose"                            --verbose "$G2" f
g "--changes"                            --changes "$G2" f

printf "\n[ Errors ]\n"
t "unknown group"                        nosuchgroup f
t "unknown numeric gid (EPERM)"          54321 f
t "group not a member of (EPERM)"        root f
t "-v failure message"                   -v root f
t "-c failure message"                   -c root f
t "-f suppresses the error"              -f root f
t "-f still fails"                       -f nosuchgroup f
t "missing file"                         "$G1" nonexistent
t "missing file with -v"                 -v "$G1" nonexistent
t "missing file with -f"                 -f "$G1" nonexistent
g "one missing among good"               "$G2" f nonexistent g
t "no operands"
t "group only"                           "$G1"
t "unknown option"                       -z "$G1" f
t "unknown long option"                  --bogus "$G1" f
t "ambiguous --no"                       --no "$G1" f
t "--reference with missing file"        --reference=nonexistent f
t "--reference no files"                 --reference=f
t "--from not accepted by chgrp"         --from=:"$G1" "$G1" f
# --help: GNU appends three "online help" lines; compare all but those.
t "empty group spec"                     "" f
t "-R --dereference needs -H or -L"      -R --dereference "$G1" d
t "dangling link default (dereference)"  "$G1" dangling
t "dangling link -h"                     -h -v "$G1" dangling

printf "\n[ --reference ]\n"
g "--reference"                          --reference=g f
g "--reference -v"                       -v --reference=g f
g "--reference to a link follows it"     -v --reference=l g

printf "\n[ Symbolic links ]\n"
g "link, default dereferences"           -v "$G2" l
g "link, -h changes the link"            -h -v "$G2" l
g "link, --dereference"                  --dereference -v "$G2" l
g "link to dir, no -R"                   -v "$G2" dl
g "link to dir, -h"                      -h -v "$G2" dl

printf "\n[ Recursion ]\n"
g "-R dir (post-order)"                  -R -v "$G2" d
g "-R -c"                                -R -c "$G2" d
g "-R multiple operands"                 -R -v "$G2" d e
g "-R on a file"                         -R -v "$G2" f
g "-R with trailing slash"               -R -v "$G2" d/
g "-R with double slash"                 -R -v "$G2" d//
g "-R -P (default): links not followed"  -R -P -v "$G2" d
g "-R -H top-level link to dir"          -R -H -v "$G2" dl
g "-R -H inner links not followed"       -R -H -v "$G2" d
g "-R -L top-level link to dir"          -R -L -v "$G2" dl
g "-R -L follows inner links"            -R -L -v "$G2" e d/inner_dl
g "-R -P top-level link to dir"          -R -P -v "$G2" dl
g "-R -h"                                -R -h -v "$G2" d
g "-R -H -h"                             -R -H -h -v "$G2" dl
g "-R -L cycle (d/sub/up -> ..)"         -R -L -v "$G2" d
g "-R unreadable dir"                    -R -v "$G2" noread
g "-R unreadable dir, -f"                -R -f "$G2" noread
t "-R missing"                           -R "$G1" nonexistent
t "-R failure inside tree"               -R -v root d
g "-R --dereference -H"                  -R --dereference -H -v "$G2" dl
g "-R last of -H -L -P wins"             -R -L -P -v "$G2" dl
g "-R -P -L"                             -R -P -L -v "$G2" dl
g "-H without -R is ignored"             -H -v "$G2" dl
g "-L without -R is ignored"             -L -v "$G2" l

printf "\n[ --preserve-root ]\n"
root_sandboxed "$SCRATCH" t "-R --preserve-root /"                 -R --preserve-root "$G1" /
root_sandboxed "$SCRATCH" t "-R --preserve-root /."                -R --preserve-root "$G1" /.
root_sandboxed "$SCRATCH" t "-R --preserve-root //"                -R --preserve-root "$G1" //
g "--preserve-root without -R is fine"   --preserve-root "$G2" f
t "--no-preserve-root accepted"          --no-preserve-root "$G1" f
root_sandboxed "$SCRATCH" t "-RL --preserve-root on link to /"     -RL --preserve-root "$G1" rootlink
root_sandboxed "$SCRATCH" run_tree "-RL --preserve-root link to /" "$SETUP; ln -s / rootlink" -RL --preserve-root "$G1" rootlink
root_sandboxed "$SCRATCH" run_tree "-RH --preserve-root link to /" "$SETUP; ln -s / rootlink" -RH --preserve-root "$G1" rootlink

printf "\n[ Deep trees ]\n"
# a second group where there is one, so that an unchanged entry shows
DG=${G2:-$G1}
low_fd_tree "-R short of descriptors"              -R -v "$DG" w
low_fd_tree "-R -L short of descriptors, links"    -R -L -v "$DG" links/0
low_fd_tree "-R fast path short of descriptors"    -R "$DG" w
very_deep_case "-R 20000 levels (fast path)" "-group $DG" -R "$DG" deep
very_deep_case "-R -c 20000 levels" "-group $DG" -R -c "$DG" deep

# a message about a very long name must come out whole (a fixed buffer dropped it)
LONG=$(printf '%0200d' 0)
run_tree "long path: diagnostic is not dropped" ':' "$(id -gn)" "$LONG/$LONG/$LONG/$LONG/$LONG/$LONG"
run_tree "very long path with control characters" ':' -v "$(id -gn)" "$(printf '\001%.0s' $(seq 250))/$LONG/$LONG/$LONG/$LONG/$LONG/$LONG/$LONG/$LONG"
LONG_TREE='L=$(printf "%0200d" 0); mkdir -p $L/$L/$L/$L/$L/$L && touch $L/$L/$L/$L/$L/$L/f'
run_tree "long paths: every -v line" "$LONG_TREE" -R -v "$(id -gn)" "$(printf '%0200d' 0)"

# --from opens the file to change it: one swapped for a FIFO while the open is
# on its way (strace holds it up) must not make that wait for a writer
if command -v strace > /dev/null 2>&1 && strace -o /dev/null true 2> /dev/null; then
    fifo_dir="$(mktemp -d)"; : > "$fifo_dir/f"
    ( cd "$fifo_dir" && timeout -s KILL 20 strace -f -o trace -e trace=openat -P f -e inject=openat:delay_enter=2000000 \
        "$BIN_DIR/chgrp" --from=:"$(id -gn)" "$(id -gn)" f > out 2>&1 ) &
    fifo_job=$!; tries=0
    while [ "$tries" -lt 200 ] && ! grep -q openat "$fifo_dir/trace" 2> /dev/null; do tries=$((tries + 1)); sleep 0.05; done
    rm "$fifo_dir/f"; mkfifo "$fifo_dir/f"
    if wait "$fifo_job" || [ "$?" -ne 137 ]; then PASS=$((PASS + 1)); echo "PASS --from does not wait on a FIFO swapped in"
    else FAIL=$((FAIL + 1)); echo "FAIL --from does not wait on a FIFO swapped in"; fi
else
    echo "SKIP --from FIFO swap (needs strace)"
fi

: > "$TMPDIR_CMP.f"; run_full "-v, full disk" -v "$(id -gn)" "$TMPDIR_CMP.f"
print_summary
[ "$FAIL" -eq 0 ]
