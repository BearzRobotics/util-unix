#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# sh-gold.sh - run tools/sh-gold.py (gold-standard comparison of our sh with
# dash, FreeBSD sh, bash, busybox ash and yash) under a systemd scope cap.
#
#   tools/sh-gold.sh [sh-gold.py options]       e.g. --source test_sh --out DIR
#   tools/sh-gold.sh --report DIR [filters]     print mismatches from a results file
#
# Every case runs in its own session and PID namespace (setsid, bwrap), so
# stray signals cannot reach the host. Never run the corpora outside this.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--report" ]; then
    shift
    exec python3 -I "$HERE/sh-gold-report.py" "$@"
fi
command -v bwrap > /dev/null 2>&1 || { echo "sh-gold: bubblewrap is required" >&2; exit 1; }
[ "${TEST_CONTAINED:-}" = "cg:$(cat /proc/self/cgroup 2>/dev/null)" ] || exec sh "$HERE/../test/contain.sh" timeout 3000 sh "$0" "$@"
exec setsid -w python3 -I "$HERE/sh-gold.py" "$@"
