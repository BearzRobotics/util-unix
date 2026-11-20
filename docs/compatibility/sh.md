# sh: compatibility record

Status: milestone 1 (non-interactive core) implemented and its recorded gaps closed; milestone 2 (interactive use, line editing, history, job control) implemented; see the test counts at the end. Date: 2026-11-19. Design: decision 0009; diagnostics: decision 0008.

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

1. **Interactive use** (milestone 2) is implemented; its own limits are listed under "Interactive use (milestone 2)" above.
2. **Not implemented:** the less common `ulimit` limits, `$RANDOM` and the other non-POSIX variables, `read -t -n`, `printf %q`, `printf -v`, `%(...)T`.
3. **Locale:** only the C locale; strings are bytes.
4. **Signals:** a trapped signal runs after the command during which it arrived (and between commands). A signal that arrives while a builtin blocks in `read` interrupts it and runs the trap; while a `wait` is blocked it is run after `wait` returns.
5. **Memory:** the syntax trees of programs that define functions are kept for the life of the shell; a long-running host that evals many function definitions grows.
6. **Platform:** Linux only (raw `fork`, `execve`, `wait4`; docs/std-io-gaps.md rows 8-24). Other systems return errors from `sys.zig`.
7. **Arithmetic:** no comma, `**`, `++`, `--` (dash does not have them either); `x=010` is octal; a literal out of the 64-bit range saturates (dash; FreeBSD sh wraps, POSIX leaves it undefined), a variable whose value is out of range is an error (dash and FreeBSD sh agree).
8. **printf:** `%#g` of a value that rounds up into the exponent range (`printf '%#g' 999999.5`) prints `1.00000e+06`; glibc prints `1.e+06` (a glibc quirk). Everything else of `%e %f %g %a` was compared with dash on 1500 random values times 11 formats and on 1300 fixed cases without a difference. `%b` width for multibyte is not handled.
9. **Alias corner cases** still open (listed in docs/compatibility/sh-corpora-failures.md): an alias whose value is empty or only blanks used as a whole command, an alias that expands to `(` or `)` pieces of a function definition, and alias text containing a here-document operator.
10. **Test oracle notes:** busybox ash and yash differ from dash in many diagnostics and builtins; only stdout and status of those are compared.

Closed since the first record: floating `printf` conversions, `umask` symbolic modes, `trap -l`, `trap` in a subshell (reports the parent's traps, POSIX.1-2024; dash and FreeBSD sh print nothing, bash and yash agree with POSIX), an alias ending in a blank, a here-document ended by end of input (the body keeps exactly the text, dash and FreeBSD sh), scripts on standard input run command by command, the duplicated script name in the rich header, the caret of runtime errors (now the offending span), diagnostic kinds chosen at each construction site (no message-text classifier any more), SH4003 and SH5012 tests.

## Third-party corpora

`tools/fetch-sh-corpora.sh` downloads three corpora at pinned commits into `~/.cache/util-unix/sh-corpora` (nothing is committed; the hashes are in the script and in `PINS`), `test/test_sh_corpora.sh` runs `sh` against them and skips a corpus that is not downloaded:

| Corpus | Pinned commit | Adapter |
|---|---|---|
| yash `tests/*-p.tst` (122 POSIX files) | f1f1e1cbe64f76ceaf172f2689d72247f5111b12 | `test/sh_corpora/yash-runner.sh`: our runner for the documented `.tst` format (stdin script, expected stdout and stderr, `-e` status, `-d`, `-f`, `setup`, `posix`, `skip`). The `sig*-p` files start their runner through `test/sh_corpora/resetsig.c`, our own equivalent of yash's compiled `resetsig` (every signal at its default, empty mask, an `alarm` instead of `timeout(1)` so an ignored signal is really inherited as ignored), built with `cc`, `gcc` or `zig cc` when one exists; without a compiler the 24 files of that kind that do not need a terminal are skipped. The `%REQUIRETTY%` files (the 38 job-control (`-m`) variants and the stop-signal files) need a controlling terminal (`ptwrap`, `checkfg`, both compiled helpers) and are not run |
| FreeBSD `bin/sh/tests` | 90bc40e26c610b68595427e736bca5215ebe5c57 | each file `NAME.N` must exit N and print `NAME.N.stdout` when it exists (stderr wording is not compared) |
| Oils `spec/*.test.sh` | d114978ca467143f171a835cbcbe8ab6ccc009a7 (Apache-2.0, fetched, never committed) | `test/sh_corpora/run_oils.py`: parses `####` cases and the `## STDOUT/status`, `## OK|BUG|N-I dash/bash` annotations; the expectation is the dash column; the python2 helpers (`argv.py`) run as python3 copies |

Containment: the cases send signals (`kill 0`, `kill -1`, process groups), so every case or runner file runs in its own session and PID namespace (`setsid -w bwrap --unshare-pid --unshare-ipc --die-with-parent`), the whole run in a systemd scope capped at 4 GiB of memory without swap and 30 minutes, with a per-case timeout. Without bwrap the corpora are skipped.

Triage follows the gold standard rule of decision 0009: a failing case is run under dash as well. If dash meets the expectation and we do not it is **our bug**; if we fail exactly as dash does the corpus encodes another shell (**follows dash**); if neither meets it, it is **shell-specific** or non-POSIX. Cases that need the interactive shell or job control are the milestone 2 gap, and the places where we implement POSIX.1-2024 against dash (`$'...'`, `trap -l`, trap listing in a subshell, symbolic `umask`) are **deliberate**.

Results of the last run (`sh test/test_sh_corpora.sh`; the complete list of every non-passing case with its category is generated into docs/compatibility/sh-corpora-failures.md by `tools/sh-corpora-doc.py`):

| Corpus | Run | Passed | Failed | our bug | interactive/jobs | deliberate | shell-specific or follows dash |
|---|---|---|---|---|---|---|---|
| yash `-p` (with the `sig*-p` files) | 6264 cases | 5751 | 507 | 0 | 0 | 0 | 507 |
| FreeBSD | 518 cases | 437 | 81 | 0 | 0 | 0 | 81 |
| Oils | 3954 cases | 1548 | 2406 | 13 | 1 | 23 | 2369 (2284 equal dash, 85 neither or recorded in `test/sh_corpora/reclassified.txt`) |

The 24 `sig*-p` files add 4320 cases; about 380 of them fail here and fail in dash too (initially ignored signals in an interactive shell, the `SIGCONT`/`SIGURG` variants and the like); no `sig*-p` case passes in dash and fails here. `test/sh_corpora/reclassified.txt` lists the cases that dash meets and we do not on purpose, each with its reason (POSIX.1-2024, FreeBSD sh and bash against dash); they are not bugs and are listed as shell-specific in sh-corpora-failures.md.

The first run (before the fixes below) had 106 (yash), 72 (FreeBSD) and 166 (Oils) cases in the our-bug class; before the second round 20, 18 and 97, now 0, 0 and 37 (the 37 are expansion, here-document, `read`, `getopts`, `test`, `$'...'`, `umask` and `printf -v` cases: the gold-standard audit and POSIX decisions of the other work stream). `test/sh_corpora/known-bugs.txt` records the open ones; the suite fails on a bug that is not in it.

Bugs the corpora found and that are fixed: alias substitution only happened for the first word of a simple command (now at every command and reserved-word position, after assignments and redirections, in `case` patterns, after a trailing blank; recursive aliases are stopped by the text they came from); backslash-newline was only a continuation at the start of a token (now everywhere but in single quotes and comments, with line numbers kept); `${a#*1}` inside double quotes treated the pattern as literal; `"${unset-}"`, `"${unset+x}"`, `"$unset"` and quoted empty strings next to split words lost their empty field; a field split with a leading blank before a delimiter lost its empty field; `read` kept a trailing delimiter in the last variable; `export A=$a` and `readonly A=$a` split and globbed the operand (also behind `command`); an assignment error before an external command did not exit; `cd -L -P` option groups, `cd -` printing, `cd ''` and `..` through a non-directory; `exit` in a trap used the wrong status; `command -pv`; `command exec` keeping redirections; `getopts` on a read-only `OPTIND`; `. --`; `sh -c - cmd` and `sh -`; `$0` of a script on standard input; PS4 was not expanded; a `$(...)` between a here-document operator and its body consumed the outer body; backquotes with several lines and with line continuations; `${}` crashed the shell (index out of bounds); a signal trap was only run after the whole command line; `! break` and `! return` negated the status; `local` restored a read-only variable and reset itself when repeated; a command substitution kept NUL bytes; a file with NUL in its first line was run as a script instead of status 126; `break` in a loop condition; `unset %` and `trap -1 EXIT` were accepted; `set -` and `set +`; `OPTIND` was not reset by `set --`; `%b` octal escapes without the leading zero; `printf` of a number with leading blanks and trailing characters; arithmetic constants out of range.

Fixed in the second round (alias, redirection, signal, builtin and invocation cases): alias substitution after a pipe, `&&` or `||` that exposes a newline, to nothing or to blanks; an empty alias line; an alias value that starts with a redirection operator after a redirection, with newlines before `(`, `)` or `esac`, with `;;`, with `|` or `)` of a case pattern (patterns are alias-expanded only after a blank-ended value, keywords win over aliases at keyword positions), for the `for` variable and word list, the operand of `<<`, the parentheses and body of a function definition, after a compound command, and in command substitutions inside here-documents; `command -v` quoting an alias value; `wait --`; the status of `wait` for a pipeline job under `pipefail`; `(cmd) &` running `cmd` without a second process; `command eval 'bad'` ending the shell; a signal trap that saw the previous command's status; a bare `exit` in a trap; redirections performed before the assignments of the same command are expanded; a redirection that opens the very descriptor it names leaked it; a blocked `open` of a FIFO and a blocked `read` were not interrupted by a trapped signal; `trap term TERM` (an action named like a signal); NUL bytes in scripts; `\177ELF` files run as scripts; `/a//b*` collapsing the slash run; `printf` `%u`/`%d` overflow and negative `%u` like strtoumax/strtoimax; descriptors above 9 (`99>f` is a word, `>&99` is a syntax error that ends the shell), `3>&3` on a closed descriptor, `1>&word`; `sh +c`; `jobs -p` one leader per job; the `hash` cache (filled by running commands, listed by `hash`, emptied by a new `PATH`, `cd` for relative entries and a vanished file); `pwd` after the directory was removed; `cd -` without `OLDPWD`, `OLDPWD` exported; builtins that cannot write their output fail with status 1; `ulimit -a` and an overflowing `ulimit` value; and the signal rules: a signal ignored on entry (SIGPIPE was reset by the runtime start-up code) stays ignored and cannot be trapped or reset, also in an interactive shell, `trap - SIG` in an interactive shell restores the shell's own handling of INT, QUIT and TERM, `exec` and children of an interactive shell hand over defaults except for a user's `trap ''`.

Differences from dash that stay, with the reason: `trap` with no operands in a subshell and `trap -l` (POSIX.1-2024 XCU trap; dash rejects `-l`, dash and FreeBSD sh print nothing in a subshell, bash and yash follow POSIX); `$'...'` (POSIX.1-2024 2.2.4); an assignment error before an external command exits the shell (POSIX 2.8.1 table; dash exits, FreeBSD sh does not); `OPTARG` unset after an option without argument (POSIX and FreeBSD sh; dash sets it empty); `umask` with extra operands is an error (FreeBSD sh too; dash ignores them).

## Gold-standard audit (tools/sh-gold.sh)

`tools/sh-gold.sh` runs every snippet of `test/test_sh.sh` (818), of the yash (`*-p.tst`, 1213), FreeBSD (511) and Oils (3722) corpora and of the lists in `test/sh_gold/*.txt` (609: error exits 2.8.1, expansion, quoting, field splitting, arithmetic, here-documents, control flow, functions; `read`, `getopts`, `test`, `set`, `trap`, `eval`, `command` and the other builtins) through dash, FreeBSD sh (`tools/bsdrun.sh`), `bash --posix`, bash as `sh`, busybox ash, `yash --posix` and our `sh`, each in its own session and PID namespace with a fresh working directory and a 5 s timeout, under a systemd scope cap. A snippet is GOLD_AGREE when dash and FreeBSD sh print the same stdout and status (that is the standard), POSIX_DECIDES when they differ; a case where dash gives different results on two runs is dropped. Result of the last run (6873 snippets; the corpus extraction drops interactive cases and the cases that need the corpus' own files):

| Source | Snippets | dash == FreeBSD | ours matches | ours differs | dash != FreeBSD | ours matches one | ours matches neither |
|---|---|---|---|---|---|---|---|
| test/test_sh.sh | 818 | 770 | 767 | 3 | 48 | 48 | 0 |
| yash `*-p.tst` | 1213 | 1127 | 1120 | 7 | 86 | 81 | 5 |
| FreeBSD tests | 511 | 384 | 382 | 2 | 126 | 116 | 10 |
| Oils spec | 3722 | 3297 | 3279 | 18 | 422 | 387 | 35 |
| test/sh_gold lists | 609 | 554 | 551 | 3 | 55 | 52 | 3 |
| all | 6873 | 6132 | 6099 | 33 | 737 | 684 | 53 |

Before the audit (the same snippets, the structured-output sh at 98284c0): 5935 of 6088 matched where the two oracles agree and 660 of 735 where they differ, 6595 of 6823 in all (96.7%); after: 6783 of 6869 (98.7%), 99.5% where dash and FreeBSD sh agree. The 33 remaining differences from the gold standard are the documented deviations (docs/posix-shell-differences.md, DEVIATIONS FROM THE GOLD STANDARD: `trap` in a subshell, `.` with arguments, `.*` not matching `.` and `..`, `kill -n`, nested function definitions, `return` above 255), `printf -v`, `cd` with an empty operand or a read-only PWD, `ulimit -S -H`, `--help`, `chdir`, and corpus cases that need bash `[[`. Where POSIX decides and ours matches neither shell the reasons are in the same document (`LINENO`, locale, NUL bytes in `printf`, `$'...'` escapes, an empty `HOME` after `~`, `-9223372036854775808 / -1`).

Behaviours changed by the audit (all follow dash and FreeBSD sh, which agree): `${##}`, `${#-}`, `${#?}`, `${#@}`; `local x` keeps the value, `local v=$w` does not split, `local -` restores the options; `command readonly x=$y` (also `\command`) does not split; `unset` drops the export attribute; `$@` in an assignment is joined with the first character of IFS; `${@:-w}` and `${*:-w}` test the joined text; `${@%pat}` trims the joined string; a quoted empty field survives an adjacent unquoted split; the word of `${x-word}` in an assignment expands tildes after colons; a command found through PATH is remembered (`hash`, until PATH is assigned or `cd` for relative entries); `command eval` with a syntax error does not exit; `set -e` applies inside a command substitution in an `if` condition; glob results keep the slashes of the pattern; a variable whose value overflows 64 bits is an arithmetic error; `test -t` with a huge or non-numeric number, `[ -a -a ]`, blanks around numbers; `kill -l 0`, `kill -l 128`; `umask` with a leading `-` or a number above 0777; `ulimit` with an extra operand, `ulimit -a`; `getopts` with a bad variable name still parses; `trap -- -l`; a file without `#!` is run by a new shell that sees only the environment; NUL bytes in a script are ignored; `.` of a directory; an error in `PS4` is ignored; `read -p`; `$'\c\\'`; `<<$(cmd)` is a syntax error; `exit` and `return` above 2147483647 are errors; a crash on `test -t 12345678910` and on `ulimit` overflow is gone.

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

Milestone 2 counts: `test_sh_interactive.sh` 281/281 (pseudo-terminal sessions: emacs and vi editing, history and `fc` against FreeBSD sh, job control against dash and FreeBSD sh, prompts, startup, signals, completion, paste and rendering; skipped without python3/pty), `test_sh.sh` 710/710, `test_sh_diag.sh` 368/368 (343 plus the cases and documentation checks of SH4006, SH5014-SH5017), `test_sh_lint.sh` 1533/1533 (the two new scripts are linted too), `zig build test` library tests 110 passed 2 skipped (readline key-sequence tests with a memory terminal, job text, history).

Counts after the gold-standard audit (merged with the corpus fixes of `sh-corpusfix`): `test_sh.sh` 829/829 (173 cases where the shells disagree are recorded; FreeBSD sh cross-check 689 same, 30 different, of 719; it was 750/750), `test_sh_diag.sh` 617/617, `test_sh_lint.sh` 1747/1747, `test_sh_interactive.sh` 281/281, `test_sh_corpora.sh` with 37 recorded open bugs (was 135, none new), `zig build test`.

Counts after the gap closure and the corpora: `test_sh.sh` 750/750 (129 cases where the shells disagree are recorded; FreeBSD sh cross-check 619 same, 25 different, of 644; it was 710/710), `test_sh_diag.sh` 582/582 (was 343; adds the exact-status-and-stdout matrix over the four styles with and without a terminal, the colour tests on a pty, the inherited SH_DIAGNOSTICS tests, the JSON catalog driven coverage check, SH4003 and SH5012), `test_sh_lint.sh` 1587/1587 (was 1530; 18 shellcheck disagreements noted), `test_sh_corpora.sh` (third-party corpora, above), `zig build test`. Each script prints its own: `sh test/test_sh.sh` (differential, about 750 cases, plus the standard-input cases against dash), `sh test/test_sh_diag.sh` (exact messages), `sh test/test_sh_lint.sh` (shellcheck hygiene and parser oracle), `sh test/test_sh_corpora.sh` (third-party corpora), `zig build test` (unit tests of lexer, parser, arithmetic, pattern matching, diagnostics, float formatting, lint, plus a fuzz target and a deterministic mutation run of the parser). Run test binaries under a memory cap: `systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 CMD`.
