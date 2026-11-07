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
t "-R --preserve-root /"                 -R --preserve-root "$G1" /
t "-R --preserve-root /."                -R --preserve-root "$G1" /.
t "-R --preserve-root //"                -R --preserve-root "$G1" //
g "--preserve-root without -R is fine"   --preserve-root "$G2" f
t "--no-preserve-root accepted"          --no-preserve-root "$G1" f
t "-RL --preserve-root on link to /"     -RL --preserve-root "$G1" rootlink
run_tree "-RL --preserve-root link to /" "$SETUP; ln -s / rootlink" -RL --preserve-root "$G1" rootlink
run_tree "-RH --preserve-root link to /" "$SETUP; ln -s / rootlink" -RH --preserve-root "$G1" rootlink

print_summary
[ "$FAIL" -eq 0 ]
