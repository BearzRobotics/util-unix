# sh: compatibility record

Status: milestones 1 (non-interactive core) and 2 (interactive use, line editing, history, job control) implemented; see the test counts at the end. Date: 2026-11-19. Design: decision 0009; diagnostics: decision 0008.

## Reference

- POSIX.1-2024 (IEEE Std 1003.1-2024) Shell Command Language, XCU chapter 2: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html, and the utility pages `sh`, `cd`, `command`, `echo`, `getopts`, `hash`, `kill`, `printf`, `pwd`, `read`, `test`, `type`, `ulimit`, `umask`, `unalias`, `wait`. Section numbers below (2.6 Word Expansions, 2.7 Redirection, 2.8 Shell Execution Environment, 2.9 Shell Commands, 2.14 Special Built-In Utilities) refer to that chapter.
- Oracles run by `test/test_sh.sh` on every case: dash 0.5.12 (stdout, exit status and stderr), bash 5.3 `--posix` (also invoked through a link named `sh`), busybox ash, yash 2.61 (`--posix` and plain) and, for the cases marked `B`, the FreeBSD sh from the Chimera Linux sysroot (`tools/bsdrun.sh`; chimerautils 14.x). The behaviour was verified by running them, not by reading their sources.
- The rule: when the references agree, `sh` must agree; when they differ, `sh` must match dash or FreeBSD sh, or POSIX where the case is marked `P` (it then must match `bash --posix` or `yash --posix`), and the case is recorded in docs/posix-shell-differences.md.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| Grammar, quoting, all expansions, redirections incl. here-documents, `set -efnuvxCa`, special and regular builtins listed in the manual | POSIX |
| `set -o pipefail` | POSIX.1-2024 (Issue 8); not in dash 0.5.12 |
| `local`, `echo` XSI escapes, `[` string `<` `>` | common extension (dash, bash, busybox, yash accept `local`) |
| `--diagnostics`, `--explain`, `--check`, SHxxxx codes | this project (decision 0008) |
| `.` passing arguments as positional parameters | POSIX.1-2024 allows it; dash does not |

## Supported

Lexer and parser for the complete POSIX grammar (incremental, one complete command at a time, so commands before a syntax error run); every expansion; redirections with any descriptor number including `<>` and `>|`; pipelines, `!`, `&&`, `||`, `;`, `&`; `if`, `while`, `until`, `for`, `case`, groups, subshells, functions; `set -e -u -x -f -n -v -C -a` and `set -o` names; positional parameters and `$@ $* $# $? $$ $! $- $0`; special builtins `: . break continue eval exec exit export readonly return set shift times trap unset`; regular builtins `alias cd command echo false getopts hash kill local printf pwd read test [ true type ulimit umask unalias wait`; traps for `EXIT` and signals (run between commands and after a foreground command ends); exit statuses 126, 127 and 2 as dash; the consequences of shell errors of 2.8.1.

## Extensions

| Extension | Kind |
|---|---|
| `--diagnostics=rich\|json\|gcc`, `--explain`, `--check`, `--diagnostics-catalog` | diagnostic (decision 0008): never changes stdout, status or POSIX behaviour; default is dash's wording unless stderr is a terminal |
| `set -e` exit note (SH4005), unterminated here-document warning (SH1003) | diagnostic, rich and json styles only |
| `set -o pipefail` | POSIX 2024 option, absent from dash |
| `local` | accepted for scripts written for dash/bash; `--check` flags it (SH7007) |

## Interactive use (milestone 2)

| Feature | State |
|---|---|
| `-i`, automatic interactive mode (stdin and stderr terminals), `$-`, PS1 (parameter expansion, command substitution, arithmetic, `!` and `!!`), PS2, PS4, ENV (expanded, absolute paths), `-l` login profiles | implemented |
| Signals: SIGINT caught, SIGQUIT and SIGTERM ignored, SIGTSTP/SIGTTIN/SIGTTOU ignored with job control, defaults restored in children | implemented |
| `exit` and end of input with stopped jobs warn once (dash and FreeBSD sh behaviour); `ignoreeof`; errors do not end the shell | implemented |
| Line editing: emacs mode (default) and the POSIX vi mode (all commands of sh(1p) except that `@letter` needs an alias named by a single letter); bracketed paste, UTF-8 width, SIGWINCH redraw, multi-line and wrapped buffers, incremental search | implemented (library `readline.zig`, testable without a terminal) |
| Tab completion: files, commands (builtins, functions, aliases, PATH), variables after `$`, vi `=` `\\` `*` | implemented behind a callback (`completion.zig`) |
| History: HISTSIZE, HISTFILE (read at start, written at exit), `fc` with `-e -l -n -r -s`, ranges, `old=new`; format of FreeBSD sh | implemented |
| Job control: process groups, terminal hand-off, `&`, `jobs -l -p`, `fg`, `bg`, `wait` for jobs, `kill %spec`, job specs (`%%` `%+` `%-` `%n` `%string` `%?string`), stop/continue states, finished-job notification before the prompt, `set -m` | implemented |
| `history` utility, `!` history expansion | not provided (not POSIX; decision 0009 one mode only) |
| TMOUT, MAIL checking, `bind`/inputrc style key customisation, vi `@` with multi-letter aliases | not implemented |
| Not testable without a human at a terminal: window-manager-driven resizing, terminals other than xterm-compatible ones, real login scripts | verified on a pseudo-terminal only |

## Known deviations and gaps

1. **Interactive use** (milestone 2) is implemented; its own limits are listed under INTERACTIVE below.
2. **Standard input scripts are read whole before running** (`sh < script`, `sh -s`). Commands in the script that read standard input see end of file instead of the rest of the script, which dash lets them consume.
3. **Not implemented:** floating-point `printf` conversions (`%e %f %g`), `%b` width for multibyte, `umask` symbolic assignment (`umask u=rwx`; reading with `-S` works), `ulimit -a` and the less common limits, `trap -l`, `alias` ending in a blank expanding the next word, `$RANDOM` and the other non-POSIX variables, `read -p -t -n`.
4. **Here-document ended by end of input** keeps the final newline of the body; dash drops it (recorded in docs/posix-shell-differences.md, case `P`).
5. **Locale:** only the C locale; strings are bytes.
6. **Signals:** a trapped signal is handled between commands. A signal that arrives while a builtin blocks in `read` interrupts it and runs the trap; while a `wait` is blocked it is run after `wait` returns.
7. **Memory:** the syntax trees of programs that define functions are kept for the life of the shell; a long-running host that evals many function definitions grows.
8. **Platform:** Linux only (raw `fork`, `execve`, `wait4`; docs/std-io-gaps.md rows 8-24). Other systems return errors from `sys.zig`.
9. **Arithmetic:** no comma, `**`, `++`, `--` (dash does not have them either); `x=010` is octal.
10. **`trap` with no operands in a subshell** prints nothing; POSIX.1-2024 says it reports the parent's traps (bash and yash do). Recorded in docs/posix-shell-differences.md.
11. **Test oracle notes:** busybox ash and yash differ from dash in many diagnostics and builtins; only stdout and status of those are compared.

## Parser oracle (shellcheck)

`test/test_sh_lint.sh` checks that the snippets and the repository's scripts are accepted or rejected by `sh -n` exactly as by `dash -n` (all agree), and compares with `shellcheck -s dash` as a second oracle. Fifteen disagreements with shellcheck are recorded (all are shellcheck being stricter or more lenient than dash and our parser, none a disagreement between dash and us): shellcheck reports a syntax error for `$((1+))`, `$((1 2))`, `f() if ...; fi`, `${10}` written as `$10`, `[ a = a;`, `[ -f ]`, `[ "(" = "(" ]`, an unterminated here-document and `for i in then do done`, all of which dash parses (errors there are raised at run time); and it accepts `eval() {...}`, `1f() {...}`, `a=(1 2)`, `function f {...}`, `cat <(...)` and `<<<` which dash rejects (shellcheck treats them as bash dialect constructs). Also `${x!}`, `${x/a/b}` and `${x:1:2}` parse everywhere and fail at expansion time, as dash.

## DIFFERENCES FROM DASH

Per decision 0008. stdout and exit status stay dash's.

| Case | dash | sh | Kind |
|---|---|---|---|
| Any diagnostic on a terminal | `sh: 1: msg` | the rich multi-line message; `--diagnostics=posix` is dash's text | diagnostic |
| `set -e` ends the shell | silent | rich style names the command and line | diagnostic |
| Unterminated quote/`$(`/`$((` | "Unterminated quoted string" etc. | rich style says where it was opened | diagnostic |
| `. file arg` | args ignored | args become `$1...` | POSIX-defined (2024) |
| `exec 10>f` | rejected | accepted | POSIX-defined (2.7) |
| `eval() { :; }` | "Bad function name" | same | matches dash (POSIX leaves it undefined) |

## Tests

Counts at the end of milestone 1 (unchanged by milestone 2 except where noted): `test_sh.sh` 710/710 (115 cases where the shells disagree are recorded; FreeBSD sh cross-check 606 same, 23 different, of 629), `test_sh_diag.sh` 343/343, `test_sh_lint.sh` 1530/1530 (15 shellcheck disagreements noted), `zig build test` 95 passed 2 skipped. Each script prints its own: `sh test/test_sh.sh` (differential, about 700 cases), `sh test/test_sh_diag.sh` (exact messages), `sh test/test_sh_lint.sh` (shellcheck hygiene and parser oracle), `zig build test` (unit tests of lexer, parser, arithmetic, pattern matching, diagnostics, lint, plus a fuzz target and a deterministic mutation run of the parser).
