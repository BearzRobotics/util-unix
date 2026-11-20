# 0009: A POSIX shell, `sh`

Status: accepted by the maintainer. Date: 2026-11-19. Milestone 1 implemented (see docs/compatibility/sh.md); milestones 2 and 3 not started.

## Goal

A POSIX.1-2024 Shell Command Language implementation, `sh`, as a library
(`util_unix.sh`) plus a thin wrapper and the usual three build modes. Reference
behaviour: dash (installed on the dev machine, the differential oracle) and
FreeBSD sh, run from the Chimera Linux sysroot (FreeBSD userland ported to Linux, `tools/bsdrun.sh`, rootfs extracted from `/stuff/Docs/Programs/Chimera.zip`; the same sysroot gives BSD grep, sed and ls as oracles for util-core). POSIX
wins when the two differ and the choice is recorded. Scope includes interactive
use: line editing, history, job control. Written fresh; nothing is borrowed
from the dksh project.

## Layout (decision 0002 applies)

`src/lib/sh/`: `lexer`, `parser` (AST), `expand` (parameter, command, arithmetic,
tilde, field splitting, pathname/`fnmatch`, quote removal), `redirect`,
`exec` (simple/compound commands, pipelines, lists, functions, subshells),
`builtins` (special and regular), `env`/`vars`, `jobs`, `trap`, `readline`
(interactive). No terminal output, no `exit`, no process-wide state in the
parser or expander; only `exec`, `jobs`, `trap` and `readline` touch the OS and
only through `sys.zig` (decision 0003, `docs/std-io-gaps.md`).
`src/commands/sh.zig` parses `sh`'s own argv (`-c`, `-s`, `-i`, `-l`, `-e`,
`-u`, `-x`, `-n`, `-f`, `-v`, `-o`, `+o`), builds the `Env`, calls `run`.

API sketch: `Shell.init(env, Options)`; `shell.parse(source) !Program`;
`shell.run(program, io) !Status`; `shell.runString`; a way for a host (DKDE)
to register extra builtins and read/write variables.

## Milestones

Revised 2026-11-19 by the maintainer: milestone 1 is a complete, usable POSIX shell,
interactive included.

1. **A complete POSIX shell.** Done first: lexer, parser (the whole POSIX grammar),
   all expansions including `$(( ))`, redirections incl. here-docs, pipelines, `&&`/`||`,
   `if`/`while`/`until`/`for`/`case`, functions, subshells, `set` options, `trap`,
   special and regular builtins, exit statuses 126/127/2, `sh -c`, scripts, stdin, the
   structured diagnostics (SHxxxx) and lint mode, differential suites against dash,
   bash --posix, busybox ash, yash and FreeBSD sh. Then: interactive mode (`PS1`/`PS2`/
   `PS4`, `ENV`), vi and emacs line editing and history (`fc`), tab completion, job
   control (`&`, `jobs`, `fg`, `bg`, `wait`, `kill %n`, `set -m`), `printf` floating
   formats, symbolic `umask`, and the `trap` details.
2. **Hardening, speed and embedding** (proposed; to be confirmed): conformance with the
   third-party corpora (yash `-p.tst`, FreeBSD, Oils) driven to near 100%, long fuzz
   campaigns on the parser and expander, benchmarks against dash/FreeBSD sh/bash --posix
   with `crap`, a stable embedding API for DKDE and dksh (host builtins, variables,
   captured output, completion callbacks), and login-shell use (`-l`, `/etc/profile`,
   full `ulimit`, `times`).

## Strict POSIX, one mode (decision, 2026-11-19)

`sh` implements POSIX and nothing else. There are no modes: it is POSIX or it is not,
and there is no `--posix` switch, no extension flag, no `[[ ... ]]`, `=~`, arrays or
`local` beyond what POSIX.1-2024 specifies. A construct that POSIX does not define is an
error, and where it is recognisable (`[[`, `function`, `source`, `local`) the diagnostic
says it is not POSIX and what to use instead (decision 0008; `sh --check` flags the
same constructs).

**Gold standard rule.** When dash and FreeBSD sh agree on a behaviour, that behaviour is
our gold standard even if bash, yash or busybox ash differ, and we deviate only for a
good reason that is written down (in `docs/posix-shell-differences.md`, category
`implementation-defined` or `bug` in the other shell, with the POSIX citation). When
dash and FreeBSD disagree, POSIX decides; if POSIX is silent we match dash and record
the choice. bash --posix, busybox ash and yash are comparison points, never targets.

Survey on 2026-11-19 with `[[ abc =~ ^a.c$ ]]`: dash and FreeBSD sh say `[[: not found`
(our answer too); yash accepts it outside `--posix` and refuses it inside; busybox ash
and bash --posix accept it.

## Process model

Subshells and command substitution need `fork`; `Io.Threaded` is not fork-safe
(rows 8, 9 of `docs/std-io-gaps.md`). The shell builds its `Io` in single-threaded
mode and forks with the raw syscall in `sys.zig`; external commands use `exec`
after the fork so redirections can be applied with `dup2` in the child.
Builtins run in the shell process except in pipelines and subshells.

## Diagnostics

Decision 0008 applies: dash's terse messages ("Syntax error: ...", "not found")
may be made clearer on stderr, with status 2/126/127 unchanged and each
difference listed under DIFFERENCES FROM DASH in the man page.
