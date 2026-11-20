#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# test_sh_interactive.sh - interactive sh on a pseudo-terminal: prompts, line
# editing (emacs and vi), history and fc, completion, signals and job control,
# compared with dash and FreeBSD sh where they define the behaviour and with
# fixed expectations elsewhere. Needs python3 with the pty module; otherwise
# the suite is skipped (exit 0).
#
#   sh test/test_sh_interactive.sh [SECTION...]   (emacs vi jobs fc prompt signals completion paste)
UTIL="sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
OURS="${OURS:-$HERE/../zig-out/bin/sh}"

if ! command -v python3 > /dev/null 2>&1 || ! python3 -c 'import pty, termios, fcntl' > /dev/null 2>&1; then
    echo "SKIP: python3 with the pty module is required"
    exit 0
fi
[ -x "$OURS" ] || { echo "SKIP: $OURS not built (zig build -Doptimize=ReleaseSafe -Dcommands=sh -Dmode=standalone)"; exit 0; }

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
# a new session of its own: a stray signal in a test cannot reach the caller
if command -v setsid > /dev/null 2>&1; then
    setsid python3 -u "$HERE/sh_interactive.py" "$OURS" "$@" > "$OUT" 2>&1 < /dev/null
else
    python3 -u "$HERE/sh_interactive.py" "$OURS" "$@" > "$OUT" 2>&1 < /dev/null
fi
cat "$OUT"
PASS=$(grep -c '^PASS' "$OUT")
FAIL=$(grep -c '^FAIL' "$OUT")
printf '\n======================================\n'
printf ' sh interactive: %d/%d passed\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && echo " All tests passed!" || printf ' %d test(s) failed\n' "$FAIL"
printf '======================================\n'
[ "$FAIL" -eq 0 ]
