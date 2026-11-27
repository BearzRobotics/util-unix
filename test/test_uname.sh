#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# uname: differential tests against GNU uname 9.7 (C locale).
UTIL="uname"
. "$(dirname "$0")/testlib.sh"
# Ubuntu's and Fedora's coreutils report the machine for -p and -i, and so does
# ours; unpatched builds (Alpine) say "unknown". Against those, the options
# that include them are checked against our own -m instead.
upstream=""
[ "$(/usr/bin/uname -p)" = unknown ] && upstream=1
for o in "" -a -s -n -r -v -m -p -i -o -sn -sr -rv -mp -io -snrvmpio "-s -n" -asn --all --kernel-name --nodename --kernel-release --kernel-version --machine --processor --hardware-platform --operating-system "--all -s"; do
    if [ -n "$upstream" ]; then
        case $o in
            -a|-p|-i|-mp|-io|-snrvmpio|-asn|--all|--processor|--hardware-platform|"--all -s")
                skip_test "uname $o (the reference does not report the processor)"; continue ;;
        esac
    fi
    run_cmp "uname $o"      $o
done
if [ -n "$upstream" ]; then
    for pair in "-p -m" "-i -m"; do
        set -- $pair
        if [ "$(ours "$1")" = "$(ours "$2")" ]; then PASS=$((PASS + 1)); echo "PASS uname $1 is the machine"
        else FAIL=$((FAIL + 1)); echo "FAIL uname $1 is the machine"; fi
    done
    m=$(ours -m)
    want="$(ours -s) $(ours -n) $(ours -r) $(ours -v) $m $m $m $(ours -o)"
    for o in -a --all -snrvmpio; do
        if [ "$(ours $o)" = "$want" ]; then PASS=$((PASS + 1)); echo "PASS uname $o is every field"
        else FAIL=$((FAIL + 1)); echo "FAIL uname $o is every field"; fi
    done
fi
run_cmp "operand"           extra
run_cmp "-x"                -x
run_cmp "--bogus"           --bogus
run_cmp "--all=x"           --all=x
run_cmp "--k ambiguous"     --kernel
run_cmp "--kernel-n"        --kernel-n
run_full "full disk" -a
run_cmp "--sysname"  --sysname
run_cmp "--release"  --release
run_cmp "--sys --rel" --sys --rel
print_summary
