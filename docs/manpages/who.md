% WHO(1) Version unreleased (after 0.2.0) | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
who - show who is logged in

SYNOPSIS
who [OPTION]... [FILE | ARG1 ARG2]

DESCRIPTION
Lists the login records in FILE (default /var/run/utmp; /var/log/wtmp is common). With ARG1 ARG2 (for example `am i`) it shows only the entry for the terminal on standard input.

OPTIONS
**-a**, **--all**: **-b -d --login -p -r -t -T -u**.

**-b**, **--boot**: time of last boot. **-d**, **--dead**: dead processes. **-l**, **--login**: login processes. **-p**, **--process**: processes spawned by init. **-r**, **--runlevel**: run level. **-t**, **--time**: last clock change. **-u**, **--users**: users logged in, with idle time and process id.

**-H**, **--heading**: print a heading line.

**-m**: only the entry for standard input's terminal.

**-q**, **--count**: all login names and their number.

**-s**, **--short**: name, line and time (the default).

**-T**, **-w**, **--mesg**, **--message**, **--writable**: add the terminal's message status (`+` writable, `-` not, `?` unknown).

**--lookup**: accepted and ignored (no DNS).

**--help**, **--version**: print and exit 0.

OUTPUT
Columns: name, optional message status, line, time, optional idle (`.` under a minute, `HH:MM`, `old`, `?`), optional pid, host in parentheses. Time is `Nov  7 13:39` in the C and POSIX locales and `2025-11-07 13:39` otherwise (decided from LC_ALL, LC_TIME, LANG).

EXIT STATUS
Status	Meaning
0	Success (also when FILE is missing or empty).
1	Usage error, unreadable FILE, or write error.

EXAMPLES
    who
    who -aH /var/log/wtmp
    who -q

DIAGNOSTICS
`who: extra operand 'X'`.

SECURITY CONSIDERATIONS
Host names and user names from the file are shown as they are.

CONCURRENCY AND ATOMICITY
The file is read once, whole.

COMPATIBILITY
Platforms
Linux (the 384-byte `struct utmp`). Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7.

Standards and references
See docs/compatibility/who.md. Decision 0006 records why this command is here.

LIMITATIONS
Reads the utmp file, not systemd-logind sessions.

PERFORMANCE
Dominated by process start-up. Not benchmarked.

SEE ALSO
utmp(5), pinky(1)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes the development version after util-unix 0.2.0 (see build.zig.zon).
