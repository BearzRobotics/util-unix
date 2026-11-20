# 0009: A POSIX shell, `sh`

Status: accepted by the maintainer. Date: 2026-11-19. Not started when this was written.

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

1. **Non-interactive core:** lexer, parser (all of the POSIX grammar), all
   expansions including `$(( ))`, redirections incl. here-docs, pipelines,
   `&&`/`||`, `if`/`while`/`until`/`for`/`case`, functions, subshells, `set -e/-u/-x/-f/-n`,
   special builtins and the regular builtins POSIX requires, `trap`, `exit`
   statuses 126/127, `sh -c`, scripts, stdin. Differential suite against dash.
2. **Interactive:** prompts (`PS1`/`PS2`/`PS4`, `ENV`), line editing and history
   (`fc`, `history`), tab completion of files and commands, job control (`&`,
   `jobs`, `fg`, `bg`, `wait`, `kill %n`, `SIGTSTP`/`SIGCONT`, `set -m`).
3. **Polish:** `getopts`, `ulimit`, `umask`, `times`, `command -v/-V`, `type`,
   `hash`, locale-free C behaviour documented; man page; compatibility record.

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
