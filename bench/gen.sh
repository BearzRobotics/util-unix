#!/bin/sh
# gen.sh DIR - write the benchmark input files into DIR (deterministic seeds).
dir=$1; mkdir -p "$dir"; cd "$dir" || exit 1
export LC_ALL=C
[ -s text.txt ] || awk 'BEGIN { srand(1); split("apple Banana cherry date Elder fig", w, " ")
    for (i = 0; i < 300000; i++)
        printf "%s%d %d %.4f the quick brown fox\n", w[1 + int(rand() * 6)], int(rand() * 99999), int(rand() * 2000001) - 1000000, rand() }' > text.txt
[ -s csv.txt ] || awk 'BEGIN { srand(2)
    for (i = 0; i < 300000; i++) printf "id%d,%s,%d,%.3f,field%d\n", i, (rand() < 0.5 ? "alpha" : "beta"), int(rand() * 100000), rand() * 1000, int(rand() * 50) }' > csv.txt
[ -s small.txt ] || head -n 10000 text.txt > small.txt
