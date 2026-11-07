% CHMOD(1) Version 0.2.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
chmod - change file mode bits

SYNOPSIS
chmod [OPTION]... MODE[,MODE]... FILE...

chmod [OPTION]... OCTAL-MODE FILE...

chmod [OPTION]... --reference=RFILE FILE...

DESCRIPTION
Changes the permission bits of each FILE to MODE, or to those of RFILE with **--reference**. MODE is octal (one to four digits, at most 07777) or symbolic (`[ugoa]*([-+=]([rwxXst]*|[ugo]))+`, comma-separated). A symbolic mode without a who letter honours the process umask. A directory keeps its set-user-ID and set-group-ID bits unless the mode names them (an octal mode of fewer than five digits, or a symbolic mode without **s**). Symbolic links met while recursing are skipped unless **-L**; the mode of a symbolic link itself is never changed.

OPTIONS
**-c**, **--changes**
: Like **-v**, but report only when a mode actually changes.

**-f**, **--silent**, **--quiet**
: Suppress error messages (the exit status still reports failure).

**-v**, **--verbose**
: Report every file processed on standard output.

**-h**, **--no-dereference**, **--dereference**
: Whether to look through symbolic links. With **-h** a symbolic link is left alone silently, since Linux cannot change its mode.

**--preserve-root**, **--no-preserve-root**
: With **-R**, refuse to operate on "/" (default: **--no-preserve-root**).

**--reference**=*RFILE*
: Use the mode of RFILE (always dereferenced) instead of MODE.

**-R**, **--recursive**
: Change files and directories recursively, a directory before its contents.

**-H**, **-L**, **-P**
: With **-R**: follow symbolic links named on the command line only (default), follow every link to a directory, or follow none. The last one given wins.

**--help**, **--version**
: Print help or version information on standard output and exit 0.

A word beginning with "-" made only of mode letters (for example `-w` or `-rwx`) is taken as the MODE operand.

OPERANDS
*MODE*: required unless **--reference** is given. *FILE*: one or more paths; relative paths are resolved against the current directory. "--" ends option processing.

OUTPUT
Standard output: only with **-c** or **-v**, one line per file: `mode of NAME changed from 0640 (rw-r-----) to 0600 (rw-------)` or `mode of NAME retained as 0600 (rw-------)`; with **-v**, `NAME could not be accessed` for a path that could not be examined. Names are shell-quoted like GNU. Standard error: diagnostics.

EXIT STATUS
Status	Meaning
0	Success.
1	Any failure, including a usage error. Processing continues with the next operand after an error on one of them.

EXAMPLES
Remove group and other access from a tree:

    chmod -R go-rwx ~/private

Make scripts executable and directories searchable, leaving plain files alone:

    chmod -R a+X project

Copy the mode of one file onto another:

    chmod --reference=template.conf new.conf

DIAGNOSTICS
`chmod: cannot access 'F': No such file or directory`: the path does not exist.

`chmod: invalid mode: 'M'`: MODE is not valid octal or symbolic; exit 1.

`chmod: changing permissions of 'F': Operation not permitted`: the file is owned by someone else.

`chmod: 'F': new permissions are r--r--r--, not ---------`: the umask kept bits the symbolic mode asked to clear; the exit status is 1.

SECURITY CONSIDERATIONS
Changing modes can expose or lock out files; **-R** on a wrong operand is hard to undo. **--preserve-root** guards "/". The walk works relative to open directories, so replacing a path component with a symbolic link during a long walk does not redirect a change. No privileges are needed beyond owning the files (or CAP_FOWNER).

CONCURRENCY AND ATOMICITY
Not atomic across files: files changed before an error stay changed. The umask is read once at start-up (it has no query call; see decision 0003).

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) against GNU coreutils 9.7 (getent: glibc 2.43). The executables are static and do not link libc, so musl or glibc matters only for the host's account files. Built for x86_64-linux-musl, the suite passes on a glibc host; a real musl distribution has not been tried. Other Unix-like systems are not supported yet: only Linux has been exercised.

Standards and references
See docs/compatibility/chmod.md for the references consulted, what is POSIX and what is a GNU extension, and every known deviation.

LIMITATIONS
Mode changes are not applied to symbolic links themselves. SELinux, ACL and extended-attribute handling is not implemented (the mode bits are set, nothing else). See docs/compatibility/chmod.md.

PERFORMANCE
Measured on 2026-11-07 against GNU chmod 9.7 (docs/benchmarks/2026-11-07.md): a recursive mode change over 10,000 files was within noise of GNU (wall 0.93-1.01, cycles 0.82-0.90, instructions 1.09-1.10 of GNU's); a single-file run used fewer cycles and instructions. The binary is about 4.5 times larger. One run per case on WSL2; differences within about 20% are noise.

SEE ALSO
chown(1), chgrp(1), umask(2), chmod(2)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes util-unix 0.2.0 (see build.zig.zon).
