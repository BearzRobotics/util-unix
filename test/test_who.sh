#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# who: differential tests against GNU who 9.7 on synthetic utmp files (made with
# python3). Terminal lines that do not exist report "?" for message status and
# idle time; "null" and "zero" exist everywhere, so those columns are real for
# them. systemd sessions and --lookup are outside what is compared.
UTIL="who"
export LC_ALL=C
. "$(dirname "$0")/testlib.sh"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP who (python3 needed to build utmp fixtures)"; exit 0
fi
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
# Some distributions confine /usr/bin/who with an AppArmor profile that only lets
# it read the system utmp files, so it cannot open the fixtures below. Run a copy
# of the same binary, still named "who" so its messages are unchanged.
mkdir "$D/bin" && cp "$(readlink -f /usr/bin/who)" "$D/bin/who" && GNU_WHO="$D/bin/who" || GNU_WHO=/usr/bin/who
gnu() { "$GNU_WHO" "$@"; }
python3 - "$D" <<'PY'
import struct, sys, time
d = sys.argv[1]
def rec(t, pid, line, uid, host, ts, idv=b"", term=0, ex=0):
    return struct.pack("<hxxi32s4s32s256shhiii16s20s", t, pid, line.encode(), idv, uid.encode(), host.encode(), term, ex, 0, ts, 0, b"", b"")
now = int(time.time())
a = b""
a += rec(2, 0, "~", "reboot", "6.1.0", now-100000)
a += rec(1, ord('3')|(ord('S')<<8), "~~", "runlevel", "6.1.0", now-99990)
a += rec(1, ord('5'), "~~", "runlevel", "", now-99980)
a += rec(3, 0, "|", "date", "", now-99970)
a += rec(4, 0, "{", "date", "", now-99960)
a += rec(5, 100, "tty1", "LOGIN", "", now-90000, b"1")
a += rec(6, 150, "tty9", "LOGIN", "", now-89000, b"9abc")
a += rec(8, 200, "tty2", "", "", now-80000, b"2", 3, 4)
a += rec(7, 1234, "pts/9991", "alice", "host.example.com", now-5000, b"s/0")
a += rec(7, 1235, "pts/9992", "averyveryverylongusername", "", now-4000, b"s/1")
a += rec(7, 1236, "tty9993", "bob", ":0", now-30, b"3")
a += rec(7, 1237, "/dev/pts/9994", "carol", "[::1]", now-100000+1, b"s/4")
a += rec(7, 1238, "pts/9995", "", "ghost", now-3000)
a += rec(7, 1239, "pts/9996", "dave", "", now-86400*3, b"s/6")
a += rec(7, 1240, "null", "erin", "", now-100, b"n")
a += rec(7, 1241, "zero", "frank", "10.1.2.3", now-7200, b"z")
open(d + "/all.utmp", "wb").write(a)
open(d + "/empty.utmp", "wb").write(b"")
open(d + "/short.utmp", "wb").write(a[:200])
open(d + "/partial.utmp", "wb").write(a[:384*9 + 100])
open(d + "/boot_only.utmp", "wb").write(rec(2, 0, "~", "reboot", "6.1.0", now-1000))
# remote host names up to the whole 256-byte field
open(d + "/longhost.utmp", "wb").write(b"".join(rec(7, 2000 + n, "pts/99%02d" % (n % 100), "mallory", ("h" * n), now-50) for n in (61, 62, 63, 200, 255, 256)))
open(d + "/ids.utmp", "wb").write(rec(7, 1, "pts/9997", "x", "h", now-10, b"ab") + rec(7, 2, "pts/9998", "y", "", now-20, b"abcd"))
PY
U="$D/all.utmp"

run_cmp "default"            "$U"
for o in -s -u -T -w -H -a -b -d -l -p -r -t -q; do run_cmp "$o"  $o "$U"; done
for o in -aH -uH -TH -bH -dH -lH -pH -rH -tH -qH -sH -uT -aT -su -sT -ab -dl -pr -ul -lp -bt; do run_cmp "$o" $o "$U"; done
run_cmp "-H -u -T"           -H -u -T "$U"
run_cmp "long host names"    "$D/longhost.utmp"
run_cmp "long host names -a" -a "$D/longhost.utmp"
run_cmp "--all"              --all "$U"
run_cmp "--boot"             --boot "$U"
run_cmp "--dead"             --dead "$U"
run_cmp "--heading"          --heading "$U"
run_cmp "--login"            --login "$U"
run_cmp "--lookup"           --lookup "$U"
run_cmp "--process"          --process "$U"
run_cmp "--count"            --count "$U"
run_cmp "--runlevel"         --runlevel "$U"
run_cmp "--short"            --short "$U"
run_cmp "--time"             --time "$U"
run_cmp "--mesg"             --mesg "$U"
run_cmp "--message"          --message "$U"
run_cmp "--writable"         --writable "$U"
run_cmp "--users"            --users "$U"
run_cmp "--us (abbrev)"      --us "$U"
run_cmp "--lo (ambiguous)"   --lo "$U"
run_cmp "-m (no tty)"        -m "$U"
run_cmp "-mH (no tty)"       -mH "$U"
run_cmp "am i (no tty)"      am i
for f in empty short partial boot_only ids; do
    run_cmp "$f"              "$D/$f.utmp"
    run_cmp "$f -a"           -a "$D/$f.utmp"
    run_cmp "$f -q"           -q "$D/$f.utmp"
done
run_cmp "missing file"       "$D/nonexistent"
# GNU prints the path it was run by in its usage line; compare after normalising.
g="$(gnu --help | sed "1s#$GNU_WHO#who#" | head -n 24)"; o="$(ours --help | grep -v '^ *--json ')"
if [ "$g" = "$o" ]; then PASS=$((PASS + 1)); echo "PASS --help"; else FAIL=$((FAIL + 1)); echo "FAIL --help"; fi
run_cmp "-x"                 -x
run_cmp "--bogus"            --bogus
run_cmp "--all=1"            --all=1
run_cmp "three operands"     a b c
run_cmp "file and two more"  "$U" b c
run_cmp "-- file"            -- "$U"
# run_cmp pins GNU to LC_ALL=C, so the locale-dependent time style is compared here.
run_loc() { # description, "VAR=value ...", args...
    description="$1"; envs="$2"; shift 2
    g="$(env -u LC_ALL $envs "$GNU_WHO" "$@" 2>&1)"
    if [ -n "${OURS_MULTICALL:-}" ]; then o="$(env -u LC_ALL $envs "$BIN_DIR/util-unix" who "$@" 2>&1)"
    else o="$(env -u LC_ALL $envs "$BIN_DIR/who" "$@" 2>&1)"; fi
    if [ "$g" = "$o" ]; then PASS=$((PASS + 1)); echo "PASS $description"
    else FAIL=$((FAIL + 1)); echo "FAIL $description"; echo "     GNU : $g" | head -3; echo "     OURS: $o" | head -3; fi
}
run_loc "ISO time style (LC_ALL=C.UTF-8)" "LC_ALL=C.UTF-8" "$U"
run_loc "ISO time style -aH"              "LC_ALL=C.UTF-8" -aH "$U"
run_loc "ISO time style -b"               "LC_ALL=C.UTF-8" -b "$U"
run_loc "ISO time style (LANG=C.UTF-8)"   "LANG=C.UTF-8" "$U"
run_loc "ISO time style (LC_TIME=C.UTF-8)" "LC_TIME=C.UTF-8" "$U"
run_loc "classic style (LC_TIME=C wins over LANG)" "LC_TIME=C LANG=C.UTF-8" "$U"
run_loc "classic style (no locale variables)" "LANG=" "$U"
TZ=Asia/Tokyo run_cmp "TZ=Asia/Tokyo -a"                  -a "$U"
TZ=America/New_York run_cmp "TZ=America/New_York -b"      -b "$U"
TZ=UTC run_cmp "TZ=UTC -a"                                -a "$U"
# on a terminal, control characters in the file are shown as '?'; elsewhere the
# output stays as GNU writes it
python3 - "$D/hostile.utmp" <<'PY'
import struct, sys
open(sys.argv[1], "wb").write(struct.pack("<hxxi32s4s32s256shhiii16s20s", 7, 1, b"null", b"", b"ev\x1bil",
    b"a)\nroot  \x1b[2J\xc2\x9b", 0, 0, 0, 1700000000, 0, b"", b""))
PY
run_cmp "control characters through a pipe" "$D/hostile.utmp"
seen="$(python3 - "$BIN_DIR/who" "$D/hostile.utmp" <<'PY'
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], ["who", sys.argv[2]])
out = b""
while True:
    try: chunk = os.read(fd, 4096)
    except OSError: break
    if not chunk: break
    out += chunk
os.waitpid(pid, 0)
bad = [c for c in out.replace(b"\r\n", b"") if c < 32 or c == 127] or (b"\xc2\x9b" in out)
print("masked" if not bad and b"ev?il" in out and b"(a)?root" in out and out.count(b"\n") == 1 else repr(out))
PY
)"
if [ "$seen" = masked ]; then PASS=$((PASS + 1)); echo "PASS control characters on a terminal are masked"
else FAIL=$((FAIL + 1)); echo "FAIL control characters on a terminal are masked: $seen"; fi
run_cmp "--mes, a prefix of synonyms"  --mes "$U"
run_cmp "--w"                          --w "$U"
POSIXLY_CORRECT=1; export POSIXLY_CORRECT
run_cmp "POSIXLY_CORRECT: no options after an operand" /dev/null -q
unset POSIXLY_CORRECT
# times past 2038 in the 32-bit field, and a login file larger than 256 MiB
python3 - "$D/late.utmp" <<'PY'
import struct, sys
open(sys.argv[1], "wb").write(b"".join(struct.pack("<hxxi32s4s32s256shhiIi16s20s", 7, 1, b"null", b"", b"me", b"", 0, 0, 0, t, 0, b"", b"")
    for t in (2147483647, 2147483648, 4000000000, 4294967295)))
PY
TZ=UTC run_cmp "times after 2038"    "$D/late.utmp"
cp "$U" "$D/big.utmp"; (ulimit -S -f unlimited 2>/dev/null; truncate -s 300M "$D/big.utmp")
if [ "$(wc -c < "$D/big.utmp")" -eq 314572800 ]; then run_cmp "a 300 MiB login file" "$D/big.utmp"
else skip_test "a 300 MiB login file: cannot make one here"; fi
# time zones given as POSIX rules, and a zone file built "slim", whose later
# times only its last line describes. One record every 43 days to 2106.
python3 - "$D/years.utmp" <<'PY'
import struct, sys
open(sys.argv[1], "wb").write(b"".join(struct.pack("<hxxi32s4s32s256shhiIi16s20s", 7, 1, b"null", b"", b"me", b"", 0, 0, 0, t, 0, b"", b"")
    for t in range(0, 4294000000, 3777777)))
PY
for z in JST-9 '<+0330>-3:30' ':JST-9' 'EST5EDT,M3.2.0,M11.1.0' 'CET-1CEST,M3.5.0,M10.5.0/3' 'AEST-10AEDT,M10.1.0,M4.1.0/3' \
    'IST-1GMT0,M10.5.0,M3.5.0/1' 'XXX3YYY2,J60/2,J300/2' 'XXX3YYY2,60/2,300/2' 'AAA-2BBB,M3.4.4/50,M10.4.4/50' Asia/Tokyo America/New_York Europe/Dublin; do
    TZ="$z" run_cmp "TZ=$z through 2106" "$D/years.utmp"
done
if [ -x /usr/sbin/zic ] && [ -r /usr/share/zoneinfo/tzdata.zi ] && /usr/sbin/zic -b slim -d "$D/slim" /usr/share/zoneinfo/tzdata.zi 2> /dev/null; then
    for z in America/New_York Australia/Sydney Pacific/Chatham Europe/Dublin; do
        TZ="$D/slim/$z" run_cmp "slim $z through 2106" "$D/years.utmp"
    done
else
    skip_test "slim zone files need zic and tzdata.zi"
fi

print_summary
