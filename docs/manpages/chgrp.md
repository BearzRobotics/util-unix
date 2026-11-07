% CHGRP(1) Version 0.2.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
chgrp - change group ownership

SYNOPSIS
chgrp [OPTION]... GROUP FILE...

chgrp [OPTION]... --reference=RFILE FILE...

DESCRIPTION
Changes the group of each FILE to GROUP (a name or a decimal id), or to that of RFILE. Shares its engine and options with chown(1); see that page for the option list. GROUP is looked up in /etc/group only (decision 0004).

OPTIONS
The same options as chown(1): **-c -f -v -h -R -H -L -P**, **--dereference**, **--from**, **--preserve-root**, **--no-preserve-root**, **--reference**, **--help**, **--version**.

OPERANDS
*GROUP* (omitted with **--reference**) and one or more *FILE*.

OUTPUT
As chown(1), with "group" wording: `changed group of 'NAME' from OLD to NEW` or `group of 'NAME' retained as GROUP`.

EXIT STATUS
Status	Meaning
0	Success.
1	Any failure, including a usage error. Processing continues with the next operand after an error on one of them.

EXAMPLES
    chgrp staff notes.txt
    chgrp -R 1000 build/

DIAGNOSTICS
`chgrp: invalid group: 'X'`; `chgrp: changing group of 'F': Operation not permitted`.

SECURITY CONSIDERATIONS
A non-root user may change a file only to a group they belong to. Same walk safety as chown(1).

CONCURRENCY AND ATOMICITY
As chown(1).

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files. Built for x86_64-linux-musl, the suite passes on a glibc host; a real musl distribution has not been tried. Other Unix-like systems are not supported yet: only Linux has been exercised.

Standards and references
See docs/compatibility/chgrp.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
See chown(1) and docs/compatibility/chgrp.md.

PERFORMANCE
Measured on 2026-11-07 against GNU chgrp 9.7 (docs/benchmarks/2026-11-07.md): recursive group changes over 10,000 files used 0.45-0.54 of GNU's cycles, with wall time 0.76-0.91 of GNU's. The binary is about 4.7 times larger. One run per case on WSL2; differences within about 20% are noise.

SEE ALSO
chown(1), chmod(1), group(5)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes util-unix 0.2.0 (see build.zig.zon).
