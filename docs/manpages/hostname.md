% HOSTNAME(1) Version unreleased (after 0.2.0) | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
hostname - show or set the system host name

SYNOPSIS
hostname [-b] [NAME | -F FILE]

hostname [-a | -d | -f | -i | -s | -y]

DESCRIPTION
With no operand prints the host name. With a NAME, or the first non-comment line of FILE, sets it (needs privilege). The display options print part of the name or look it up in /etc/hosts.

OPTIONS
**-s**, **--short**: the name up to the first dot.

**-f**, **--fqdn**, **--long**: the first name on the /etc/hosts line that lists the host name.

**-d**, **--domain**: what follows the first dot of that name.

**-a**, **--alias**: the other names on that line.

**-i**, **--ip-address**: the IPv4 addresses on the matching lines.

**-y**, **--yp**, **--nis**: the NIS domain name from the kernel.

**-b**, **--boot**: if the host name is empty or `(none)`, set it from /etc/hostname, else `localhost`.

**-F** FILE, **--file** FILE: read the new name from FILE.

**-V**, **--version**, **-h**, **--help**: print and exit. (**-h** prints the usage and exits 255, as the reference does.)

**-A**, **-I**: not supported.

EXIT STATUS
Status	Meaning
0	Success.
1	The change was refused, the file could not be read, or a lookup failed.
255	Usage error.

EXAMPLES
    hostname
    hostname -s
    hostname -F /etc/hostname

DIAGNOSTICS
`hostname: you must be root to change the host name`, `hostname: Name or service not known` (the name is not in /etc/hosts).

SECURITY CONSIDERATIONS
Changing the host name needs CAP_SYS_ADMIN in the UTS namespace.

CONCURRENCY AND ATOMICITY
The change is one system call.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against hostname 3.25.

Standards and references
See docs/compatibility/hostname.md. Decision 0006 records why this command is here.

LIMITATIONS
No DNS or NSS: names are completed from /etc/hosts only.

PERFORMANCE
Dominated by process start-up. Not benchmarked.

SEE ALSO
hostname(7), gethostname(2), sethostname(2), hosts(5)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes the development version after util-unix 0.2.0 (see build.zig.zon).
