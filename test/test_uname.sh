#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# uname: differential tests against GNU uname 9.7 (C locale).
UTIL="uname"
. "$(dirname "$0")/testlib.sh"
for o in "" -a -s -n -r -v -m -p -i -o -sn -sr -rv -mp -io -snrvmpio "-s -n" -asn --all --kernel-name --nodename --kernel-release --kernel-version --machine --processor --hardware-platform --operating-system "--all -s"; do
    run_cmp "uname $o"      $o
done
run_cmp "operand"           extra
run_cmp "-x"                -x
run_cmp "--bogus"           --bogus
run_cmp "--all=x"           --all=x
run_cmp "--k ambiguous"     --kernel
run_cmp "--kernel-n"        --kernel-n
print_summary
