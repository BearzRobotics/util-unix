#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# --json modes of uname, id and who (decision 0007). GNU has no --json, so
# these are not differential: the output must parse as JSON and carry the same
# facts as the plain output. Needs python3 and the built binaries.
# a memory-limited scope of its own, so a runaway case cannot take the caller down
[ "${TEST_CONTAINED:-}" = "cg:$(cat /proc/self/cgroup 2>/dev/null)" ] || exec sh "$(dirname "$0")/contain.sh" sh "$0" "$@"
BIN="${OURS_DIR:-$(dirname "$0")/../zig-out/bin}"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { # name, command that must succeed
    if sh -c "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
}
py() { python3 -c "$1"; }

check "uname --json parses" "$BIN/uname --json | python3 -m json.tool"
# jget "COMMAND" EXPR: EXPR over the parsed output of a command that succeeds
jget() {
    out=$($1) || return 1
    printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}
# same NAME A B: both succeed and print the same, which is not nothing
same() {
    if a=$(eval "$2" 2>/dev/null) && b=$(eval "$3" 2>/dev/null) && [ -n "$a" ] && [ "$a" = "$b" ]; then ok "$1"; else bad "$1"; fi
}
# refused NAME MESSAGE COMMAND...: status 1 with the message, not any failure
refused() {
    name=$1 want=$2; shift 2
    err=$("$@" 2>&1 >/dev/null); rc=$?
    case "$rc:$err" in 1:*"$want"*) ok "$name" ;; *) echo "     status $rc: $err"; bad "$name" ;; esac
}

same "uname --json -m equals uname -m" 'jget "$BIN/uname --json -m" "d[\"machine\"]"' '"$BIN/uname" -m'
same "uname --json -sn has exactly two keys" 'jget "$BIN/uname --json -sn" "len(d)"' 'echo 2'
same "id --json uid equals id -u" 'jget "$BIN/id --json" "d[\"euid\"]"' '"$BIN/id" -u'
same "id --json groups match id -G" 'jget "$BIN/id --json" "\" \".join(str(g[\"id\"]) for g in d[\"groups\"])"' '"$BIN/id" -G'
same "id --json root: one object per operand" '"$BIN/id" --json root 0 | grep -c "^{"' 'echo 2'
refused "id --json -u is refused" "--json" "$BIN/id" --json -u
refused "id --json unknown user fails" "no such user" "$BIN/id" --json no-such-user-zz

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
    "[ \"\$($BIN/who --json -b $d/utmp | python3 -c 'import json,sys;r=json.load(sys.stdin);print(len(r),r[0][\"type\"])')\" = '1 boot' ]"
check "who --json -q" \
    "[ \"\$($BIN/who --json -q $d/utmp | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"count\"])')\" = 2 ]"
check "who --json record count equals plain who line count" \
    "[ \"\$($BIN/who --json -a $d/utmp | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')\" = \"\$($BIN/who -a $d/utmp | wc -l)\" ]"

echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
