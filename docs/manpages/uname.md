% UNAME(1) Version 0.3.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
uname - print system information

SYNOPSIS
uname [OPTION]...

DESCRIPTION
Prints selected fields of uname(2), always in the order kernel name, node name, release, version, machine, processor, hardware platform, operating system, separated by single spaces. Without options only the kernel name is printed. **-p** and **-i** print the machine name, and **-o** prints "GNU/Linux" on Linux, as GNU 9.7 does here.

OPTIONS
**-a**, **--all**: all fields.

**-s**, **--kernel-name**; **-n**, **--nodename**; **-r**, **--kernel-release**; **-v**, **--kernel-version**; **-m**, **--machine**; **-p**, **--processor**; **-i**, **--hardware-platform**; **-o**, **--operating-system**.

**--help**, **--version**: print and exit 0.

OPERANDS
None; an operand is an error.

OUTPUT
One line on standard output.

EXIT STATUS
Status	Meaning
0	Success.
1	Any failure, including a usage error. Processing continues with the next operand after an error on one of them.

EXAMPLES
    uname -sr
    uname -a

DIAGNOSTICS
`uname: extra operand 'X'`.

SECURITY CONSIDERATIONS
None.

CONCURRENCY AND ATOMICITY
None.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files. Built for x86_64-linux-musl, the suite passes on a glibc host; a real musl distribution has not been tried. Other Unix-like systems are not supported yet: only Linux has been exercised; other systems print "unknown" for every field.

Standards and references
See docs/compatibility/uname.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
See docs/compatibility/uname.md.

PERFORMANCE
Dominated by process start-up. Measured on 2026-11-07 against GNU uname 9.7 (docs/benchmarks/2026-11-07.md): 0.17 of GNU's cycles, wall 0.81-0.84. The binary is about 7 times larger. One run per case on WSL2; differences within about 20% are noise.

SEE ALSO
uname(2), arch(1)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes util-unix 0.3.0 (see build.zig.zon).
