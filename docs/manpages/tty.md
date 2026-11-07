% TTY(1) Version 0.3.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
tty - print the file name of the terminal on standard input

SYNOPSIS
tty [-s | --silent | --quiet]

DESCRIPTION
Prints the path of the terminal connected to standard input, found through /proc/self/fd/0, or `not a tty`. With **-s** nothing is printed and only the exit status is set.

OPTIONS
**-s**, **--silent**, **--quiet**: print nothing.

**--help**, **--version**: print and exit 0.

OPERANDS
None; an operand is an error.

OUTPUT
Standard output: the terminal path, or `not a tty` unless **-s**.

EXIT STATUS
Status	Meaning
0	Standard input is a terminal.
1	Standard input is not a terminal (or its name cannot be found).
2	Usage error.
3	Write error.

EXAMPLES
    tty
    tty -s && echo interactive

DIAGNOSTICS
`tty: extra operand 'X'`.

SECURITY CONSIDERATIONS
None.

CONCURRENCY AND ATOMICITY
None.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files. Built for x86_64-linux-musl, the suite passes on a glibc host; a real musl distribution has not been tried. Other Unix-like systems are not supported yet: only Linux has been exercised.

Standards and references
See docs/compatibility/tty.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
Needs /proc to name the terminal; without it a terminal is reported as "not a tty" with status 1. See docs/compatibility/tty.md.

PERFORMANCE
Dominated by process start-up. Measured on 2026-11-07 against GNU tty 9.7 with standard input on /dev/null (docs/benchmarks/2026-11-07.md): 0.18 of GNU's cycles, wall 0.90. The binary is about 7 times larger. One run per case on WSL2; differences within about 20% are noise.

SEE ALSO
isatty(3), ttyname(3)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes util-unix 0.3.0 (see build.zig.zon).
