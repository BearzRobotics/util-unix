% STTY(1) Version unreleased (after 0.2.0) | util-unix Manual
% util-unix contributors
% 2026-11-07

NAME
stty - show or change terminal settings

SYNOPSIS
stty [-F DEVICE | --file=DEVICE] [SETTING]...

stty [-F DEVICE] -a | --all

stty [-F DEVICE] -g | --save

DESCRIPTION
With no operand prints the speed, the line discipline and every setting that differs from `stty sane`. With SETTINGs changes the terminal; **-a** prints everything readably, **-g** prints it in a form that `stty` accepts back as one operand. The terminal is standard input, or DEVICE.

All SETTINGs are checked before the terminal is touched; a bad one changes nothing.

SETTINGS
The complete list is `stty --help`. In short:

Special characters: `intr quit erase kill eof eol eol2 swtch start stop susp rprnt werase lnext discard` followed by CHAR, which is one literal character, `^c` (control-c), `^?`, `^-` or `undef` (disabled), or a number (decimal, 0x hex, 0 octal).

Numbers: `N` (speed for input and output), `ispeed N`, `ospeed N`, `rows N`, `cols N` (`columns N`), `line N`, `min N`, `time N`; `size` and `speed` print the window size and speed.

Flags, each with a negating `-`: control (`parenb parodd cmspar hupcl cstopb cread clocal crtscts`, `cs5` to `cs8`), input (`ignbrk brkint ignpar parmrk inpck istrip inlcr igncr icrnl ixon ixoff iuclc ixany imaxbel iutf8`), output (`opost olcuc ocrnl onlcr onocr onlret ofill ofdel`, `nl0 nl1 cr0..cr3 tab0..tab3 bs0 bs1 vt0 vt1 ff0 ff1`), local (`isig icanon iexten echo echoe echok echonl noflsh xcase tostop echoprt echoctl echoke flusho extproc`).

Combinations: `evenp oddp parity nl ek sane cooked raw pass8 litout cbreak decctlq tabs lcase LCASE crt dec`.

OPTIONS
**-a**, **--all**: all settings, human-readable. **-g**, **--save**: settings in stty-readable form. **-F** DEVICE, **--file=**DEVICE: use DEVICE instead of standard input. **--help**, **--version**: print and exit 0.

OUTPUT
Lines wrap at the terminal width (the terminal on standard output, else $COLUMNS, else 80).

EXIT STATUS
Status	Meaning
0	Success.
1	Any failure: a bad setting, no terminal, or the terminal refused part of the request.

EXAMPLES
    stty -a
    stty -echo; read -r secret; stty echo
    saved=$(stty -g); stty raw; stty "$saved"
    stty -F /dev/ttyUSB0 115200 cs8 -parenb

DIAGNOSTICS
`stty: 'standard input': Inappropriate ioctl for device`, `stty: invalid argument 'X'`, `stty: missing argument to 'intr'`, `stty: invalid integer argument: 'X'`, `stty: 'standard input': unable to perform all requested operations` (the terminal kept some setting from before; a pseudo-terminal always keeps 8 data bits and no parity).

SECURITY CONSIDERATIONS
Changing a terminal's settings needs write access to its device. `stty -echo` hides typed input only while it is in effect.

CONCURRENCY AND ATOMICITY
The settings are applied in one TCSETSW call, after waiting for pending output to drain. The window size is a separate call.

COMPATIBILITY
Platforms
Linux on architectures with the generic termios layout (x86, arm, arm64, riscv, s390x, loongarch). Tested on a pseudo-terminal on Linux 6.18 (WSL2) against GNU coreutils 9.7.

Standards and references
See docs/compatibility/stty.md. Decision 0006 records why this command is here.

LIMITATIONS
Arbitrary baud rates are not available; a device named with -F is opened blocking; not tested on a real serial line.

PERFORMANCE
Dominated by process start-up. Not benchmarked.

SEE ALSO
termios(3), tty_ioctl(4), tty(1)

COPYRIGHT
Copyright (c) 2026 Dakota Keeler and the util-unix contributors. SPDX-License-Identifier: GPL-2.0-or-later.

LICENSE
This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY. The full text is in the file LICENSE of the source distribution.

VERSION
This manual describes the development version after util-unix 0.2.0 (see build.zig.zon).
