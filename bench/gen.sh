#!/bin/sh
# gen.sh DIR - write the benchmark inputs into DIR: a tree of 100 directories
# with 100 files each (owned by the current user, so ownership changes are
# no-ops that still cost one syscall per file).
dir=$1; mkdir -p "$dir"; cd "$dir" || exit 1
if [ ! -d tree/d99 ]; then
    i=0
    while [ $i -lt 100 ]; do
        mkdir -p "tree/d$i"
        j=0
        while [ $j -lt 100 ]; do : > "tree/d$i/f$j"; j=$((j + 1)); done
        i=$((i + 1))
    done
fi
