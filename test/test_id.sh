#!/bin/sh
# id: differential tests against GNU id 9.7 (C locale). Users come from this
# machine's /etc/passwd and /etc/group.
UTIL="id"
. "$(dirname "$0")/testlib.sh"
ME="$(/usr/bin/id -un)"
USERS="$ME root nobody daemon bin sys sync games www-data 0 1 1000 65534 99999 nosuchuser_xyz ''"
for o in "" -u -g -G -un -gn -Gn -ur -gr -Gr -unr -gnr -Gnr -z "-z -G" "-zG" "-zGn" -uz -gz -a "-a -u" "-n" "-r" "-nr" "-ug" "-uG" "-gG" "-ugG" -Z "-Z -u" --user --group --groups "--user --name" "--groups --name --real" --zero "--groups --zero" --context; do
    run_cmp "id $o"        $o
done
for u in $USERS; do
    for o in "" -u -g -G -un -gn -Gn -ur -z; do
        run_cmp "id $o $u"     $o "$u"
    done
done
run_cmp "two users"        root nobody
run_cmp "user then bad"    root nosuchuser_xyz nobody
run_cmp "-G two users"     -G root nobody
run_cmp "-- user"          -- root
run_cmp "-x"               -x
run_cmp "--bogus"          --bogus
run_cmp "--user=x"         --user=x
run_cmp "-u user missing"  -u nosuchuser_xyz
print_summary
