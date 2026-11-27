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
run_full "not a tty, full disk"
run_full "--help, full disk" --help
run_cmp "an option after -- is an operand" -- -s
for o in --silent=x --quiet=x --help=x --version=x; do
    run_cmp "no value for $o"          "$o"
done
print_summary
