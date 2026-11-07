#!/bin/sh
# split: differential tests against GNU split. References: POSIX.1-2024 split;
# GNU coreutils manual "split invocation". Every case runs GNU and ours in
# separate fresh directories and compares stdout, normalised stderr, exit
# status and the resulting tree (names, modes, md5 of every file).
UTIL="split"
. "$(dirname "$0")/testlib.sh"
export LC_ALL=C

# Fixture creation, run in every scratch directory.
SETUP='seq 1 25 > in; printf "a\nb\nc" > nonl; : > empty; printf "a\0b\0c\0d\0e\0" > nul
seq 1 3000 | gzip -nc > bin; awk "BEGIN{for(i=1;i<=300;i++){s=\"\";for(j=0;j<i%37;j++)s=s\"x\";print s}}" > ragged
printf "short\n%0100d\nmid\n%050d\nend\n" 0 0 > longlines; seq -w 6 10 > k; mkdir dir'

t() { desc=$1; shift; run_tree "$desc" "$SETUP" "$@"; }

printf "\n[ POSIX: -l -b -a, operands ]\n"
t "default 1000 lines"                 in
t "-l 5"                               -l 5 in
t "-l5 no space"                       -l5 in
t "-l 1"                               -l 1 in
t "-l larger than input"               -l 100 in
t "no trailing newline"                -l 2 nonl
t "empty input makes no files"         empty
t "-b 7"                               -b 7 in
t "-b 1"                               -b 1 nonl
t "-b 1k (POSIX suffix)"               -b 1k bin
t "-b 1m (POSIX suffix)"               -b 1m bin
t "-a 3"                               -a 3 -l 1 in
t "-a 1 within range"                  -a 1 -l 5 in
t "-a 1 exhausted (26 files)"          -a 1 -l 1 -d in
t "prefix operand"                     -l 10 in part_
t "prefix with directory"              -l 10 in dir/p
t "obsolete -NUM"                      -5 in
t "obsolete -NUM overrides earlier"    -2 -3 in
t "stdin as -"                         -l 10 - pre

TREE_STDIN=in
printf "\n[ stdin ]\n"
t "stdin default operand"              -l 10
t "stdin with prefix"                  -l 10 - zz
unset TREE_STDIN

printf "\n[ Suffixes ]\n"
t "-d"                                 -d -l 3 in
t "-d widens? no: -d with -a2 stops"   -d -a 2 -l 1 in
t "--numeric-suffixes=5"               --numeric-suffixes=5 -l 5 in
t "--numeric-suffixes=05 -a3"          --numeric-suffixes=05 -a 3 -l 5 in
t "--numeric-suffixes (no value)"      --numeric-suffixes -l 5 in
t "-x"                                 -x -l 1 in
t "--hex-suffixes=8"                   --hex-suffixes=8 -l 1 in
t "--additional-suffix"                --additional-suffix=.txt -l 10 in
t "additional suffix + -d"             -d --additional-suffix=.dat -l 10 in
t "--additional-suffix is slash"       --additional-suffix=a/b -l 10 in
t "suffix too small for -d start"      -a 1 --numeric-suffixes=10 in
t "numeric start invalid"              --numeric-suffixes=zz in
t "hex start invalid"                  --hex-suffixes=1g in
t "-a 0 means default"                 -a 0 -l 5 in
t "-a x invalid"                       -a x in
t "-a -1 range"                        -a -1 in
t "auto widening 650 -> xzaaa"         -b 1 -a 0 --verbose bin

printf "\n[ -b sizes ]\n"
t "-b 2KB"                             -b 2KB bin
t "-b 2KiB"                            -b 2KiB bin
t "-b 1b"                              -b 1b bin
t "-b K alone"                         -b K bin
t "-b 99999999999999999999"            -b 99999999999999999999 in
t "-b 0 invalid"                       -b 0 in
t "-b 1x invalid"                      -b 1x in
t "-b -1 invalid"                      -b -1 in
t "-l 1K invalid (plain count)"        -l 1K in
t "-l 0 invalid"                       -l 0 in
t "-l +3"                              -l +3 in
t "-l x invalid"                       -l x in

printf "\n[ -C line-bytes ]\n"
t "-C 20"                              -C 20 in
t "-C 6 ragged"                        -C 6 ragged
t "-C 10 ragged"                       -C 10 ragged
t "-C 64 ragged"                       -C 64 ragged
t "-C 1 (every byte a piece)"          -C 1 k
t "-C 30 long lines"                   -C 30 longlines
t "-C 40 long lines"                   -C 40 longlines
t "-C 100 long lines"                  -C 100 longlines
t "-C 101 long lines"                  -C 101 longlines
t "-C 8 no trailing newline"           -C 8 nonl
t "-C 1K binary"                       -C 1K bin
t "-C 7 -t NUL"                        -C 7 -t '\0' nul
t "-C 0 invalid"                       -C 0 in

printf "\n[ -n chunks ]\n"
t "-n 3"                               -n 3 in
t "-n 7"                               -n 7 in
t "-n 1"                               -n 1 in
t "-n 100 (more chunks than bytes)"    -n 100 k
t "-n 30 -e"                           -n 30 -e k
t "-n 3 bin"                           -n 3 bin
t "-n 2/3 to stdout"                   -n 2/3 in
t "-n 1/3 to stdout"                   -n 1/3 in
t "-n 3/3 to stdout"                   -n 3/3 in
t "-n 5/5 bin to stdout"               -n 5/5 bin
t "-n l/3"                             -n l/3 k
t "-n l/4 in"                          -n l/4 in
t "-n l/7 in"                          -n l/7 in
t "-n l/3 ragged"                      -n l/3 ragged
t "-n l/10 ragged"                     -n l/10 ragged
t "-n l/60 ragged (some empty)"        -n l/60 ragged
t "-n l/5 -e longlines"                -n l/5 -e longlines
t "-n l/9 longlines"                   -n l/9 longlines
t "-n l/4 no trailing newline"         -n l/4 nonl
t "-n l/7/33 (GNU manual)"             -n l/7/33 ragged
t "-n l/1/4"                           -n l/1/4 in
t "-n l/2/4"                           -n l/2/4 in
t "-n l/4/4"                           -n l/4/4 in
t "-n l/3/7 ragged"                    -n l/3/7 ragged
t "-n r/3"                             -n r/3 k
t "-n r/4 in"                          -n r/4 in
t "-n r/60 ragged"                     -n r/60 ragged
t "-n r/2/3"                           -n r/2/3 in
t "-n r/3/3 -u"                        -n r/3/3 -u in
t "-n r/3 -u"                          -n r/3 -u in
t "-n r/30 -e (empty files elided)"    -n r/30 -e k
t "-n r/8 no trailing newline"         -n r/8 nonl
t "-n r/3 -t NUL"                      -n r/3 -t '\0' nul
t "-n 0 invalid"                       -n 0 in
t "-n x invalid"                       -n x in
t "-n 3/2 invalid chunk"               -n 3/2 in
t "-n 0/2 invalid chunk"               -n 0/2 in
t "-n l/x invalid"                     -n l/x in
t "-n -3 invalid"                      -n -3 in
t "-n ' 3' leading blank"              -n ' 3' in
t "-n 30 -a 1 suffix too short"        -n 30 -a 1 in
t "-n 700 -a 2 suffix too short"       -n 700 -a 2 in
t "-n 30 widens suffix to 2"           -n 30 in
t "-n 30 -d"                           -n 30 -d in
t "-n 12 --numeric-suffixes=95 (-a3)"  -n 12 --numeric-suffixes=95 in
t "-n 3 --additional-suffix"           -n 3 --additional-suffix=.p in

printf "\n[ -t, -e, --verbose ]\n"
t "-t NUL via \\0"                     -t '\0' -l 2 nul
t "-t ,"                               -t , -l 2 nonl
t "-t xx invalid"                      -t xx in
t "-t empty invalid"                   -t '' in
t "-t a -t b conflict"                 -t a -t b in
t "-t a -t a ok"                       -t a -t a -l 1 in
t "--verbose"                          --verbose -l 10 in
t "--verbose quoting"                  --verbose -l 10 in 'a b'
t "--verbose -n 3"                     --verbose -n 3 in
t "--verbose -n r/3"                   --verbose -n r/3 in

printf "\n[ Option errors ]\n"
t "-l and -b conflict"                 -l 1 -b 1 in
t "-n and -l conflict"                 -n 3 -l 1 in
t "-NUM and -l conflict"               -5 -l 2 in
t "-C and -b conflict"                 -C 3 -b 3 in
t "extra operand"                      in a b
t "unknown short option"               -z
t "unknown long option"                --bogus
t "-d=x"                               -d=x in
t "--lines missing argument"           --lines
t "-l missing argument"                -l
t "--verbose=1 takes none"             --verbose=1 in
t "ambiguous --n=3"                    --n=3 in
t "ambiguous --lin"                    --lin in
t "abbreviation --lines"               --li=5 in
t "abbreviation --bytes"               --by=7 in
t "--lines 5"                          --lines 5 in
t "--suffix-length=3"                  --suffix-length=3 -l 5 in
t "--elide-empty-files"                --elide-empty-files -n 30 k
t "-- ends options"                    -l 5 -- in
t "options after operands"             in -l 5
t "--filter with chunk K/N"            --filter=cat -n 1/2 in
t "no such input"                      nonexist
t "directory input"                    dir

printf "\n[ Filter ]\n"
t "--filter cat"                       --filter='cat > $FILE.out' -l 10 in
t "--filter with -b"                   --filter='wc -c > $FILE.n' -b 100 in
t "--filter exit status"               --filter='cat >/dev/null; exit 3' -l 10 in
t "--filter killed by signal"          --filter='kill -TERM $$' -l 10 in
t "--filter ignores EPIPE"             --filter='exit 0' -l 1 in
t "--filter -n r/3"                    --filter='cat > $FILE.r' -n r/3 in
t "--filter -n 3"                      --filter='cat > $FILE.c' -n 3 in
t "--filter --verbose"                 --filter='cat >/dev/null' --verbose -l 10 in

printf "\n[ Suffix widening and descriptor limits ]\n"
BIGSETUP='seq 1 4500 > big; wc -c < big > size'
run_tree "second widening (xzzaaaa) over 18000 files" "$BIGSETUP" -b 1 big
run_tree "numeric suffix exhaustion with -a 3"        "$BIGSETUP" -d -a 3 -b 1 big
TREE_PRE="ulimit -n 16"
run_tree "-n r/40 under a descriptor limit"           "$SETUP" -n r/40 in
run_tree "-n r/40 -u under a descriptor limit"        "$SETUP" -n r/40 -u in
unset TREE_PRE
run_tree "-n r/2000 (many files, small buffers)"      "$SETUP; seq 1 5000 > many" -n r/2000 many

printf "\n[ Existing files ]\n"
run_tree "existing outputs are truncated"          "$SETUP; echo OLD > xaa; echo OLD > xab" -l 10 in
run_tree "existing output longer than new piece"   "$SETUP; seq 1 1000 > xaa" -l 2 in
run_tree "output would overwrite input"            "$SETUP; cp in xaa" -l 2 xaa
run_tree "input is the last output"                "$SETUP; cp in xac" -l 10 xac
run_tree "unwritable output location"              "$SETUP" -l 10 in no/such/dir/p
run_tree "name too long"                           "$SETUP" -l 10 in "$(printf 'x%.0s' $(seq 1 300))"
run_tree "fifo output: not truncated as file"      "$SETUP; mkfifo xaa" -n 1 -e empty

printf "\n[ Read errors and special input ]\n"
run_tree "pipe input with -n (spooled)"            "$SETUP" -n l/3 /dev/stdin
TREE_STDIN=/dev/null
run_tree "/dev/null input"                         "$SETUP" -n 3 /dev/null
unset TREE_STDIN

print_summary
[ "$FAIL" -eq 0 ]
