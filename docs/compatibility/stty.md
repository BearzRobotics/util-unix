# stty: compatibility record

Status: implemented; 670 differential cases pass against GNU stty 9.7 in individual and multicall mode (about 660 on a pseudo-terminal, the rest without a terminal). Date: 2026-11-07. Ownership: decision 0006.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `stty` and the General Terminal Interface: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/stty.html (cited; the page was not re-read when this record was written).
- GNU coreutils 9.7 manual, node "stty invocation" and `stty --help` (embedded in the program as its help text), as installed (`stty (GNU coreutils) 9.7`).
- termios(3), tty_ioctl(4), ioctl_tty(2), Linux man-pages.
- Behaviour was verified by running both binaries on a pseudo-terminal created by `test/stty_pty.py` and comparing output, error text, exit status and the terminal's final state. The upstream source of the reference implementation was not consulted; the implementation is independent.

## What is POSIX and what is an extension

POSIX has `-a`, `-g`, the special characters, the common modes and speeds; most flags marked `*` in `stty --help`, `-F`, `--file`, `size`, `rows`, `cols`, `line`, `sane` details and the combination settings beyond POSIX's are GNU.

## Supported

Everything in GNU stty 9.7's help on Linux: `-a`/`--all`, `-g`/`--save` and restoring from its output, `-F`/`--file`, `size`, `speed`, `rows`/`cols`/`columns`, `line`, `min`, `time`, `ispeed`, `ospeed`, numeric speeds (0 to 4000000 baud), all special characters (`^C`, `^?`, `^-`, `undef`, a literal character, or a number in hex/octal/decimal), every control, input, output and local flag and its negation, the multi-valued delays (`nl0` ... `ff1`, `cs5` ... `cs8`) and the combinations (`evenp`, `oddp`, `parity`, `nl`, `ek`, `sane`, `cooked`, `raw`, `pass8`, `litout`, `cbreak`, `decctlq`, `tabs`, `lcase`, `LCASE`, `crt`, `dec`). Compared: each setting alone and negated, each character with eleven spellings, every speed, the line wrapping of `-a` and of the default display at every terminal width from 10 to 120 (and 150, 200) set through `COLUMNS`, option parsing (`-ag`, `-aF DEV`, `--al`, ...), and the error messages and the order of checking (all settings are validated before the terminal is touched).

## Deliberate deviations and gaps

1. **A pseudo-terminal ignores some requests** (it keeps 8 data bits, no parity and the receiver on). For `parenb`, `-cread`, `cs5`, `cs6`, `cs7`, `evenp`, `oddp`, `parity`, `-pass8` and `-litout` both programs fail with status 1 and print the same standard output, but the error text differs: GNU, through glibc 2.42, reports "Invalid argument" for some of them and "unable to perform all requested operations" for others (the rule could not be inferred); this program always says "unable to perform all requested operations". The tests compare only output and status for these.
2. **Speeds above the Bxxx constants (arbitrary baud rates) are not available:** only the classic `TCGETS` structure is used, as above 4000000 baud and `BOTHER` need `TCGETS2`.
3. **`-F DEVICE` is opened blocking.** GNU opens it with `O_NONBLOCK`; a modem line waiting for carrier blocks the open here.
4. **`drain`/`-drain`** are accepted and do nothing (as in GNU on Linux, where the change is always drained).
5. **`line N` above 255** reports the error twice and carries on with status 0, as GNU 9.7 does.
6. **`rows`/`cols` are stored in 16 bits without a range check**, as GNU 9.7 does (`rows 65536` sets 0).
7. **`--help`** matches GNU's text apart from the program path and the trailing GNU-specific lines; **`--version`** prints `stty (util-unix) VERSION`.
8. **Not verified on a real serial port.** The VM test harness (`test/vm/`) has no stty tests yet; the pseudo-terminal cannot show baud-rate, parity or character-size changes.

## Platforms

Linux on the generic termios layout (x86, arm, arm64, riscv, s390x, loongarch). Other Linux architectures return "Operation not supported". The executable is static and does not link libc. Tested on x86-64 Linux 6.18 (WSL2).
