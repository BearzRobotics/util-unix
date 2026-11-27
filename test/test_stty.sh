#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# stty: differential tests against GNU stty 9.7. Terminal tests run on a
# pseudo-terminal (test/stty_pty.py); the no-terminal cases run here.
UTIL="stty"
. "$(dirname "$0")/testlib.sh"
# musl words "Inappropriate ioctl for device" its own way; ours uses glibc's
if ldd --version 2>&1 | grep -q '^musl'; then
    gnu() {
        "/usr/bin/stty" "$@" 2> "$TMPDIR_CMP.stderr"; st_rc=$?
        sed 's/: Not a tty$/: Inappropriate ioctl for device/' "$TMPDIR_CMP.stderr" >&2
        return $st_rc
    }
fi

if command -v python3 >/dev/null 2>&1; then
    if [ -n "${OURS_MULTICALL:-}" ]; then OURS_CMD="$BIN_DIR/util-unix stty"; else OURS_CMD="$BIN_DIR/stty"; fi
    # shellcheck disable=SC2086
    py_out="$(python3 "$(dirname "$0")/stty_pty.py" $OURS_CMD)"; py_rc=$?
    printf '%s\n' "$py_out" | grep -E '^(PASS|FAIL|     )'
    p=$(printf '%s\n' "$py_out" | grep -c '^PASS'); f=$(printf '%s\n' "$py_out" | grep -c '^FAIL')
    PASS=$((PASS + p)); FAIL=$((FAIL + f))
    # see test_sh_interactive.sh: a crashed harness must not read as success
    if ! printf '%s\n' "$py_out" | grep -q '^ stty: [0-9][0-9]*/[0-9][0-9]* passed$' || { [ "$py_rc" -ne 0 ] && [ "$f" -eq 0 ]; }; then
        FAIL=$((FAIL + 1)); echo "FAIL the python harness did not finish (exit status $py_rc)"
    fi
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
run_full "--help, full disk" --help
run_cmp "two devices"            -F /dev/null -F /dev/null -echo
run_cmp "two devices, attached"  -F/dev/null --file=/dev/null
print_summary
