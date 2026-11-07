#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# hostname: differential tests against hostname 3.25 (Debian). The host name is
# never changed: setting needs root, and the unprivileged runs below compare the
# refusals. Name completion is checked against whatever /etc/hosts says on this
# machine, so -f/-d/-a/-i only match where the host name is listed there.
UTIL="hostname"
REF_PATTERN="hostname"
. "$(dirname "$0")/testlib.sh"
run_cmp "hostname"
run_cmp "-s"              -s
run_cmp "--short"         --short
run_cmp "--s"             --s
run_cmp "-y"              -y
run_cmp "--yp"            --yp
run_cmp "--nis"           --nis
run_cmp "-s -y (last wins)" -s -y
run_cmp "-y -s (last wins)" -y -s
run_cmp "-b"              -b
run_cmp "--boot"          --boot
if grep -qi -w "$(hostname)" /etc/hosts 2>/dev/null; then
    run_cmp "-f"          -f
    run_cmp "--fqdn"      --fqdn
    run_cmp "--long"      --long
    run_cmp "-d"          -d
    run_cmp "--domain"    --domain
    run_cmp "-a"          -a
    run_cmp "--alias"     --alias
    run_cmp "-i"          -i
    run_cmp "--ip-address" --ip-address
else
    skip_test "-f -d -a -i (host name not in /etc/hosts)"
fi
run_cmp "-h"              -h
run_cmp "--help"          --help
run_cmp "-x"              -x
run_cmp "--bogus"         --bogus
run_cmp "-F without value" -F
run_cmp "--file without value" --file
run_cmp "two operands"    a b
run_cmp "operand with -s" -s foo
run_cmp "operand with -f" -f foo
if [ "$(id -u)" != 0 ]; then
    run_cmp "set (not root)"   somename
    run_cmp "set too long (not root)" "$(printf 'a%.0s' $(seq 1 70))"
    F="$(mktemp)"; printf '# c\n\n  filehost \nother\n' > "$F"
    run_cmp "-F file (not root)"      -F "$F"
    run_cmp "-F attached (not root)"  -F"$F"
    run_cmp "--file=file (not root)"  --file="$F"
    run_cmp "--file file (not root)"  --file "$F"
    run_cmp "-F with operand"         -F "$F" x
    run_cmp "-F with -s"              -F "$F" -s
    rm -f "$F"
    run_cmp "-F missing file" -F /nonexistent/hostname
else
    skip_test "set-refusal tests need a non-root user"
fi
print_summary
