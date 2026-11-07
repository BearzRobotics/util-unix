#!/bin/sh
# groups: differential tests against GNU groups 9.7 (C locale).
UTIL="groups"
. "$(dirname "$0")/testlib.sh"
ME="$(/usr/bin/id -un)"
run_cmp "groups"
for u in $ME root nobody daemon bin www-data nosuchuser_xyz 0 1000; do
    run_cmp "groups $u"    "$u"
done
run_cmp "two users"        root nobody
run_cmp "user, bad, user"  root nosuchuser_xyz nobody
run_cmp "-x"               -x
run_cmp "--bogus"          --bogus
run_cmp "--"               -- root
print_summary
