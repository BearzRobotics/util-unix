#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# pinky: the long format (-l) is compared against GNU pinky 9.7 inside a user and
# mount namespace (unshare -rm) with a synthetic /etc/passwd bind-mounted and
# throw-away home directories. The short format cannot be compared: the GNU
# build used for the reference reads systemd-logind, never the utmp file, so
# short-format tests are golden (expected text written from the documented
# column layout) and use /run/utmp inside the namespace. Skipped when
# namespaces are unavailable.
UTIL="pinky"
export LC_ALL=C
. "$(dirname "$0")/testlib.sh"

if ! unshare -rm true 2>/dev/null; then echo "SKIP pinky (unshare -rm unavailable)"; exit 0; fi
if ! command -v python3 >/dev/null 2>&1; then echo "SKIP pinky (python3 needed)"; exit 0; fi
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
mkdir -p "$D/h/alice" "$D/h/bob" "$D/h/carol" "$D/h/frank"
printf 'Project line 1\nproject line 2\n' > "$D/h/alice/.project"
printf 'Plan A\n\nPlan B no newline' > "$D/h/alice/.plan"
printf 'KEY\n' > "$D/h/alice/.pgpkey"
printf 'only plan\n' > "$D/h/bob/.plan"
: > "$D/h/carol/.project"
printf 'no trailing newline in project' > "$D/h/frank/.project"
printf 'frank plan\n' > "$D/h/frank/.plan"
cat > "$D/passwd" <<PW
root:x:0:0:root:/root:/bin/sh
alice:x:1001:1001:Alice Smith,Room 5,555-1234,555-9999:$D/h/alice:/bin/zsh
bob:x:1002:1002:&:$D/h/bob:/bin/sh
carol:x:1003:1003:Dr. & Q. Public:$D/h/carol:
dan:x:1004:1004::/nonexistent:/bin/false
evelyn:x:1005:1005:A very very very long real name that exceeds nineteen,,,:$D/h/evelyn:/bin/sh
frank:x:1006:1006:Frank:$D/h/frank:/bin/sh
PW
python3 - "$D" <<'PY'
import struct, sys
d = sys.argv[1]
def rec(t, pid, line, uid, host, ts, idv=b""):
    return struct.pack("<hxxi32s4s32s256shhiii16s20s", t, pid, line.encode(), idv, uid.encode(), host.encode(), 0, 0, 0, ts, 0, b"", b"")
t0 = 1762518896  # 2025-11-07 12:34:56 UTC
open(d + "/utmp", "wb").write(
    rec(7, 11, "nosuch1", "alice", "host.example.com", t0, b"1") +
    rec(7, 12, "nosuch2", "dan", "", t0 + 60, b"2") +
    rec(7, 13, "/dev/nosuch3", "stranger", ":0", t0 + 120, b"3") +
    rec(8, 14, "nosuch4", "bob", "", t0, b"4"))
PY

# in_ns CMD...: run CMD in the namespace with the fixture passwd in place.
in_ns() {
    unshare -rm sh -c 'mount --bind "$0/passwd" /etc/passwd && mount -t tmpfs tmpfs /run && cp "$0/utmp" /run/utmp && exec "$@"' "$D" "$@"
}
long_cmp() { # description, args...
    description="$1"; shift
    in_ns /usr/bin/pinky "$@" > "$D/g.out" 2> "$D/g.err"; gx=$?
    if [ -n "${OURS_MULTICALL:-}" ]; then in_ns "$BIN_DIR/util-unix" pinky "$@" > "$D/o.out" 2> "$D/o.err"; ox=$?
    else in_ns "$BIN_DIR/pinky" "$@" > "$D/o.out" 2> "$D/o.err"; ox=$?; fi
    norm_err < "$D/g.err" > "$D/g.err2"; norm_err < "$D/o.err" > "$D/o.err2"
    if cmp -s "$D/g.out" "$D/o.out" && cmp -s "$D/g.err2" "$D/o.err2" && [ "$gx" = "$ox" ]; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$description"
        printf "     GNU  (rc=%s) out: %s err: %s\n" "$gx" "$(cat -A "$D/g.out")" "$(cat -A "$D/g.err2")"
        printf "     OURS (rc=%s) out: %s err: %s\n" "$ox" "$(cat -A "$D/o.out")" "$(cat -A "$D/o.err2")"
    fi
}
for u in alice bob carol dan evelyn frank root nosuch; do long_cmp "-l $u" -l "$u"; done
for o in -lb -lh -lp -lbh -lbp -lhp -lbhp; do long_cmp "$o alice" $o alice; long_cmp "$o frank" $o frank; done
long_cmp "-l several users"      -l alice bob carol dan
long_cmp "-l with nosuch in the middle" -l alice nosuch bob
long_cmp "-l -s (short last)"    -l -s nobodyhere
long_cmp "-s -l (long last)"     -s -l alice
long_cmp "-sl"                   -sl alice
long_cmp "-l without users"      -l
long_cmp "-x"                    -x
long_cmp "--bogus"               --bogus
long_cmp "--lookup -l"           --lookup -l bob
long_cmp "-- operand"            -l -- alice

# Short format, golden. Times are UTC, terminals do not exist (so '?').
golden() { # description, expected, args...
    description="$1"; want="$2"; shift 2
    got="$(TZ=UTC in_ns "$BIN_DIR/pinky" "$@" 2>&1)"
    if [ "$got" = "$want" ]; then PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else FAIL=$((FAIL + 1)); printf "FAIL %s\n     want: %s\n     got : %s\n" "$description" "$(printf '%s' "$want" | cat -A)" "$(printf '%s' "$got" | cat -A)"; fi
}
golden "short format" "Login    Name                 TTY      Idle   When         Where
alice    Alice Smith         ?nosuch1  ?????  Nov  7 12:34 host.example.com
dan                          ?nosuch2  ?????  Nov  7 12:35
stranger                 ??? ?nosuch3  ?????  Nov  7 12:36 :0"
golden "short, one user"  "Login    Name                 TTY      Idle   When         Where
dan                          ?nosuch2  ?????  Nov  7 12:35" dan
golden "short, no heading (-f)" "alice    Alice Smith         ?nosuch1  ?????  Nov  7 12:34 host.example.com
dan                          ?nosuch2  ?????  Nov  7 12:35
stranger                 ??? ?nosuch3  ?????  Nov  7 12:36 :0" -f
golden "short -w" "Login     TTY      Idle   When         Where
alice    ?nosuch1  ?????  Nov  7 12:34 host.example.com
dan      ?nosuch2  ?????  Nov  7 12:35
stranger ?nosuch3  ?????  Nov  7 12:36 :0" -w
golden "short -i" "Login     TTY      Idle   When        
alice    ?nosuch1  ?????  Nov  7 12:34
dan      ?nosuch2  ?????  Nov  7 12:35
stranger ?nosuch3  ?????  Nov  7 12:36" -i
golden "short -q" "Login     TTY      When        
alice    ?nosuch1  Nov  7 12:34
dan      ?nosuch2  Nov  7 12:35
stranger ?nosuch3  Nov  7 12:36" -q
golden "short, nobody matches" "Login    Name                 TTY      Idle   When         Where" nobody
print_summary
