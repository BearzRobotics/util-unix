% UNAME(1) Version 0.1.0 | util-unix Manual
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
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files; no musl-specific testing has been done. Other Unix-like systems are not supported yet: only Linux has been exercised; other systems print "unknown" for every field.

Standards and references
See docs/compatibility/uname.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
See docs/compatibility/uname.md.

SEE ALSO
uname(2), arch(1)

VERSION
This manual describes util-unix 0.1.0 (see build.zig.zon).
