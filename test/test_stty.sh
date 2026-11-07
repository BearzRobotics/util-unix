#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# stty: differential tests against GNU stty 9.7. Terminal tests run on a
# pseudo-terminal (test/stty_pty.py); the no-terminal cases run here.
UTIL="stty"
. "$(dirname "$0")/testlib.sh"

if command -v python3 >/dev/null 2>&1; then
    if [ -n "${OURS_MULTICALL:-}" ]; then OURS_CMD="$BIN_DIR/util-unix stty"; else OURS_CMD="$BIN_DIR/stty"; fi
    # shellcheck disable=SC2086
    py_out="$(python3 "$(dirname "$0")/stty_pty.py" $OURS_CMD)"; py_rc=$?
    printf '%s\n' "$py_out" | grep -E '^(PASS|FAIL|     )'
    p=$(printf '%s\n' "$py_out" | grep -c '^PASS'); f=$(printf '%s\n' "$py_out" | grep -c '^FAIL')
    PASS=$((PASS + p)); FAIL=$((FAIL + f))
else
    skip_test "pseudo-terminal tests (python3 needed)"
fi

# Without a terminal.
run_cmp "no tty"                 
run_cmp "no tty -a"              -a
run_cmp "no tty -g"              -g
run_cmp "no tty size"            size
run_cmp "no tty setting"         -echo
run_cmp "no tty bad setting"     foo
run_cmp "-a -g without tty"      -a -g
run_cmp "-F /dev/null"           -F /dev/null
run_cmp "-F /nonexistent"        -F /nonexistent
run_cmp "-F directory"           -F /tmp
run_cmp "--file=/dev/null -a"    --file=/dev/null -a
g="$(gnu --help | sed 's#/usr/bin/stty#stty#g' | sed '/^GNU coreutils online help/,$d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
o="$(ours --help | sed 's#^\(Usage: \|  or:  \)[^ ]*stty#\1stty#')"
if [ "$g" = "$o" ]; then PASS=$((PASS + 1)); echo "PASS --help"; else FAIL=$((FAIL + 1)); echo "FAIL --help"; fi
print_summary
