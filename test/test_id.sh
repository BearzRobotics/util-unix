#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# id: differential tests against GNU id 9.7 (C locale). Users come from this
# machine's /etc/passwd and /etc/group.
UTIL="id"
. "$(dirname "$0")/testlib.sh"

# On musl, GNU id lists a group twice when /etc/group names the user in their own
# primary group (musl's getgrouplist), and its "no such user" ends in an errno
# text. Neither comes from id, so both are taken out of the reference's output
# there; ours is compared with it unchanged.
if ldd --version 2>&1 | grep -q '^musl'; then
    gnu() {
        "/usr/bin/id" "$@" > "$TMPDIR_CMP.idraw" 2> "$TMPDIR_CMP.iderr"; id_rc=$?
        python3 -I -c 'import re, sys
data = open(sys.argv[1], "rb").read()
def uniq(items): return list(dict.fromkeys(items))
if b"groups=" in data:
    data = re.sub(rb"groups=([^ \n\0]+)", lambda m: b"groups=" + b",".join(uniq(m.group(1).split(b","))), data)
elif any(a == "--groups" or (a[:1] == "-" and a[:2] != "--" and "G" in a) for a in sys.argv[2:]):
    out = b""
    for line in re.split(rb"(\n|\0\0)", data):
        parts = re.split(rb"([ \0])", line)
        seen, kept = set(), []
        for i in range(0, len(parts), 2):
            if parts[i] and parts[i] in seen: continue
            seen.add(parts[i]); kept.append(parts[i] + (parts[i + 1] if i + 1 < len(parts) else b""))
        out += b"".join(kept)
    data = out
sys.stdout.buffer.write(data)' "$TMPDIR_CMP.idraw" "$@"
        sed 's/\(no such user\): [A-Z][a-z ]*$/\1/' "$TMPDIR_CMP.iderr" >&2
        return $id_rc
    }
    gnu_full() { "/usr/bin/id" "$@"; }
fi
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
run_full "full disk" root
POSIXLY_CORRECT=1; export POSIXLY_CORRECT
run_cmp "POSIXLY_CORRECT: no options after an operand" root -u
unset POSIXLY_CORRECT
for o in -Gz -Gnz -Grz -uz -gz; do
    run_cmp "$o with two users"       $o root nobody
done
run_cmp "-Gz with one user"            -Gz root
print_summary
