# runcon: compatibility record

Status: implemented but only partly verified; 26 differential cases pass against GNU runcon 9.7 in individual and multicall mode, all of them on a kernel without SELinux. Date: 2026-11-07. Ownership: decision 0006.

## References

- GNU coreutils 9.7 manual, node "runcon invocation" and `runcon --help` (embedded as the program's help text), as installed (`runcon (GNU coreutils) 9.7`). runcon is not in POSIX.
- selinux(8), proc_pid_attr(5), Linux man-pages.
- The upstream source of the reference implementation and libselinux were not consulted; the implementation is independent.

## What was verified

On the development host (no SELinux policy; `selinuxfs` listed but not mounted, process context `kernel`): the current-context display with no operands (also with `-c` or component options alone), the option grammar (short and long, attached and separate values, abbreviations, `--`, option parsing stopping at the first operand), the "no command specified" error, the usage errors (status 125), and the refusal "may be used only on a SELinux kernel" in every position it appears.

## What was not verified

Everything that happens on an SELinux kernel: building the new context from the current one with `-u -r -t -l`, writing it to `/proc/self/attr/exec`, running the command, and the diagnostics of each failure there. That code follows proc_pid_attr(5) and the documented behavior; its messages (`unable to set security context`, `failed to create security context`, ...) are not compared with GNU's. It needs a machine with a policy loaded (the QEMU harness in `test/vm/` does not have one).

## Deliberate deviations and gaps

1. **`-c`/`--compute` is not supported** (it asks the policy for the transition context); with SELinux enabled it fails with a message and status 125. Without SELinux it behaves as GNU does (the refusal comes first).
2. **"SELinux is enabled"** means: `selinuxfs` is mounted and the process context is not `kernel`. libselinux decides this by its own method.
3. **`--version`** prints `runcon (util-unix) VERSION`; the refusal message names the program as invoked.

## Platforms

Linux only. The executable is static and does not link libc. Tested on x86-64 Linux 6.18 (WSL2), without SELinux.
