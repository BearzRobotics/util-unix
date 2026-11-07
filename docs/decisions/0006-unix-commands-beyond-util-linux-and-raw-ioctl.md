# 0006: Commands that util-linux or procps also ship; raw ioctl, xattr and utmp access

Status: accepted by the maintainer. Date: 2026-11-07
(request: "Lets override the spec for those. As i'm not building a util-linux",
about `kill`, `stty`, `who`, `pinky`, `chcon`, `runcon`, `hostname` and `uptime`;
`kill` and `uptime` were withdrawn the same day, see below)

## Context

SPEC §1 and §4.1 say util-unix must not duplicate commands maintained by
upstream util-linux. Of the six commands kept:

| Command | Upstream that ships it | Reference used here |
|---|---|---|
| `stty`, `who`, `pinky`, `chcon`, `runcon` | GNU coreutils 9.7 | GNU coreutils 9.7 |
| `hostname` | net-tools / the Debian `hostname` package | `hostname` 3.25 |

None of them is in the Core Utils project: `~/de/util-core/src/commands/` was
listed on 2026-11-07 and has none of the six names (it has `users`, `whoami`,
`logname`, `chroot`, `nice`, `hostid`, `nohup` and `arch`, which are not
affected). The upstream util-linux inventory was not consulted for this
decision beyond SPEC §13.1; the maintainer's reason is that util-unix is not
being built as a util-linux companion.

## Decision

1. The no-duplication rule of SPEC §1/§4.1 is lifted for these six commands.
   util-unix owns them. The SPEC text is amended accordingly (§1, §4.1, §13).
   `kill` (still excluded by §13.1) and `uptime`, which the maintainer first
   included, were removed again on 2026-11-07 once it was clear they come from
   procps-ng; their code, tests and docs were deleted.
2. The rule is not abolished for other names: a new command that an upstream
   package ships still needs its own ownership decision, and SPEC §5's "one
   owner among the projects here" stays.
3. Each command is a library module plus a thin wrapper (decision 0002) and is
   tested differentially against the installed reference binary named above.
4. These commands need operating-system interfaces that `std.Io` (Zig 0.17.1)
   does not offer. They are listed here as exceptions in the sense of decision
   0003. All are Linux-only and confined to the library files shown.

| Used | Where | Why `std.Io` cannot |
|---|---|---|
| `ioctl` TCGETS/TCSETSW/TIOCGWINSZ/TIOCSWINSZ | `lib/stty.zig` | no termios or window-size API |
| `getxattr`/`setxattr` (and `l` forms) for `security.selinux`; `write(2)` to `/proc/self/attr/exec` | `lib/selinux.zig` | no extended attributes; the kernel's error number (EINVAL) is needed and `writeStreamingAll` hides it |
| `sethostname(2)`, `uname(2)` domain name | `lib/hostname.zig`, `lib/proc.zig` | no host-name API |

Reading `/var/run/utmp`, `/proc/mounts`,
`/etc/hosts`, `/etc/localtime` and `/usr/share/zoneinfo/*` goes through
`std.Io`. Time zones are read with `std.tz`.

## Consequences

- Reading utmp directly is a deliberate difference from the GNU coreutils and
  procps builds on systemd machines: those read systemd-logind sessions, not
  the utmp file. `who` and `pinky` here show what is in
  `/var/run/utmp` (and nothing from logind). Per command, in
  `docs/compatibility/`.
- Host names are completed from `/etc/hosts` only (no DNS, no NSS), the same
  boundary as decision 0004.
- `stty` supports the architectures that share the generic termios layout
  (x86, arm, arm64, riscv, s390x, loongarch); other Linux architectures report
  "Operation not supported".
- `runcon`'s transition under a real SELinux policy has not been run: the
  development host has none. Its argument handling and the "may be used only on
  a SELinux kernel" refusal are compared with GNU; the rest follows
  proc_pid_attr(5) and is marked unverified in its compatibility record.
