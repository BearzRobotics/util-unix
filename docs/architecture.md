# Architecture

Describes what is implemented now (not the target in `ai/SPECS.md`). Update it
with every structural change.

- Toolchain: Zig 0.17.1; standard-library APIs were checked against
  `~/.zvm/0.17.1/lib/std`.
- Commands implemented: `chmod`, `chown`, `chgrp`, `getent`, `id`, `groups`,
  `tty`, `uname` (why these belong here: decision 0005) and `stty`,
  `who`, `pinky`, `chcon`, `runcon`, `hostname` (decision 0006, which
  also lifts the SPEC rule against commands that util-linux or procps ship).
- Shape: a reusable library module, `util_unix`, plus thin command wrappers
  (decision 0002). DKDE and other Zig projects import the module; the
  executables are just one client of it.

## Layout

```
build.zig            exports module "util_unix"; per-command exes, multicall exe, tests
build.zig.zon        package: name util_unix, no dependencies
src/
  root.zig           the library's public surface (one `pub const` per module)
  lib/               library: takes std.Io, prints nothing, parses no argv
    mode.zig         chmod mode grammar (octal/symbolic) and `rwxr-xr-x` text
    chmod.zig        chmod engine: walk, set modes, report events
    ownership.zig    chown/chgrp engine: walk, --from, report events
    fsown.zig        statx (uid/gid/dev) and fchownat, which std.Io lacks
    userspec.zig     OWNER[:GROUP] parsing
    userdb.zig       /etc/passwd and /etc/group (files only, decision 0004)
    identity.zig     id and groups output formats, user lookup
    proc.zig         credentials, umask, uname(2) (decision 0003)
    uname.zig        uname field selection and output
    tty.zig          is-a-terminal and terminal name
    getent.zig       getent databases (files backend)
    hostname.zig     sethostname(2), /etc/hosts lookup, host-name file parsing
    utmp.zig         the Linux 384-byte utmp record
    localtime.zig    TZif zone (std.tz) to local calendar time
    who.zig          who columns, idle/message status of a terminal, time styles
    pinky.zig        pinky short and long formats
    stty.zig         termios model, setting tables, ioctl calls, -a/-g/default output
    selinux.zig      context text editing, security.selinux xattr, /proc/self/attr
    chcon.zig        chcon engine: walk, partial/full context, report events
  cli.zig            wrapper-side: Context, getopt-style matching, warn, errText,
                     quotef/quoteaf/quoteC (GNU C-locale quoting)
  sys.zig            wrapper-side: the only sigaction use (SIGPIPE)
  ownership_cli.zig  wrapper shared by chown and chgrp
  identity_cli.zig   wrapper helper shared by id and groups
  commands.zig       registry: `all` + `modules` + get/find
  commands/<name>.zig  option parsing, GNU validation order, diagnostics -> library
                     (stty, chcon and runcon embed their help text from <name>_help.txt)
  exe.zig            entry of an individual executable (command fixed by build option)
  multicall.zig      entry of `util-unix`: argv[0] link name, else `util-unix <cmd>`
  test_all.zig       unit-test root for the wrapper side
test/                differential shell tests against GNU (testlib.sh, test_<cmd>.sh,
                     run_all_tests.sh); OURS_MULTICALL=1 for multicall mode
test/stty_pty.py     stty cases on a pseudo-terminal, GNU against ours (called by test_stty.sh)
test/vm/             QEMU guest (busybox + our binaries, root): real terminal, privileged
                     chown/chgrp/chmod, a process with 1500 groups (run.sh, init.sh)
bench/               poop comparison against the GNU binaries (README.md, run.sh)
docs/                this file, decisions/, compatibility/, manpages/, benchmarks/
```

## Data flow

```
 argv ──► commands/chmod.zig ──► chmod.Options ──► chmod.run(io, gpa, operand, opts)
          (parse, validate,                          │   │
           GNU order)                                │   └─ Io.Dir.statFile / setFilePermissions,
                                                     │      relative to the directory being walked
          exit status ◄── format(Event) ◄── Reporter ┘
```

`chown`, `chgrp`, `id`, `groups`, `uname`, `tty` and `getent` have the same
shape: the wrapper parses and validates, the library returns values or events,
and the wrapper formats them as GNU does. Libraries that print (`identity`,
`uname`, `getent`) write to a caller-supplied `*Io.Writer`.

Two shapes differ from the files-and-flags commands above:

- `who` and `pinky` read a utmp-format file whole (`utmp.load`),
  decode records in place (`utmp.record`, slices into the buffer) and format
  with `localtime.Zone` for the zone in `TZ` or `/etc/localtime`. They never
  look at systemd-logind.
- `stty` has a *parse everything first, then touch the terminal* order: the
  wrapper turns the settings into `Op` values (any error stops here), then
  reads the termios, applies the operations to a copy, writes it with
  `TCSETSW`, re-reads it and compares.

## Memory and resources

- `chmod.run` and `ownership.run` hold the display path of the entry being
  visited and one open directory descriptor per level of recursion; nothing else
  grows with the tree.
- `userdb.Db` reads both account files into memory once (64 MiB cap each) and
  borrows from them for every lookup; the caller frees it.
- `id` and `groups` ask getgroups(2) for the count and allocate exactly that many
  entries (freed before exit).
- Writers are 4-8 KiB stack buffers flushed at the end or before a warning.

## Build

- `zig build` installs one executable per command plus `util-unix`.
- `-Dcommands=a,b` restricts the set; unknown names fail the build.
- Adding a command: `src/lib/<name>.zig` (+ line in `root.zig`),
  `src/commands/<name>.zig`, then the name in `all` and `modules` in `commands.zig`.
- Binaries are statically linked and do not use libc (`file zig-out/bin/id`).
  Stripped ReleaseFast sizes are 245-306 KB per command (4.4-7.7 times GNU's);
  see docs/benchmarks/2026-11-07.md.
