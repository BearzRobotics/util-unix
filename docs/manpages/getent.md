% GETENT(1) Version 0.1.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
getent - get entries from administrative databases

SYNOPSIS
getent [OPTION...] database [key ...]

DESCRIPTION
Looks up each key in the named database and prints the matching entries in the same format as glibc's getent; with no key it lists the whole database where that is possible. Only the "files" source is consulted: /etc/passwd, /etc/group, /etc/shadow, /etc/services and the like. Nothing reads nsswitch.conf, DNS, LDAP, NIS or systemd-userdb (decision 0004).

OPTIONS
**-s**, **--service**=*CONFIG*
: Service configuration; only "files" returns anything.

**-A**, **--no-addrconfig**, **-i**, **--no-idn**
: Accepted and ignored.

**-?**, **--help**, **--usage**, **-V**, **--version**
: Print and exit 0.

Databases: ahosts ahostsv4 ahostsv6 aliases ethers group gshadow hosts initgroups netgroup networks passwd protocols rpc services shadow.

OPERANDS
*database*, then zero or more *key*s.

OUTPUT
Entries on standard output, one per line, in glibc's formats. Errors on standard error.

EXIT STATUS
Status	Meaning
0	All keys found (or the database listed).
1	Usage error or unknown database.
2	At least one key not found.
3	Enumeration not supported for that database.
64	Invalid option.

EXAMPLES
    getent passwd root
    getent group 0 100

DIAGNOSTICS
`Unknown database: X`; `Enumeration not supported on X`.

SECURITY CONSIDERATIONS
Reading shadow and gshadow needs privilege; as an ordinary user they read as empty.

CONCURRENCY AND ATOMICITY
None.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files. Built for x86_64-linux-musl, the suite passes on a glibc host; a real musl distribution has not been tried. Other Unix-like systems are not supported yet: only Linux has been exercised.

Standards and references
See docs/compatibility/getent.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
Answers that glibc gets from a non-file source differ ("not found"). See docs/compatibility/getent.md.

PERFORMANCE
Measured on 2026-11-07 against glibc 2.43 getent (docs/benchmarks/2026-11-07.md): 0.08-0.23 of its cycles, wall 0.49-0.82. This is not equal work: ours reads the files only, glibc goes through NSS. The binary is about 7.7 times larger. One run per case on WSL2; differences within about 20% are noise.

SEE ALSO
passwd(5), group(5), services(5), hosts(5), nsswitch.conf(5)

VERSION
This manual describes util-unix 0.1.0 (see build.zig.zon).
