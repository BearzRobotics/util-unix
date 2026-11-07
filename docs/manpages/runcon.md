% RUNCON(1) Version unreleased (after 0.2.0) | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
runcon - run a command in a different SELinux security context

SYNOPSIS
runcon CONTEXT COMMAND [ARG]...

runcon [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] COMMAND [ARG]...

runcon

DESCRIPTION
With no operand prints the current security context. Otherwise sets the context for the next exec (through /proc/self/attr/exec) and replaces itself with COMMAND, so COMMAND's exit status is runcon's. With **-u -r -t -l** the new context is the current one with those parts replaced.

Option parsing stops at the first operand: everything from CONTEXT or COMMAND on belongs to the command.

OPTIONS
**-u**, **--user=**USER, **-r**, **--role=**ROLE, **-t**, **--type=**TYPE, **-l**, **--range=**RANGE: replace that part of the current context.

**-c**, **--compute**: compute the transition from the policy. Not supported: it fails when SELinux is enabled.

**--help**, **--version**: print and exit 0.

EXIT STATUS
Status	Meaning
125	runcon itself failed (usage error, SELinux not enabled, context refused).
126	COMMAND was found but could not be run.
127	COMMAND was not found.
other	COMMAND's own status.

EXAMPLES
    runcon
    runcon -t httpd_t /usr/sbin/httpd

DIAGNOSTICS
`runcon: no command specified`, `runcon: runcon may be used only on a SELinux kernel`.

SECURITY CONSIDERATIONS
The policy decides whether the transition is allowed; the kernel refuses otherwise.

CONCURRENCY AND ATOMICITY
The context applies to the calling thread's next exec only.

COMPATIBILITY
Platforms
Linux. Tested on Linux 6.18 (WSL2) without SELinux, against GNU coreutils 9.7: usage errors, the current-context display and the refusal. The transition itself has not been run.

Standards and references
See docs/compatibility/runcon.md. Decision 0006 records why this command is here.

LIMITATIONS
**-c** is not supported; the transition under a policy is unverified.

PERFORMANCE
Not applicable.

SEE ALSO
chcon(1), selinux(8), proc_pid_attr(5)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes the development version after util-unix 0.2.0 (see build.zig.zon).
