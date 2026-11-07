% CHOWN(1) Version 0.1.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
chown - change file owner and group

SYNOPSIS
chown [OPTION]... [OWNER][:[GROUP]] FILE...

chown [OPTION]... --reference=RFILE FILE...

DESCRIPTION
Changes the owner and/or group of each FILE. OWNER and GROUP are names or decimal ids; "OWNER:" also sets the group to OWNER's login group; a missing part is left unchanged. A part that names an existing user or group is that user or group even if it looks like a number; a leading "+" forces the numeric reading. Names are looked up in /etc/passwd and /etc/group only (decision 0004).

OPTIONS
**-c**, **--changes**, **-v**, **--verbose**, **-f**, **--silent**, **--quiet**
: As for chmod(1).

**--dereference**, **-h**, **--no-dereference**
: Affect the referent of a symbolic link (default) or the link itself.

**--from**=*CURRENT_OWNER:CURRENT_GROUP*
: Change a file only if its current owner and/or group match; an omitted part is not required to match.

**--preserve-root**, **--no-preserve-root**, **--reference**=*RFILE*, **-R**, **-H**, **-L**, **-P**
: As for chmod(1), except that **-P** is the default traversal.

**--help**, **--version**
: Print and exit 0.

OPERANDS
*OWNER[:GROUP]* (omitted with **--reference**) and one or more *FILE*.

OUTPUT
Standard output: with **-c** or **-v**, `changed ownership of 'NAME' from OLD to NEW`, `ownership of 'NAME' retained as OWNER` or `failed to change ownership of ...`. Standard error: diagnostics, including a warning for the old "OWNER.GROUP" separator.

EXIT STATUS
Status	Meaning
0	Success.
1	Any failure, including a usage error. Processing continues with the next operand after an error on one of them.

EXAMPLES
    chown alice:staff report.txt
    chown -R --from=root:root alice /srv/data
    chown -h alice link

DIAGNOSTICS
`chown: invalid user: 'X'` / `invalid group`: no such name and not a number; exit 1.

`chown: changing ownership of 'F': Operation not permitted`: only a privileged process may give files away.

SECURITY CONSIDERATIONS
Privileged operation: changing owners normally needs root (CAP_CHOWN). Changes are made through fchownat relative to open directories so a path swapped for a symbolic link during a walk cannot redirect them.

CONCURRENCY AND ATOMICITY
Not atomic across files. A directory is processed after its contents (post-order), as fts does for chown.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files; no musl-specific testing has been done. Other Unix-like systems are not supported yet: only Linux has been exercised.

Standards and references
See docs/compatibility/chown.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
Accounts that exist only in LDAP, SSSD or systemd-userdb are not seen (decision 0004). See docs/compatibility/chown.md.

SEE ALSO
chgrp(1), chmod(1), passwd(5), group(5), chown(2)

VERSION
This manual describes util-unix 0.1.0 (see build.zig.zon).
