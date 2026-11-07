% CHCON(1) Version 0.3.0 | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
chcon - change the SELinux security context of files

SYNOPSIS
chcon [OPTION]... CONTEXT FILE...

chcon [OPTION]... [-u USER] [-r ROLE] [-l RANGE] [-t TYPE] FILE...

chcon [OPTION]... --reference=RFILE FILE...

DESCRIPTION
Sets the `security.selinux` attribute of each FILE to CONTEXT, to RFILE's context, or, with **-u -r -t -l**, to the file's current context with those parts replaced. A context is `user:role:type[:range]`.

OPTIONS
**-u**, **--user=**USER, **-r**, **--role=**ROLE, **-t**, **--type=**TYPE, **-l**, **--range=**RANGE: replace that part of each file's current context.

**--reference=**RFILE: use RFILE's context.

**-R**, **--recursive**: recurse into directories; a directory is changed after its contents.

**-H**: follow a command-line symbolic link to a directory. **-L**: follow every such link. **-P**: follow none (default). The last of the three wins; they matter only with **-R**.

**-h**, **--no-dereference**: change a symbolic link itself. **--dereference**: change what it points to (the default without **-R**).

**-v**, **--verbose**: print `changing security context of 'FILE'` for each file.

**--preserve-root**: refuse **-R** on `/`. **--no-preserve-root**: do not (the default).

**--help**, **--version**: print and exit 0.

EXIT STATUS
Status	Meaning
0	Every file was changed.
1	A file could not be examined or changed, or the usage was wrong.

EXAMPLES
    chcon system_u:object_r:httpd_sys_content_t:s0 index.html
    chcon -R -t httpd_sys_content_t /srv/www
    chcon --reference=/etc/passwd newfile

DIAGNOSTICS
`chcon: cannot access 'F': No such file or directory`, `chcon: can't apply partial context to unlabeled file 'F'`, `chcon: failed to change context of 'F' to 'C': Operation not supported`.

SECURITY CONSIDERATIONS
Changing a context needs the permission the policy requires; the kernel decides. This program does not check a context against a policy.

CONCURRENCY AND ATOMICITY
Each file is one attribute write; a recursive run is not atomic.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2), where `security.selinux` is a plain attribute (no SELinux), against GNU coreutils 9.7.

Standards and references
See docs/compatibility/chcon.md. Decision 0006 records why this command is here.

LIMITATIONS
Behaviour under a loaded policy was not run.

PERFORMANCE
Dominated by process start-up and the attribute calls. Not benchmarked.

SEE ALSO
runcon(1), selinux(8), xattr(7)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes util-unix 0.3.0 (see build.zig.zon).
