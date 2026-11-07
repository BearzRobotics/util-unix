% SPLIT(1) Version 0.0.0-dev | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
split - split a file into pieces

SYNOPSIS
split [-a suffix_length] [-b n[k|m] | -l line_count] [file [name]]

split [OPTION]... [FILE [PREFIX]]

DESCRIPTION
split reads FILE (standard input if FILE is omitted or is -) and writes it to a series of output files whose names are PREFIX followed by a generated suffix: aa, ab, ..., az, ba, ... By default each output file holds 1000 lines and PREFIX is x. Concatenating the files in name order gives back the input (except with -n r/N). If the input is empty, no file is created.

The default suffix is two lowercase letters. When the first letter reaches z, split widens the suffix by two (xyz is followed by xzaaa) so names keep sorting correctly; -a, -n and --numeric-suffixes=FROM turn that off. If the names run out, split reports an error and keeps the files it already wrote.

The options -a, -b (with k and m suffixes) and -l, and the two operands, are specified by POSIX.1-2024. Everything else is a GNU extension and is marked below.

CONVENTIONS
SIZE is an integer with an optional unit: b (512), K, M, G, T, P, E, Z, Y, R, Q (powers of 1024), KB, MB, ... (powers of 1000) or KiB, MiB, ... (powers of 1024). Only plain integers are accepted for line counts. Options may follow operands; -- ends options.

OPTIONS
-a, --suffix-length=N
: Use suffixes of length N. 0 means the default (2, widening automatically).

--additional-suffix=SUFFIX
: (GNU) Append SUFFIX to every file name. It must not contain a slash.

-b, --bytes=SIZE
: Put SIZE bytes in each file. POSIX defines only the suffixes k and m.

-C, --line-bytes=SIZE
: (GNU) Put as many whole records as fit in SIZE bytes in each file. A record longer than SIZE starts a new file and is cut into SIZE-byte pieces.

-d, --numeric-suffixes[=FROM]
: (GNU) Use digits for suffixes. With FROM (long form only), start counting there and do not widen.

-x, --hex-suffixes[=FROM]
: (GNU) Like -d with lowercase hexadecimal digits.

-e, --elide-empty-files
: (GNU) With -n, do not create empty files.

--filter=COMMAND
: (GNU) Pipe each piece to `$SHELL -c COMMAND` (default /bin/sh) instead of writing a file; $FILE holds the would-be name. The exit status of split is that of the first failing filter.

-l, --lines=NUMBER
: Put NUMBER lines (records, with -t) in each file. The obsolete form -NUMBER is accepted.

-n, --number=CHUNKS
: (GNU) Make CHUNKS files. CHUNKS is N (equal byte ranges; the first files are one byte longer when it does not divide evenly), K/N (write only the Kth of N to standard output), l/N and l/K/N (as above, but never break a record), or r/N and r/K/N (deal records to the files in turn). Inputs that are not regular files are read into memory first, except for r/.

-t, --separator=SEP
: (GNU) Records end in SEP instead of newline. \0 means NUL.

-u, --unbuffered
: (GNU) With -n r/..., write each record immediately.

--verbose
: (GNU) Print `creating file 'NAME'` to standard output before each file is created.

--help, --version
: Print help or version to standard output and exit.

EXIT STATUS
0 on success. 1 on any error: unreadable input, a file that cannot be created or written, a bad option, suffixes exhausted, or an output that would overwrite the input. With --filter, the exit status of a filter that failed (128+N if it was killed by signal N other than SIGPIPE).

SUPPORTED PLATFORMS
Linux (x86_64 tested). The code uses only std.Io and compiles for other Unix targets; they are untested.

PRIVILEGES AND SIDE EFFECTS
No privileges. Creates or truncates files named PREFIX+suffix in the current directory (or as PREFIX says). It refuses to truncate the input file. With --filter it starts one shell per piece.

FAILURE BEHAVIOR
Files already written are left in place. Diagnostics go to standard error as `split: MESSAGE`, in the wording of GNU split.

EXAMPLES
    split foo                      # xaa, xab, ... of 1000 lines each (POSIX)
    split -a 4 -l 2000 foo bar_    # bar_aaaa, bar_aaab, ... (POSIX)
    split -b 20k -a 5 foo          # 20 KiB pieces, 5-letter suffixes (POSIX)
    split -d -b 1M big part-       # part-00, part-01, ... (GNU)
    split -n l/7/33 big            # the 7th of 33 pieces, whole lines (GNU)
    xz -dc BIG.xz | split -b200G --filter='xz > $FILE.xz' - big-

STANDARDS
POSIX.1-2024 split; GNU coreutils 9.7 split. Differences: docs/compatibility/split.md.

SEE ALSO
csplit(1), cat(1), the GNU coreutils manual, "split invocation".
