#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# tty: differential tests against GNU tty 9.7 (standard input is never a tty here).
UTIL="tty"
. "$(dirname "$0")/testlib.sh"
run_cmp "tty (stdin /dev/null)"
run_cmp "-s"                -s
run_cmp "--silent"          --silent
run_cmp "--quiet"           --quiet
run_cmp "operand"           x
run_cmp "-x"                -x
run_cmp "--bogus"           --bogus
IN="$(mktemp)"; echo hi > "$IN"
CMP_STDIN="$IN" run_cmp "tty (stdin file)"
CMP_STDIN="$IN" run_cmp "tty -s (stdin file)" -s
rm -f "$IN"
print_summary
