#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# chown: differential tests against GNU chown. References: POSIX.1-2024 chown;
# GNU coreutils manual "chown invocation". Runs unprivileged (see ownlib.sh):
# the owner can only be set to the invoking user, so the owner:group grammar is
# exercised with that user and with failing (EPERM / unknown) specs.
UTIL="chown"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/ownlib.sh"
export LC_ALL=C

t() { desc=$1; shift; run_tree "$desc" "$SETUP" "$@"; }
g() { desc=$1; shift; need_group2 "$desc" && run_tree "$desc" "$SETUP" "$@"; }

printf "\n[ OWNER[:GROUP] grammar ]\n"
t "owner only (self)"                    "$U" f
t "owner by uid"                         "$UID1" f
t "owner by +uid"                        +"$UID1" f
t "owner -v retained"                    -v "$U" f
g "owner:group"                          -v "$U:$G2" f
g "owner.group (deprecated separator)"   -v "$U.$G2" f
g ":group"                               -v ":$G2" f
g "owner: (login group)"                 -v "$U:" f
t "owner: -v retained (login group)"     -v "$U:" f
g "uid:gid numeric"                      -v "$UID1:$G2ID" f
g "+uid:+gid"                            -v "+$UID1:+$G2ID" f
t "':' alone changes nothing"            -v : f
t "empty spec"                           "" f
t "'.' alone"                            . f
g "group only -c"                        -c ":$G2" f
g "-c owner:group"                       -c "$U:$G2" f
g "-v owner:group when group same"       -v "$U:$G1" f
t "unknown user"                         nosuchuser f
t "unknown group"                        "$U:nosuchgroup" f
t "unknown user with group"              nosuchuser:"$G1" f
t "unknown numeric owner (EPERM)"        54321 f
t "numeric > uid_t max"                  99999999999 f
t "uid -1 (4294967295)"                  4294967295 f
t "negative uid"                         -- -1 f
t "owner: for unknown user"              nosuchuser: f
t "numeric owner: invalid spec"          54321: f
t "root (EPERM)"                         root f
t "root -v failure"                      -v root f
t "root -c failure"                      -c root f
t "root -f"                              -f root f
t "root:group (EPERM)"                   root:"$G1" f
t "0"                                    0 f
t "user.group warning, unknown dot user" nosuchuser.nosuchgroup f
g "dot with warning prints warning"      "$U.$G2" f g

printf "\n[ --from ]\n"
t "--from=user matches"                  --from="$U" -v "$U" f
t "--from=user does not match"           --from=root -v "$U" f
g "--from=:group matches"                --from=:"$G1" -v ":$G2" f
g "--from=:group does not match"         --from=:"$G2" -v ":$G1" f
g "--from=user:group matches"            --from="$U:$G1" -v ":$G2" f
t "--from=nosuchuser"                    --from=nosuchuser -v "$U" f
t "--from=nosuchgroup"                   --from=:nosuchgroup -v "$U" f
t "--from=0 (numeric)"                   --from=0 -v "$U" f
g "--from with -R"                       --from="$U:$G1" -R -v ":$G2" d
g "--from -R mismatch"                   --from=root -R -v ":$G2" d
g "--from -h link"                       --from="$U" -h -v ":$G2" l
g "--from on a directory"                --from="$U" -v ":$G2" d
g "--from dot warning"                   --from="$U.$G1" -v ":$G2" f

printf "\n[ Errors and operands ]\n"
t "no operands"
t "owner only, no file"                  "$U"
t "missing file"                         "$U" nonexistent
t "missing file -v"                      -v "$U" nonexistent
t "missing file -f"                      -f "$U" nonexistent
t "--reference only"                     --reference=f
t "--reference missing"                  --reference=nonexistent f
t "unknown option"                       -z "$U" f
t "unknown long option"                  --bogus "$U" f
t "ambiguous --no"                       --no "$U" f
t "--from missing argument"              --from
t "--reference missing argument"         --reference
t "--verbose=x takes no argument"        --verbose=x "$U" f
t "-R --dereference needs -H or -L"      -R --dereference "$U" d
t "dangling link default"                "$U" dangling
t "dangling link -h"                     -h -v "$U" dangling

printf "\n[ --reference ]\n"
g "--reference (owner and group)"        -v --reference=g f
t "--reference self"                     -v --reference=f f
g "--reference via link"                 -v --reference=l g

printf "\n[ Recursion and symbolic links ]\n"
g "-R tree"                              -R -v "$U:$G2" d
g "-R -c"                                -R -c "$U:$G2" d
g "-R -H"                                -R -H -v "$U:$G2" dl
g "-R -L"                                -R -L -v "$U:$G2" dl
g "-R -P"                                -R -P -v "$U:$G2" dl
g "-R -h"                                -R -h -v "$U:$G2" d
g "-h on link"                           -h -v "$U:$G2" l
g "link default dereferences"            -v "$U:$G2" l
g "-R unreadable dir"                    -R -v "$U:$G2" noread
t "-R --preserve-root /"                 -R --preserve-root "$U" /
t "-R failure inside tree (EPERM)"       -R -v root d

print_summary
[ "$FAIL" -eq 0 ]
