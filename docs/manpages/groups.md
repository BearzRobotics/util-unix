% GROUPS(1) Version 0.2.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
groups - print the groups a user is in

SYNOPSIS
groups [OPTION]... [USERNAME]...

DESCRIPTION
Prints the group names of each USERNAME, or of the calling process with none. Same data as `id -Gn`; with user names each line is prefixed `NAME : `. Unlike id(1), a USERNAME must be a name (a number is not tried). Names come from /etc/passwd and /etc/group only.

OPTIONS
**--help**, **--version**: print and exit 0.

OPERANDS
*USERNAME*: zero or more existing user names.

OUTPUT
One line per user, group names separated by spaces; an unnamed group is printed as its number with a warning on standard error (exit 1).

EXIT STATUS
Status	Meaning
0	Success.
1	Any failure, including a usage error. Processing continues with the next operand after an error on one of them.

EXAMPLES
    groups
    groups root alice

DIAGNOSTICS
`groups: 'X': no such user`.

SECURITY CONSIDERATIONS
Read-only; needs no privileges.

CONCURRENCY AND ATOMICITY
None beyond reading the account files.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files. Built for x86_64-linux-musl, the suite passes on a glibc host; a real musl distribution has not been tried. Other Unix-like systems are not supported yet: only Linux has been exercised.

Standards and references
See docs/compatibility/groups.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
Same group-count limit as id(1). See docs/compatibility/groups.md.

PERFORMANCE
Dominated by process start-up. Measured on 2026-11-07 against GNU groups 9.7 (docs/benchmarks/2026-11-07.md): 0.12-0.20 of GNU's cycles, wall 0.66-0.72. The binary is about 7 times larger. One run per case on WSL2; differences within about 20% are noise.

SEE ALSO
id(1), group(5)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes util-unix 0.2.0 (see build.zig.zon).
