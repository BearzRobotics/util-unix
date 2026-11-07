% PINKY(1) Version unreleased (after 0.2.0) | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
pinky - lightweight finger

SYNOPSIS
pinky [-s] [-fwiq] [USER]...

pinky -l [-bhp] USER...

DESCRIPTION
Short format (the default) lists the user sessions in /var/run/utmp, optionally only those of the named users: login, real name, terminal, idle time, login time and remote host. Long format (**-l**) describes the named accounts from /etc/passwd and their .project and .plan files.

OPTIONS
**-l**: long format. **-s**: short format. The last of the two on the line wins.

**-b**: omit the directory and shell in long format. **-h**: omit the .project file. **-p**: omit the .plan file.

**-f**: omit the heading line. **-w**: omit the real name. **-i**: omit the real name and the remote host. **-q**: omit the real name, remote host and idle time.

**--lookup**: accepted and ignored (no DNS). **--help**, **--version**: print and exit 0.

OUTPUT
Short: `Login Name TTY Idle When Where`. The terminal column starts with `*` when the terminal does not accept messages and `?` when it cannot be examined. Idle is blank under a minute, `HH:MM` under a day, `Nd` beyond. Long: `Login name:`, `In real life:`, `Directory:`, `Shell:`, `Project:` and `Plan:` followed by the file text, then a blank line. An unknown account shows `???` as its name and nothing else.

EXIT STATUS
Status	Meaning
0	Success.
1	Usage error, or `-l` without a user.

EXAMPLES
    pinky
    pinky -l alice

DIAGNOSTICS
`pinky: no username specified; at least one must be specified when using -l`.

SECURITY CONSIDERATIONS
.plan and .project files are copied to the output unchanged, control characters included.

CONCURRENCY AND ATOMICITY
Files are read once.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (long format only).

Standards and references
See docs/compatibility/pinky.md. Decision 0006 records why this command is here.

LIMITATIONS
The short format is not verified against GNU: the available GNU pinky reads systemd-logind sessions, not the utmp file. This program reads the utmp file only.

PERFORMANCE
Dominated by process start-up. Not benchmarked.

SEE ALSO
who(1), utmp(5), passwd(5)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes the development version after util-unix 0.2.0 (see build.zig.zon).
