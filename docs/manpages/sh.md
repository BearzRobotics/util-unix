# NAME

sh - POSIX shell command language interpreter

# SYNOPSIS

    sh [-abCefhimnuvx] [-o option] [+abCefhimnuvx] [+o option] [--diagnostics=STYLE] [-c command [name [argument...]] | -s [argument...] | file [argument...]]

    sh --check file

    sh --explain CODE | --diagnostics-catalog | --list-diagnostics | --help | --version

# DESCRIPTION

**sh** reads commands from a string (**-c**), from standard input (**-s**, or when no file is given) or from a script file, and runs them as defined by the Shell Command Language of POSIX.1-2024 (XCU chapter 2). It is written from that specification; the reference implementations used to check behaviour are dash 0.5.12 (the differential oracle), the FreeBSD sh, bash in POSIX mode, busybox ash and yash. Where those disagree, POSIX decides and the choice is recorded in docs/compatibility/sh.md and docs/posix-shell-differences.md.

Milestones 1 and 2 of decision 0009 are implemented: the whole non-interactive language, and interactive use with prompts, line editing (emacs and vi modes), history and **fc**, tab completion and job control. See INTERACTIVE USE, LINE EDITING, HISTORY and JOB CONTROL.

The shell is also the library `util_unix.sh` (`Shell`, `parse`, `runString`, `registerBuiltin`, `getVar`, `setVar`); this page describes the executable.

# CONVENTIONS

Bold type is literal text. Italic or uppercase names are values you supply. A diagnostic code such as SH1007 is stable; see DIAGNOSTICS.

# OPTIONS

-a
: Export every variable that is assigned (allexport). **+a** turns it off.

-b
: Accepted (notify); no effect without job control.

-C
: Do not let **>** overwrite an existing regular file (noclobber); **>|** overrides.

-c
: Read commands from the first operand, which is a string. The next operand, if any, becomes **$0** and the rest the positional parameters.

-e
: Exit when a command fails, except in the places POSIX lists (conditions of **if**, **while** and **until**, every part but the last of an **&&** or **||** list, and a pipeline negated with **!**).

-f
: Disable pathname expansion (noglob).

-h
: Accepted (hashall).

-i
: Interactive shell (see INTERACTIVE USE). Also the default when neither **-c** nor a file is given and standard input and standard error are terminals.

-l
: Login shell: run **/etc/profile** and then **$HOME/.profile** before the first command.

-m
: Job control (monitor): each pipeline runs in its own process group (see JOB CONTROL). On by default in an interactive shell; allowed in scripts with **set -m**.

-n
: Read and parse but do not run (noexec). A syntax error still gives status 2.

-o option, +o option
: Turn an option on or off by name: allexport, errexit, ignoreeof, monitor, noclobber, noexec, noglob, nolog, notify, nounset, pipefail, verbose, vi, xtrace, emacs. With no name, **-o** prints the settings and **+o** prints commands that restore them.

-s
: Read commands from standard input. The operands are the positional parameters.

-u
: Treat expansion of an unset parameter (other than **@** and **\***) as an error (nounset).

-v
: Write each input line to standard error as it is read.

-x
: Write each command to standard error, prefixed by **$PS4**, after expansion (xtrace).

--check file
: Parse the file and run the static checks of the CHECK MODE section. Nothing is executed. Exit status 0 clean, 1 findings, 2 syntax error.

--diagnostics=STYLE
: How diagnostics are written to standard error: **posix** (dash's one-line wording), **rich** (see DIAGNOSTICS), **json** (one object per line), **gcc** (file:line:column: severity: message) or **auto**. The environment variable SH_DIAGNOSTICS supplies a default. Default **auto**: rich when standard error is a terminal, posix otherwise. Colour is used only in the rich style, only on a terminal and never when NO_COLOR is set. The style never changes standard output, exit statuses or any behaviour POSIX specifies.

--color=WHEN, --diagnostics-color=WHEN
: Colour of the rich style: **auto** (the default: only when standard error is a terminal and NO_COLOR is not set), **always** (escapes even off a terminal, also with NO_COLOR) or **never**. The other styles never use colour.

--explain CODE
: Print the long explanation of a diagnostic (for example `sh --explain SH1007`) with a bad and a good example, and the ShellCheck id where one exists. With `--diagnostics=json` one JSON object with the keys code, kind, severity, exit, summary, message, posix, shellcheck, help, explain, bad and good.

--diagnostics-catalog
: Print the catalog as markdown (the source of docs/sh-diagnostics.md).

--list-diagnostics
: Print the code and kind of every diagnostic, one per line; with `--diagnostics=json` the whole catalog, one object (as for --explain) per line.

--help, --version
: Print and exit 0.

# OPERANDS

file
: A script. Its name becomes **$0**; remaining operands are the positional parameters. If it cannot be opened the status is 127.

# LANGUAGE

Quoting (backslash, single and double quotes), comments, simple commands with assignments and redirections, pipelines with **!**, the lists **;**, **&**, **&&**, **||**, and the compound commands **if**/**elif**/**else**, **while**, **until**, **for**, **case**, brace groups, subshells and function definitions. Expansions in the POSIX order: tilde, parameter (all of `-` `=` `?` `+` with and without `:`, `#` `##` `%` `%%` and `${#name}`), command substitution (`$(...)` and backquotes), arithmetic (`$((...))`, signed 64-bit, C operators without `,` `**` `++` `--`), field splitting by IFS, pathname expansion, quote removal. Redirections: `<` `>` `>>` `>|` `<>`, `n>&m`, `n<&m`, `>&-`, here-documents `<<` and `<<-` (quoted and unquoted delimiters), with any descriptor number. Not implemented: `$'...'`, aliases that end in a blank expanding the next word, `fc`, `jobs`, `fg`, `bg`, and `printf` floating-point conversions.

# INTERACTIVE USE

An interactive shell writes its prompts to standard error. Before reading a command it reports jobs that finished or stopped, then expands **PS1** (parameter expansion, command substitution and arithmetic; **!** is replaced by the history number of the command and **!!** by a literal **!**) and shows it. While a command is incomplete (an open quote, **if** without **fi**, a here-document, a trailing backslash) it asks for more with **PS2**. **PS4** is the **-x** trace prefix. At start-up the file named by **ENV**, after parameter expansion and when the result is an absolute path, is read; a login shell (**-l**) reads **/etc/profile** and **~/.profile** first.

An interactive shell ignores SIGTERM and SIGQUIT, catches SIGINT (it interrupts **wait** and **read** and abandons the line being edited) and, with job control, ignores SIGTSTP, SIGTTIN and SIGTTOU. Commands it starts get the default dispositions. Errors that would end a non-interactive shell (a syntax error, a failing special builtin, a read-only assignment, an expansion error) only set the status.

End of input at the prompt leaves the shell; with **set -o ignoreeof** the shell says **Use "exit" to leave shell.** up to ten times first. **exit** (or end of input) with stopped jobs prints **You have stopped jobs.** and does not leave; the next **exit** leaves and hangs the stopped jobs up. Standard input that is not a terminal is read a byte at a time without line editing, so commands that read it see the rest of the input.

# LINE EDITING

When standard input and standard error are terminals (and TERM is not **dumb**), commands are edited. **set -o emacs** (the default) gives the emacs-style mode; **set -o vi** gives the vi mode of POSIX sh (Command Line Editing (vi-mode)), starting in insert mode; **set +o emacs** (with vi off) leaves editing to the terminal driver.

Emacs mode: C-a C-e C-b C-f and the arrow, Home, End keys move; M-b M-f and C-Left C-Right move by words; C-d, Delete and Backspace delete; C-k C-u C-w M-d M-Backspace kill (killed text accumulates), C-y and M-y yank; C-t M-t transpose; M-u M-l M-c change case; C-_ undoes; C-p C-n and Up Down move through the history; M-< and M-> jump to its ends; M-. inserts the last word of the previous command; C-r and C-s search incrementally (C-g aborts); C-v and C-q insert the next key literally; C-l redraws; M-digits give a repeat count; Tab completes (a second Tab lists the candidates); M-? lists them; M-# comments the line and enters it; C-c abandons the line; C-d on an empty line ends input.

vi mode: insert mode takes characters, Backspace, C-w, C-u (clear the line), C-v, Tab and ESC; command mode has the commands of POSIX: counts; h l w W b B e E 0 ^ $ | f F t T ; , motions; a A i I R c d y with motions, cc dd yy, C D S s x X r ~ p P u U .; k j - + G / ? n N history commands (**^** anchors a search); **_**, **#**, **v** (edit the line with $VISUAL, $EDITOR or vi and run the result), **@**letter (perform the alias named letter), **=** (list completions), **\\** (complete), **\***(expand all) and C-l.

Bracketed paste is enabled while editing, so pasted text (including newlines and tabs) is inserted literally. Widths are computed from UTF-8 (combining marks take no column, East Asian wide characters two); a change of the window size (SIGWINCH) redraws the line. Multi-line buffers and lines longer than the screen are redrawn correctly.

Tab completion completes, at the cursor: a word starting with **$** as a variable name; the first word of a command (no slash) as a builtin, function, alias or executable in PATH; anything else as a file name (directories get a slash, hidden files only when the word starts with a dot, special characters are backslash-escaped).

# HISTORY

An interactive shell keeps the commands it ran (as typed, a multi-line command as one entry) in a list of **HISTSIZE** entries (default 128) numbered upwards. If **HISTFILE** is set the list is read from that file at start-up and written back at exit (no default file). **fc** lists, edits and re-runs entries:

    fc [-r] [-e editor] [first [last]]
    fc -l [-nr] [first [last]]
    fc -s [old=new] [first]

An operand is a number, a negative number counting back from the most recent command, or text that a command starts with. With **-l** the default is the last 16 commands; without it, the previous command. **-n** omits numbers, **-r** reverses. **-s** (or **-e -**) re-runs a command after replacing the first **old** by **new**. Editing writes the commands to a temporary file, runs **editor** (**-e**, then **FCEDIT**, then **ed**) and runs what the file then contains; the commands that run are entered in the history (**-s** also shows the command on standard error). The command being run is entered after it finishes, so **fc -l** does not list itself. History does not exist in a non-interactive shell (**fc: history not active**). There is no **history** utility and no **!** expansion: both are outside POSIX.

# JOB CONTROL

With job control (**-m**, automatic when interactive) every pipeline runs in its own process group, the terminal is given to the foreground group and taken back when it ends or stops, and SIGTSTP (typically ^Z) stops the foreground job. A command ending in **&** starts a background job; a stopped or finished job is reported before the next prompt as **[1] + Stopped** or **[1] + Done**. Without job control a background command is still a job (it can be named by **wait**, **kill** and **jobs**) but runs in the shell's process group with SIGINT and SIGQUIT ignored and standard input from /dev/null.

A job is named by **%%** or **%+** (current: the most recently stopped job, else the newest), **%-** (previous), **%n**, **%string** (a job whose command starts with it) or **%?string** (contains it); a specification that matches several jobs is an error.

jobs [-lp] [job ...]
: List jobs, newest first, as **[n] c state command** where **c** is **+** for the current job and **-** for the previous one. **-l** adds process ids (one line per process of a pipeline); **-p** prints only the process ids. The column of the command is dash's.

fg [job]
: Print the command, continue the job (default: current) in the foreground and wait; the status is the job's, or 128 plus the signal when it stops again.

bg [job]
: Continue a stopped job in the background and print **[n] command**.

wait [job|pid ...]
: Wait for the named jobs or processes (all background jobs when none are named). The status is that of the last one; 127 for an unknown pid; an interactive shell interrupted by SIGINT returns 130.

kill [-s signal | -signal] job|pid ...
: A job specification signals the whole process group.

# BUILTINS

Special builtins (an error in one exits a non-interactive shell; their variable assignments persist):

| Name | Notes |
|------|-------|
| : . break continue | `.` searches PATH and accepts arguments (as bash, unlike dash) |
| eval exec exit | `exec` with only redirections makes them permanent |
| export readonly | `-p` lists |
| return set shift | `set -o` names listed under OPTIONS |
| times trap unset | `trap` accepts signal names and numbers and `EXIT`; `trap -l` lists the signals; `trap` with no operands in a subshell reports the parent's traps (POSIX.1-2024) |

Regular builtins:

| Name | Notes |
|------|-------|
| alias unalias | expansion at every command and reserved-word position; a value ending in a blank makes the next word eligible too |
| cd pwd | `-L` `-P`, CDPATH, OLDPWD |
| command type hash | `command -v -V -p` |
| echo printf | `echo` is dash's (XSI escapes, only `-n`); `printf` supports `d i u o x X c s b %` and the floating conversions `e E f F g G a A` (exact, round-half-even as C), flags, width, precision |
| getopts read test [ | the POSIX argument-count rules for `test` |
| kill wait umask ulimit jobs fg bg fc | `umask` takes an octal or a symbolic mode (`umask u=rwx,g=rx,o=`, `-S` prints it); `ulimit` supports -c -d -f -n -s -t -v -m, -S, -H |
| true false local | `local` is not POSIX; see CHECK MODE |

# ENVIRONMENT

HOME, PATH, IFS, PWD, OLDPWD, PS1, PS2, PS4, OPTIND, OPTARG, CDPATH, PPID, ENV, HISTFILE, HISTSIZE and FCEDIT are used or set as POSIX describes (TMOUT and MAIL are not implemented). PS4 is expanded (parameters, command substitution, arithmetic) each time it is printed.

SH_DIAGNOSTICS (`posix`, `rich`, `json`, `gcc`) is the default of `--diagnostics`. Like every variable it is inherited: when it is set to `json`, a `sh -c` started by a script also prints JSON. An explicit `--diagnostics=STYLE` or `--color=WHEN` on the inner shell wins over the environment, and the colour setting is not inherited (it is decided from the terminal and NO_COLOR of each shell). NO_COLOR (any value) turns colour off in `auto` mode. These variables change only what is written to standard error, never standard output or an exit status.

# EXIT STATUS

| Status | Meaning |
|--------|---------|
| 0 | The last command succeeded. |
| 1-125 | The status of the last command, or an error as listed under DIAGNOSTICS. |
| 2 | Syntax error, fatal expansion error or a special-builtin error in a non-interactive shell. |
| 126 | The command was found but could not be executed. |
| 127 | The command was not found, or the script could not be opened. |
| 128+n | The command was terminated by signal n. |

# SHELL ERRORS

The consequences of errors follow POSIX XCU 2.8.1. In a non-interactive shell a syntax error exits (status 2, after running the commands before it); a special builtin that fails with a usage error, a redirection error on a special builtin, an assignment to a read-only variable, an arithmetic error, a bad substitution and `${x?}` on an unset variable exit the shell. The same errors in a regular builtin or an external command only set the status. A redirection error on a regular command gives status 2 and does not run the command.

# CHECK MODE

`sh --check script` parses the script and reports, without running anything: unquoted expansions that will be split and globbed (SH7001), `cd` whose failure is not checked (SH7002), `rm -r` on a path that starts with a variable (SH7003), and constructs that are not POSIX: `[[` (SH7004), the `function` keyword (SH7005), `source` (SH7006), `local` (SH7007), `echo -e` (SH7008) and `==` in `[` (SH7009). The default output style is gcc; use `--diagnostics=json` for editors. The checks and their messages are this project's own; docs/sh-diagnostics.md maps each to the nearest ShellCheck id.

# DIAGNOSTICS

Every message has a code SHxxxx and a kind. The default one-line wording equals dash's; the rich style looks like this:

    sh: script.sh:12:1: error[SH1007]: unexpected 'fi', expected 'done' to close the 'while' started at 9:1
       |
    12 | fi
       | ^^
    note: the 'while' started here
       |
     9 | while true; do
       | -----
    help: insert 'done' where the construct should end

The JSON style prints one object per diagnostic with the keys code, kind, severity, file, line, column, end, message, help, token, expected and posix. The library returns the same data as a `Diagnostic` value; rendering is a separate module so a host can present it differently. `sh --explain CODE` prints a long explanation. Exit statuses are those of POSIX, unchanged by the style.

Catalog (what each code means, an example that triggers it, and the dash message it replaces; docs/sh-diagnostics.md has the full explanations):

| Code | Kind | Status | Example | dash says |
|------|------|--------|---------|-----------|
| SH1001 | unexpected_token | 2 | `echo )` | `Syntax error: ")" unexpected` |
| SH1002 | unterminated_quote | 2 | `echo 'abc` | `Syntax error: Unterminated quoted string` |
| SH1003 | unterminated_heredoc | - | `cat <<EOF ; body` | `warning: here-document at line 1 delimited by end-of-file (wanted `EOF')` |
| SH1004 | unterminated_command_substitution | 2 | `echo $(date` | `Syntax error: end of file unexpected (expecting ")")` |
| SH1005 | unterminated_arithmetic | 2 | `echo $((1+2)` | `Syntax error: Missing '))'` |
| SH1006 | bad_substitution | 2 | `echo ${x/a/b}` | `Bad substitution` |
| SH1007 | mismatched_closer | 2 | `while true; do ;   echo x ; fi` | `Syntax error: "fi" unexpected (expecting "done")` |
| SH1008 | bad_for_variable | 2 | `for 1x in a; do :; done` | `Syntax error: Bad for loop variable` |
| SH1009 | bad_function_name | 2 | `1f() { :; }` | `Syntax error: Bad function name` |
| SH1010 | missing_redirect_target | 2 | `echo >` | `Syntax error: newline unexpected` |
| SH2001 | division_by_zero | 2 | `echo $((1/0))` | `arithmetic expression: division by zero: "1/0"` |
| SH2002 | arithmetic_syntax | 2 | `echo $((1+))` | `arithmetic expression: expecting primary: "1+"` |
| SH2003 | illegal_number | 2 | `x=abc; echo $((x+1))` | `Illegal number: abc` |
| SH2004 | unset_variable | 2 | `set -u; echo $x` | `x: parameter not set` |
| SH2005 | parameter_error | 2 | `echo ${x?need x}` | `x: need x` |
| SH2006 | cannot_assign | 2 | `echo ${1=x}` | `1: cannot assign in this way` |
| SH2007 | readonly_assignment | 2 | `readonly r=1; r=2` | `r: is read only` |
| SH3001 | cannot_open | 2 | `cat < missing.txt` | `cannot open missing.txt: No such file` |
| SH3002 | cannot_create | 2 | `echo x > /nonexistent/f` | `cannot create /nonexistent/f: Directory nonexistent` |
| SH3003 | bad_fd | 2 | `echo hi >&9` | `9: Bad file descriptor` |
| SH3004 | noclobber | 2 | `set -C; echo a > f; echo b > f` | `cannot create f: File exists` |
| SH3005 | bad_fd_number | 2 | `echo hi >&file` | `Syntax error: Bad fd number` |
| SH4001 | not_found | 127 | `nosuchcommand` | `nosuchcommand: not found` |
| SH4002 | not_executable | 126 | `./notexecutable` | `./notexecutable: Permission denied` |
| SH4003 | cannot_fork | 2 | `(ulimit -u 1; : \| :)` | `Cannot fork` |
| SH4004 | cannot_open_script | 127 | `sh nosuch.sh` | `Can't open nosuch.sh` |
| SH4005 | errexit_exit | - | `set -e ; false ; echo unreachable` | `(none: dash exits silently)` |
| SH4006 | stopped_jobs | 1 | `exit` with a stopped job | `You have stopped jobs.` |
| SH5001 | illegal_option | 2 | `set -Z` | `set: Illegal option -Z` |
| SH5002 | cannot_shift | 2 | `set -- a; shift 2` | `shift: can't shift that many` |
| SH5003 | cannot_cd | 2 | `cd /nonexistent` | `cd: can't cd to /nonexistent` |
| SH5004 | bad_trap | 1 | `trap : NOSUCH` | `trap: NOSUCH: bad trap` |
| SH5005 | bad_variable_name | 2 | `export 1x=3` | `export: 1x: bad variable name` |
| SH5006 | test_error | 2 | `[ a b ]` | `[: a: unexpected operator` |
| SH5007 | printf_number | 1 | `printf '%d\ ; ' abc` | `printf: abc: expected numeric value` |
| SH5008 | kill_error | 2 | `kill -s NOSUCH 1` | `kill: invalid signal number or name: NOSUCH` |
| SH5009 | usage | 2 | `getopts a` | `getopts: usage: getopts optstring var [arg]` |
| SH5010 | io_error | 1 | `echo hi >&-` | `echo: echo: I/O error` |
| SH5011 | alias_not_found | 1 | `unalias nosuch` | `unalias: nosuch: not found` |
| SH5012 | bad_limit | 1 | `ulimit -n 99999999999` | `ulimit: bad limit: Operation not permitted` |
| SH5013 | not_in_function | 2 | `local x=1` | `local: not in a function` |
| SH5014 | no_such_job | 1 | `fg` | `fg: No current job` |
| SH5015 | no_job_control | 1 | `sh -i < file` | `can't access tty; job control turned off` |
| SH5016 | history_error | 1 | `fc -l` (not interactive) | `fc: history not active` |
| SH5017 | ambiguous_job | 1 | `fg %sl` | `fg: %sl: Ambiguous` |
| SH6001 | invocation_option | 2 | `sh -Z` | `Illegal option -Z` |
| SH6002 | missing_argument | 2 | `sh -c` | `-c requires an argument` |
| SH7001 | lint_unquoted_expansion | 1 | `rm $file` | `(none)` |
| SH7002 | lint_cd_unchecked | 1 | `cd /build ; rm -rf ./*` | `(none)` |
| SH7003 | lint_rm_variable | 1 | `rm -rf "$dir/"` | `(none)` |
| SH7004 | lint_double_bracket | 1 | `[[ $a = b ]]` | `[[: not found` |
| SH7005 | lint_function_keyword | 1 | `function f { :; }` | `function: not found` |
| SH7006 | lint_source | 1 | `source ./lib.sh` | `source: not found` |
| SH7007 | lint_local | 1 | `f() { local x=1; }` | `(accepted)` |
| SH7008 | lint_echo_option | 1 | `echo -e "a\tb"` | `(prints -e)` |
| SH7009 | lint_double_equals | 1 | `[ "$a" == b ]` | `[: a: unexpected operator` |
| SH9000 | other | - | `-` | - |

# DIFFERENCES FROM DASH

Each row is an improvement of a message or a deliberate choice; stdout and the exit status are dash's unless stated.

| Where | dash | sh |
|-------|------|----|
| Rich style (terminal) | one line `sh: 1: msg` | the multi-line message above; `--diagnostics=posix` restores dash's wording exactly |
| `set -e` exit | silent | rich and json styles name the command and line (SH4005); posix style is silent |
| Unterminated quote or `$(` | `Syntax error: Unterminated quoted string` | rich style names where it was opened |
| `.` with arguments | positional parameters unchanged | arguments become the positional parameters during the file (as POSIX XCU dot, bash, FreeBSD) |
| Descriptor numbers of two or more digits (`exec 10>f`) | rejected (`exec: 10: not found`) | accepted, per POSIX 2.7 |
| `$((` without a matching `))` | `Missing '))'` | same |
| Here-document ended by end of input | no warning | warning SH1003 in rich and json styles; posix style is silent |
| `*` and `.*` as filename patterns | `.*` matches `.` and `..` | `.*` does not match `.` or `..` (POSIX XCU 2.14.3: they may be ignored); `../` and `./` still work as literal names |
| `kill -n 9 pid` | error | sends the signal (POSIX.1-2024 kill) |
| `$'a\tb'` | literal text | C-style escapes (POSIX.1-2024 XCU 2.2.4) |
| `set -o pipefail` | no effect | works (POSIX.1-2024) |
| `trap` with no operands in a subshell or `$(...)` | prints nothing | prints the parent's traps (POSIX XCU trap) |
| `f() g() { :; }` | accepted | syntax error: a function body is a compound command (XCU 2.10.2) |
| `return 256`, `exit 256` | `$?` keeps 256 after `return` | statuses are 0 to 255 (POSIX leaves larger ones unspecified) |
| `trap -l` | error | lists the signals (POSIX.1-2024) |

Every other difference from dash that is not a message is a bug of ours: `tools/sh-gold.sh` compares our stdout and status with dash and FreeBSD sh on 6800 snippets (the test suite, the yash, FreeBSD and Oils corpora and the lists in `test/sh_gold`), and docs/posix-shell-differences.md records where the shells disagree and which rule decided.

The first word of the header is always the program (`sh`), then the script as it was named on the command line; the posix style keeps dash's `$0: line: message`. The caret underlines the offending part (the redirection target, the `${...}` or `$((...))` expansion, the command word), not only the command word.

A script on standard input is read and run command by command, 8192 bytes at a time as dash does: a command such as `cat` or `read` sees the input the shell has not yet buffered.

# EXAMPLES

    sh -c 'echo "$0 $1" ' name arg
    sh -e script.sh
    sh --check deploy.sh
    sh --diagnostics=json -n script.sh
    sh --explain SH1007

# SEE ALSO

docs/compatibility/sh.md, docs/posix-shell-differences.md, docs/sh-diagnostics.md, decision 0009.

# STANDARDS

POSIX.1-2024 XCU chapter 2 (Shell Command Language) and the utilities sh, cd, command, echo, getopts, hash, kill, printf, pwd, read, test, type, ulimit, umask, unalias, wait.
