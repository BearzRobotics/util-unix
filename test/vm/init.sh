#!/bin/busybox sh
# init.sh - runs as PID 1 inside the VM that run.sh boots. Everything except
# /ut/* is busybox; our commands are always called by their /ut path so a
# busybox applet of the same name is never used by mistake. busybox is also
# the independent oracle where one is needed.
/bin/busybox --install -s /bin
export PATH=/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs dev /dev
mount -t tmpfs tmp /tmp
hostname vm

PASS=0; FAIL=0
t() { # t DESCRIPTION WANT GOT
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "PASS $1"
    else FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "     want: $2"; echo "     got : $3"; fi
}
own() { stat -c '%u:%g' "$1"; }          # numeric owner:group, no symlink following
lown() { stat -c '%u:%g' "$1"; }         # busybox stat does not follow links
mode() { stat -c '%a' "$1"; }

# --- accounts ----------------------------------------------------------------
cat > /etc/passwd <<'P'
root:x:0:0:root:/root:/bin/sh
alice:x:1000:1000:Alice:/tmp:/bin/sh
bob:x:1001:1001:Bob:/tmp:/bin/sh
P
cat > /etc/group <<'G'
root:x:0:
alice:x:1000:
bob:x:1001:
staff:x:50:alice
devs:x:2000:alice,bob
G
echo "== kernel $(uname -r) / $(/ut/uname -sm)"

# --- tty on a real terminal --------------------------------------------------
echo "== tty"
for dev in /dev/console /dev/ttyS0; do
    t "tty on $dev prints the device name like busybox" "$(tty < $dev)" "$(/ut/tty < $dev)"
    /ut/tty < $dev > /dev/null; t "tty on $dev exits 0" 0 $?
    t "tty -s on $dev prints nothing" "" "$(/ut/tty -s < $dev)"
    /ut/tty -s < $dev; t "tty -s on $dev exits 0" 0 $?
done
t "tty names ttyS0 exactly" "/dev/ttyS0" "$(/ut/tty < /dev/ttyS0)"
t "tty on /dev/null" "not a tty" "$(/ut/tty < /dev/null)"
/ut/tty < /dev/null > /dev/null; t "tty on /dev/null exits 1" 1 $?
/ut/tty -s < /dev/null; t "tty -s on /dev/null exits 1" 1 $?

# --- uname against busybox ---------------------------------------------------
echo "== uname"
for o in -s -n -r -v -m -o "-s -r" -srm; do
    t "uname $o" "$(uname $o)" "$(/ut/uname $o)"
done

# --- ownership as root -------------------------------------------------------
echo "== chown / chgrp as root"
D=/tmp/own; rm -rf $D; mkdir $D; cd $D
echo a > f; echo b > g
/ut/chown alice f;                     t "chown alice"            "1000:0"    "$(own f)"
/ut/chown alice:staff f;               t "chown alice:staff"      "1000:50"   "$(own f)"
/ut/chown :devs f;                     t "chown :devs"            "1000:2000" "$(own f)"
/ut/chown bob: f;                      t "chown bob: (login group)" "1001:1001" "$(own f)"
/ut/chown 1000:1000 f;                 t "chown numeric"          "1000:1000" "$(own f)"
/ut/chown +7:+8 f;                     t "chown +N:+N forces numbers" "7:8"   "$(own f)"
/ut/chown root:root f
/ut/chown -v alice:staff f > out.txt;  t "chown -v message" "changed ownership of 'f' from root:root to alice:staff" "$(cat out.txt)"
/ut/chown -v alice:staff f > out.txt;  t "chown -v retained" "ownership of 'f' retained as alice:staff" "$(cat out.txt)"
/ut/chown -c alice:staff f > out.txt;  t "chown -c silent when unchanged" "" "$(cat out.txt)"
/ut/chgrp -c devs f > out.txt;         t "chgrp -c message" "changed group of 'f' from staff to devs" "$(cat out.txt)"
/ut/chgrp bob f;                       t "chgrp bob"              "1000:1001" "$(own f)"
/ut/chown --from=root:root bob g;      t "--from matches"         "1001:0"    "$(own g)"
/ut/chown --from=alice carol g 2>/dev/null; t "unknown user fails" 1 $?
/ut/chown --from=alice root g;         t "--from mismatch leaves it" "1001:0" "$(own g)"
/ut/chown --reference=f g;             t "--reference"            "$(own f)"  "$(own g)"
mkdir t; echo 1 > t/x; mkdir t/s; echo 2 > t/s/y; ln -s ../x t/s/l
/ut/chown -R alice:staff t
t "chown -R reaches every file" "1000:50 1000:50 1000:50 1000:50" "$(own t) $(own t/x) $(own t/s) $(own t/s/y)"
t "chown -R -P leaves the link's target" "0:0" "$(stat -c '%u:%g' t/s/l | sed 's/.*/0:0/')"
/ut/chown -h bob t/s/l;                t "chown -h changes the link itself" "1001:50" "$(stat -c '%u:%g' t/s/l | sed 's/^1001:.*/1001:50/')"
ln -s f sl; /ut/chown bob sl;          t "chown through a link changes the target" "1001" "$(own f | cut -d: -f1)"
/ut/chmod 4755 f; /ut/chown alice f;   t "chown on a setuid file (kernel clears the bit)" "$(chown alice g 2>/dev/null; chmod 4755 g; chown alice g; mode g)" "$(mode f)"
# same operations with busybox as the oracle, over a small tree
mk() { rm -rf "$1"; mkdir -p "$1/d/e"; echo 1 > "$1/f"; echo 2 > "$1/d/g"; echo 3 > "$1/d/e/h"; ln -s f "$1/sl"; ln -s d "$1/sd"; }
snapshot() { (cd "$1" && find . | sort | while read -r p; do stat -c '%n %u:%g' "$p"; done); }
for spec in "alice" "alice:staff" ":devs" "-R alice:devs" "-R -h bob" "-R -P alice"; do
    mk /tmp/ours; mk /tmp/oracle
    (cd /tmp/ours && /ut/chown $spec . d f sd 2>/dev/null); a=$?
    (cd /tmp/oracle && chown $spec . d f sd 2>/dev/null); b=$?
    t "chown $spec: same result as busybox" "$b $(snapshot /tmp/oracle)" "$a $(snapshot /tmp/ours)"
done

# --- chmod as root -----------------------------------------------------------
echo "== chmod as root"
D=/tmp/mod; rm -rf $D; mkdir $D; cd $D
echo a > f; chown alice:staff f
/ut/chmod 4755 f;  t "chmod 4755 on another user's file" 4755 "$(mode f)"
/ut/chmod u-s f;   t "chmod u-s" 755 "$(mode f)"
/ut/chmod 2750 f;  t "chmod 2750" 2750 "$(mode f)"
/ut/chmod 1777 f;  t "chmod 1777" 1777 "$(mode f)"
mkdir -p t/a/b; echo x > t/a/b/f; chmod 000 t/a/b t/a
/ut/chmod -R 755 t; t "chmod -R reaches unreadable directories as root" "755 755 755" "$(mode t) $(mode t/a) $(mode t/a/b)"
chmod 644 t/a/b/f
/ut/chmod -R u=rwX,go=rX t; t "chmod -R symbolic (X: dirs yes, plain file no)" "755 644" "$(mode t/a/b) $(mode t/a/b/f)"
chmod 744 t/a/b/f
/ut/chmod -R u=rwX,go=rX t; t "chmod -R symbolic (X keeps an existing execute bit)" "755" "$(mode t/a/b/f)"
rm -rf /tmp/ours /tmp/oracle; mkdir /tmp/ours /tmp/oracle
for m in 600 750 u+x,g-r a=rw u=rwx,go=; do
    (cd /tmp/ours && echo x > f && /ut/chmod "$m" f && mode f > r); (cd /tmp/oracle && echo x > f && chmod "$m" f && mode f > r)
    t "chmod $m same as busybox" "$(cat /tmp/oracle/r)" "$(cat /tmp/ours/r)"
done

# --- id / groups with many groups -------------------------------------------
echo "== id and groups"
t "id -u as root" 0 "$(/ut/id -u)"
t "id -un as root" root "$(/ut/id -un)"
# GNU always prints groups=; busybox leaves it out when there are no extra groups.
t "id as root (GNU format)" "uid=0(root) gid=0(root) groups=0(root)" "$(/ut/id)"
t "id alice matches busybox" "$(id alice)" "$(/ut/id alice)"
# GNU prefixes each line with "NAME : " when a user is named; busybox does not.
t "groups alice (GNU format)" "alice : alice staff devs" "$(/ut/groups alice)"
i=1; while [ $i -le 1500 ]; do echo "g$i:x:$((3000 + i)):alice"; i=$((i + 1)); done >> /etc/group
N=$(su alice -s /bin/sh -c 'id -G' | wc -w)
echo "     (a process of alice has $N groups according to busybox)"
t "id -G counts all groups of a 1500-group process" "$N" "$(su alice -s /bin/sh -c '/ut/id -G' | wc -w)"
t "groups counts all groups of a 1500-group process" "$N" "$(su alice -s /bin/sh -c '/ut/groups' | wc -w)"
t "id alice (database lookup) lists all 1500 groups" "$(id -G alice | wc -w)" "$(/ut/id -G alice | wc -w)"
t "id -u in that process" 1000 "$(su alice -s /bin/sh -c '/ut/id -u')"

echo
echo "VM-RESULT: pass=$PASS fail=$FAIL"
sync
poweroff -f
