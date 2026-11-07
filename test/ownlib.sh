#!/bin/sh
# ownlib.sh - shared fixtures for the chown and chgrp differential tests.
#
# Tests run unprivileged: they may change a file's group to any group the
# invoking user belongs to, and its owner to the user itself. Anything else
# fails with EPERM, which is also compared against GNU. Changing to arbitrary
# users needs root and is NOT covered here (see docs/compatibility/chown.md).

U=$(id -un)
G1=$(id -gn)
G2=$(id -Gn | tr ' ' '\n' | grep -vx "$G1" | head -n 1)
G2ID=$(getent group "$G2" 2>/dev/null | cut -d: -f3)
G1ID=$(id -g)
UID1=$(id -u)

# A tree with every kind of entry the traversal rules distinguish.
SETUP='mkdir -p d/sub e; touch f d/a d/sub/b e/x; ln -s f l; ln -s d dl; ln -s nosuch dangling
ln -s ../f d/inner_l; ln -s ../e d/inner_dl; ln -s .. d/sub/up; mkdir noread; touch noread/y; chmod 000 noread
touch zero; chmod 000 zero; printf "data" > g; chmod 755 d'

# need_group2: skip group-changing tests when the user has only one group.
need_group2() {
    [ -n "$G2" ] && return 0
    skip_test "$1 (user belongs to only one group)"
    return 1
}
