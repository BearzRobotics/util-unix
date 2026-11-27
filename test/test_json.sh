#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# --json modes of uname, id and who (decision 0007). GNU has no --json, so
# these are not differential: the output must parse as JSON and carry the same
# facts as the plain output. Needs python3 and the built binaries.
BIN="${OURS_DIR:-$(dirname "$0")/../zig-out/bin}"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { # name, command that must succeed
    if sh -c "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
}
py() { python3 -c "$1"; }

check "uname --json parses" "$BIN/uname --json | python3 -m json.tool"
check "uname --json -m equals uname -m" \
    "[ \"\$($BIN/uname --json -m | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"machine\"])')\" = \"\$($BIN/uname -m)\" ]"
check "uname --json -sn has exactly two keys" \
    "[ \"\$($BIN/uname --json -sn | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')\" = 2 ]"
check "id --json uid equals id -u" \
    "[ \"\$($BIN/id --json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"euid\"])')\" = \"\$($BIN/id -u)\" ]"
check "id --json groups match id -G" \
    "[ \"\$($BIN/id --json | python3 -c 'import json,sys;print(\" \".join(str(g[\"id\"]) for g in json.load(sys.stdin)[\"groups\"]))')\" = \"\$($BIN/id -G)\" ]"
check "id --json root: one object per operand" \
    "[ \"\$($BIN/id --json root 0 | wc -l)\" = 2 ]"
check "id --json -u is refused" "! $BIN/id --json -u"
check "id --json unknown user fails" "! $BIN/id --json no-such-user-zz"

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
python3 - "$d/utmp" <<'PY'
import struct, sys
def rec(kind, pid, line, user, host, t):
    b = bytearray(384)
    struct.pack_into("<hxx", b, 0, kind)
    struct.pack_into("<i", b, 4, pid)
    b[8:8+len(line)] = line; b[44:44+len(user)] = user; b[76:76+len(host)] = host
    struct.pack_into("<i", b, 340, t)
    return bytes(b)
open(sys.argv[1], "wb").write(
    rec(2, 0, b"~", b"reboot", b"6.1", 100)
    + rec(7, 11, b"pts/7", b"al\"ice", b"h\xffost", 200)
    + rec(7, 12, b"pts/8", b"bob", b"", 300))
PY
check "who --json parses, escapes and repairs bytes" \
    "$BIN/who --json -u $d/utmp | python3 -c 'import json,sys;r=json.load(sys.stdin);assert [x[\"user\"] for x in r]==[\"al\\\"ice\",\"bob\"];assert r[0][\"host\"]==\"h�ost\";assert r[0][\"time\"]==200'"
python3 - "$d/levels" <<'PY'
import struct, sys
def rec(pid):
    b = bytearray(384)
    struct.pack_into("<hxx", b, 0, 1); struct.pack_into("<i", b, 4, pid)
    return bytes(b)
open(sys.argv[1], "wb").write(rec(0) + rec(34) + rec(255) + rec(ord("5") | ord("S") << 8))
PY
check "who --json: run levels of any bytes still parse" \
    "$BIN/who --json -r $d/levels | python3 -c 'import json,sys;r=json.load(sys.stdin);assert [x[\"runlevel\"] for x in r]==[None,chr(34),chr(0xfffd),\"5\"];assert r[3][\"previous\"]==\"S\" and r[0][\"previous\"] is None'"
check "who --json -b selects the boot record" \
    "[ \"\$($BIN/who --json -b $d/utmp | python3 -c 'import json,sys;print(json.load(sys.stdin)[0][\"type\"])')\" = boot ]"
check "who --json -q" \
    "[ \"\$($BIN/who --json -q $d/utmp | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"count\"])')\" = 2 ]"
check "who --json record count equals plain who line count" \
    "[ \"\$($BIN/who --json -a $d/utmp | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')\" = \"\$($BIN/who -a $d/utmp | wc -l)\" ]"

echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
