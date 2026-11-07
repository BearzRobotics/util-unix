% ID(1) Version 0.3.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
id - print real and effective user and group IDs

SYNOPSIS
id [OPTION]... [USER]...

DESCRIPTION
Prints user and group information for each USER (a name, or a decimal uid when no user has that name) or, with none, for the calling process. Without options it prints `uid=N(name) gid=N(name) [euid=...] [egid=...] groups=N(name),...`; the effective group is listed first. Names come from /etc/passwd and /etc/group only (decision 0004).

OPTIONS
**-u**, **--user**, **-g**, **--group**, **-G**, **--groups**
: Print only the effective user id, group id, or all group ids. Only one may be given.

**-n**, **--name**
: Print a name instead of a number (needs **-u**, **-g** or **-G**).

**-r**, **--real**
: Print the real instead of the effective id.

**-z**, **--zero**
: Delimit entries with NUL (not allowed in the default format).

**-a**
: Ignored.

**-Z**, **--context**
: Always fails: no SELinux support.

**--help**, **--version**
: Print and exit 0.

OPERANDS
*USER*: zero or more. With several users each is described on its own line.

OUTPUT
One line per user. With **-n**, an id that has no name is printed as a number and a warning `id: cannot find name for group ID N` goes to standard error just before it (exit 1). In the default format an unnamed id is simply printed without a name.

EXIT STATUS
Status	Meaning
0	Success.
1	Any failure, including a usage error. Processing continues with the next operand after an error on one of them.

EXAMPLES
    id
    id -un
    id -Gn alice

DIAGNOSTICS
`id: 'X': no such user`; `id: cannot print "only" of more than one choice`; `id: printing only names or real IDs requires -u, -g, or -G`; `id: option --zero not permitted in default format`.

SECURITY CONSIDERATIONS
Read-only; needs no privileges.

CONCURRENCY AND ATOMICITY
Reads the account files once per run. The list of supplementary groups of the calling process comes from getgroups(2).

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files. Built for x86_64-linux-musl, the suite passes on a glibc host; a real musl distribution has not been tried. Other Unix-like systems are not supported yet: only Linux has been exercised.

Standards and references
See docs/compatibility/id.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
No SELinux context. The number of supplementary groups is limited only by the kernel (65536); a 1503-group process was tested in a VM. See docs/compatibility/id.md.

PERFORMANCE
Dominated by process start-up. Measured on 2026-11-07 against GNU id 9.7 (docs/benchmarks/2026-11-07.md): 0.08-0.18 of GNU's cycles, wall 0.45-0.63. The binary is about 6 times larger. One run per case on WSL2; differences within about 20% are noise.

SEE ALSO
groups(1), passwd(5), group(5), getgroups(2)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes util-unix 0.3.0 (see build.zig.zon).
