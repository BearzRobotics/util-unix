# sh: compatibility record

Status: milestone 1 (non-interactive core) implemented and its recorded gaps closed; see the test counts at the end. Date: 2026-11-19. Design: decision 0009; diagnostics: decision 0008.

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

## Known deviations and gaps

1. **Interactive use is not implemented** (milestone 2): no prompts, line editing, history, `fc`, tab completion, job control (`jobs`, `fg`, `bg`, `kill %n`, `wait %n`, `set -m` has no effect). `-i` is accepted.
2. **Not implemented:** `ulimit -a` and the less common limits, `$RANDOM` and the other non-POSIX variables, `read -p -t -n`, `printf %q`, `printf -v`, `%(...)T`.
3. **Locale:** only the C locale; strings are bytes.
4. **Signals:** a trapped signal runs after the command during which it arrived (and between commands). A signal that arrives while a builtin blocks in `read` interrupts it and runs the trap; while a `wait` is blocked it is run after `wait` returns.
5. **Memory:** the syntax trees of programs that define functions are kept for the life of the shell; a long-running host that evals many function definitions grows.
6. **Platform:** Linux only (raw `fork`, `execve`, `wait4`; docs/std-io-gaps.md rows 8-24). Other systems return errors from `sys.zig`.
7. **Arithmetic:** no comma, `**`, `++`, `--` (dash does not have them either); `x=010` is octal; a constant out of the 64-bit range saturates (dash; FreeBSD sh reports an error, POSIX leaves it undefined).
8. **printf:** `%#g` of a value that rounds up into the exponent range (`printf '%#g' 999999.5`) prints `1.00000e+06`; glibc prints `1.e+06` (a glibc quirk). Everything else of `%e %f %g %a` was compared with dash on 1500 random values times 11 formats and on 1300 fixed cases without a difference. `%b` width for multibyte is not handled.
9. **Alias corner cases** still open (listed in docs/compatibility/sh-corpora-failures.md): an alias whose value is empty or only blanks used as a whole command, an alias that expands to `(` or `)` pieces of a function definition, and alias text containing a here-document operator.
10. **Test oracle notes:** busybox ash and yash differ from dash in many diagnostics and builtins; only stdout and status of those are compared.

Closed since the first record: floating `printf` conversions, `umask` symbolic modes, `trap -l`, `trap` in a subshell (reports the parent's traps, POSIX.1-2024; dash and FreeBSD sh print nothing, bash and yash agree with POSIX), an alias ending in a blank, a here-document ended by end of input (the body keeps exactly the text, dash and FreeBSD sh), scripts on standard input run command by command, the duplicated script name in the rich header, the caret of runtime errors (now the offending span), diagnostic kinds chosen at each construction site (no message-text classifier any more), SH4003 and SH5012 tests.

## Third-party corpora

`tools/fetch-sh-corpora.sh` downloads three corpora at pinned commits into `~/.cache/util-unix/sh-corpora` (nothing is committed; the hashes are in the script and in `PINS`), `test/test_sh_corpora.sh` runs `sh` against them and skips a corpus that is not downloaded:

| Corpus | Pinned commit | Adapter |
|---|---|---|
| yash `tests/*-p.tst` (122 POSIX files) | f1f1e1cbe64f76ceaf172f2689d72247f5111b12 | `test/sh_corpora/yash-runner.sh`: our runner for the documented `.tst` format (stdin script, expected stdout and stderr, `-e` status, `-d`, `-f`, `setup`, `posix`, `skip`); the `sig*-p` files (they need yash's compiled `resetsig`) and the `%REQUIRETTY%` files are not run |
| FreeBSD `bin/sh/tests` | 90bc40e26c610b68595427e736bca5215ebe5c57 | each file `NAME.N` must exit N and print `NAME.N.stdout` when it exists (stderr wording is not compared) |
| Oils `spec/*.test.sh` | d114978ca467143f171a835cbcbe8ab6ccc009a7 (Apache-2.0, fetched, never committed) | `test/sh_corpora/run_oils.py`: parses `####` cases and the `## STDOUT/status`, `## OK|BUG|N-I dash/bash` annotations; the expectation is the dash column; the python2 helpers (`argv.py`) run as python3 copies |

Containment: the cases send signals (`kill 0`, `kill -1`, process groups), so every case or runner file runs in its own session and PID namespace (`setsid -w bwrap --unshare-pid --unshare-ipc --die-with-parent`), the whole run in a systemd scope capped at 4 GiB of memory without swap and 30 minutes, with a per-case timeout. Without bwrap the corpora are skipped.

Triage follows the gold standard rule of decision 0009: a failing case is run under dash as well. If dash meets the expectation and we do not it is **our bug**; if we fail exactly as dash does the corpus encodes another shell (**follows dash**); if neither meets it, it is **shell-specific** or non-POSIX. Cases that need the interactive shell or job control are the milestone 2 gap, and the places where we implement POSIX.1-2024 against dash (`$'...'`, `trap -l`, trap listing in a subshell, symbolic `umask`) are **deliberate**.

Results of the last run (`sh test/test_sh_corpora.sh`; the complete list of every non-passing case with its category is generated into docs/compatibility/sh-corpora-failures.md by `tools/sh-corpora-doc.py`):

| Corpus | Run | Passed | Failed | our bug | interactive/jobs | deliberate | shell-specific or follows dash |
|---|---|---|---|---|---|---|---|
| yash `-p` | 1944 cases | 1719 | 219 | 20 | 1 | 0 | 198 |
| FreeBSD | 518 cases | 402 | 116 | 27 | 1 | 0 | 88 |
| Oils | 3954 cases | 1500 | 2454 | 62 | 4 | 34 | 2354 (2274 equal dash, 80 neither) |

The first run (before the fixes below) had 106 (yash), 72 (FreeBSD) and 166 (Oils) cases in the our-bug class. `test/sh_corpora/known-bugs.txt` records the open ones; the suite fails on a bug that is not in it.

Bugs the corpora found and that are fixed: alias substitution only happened for the first word of a simple command (now at every command and reserved-word position, after assignments and redirections, in `case` patterns, after a trailing blank; recursive aliases are stopped by the text they came from); backslash-newline was only a continuation at the start of a token (now everywhere but in single quotes and comments, with line numbers kept); `${a#*1}` inside double quotes treated the pattern as literal; `"${unset-}"`, `"${unset+x}"`, `"$unset"` and quoted empty strings next to split words lost their empty field; a field split with a leading blank before a delimiter lost its empty field; `read` kept a trailing delimiter in the last variable; `export A=$a` and `readonly A=$a` split and globbed the operand (also behind `command`); an assignment error before an external command did not exit; `cd -L -P` option groups, `cd -` printing, `cd ''` and `..` through a non-directory; `exit` in a trap used the wrong status; `command -pv`; `command exec` keeping redirections; `getopts` on a read-only `OPTIND`; `. --`; `sh -c - cmd` and `sh -`; `$0` of a script on standard input; PS4 was not expanded; a `$(...)` between a here-document operator and its body consumed the outer body; backquotes with several lines and with line continuations; `${}` crashed the shell (index out of bounds); a signal trap was only run after the whole command line; `! break` and `! return` negated the status; `local` restored a read-only variable and reset itself when repeated; a command substitution kept NUL bytes; a file with NUL in its first line was run as a script instead of status 126; `break` in a loop condition; `unset %` and `trap -1 EXIT` were accepted; `set -` and `set +`; `OPTIND` was not reset by `set --`; `%b` octal escapes without the leading zero; `printf` of a number with leading blanks and trailing characters; arithmetic constants out of range.

Differences from dash that stay, with the reason: `trap` with no operands in a subshell and `trap -l` (POSIX.1-2024 XCU trap; dash rejects `-l`, dash and FreeBSD sh print nothing in a subshell, bash and yash follow POSIX); `$'...'` (POSIX.1-2024 2.2.4); an assignment error before an external command exits the shell (POSIX 2.8.1 table; dash exits, FreeBSD sh does not); `OPTARG` unset after an option without argument (POSIX and FreeBSD sh; dash sets it empty); `umask` with extra operands is an error (FreeBSD sh too; dash ignores them).

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

Counts after the gap closure and the corpora: `test_sh.sh` 750/750 (129 cases where the shells disagree are recorded; FreeBSD sh cross-check 619 same, 25 different, of 644; it was 710/710), `test_sh_diag.sh` 582/582 (was 343; adds the exact-status-and-stdout matrix over the four styles with and without a terminal, the colour tests on a pty, the inherited SH_DIAGNOSTICS tests, the JSON catalog driven coverage check, SH4003 and SH5012), `test_sh_lint.sh` 1587/1587 (was 1530; 18 shellcheck disagreements noted), `test_sh_corpora.sh` (third-party corpora, above), `zig build test`. Each script prints its own: `sh test/test_sh.sh` (differential, about 750 cases, plus the standard-input cases against dash), `sh test/test_sh_diag.sh` (exact messages), `sh test/test_sh_lint.sh` (shellcheck hygiene and parser oracle), `sh test/test_sh_corpora.sh` (third-party corpora), `zig build test` (unit tests of lexer, parser, arithmetic, pattern matching, diagnostics, float formatting, lint, plus a fuzz target and a deterministic mutation run of the parser). Run test binaries under a memory cap: `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 CMD`.
