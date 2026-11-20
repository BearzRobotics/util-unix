# NAME

posix-shell-differences - where POSIX shells disagree, and how to write scripts that do not care

# DESCRIPTION

Generated from `sh test/test_sh.sh` with `SH_DOC_OUT` set (the table) plus the chapters below. The table lists every case of the differential suite on which the shells that were run disagree: dash 0.5.12, bash 5.3 in POSIX mode (`bash --posix`) and run through a link named `sh`, busybox ash, yash 2.61 (`--posix` and plain), FreeBSD sh (Chimera sysroot, only for cases marked B) and our `sh`. 129 cases differ.

The rule for `sh`: when the other shells agree, we agree. When they differ we match dash or FreeBSD sh, or, for cases marked P in the suite, POSIX (checked against `bash --posix` and `yash --posix`); the choice is recorded here. Only stdout and the exit status are compared across shells; stderr is compared with dash alone because POSIX leaves diagnostic wording free (XCU 2.8.1 requires only that diagnostics go to standard error).

Categories used in the table:

| Category | Meaning |
|----------|---------|
| POSIX-defined | POSIX.1-2024 XCU specifies the behaviour; a shell that differs has a bug (or, for Issue 8 additions, has not caught up). |
| POSIX-undefined | POSIX says unspecified, undefined, or does not mention it; any behaviour conforms. |
| implementation-defined | POSIX requires a documented choice or leaves the exact value (a status above zero, an output format) to the implementation. |
| bug | A shell contradicts what POSIX says or what it documents. |

Sources: the Shell Command Language, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html (XCU 2.x numbers below), and the utility pages (`echo`, `printf`, `test`, `getopts`, `trap`, `set`, ...). The 2017 man-pages-posix (man1p) were not installed on this machine, so the 2024 text was used.

# WRITING PORTABLE POSIX SCRIPTS

# Quoting

Quote every expansion unless you want splitting and globbing: `"$var"`, `"$@"`, `"$(cmd)"`. An unquoted `$var` is split at IFS characters and each word is a pathname pattern (XCU 2.6.5, 2.6.6), so a value with a space or `*` changes the command's argument list. `"$@"` expands to separate words, `"$*"` to one word joined with the first IFS character. A pattern in `case` or `${x#pat}` is quoted the same way: `"$p"` matches literally, `$p` as a pattern.

Backslash inside double quotes escapes only `$`, backquote, `"`, `\` and newline; elsewhere it stays. Single quotes cannot contain a single quote: write `'it'\''s'`. The Issue 8 form `$'a\tb'` is supported here and in bash, yash and busybox but not in dash 0.5.12, so portable scripts use `printf`.

# Expansion order

Tilde expansion, parameter expansion, command substitution and arithmetic happen first (left to right), then field splitting of the unquoted results, then pathname expansion, then quote removal (XCU 2.6). Consequences: a variable holding `*` is globbed when unquoted; `a=$b` and `case $x in` do no splitting or globbing; `x=~` expands the tilde but `echo x=~` does not. Assignments before a command (`a=1 b=$a cmd`) are expanded in order in Issue 8; do not rely on it in older shells.

# set -e pitfalls

`set -e` does not fire in the condition of `if`, `while` or `until`, in any part but the last of an `&&` or `||` list, in a negated pipeline, or anywhere inside a function or compound command that is itself in one of those positions (XCU 2.14). So `f() { false; echo still-runs; }; if f; then :; fi` prints `still-runs`. A failing command substitution in `x=$(false)` fails the assignment; in `echo $(false)` it does not. `set -e` is not a substitute for checking: write `cd dir || exit 1`, and `cmd || :` for allowed failures. `sh --check` reports an unchecked `cd`; with `--diagnostics=rich`, `sh` says which command ended a `set -e` run.

# Bashisms and their POSIX spellings

| Not portable | POSIX |
|--------------|-------|
| `local x=1` | a subshell function `f() ( ... )`, or unique names |
| `echo -e "a\tb"` | `printf 'a\tb\n'` (`echo` with backslashes or `-n` differs between shells) |
| `[[ $a = b* ]]`, `[[ -n $x && -f $y ]]` | `case $a in b*) ...;; esac`, `[ -n "$x" ] && [ -f "$y" ]` |
| `a=(1 2 3)`, `${a[1]}` | positional parameters (`set -- 1 2 3`) or newline-separated text |
| `[ a == b ]` | `[ a = b ]` |
| `function f { ...; }` | `f() { ...; }` |
| `source file` | `. ./file` |
| `${x/a/b}`, `${x:1:2}`, `${x^^}` | `sed`, `cut`, `tr`, or the `#`/`%` trims |
| `<(cmd)`, `<<< word`, `&>file` | temporary files or a pipe; `printf '%s\n' "$word" \|`; `>file 2>&1` |
| `$RANDOM`, `$BASHPID`, `$EUID`, `$PIPESTATUS` | none: use `awk` or `/dev/urandom`; `$$`; `id -u`; a temporary file |
| `[ -a file ]`, `-o` and `-a` joining tests | `[ -e file ]`; two `[ ]` tests joined with the shell's `\|\|` |

`sh --check script` flags the ones above that parse (`[[`, `function`, `source`, `local`, `echo -e`, `==`).

# Here-documents

`<<EOF` expands `$`, backquote and `\`; `<<'EOF'` (any quoting of the delimiter) does not. `<<-EOF` strips leading tabs, not spaces, from the body and the delimiter line. The delimiter must be alone on its line. The body of several here-documents on one line is read in order after the newline. A here-document inside `$(...)` needs the delimiter before the closing parenthesis.

# read and IFS

`read -r` keeps backslashes; without `-r` a backslash escapes the next character and a backslash-newline continues the line. Leading and trailing IFS white space is trimmed from the last variable; other IFS characters delimit empty fields. `IFS=: read a b` assigns only for that command. `read` reads one byte at a time from a pipe so it does not consume more than the line. `echo "$x" | read y` runs `read` in a subshell in most shells: `y` is not set afterwards. Use `read y <<EOF` or a loop `while read l; do ...; done < file`.

# Arithmetic

`$((...))` is signed integer arithmetic with the C operators `+ - * / % << >> < <= > >= == != & ^ | && || ! ~ ?:` and assignment forms. `0x` hexadecimal and leading-`0` octal constants: `$((08))` is an error. Division and remainder by zero are errors that end a non-interactive shell. Variables are named without `$`; an unset or empty one is 0 but a non-numeric value is an error in dash and this shell (bash evaluates it as an expression). There is no `**`, `++`, `--` or comma operator in POSIX.

# trap

`trap 'cmd' EXIT` runs when the shell exits, including after `exit` and after a `set -e` exit; a subshell has its own EXIT trap and does not inherit the parent's. `trap '' SIG` ignores a signal and the ignore is inherited by commands; a trapped signal is reset to default in a command. The trap runs after the foreground command that was running completes; a `wait` is interrupted by a trapped signal. `trap - SIG` restores the default. Do not rely on `trap` with no arguments inside a subshell.

# $? in pipelines

The status of a pipeline is that of its last command; the others are lost (`false | true` is 0). `set -o pipefail` (POSIX.1-2024; `bash`, `yash`, busybox, this shell; no effect in dash 0.5.12) makes it the status of the rightmost command that failed. There is no `PIPESTATUS` in POSIX. `! pipeline` inverts the final status and also disables `set -e` for it. In `cmd | while read ...; do ...; done` the loop runs in a subshell in most shells, so variables set inside are lost.

# DIFFERENCES

| Snippet | Results (shells that agree are grouped) | Category | POSIX says, and what ours does |
|---------|----------------------------------------|----------|-------------------------------|
| `echo a\ b\\c` | dash, yash-posix, yash: `a brc=0`; bash-posix, bash-as-sh, busybox-ash, freebsd: `a b\c~rc=0` | implementation-defined | XCU echo (XSI): `\c` ends output; without XSI backslash handling is implementation-defined. Ours (`a brc=0`): dash/XSI: escapes processed, as in the dash oracle |
| `echo "a\$b\"c\\d\e"` | dash, yash-posix, yash: `a$b"c\d~rc=0`; bash-posix, bash-as-sh, busybox-ash, freebsd: `a$b"c\d\e~rc=0` | implementation-defined | XCU echo: backslash handling in operands. Ours (`a$b"c\d\e~rc=0`): dash/XSI behaviour |
| `echo ${u?boom}; echo not reached` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | XCU 2.8.1 Consequences of Shell Errors: a non-interactive shell exits; the status is only required to be non-zero. Ours (`rc=2`): exits with 2 like dash; bash --posix exits with 127 |
| `u=; echo ${u:?empty}; echo not reached` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | XCU 2.8.1 Consequences of Shell Errors: a non-interactive shell exits; the status is only required to be non-zero. Ours (`rc=2`): exits with 2 |
| `echo ${u?}` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | XCU 2.8.1 Consequences of Shell Errors: a non-interactive shell exits; the status is only required to be non-zero. Ours (`rc=2`): exits with 2 |
| `echo "[$-]"` | dash, freebsd: `[]~rc=0`; bash-posix, bash-as-sh: `[hBc]~rc=0`; busybox-ash, yash-posix, yash: `[c]~rc=0` | implementation-defined | XCU 2.5.2: `$-` is the current option flags; the initial set is not specified. Ours (`[]~rc=0`): empty, as dash |
| `echo "[$!]"` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `[]~rc=0`; yash-posix, yash: `[0]~rc=0` | POSIX-undefined | XCU 2.5.2: `$!` is unspecified before any asynchronous command. Ours (`[]~rc=0`): empty, as dash |
| `echo $0` | dash: `/usr/bin/dash~rc=0`; bash-posix: `/usr/bin/bash~rc=0`; bash-as-sh: `/tmp/tmp.0USm1yR0th/bin/sh~rc=0`; busybox-ash: `ash~rc=0`; yash-posix, yash: `/usr/bin/yash~rc=0`; freebsd: `sh~rc=0` | implementation-defined | XCU 2.5.2 / sh: `$0` without a name operand is the shell's name; its spelling depends on how it was invoked. Ours (`sh~rc=0`): `sh` |
| `set -u; echo $u; echo after` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | XCU 2.14 set -u and 2.8.1: expansion of an unset parameter writes a diagnostic and a non-interactive shell exits. Ours (`rc=2`): exit 2 |
| `set -u; echo $1` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | same. Ours (`rc=2`): exit 2 |
| `a=1 b=$a; echo $b` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `1~rc=0`; freebsd: `~rc=0` | POSIX-defined | XCU 2.9.1 (Issue 8): assignments are expanded and made in order, so `b` sees `a`; earlier editions left it unspecified. FreeBSD sh expands all values before assigning. Ours (`1~rc=0`): sequential (dash, bash, busybox, yash agree) |
| `echo $((1/0)); echo after` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | XCU 2.6.4: an arithmetic error is an expansion error; XCU 2.8.1 Consequences of Shell Errors: a non-interactive shell exits; the status is only required to be non-zero. Ours (`rc=2`): exit 2 |
| `echo $((1%0)); echo after` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | same. Ours (`rc=2`): exit 2 |
| `echo $((1+)); echo after` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | same (syntax error in the expression). Ours (`rc=2`): exit 2 |
| `echo $((08)); echo after` | dash, busybox-ash, yash-posix, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127`; yash: `8~after~rc=0` | POSIX-defined | XCU 2.6.4: constants follow ISO C; `08` is an invalid octal constant. yash (non-POSIX mode) accepts it: bug in yash. Ours (`rc=2`): error, as dash |
| `echo $((1 2)); echo after` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | same. Ours (`rc=2`): exit 2 |
| `echo $((0&&1/0)) $((1\|\|1/0))` | dash, bash-posix, bash-as-sh, yash-posix, yash, freebsd: `0 1~rc=0`; busybox-ash: `rc=2` | POSIX-defined | XCU 2.6.4: ISO C operators; `&&` and `||` do not evaluate the right operand when the result is known. busybox ash evaluates both: bug in busybox. Ours (`0 1~rc=0`): short-circuits |
| `echo $((9223372036854775807)) $((9223372036854775807+1))` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `9223372036854775807 -9223372036854775808~rc=0`; yash-posix, yash: `rc=2` | POSIX-undefined | XCU 2.6.4: signed integer overflow is undefined in C; yash reports an error. Ours (`9223372036854775807 -9223372036854775808~rc=0`): wraps (two's complement), as dash |
| `echo $((1<<63))` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `-9223372036854775808~rc=0`; yash-posix, yash: `rc=2` | POSIX-undefined | same (shift into the sign bit). Ours (`-9223372036854775808~rc=0`): wraps, as dash |
| `x="1+2"; echo $((x)); echo after` | dash, yash-posix, freebsd: `rc=2`; bash-posix, bash-as-sh, busybox-ash: `3~after~rc=0`; yash: `1+2~after~rc=0` | POSIX-undefined | XCU 2.6.4: a variable whose value is not an integer constant leaves the result unspecified. Ours (`rc=2`): error `Illegal number`, as dash |
| `echo $((1,2)); echo after` | dash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh, busybox-ash: `2~after~rc=0` | POSIX-undefined | XCU 2.6.4: operators beyond the required set are implementation extensions. Ours (`rc=2`): rejected, as dash (no comma operator) |
| `echo $((2**3)); echo after` | dash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh, busybox-ash: `8~after~rc=0` | POSIX-undefined | same. Ours (`rc=2`): rejected, as dash |
| `touch a1 b1 c1; echo [^a]1` | dash: `a1~rc=0`; bash-posix, bash-as-sh, busybox-ash, yash-posix, yash, freebsd: `b1 c1~rc=0` | POSIX-undefined | XCU 2.14.1: `[!...]` negates; `[^...]` is unspecified. Ours (`b1 c1~rc=0`): negates (bash, busybox, yash and FreeBSD agree); dash treats `^` literally |
| `touch b a c B A; echo *` | dash, busybox-ash, freebsd: `A B a b c~rc=0`; bash-posix, bash-as-sh, yash-posix, yash: `a A b B c~rc=0` | implementation-defined | XCU 2.14.3: sorted according to the collating sequence of the current locale. Ours (`A B a b c~rc=0`): C locale: byte order, as dash |
| `echo a > f; set -C; echo b > f; echo "rc=$?"; cat f` | dash, yash-posix, yash, freebsd: `rc=2~a~rc=0`; bash-posix, bash-as-sh, busybox-ash: `rc=1~a~rc=0` | implementation-defined | XCU 2.7.2: a redirection error makes the command fail with non-zero status (the value is unspecified). Ours (`rc=2~a~rc=0`): status 2, as dash |
| `cat < nosuchfile; echo "rc=$?"` | dash, yash-posix, yash, freebsd: `rc=2~rc=0`; bash-posix, bash-as-sh, busybox-ash: `rc=1~rc=0` | implementation-defined | XCU 2.8.1: redirection error status is non-zero. Ours (`rc=2~rc=0`): status 2, as dash |
| `echo x > /nonexistent/f; echo "rc=$?"` | dash, yash-posix, yash, freebsd: `rc=2~rc=0`; bash-posix, bash-as-sh, busybox-ash: `rc=1~rc=0` | implementation-defined | same. Ours (`rc=2~rc=0`): status 2 |
| `exec 10>f; echo a >&10; exec 10>&-; cat f` | dash: `rc=127`; bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `a~rc=0` | POSIX-defined | XCU 2.7: the number before the operator is any decimal digit string. dash and FreeBSD sh accept one digit only: bug in those. Ours (`a~rc=0`): accepted |
| `cat <&3 3<<EOF x EOF` | dash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh, busybox-ash: `rc=1` | implementation-defined | XCU 2.7: redirections are processed left to right, so descriptor 3 is not open at `<&3`; the failure status is unspecified. Ours (`rc=2`): status 2, as dash |
| `echo a > f; > f; wc -c < f` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `0~rc=0`; freebsd: `       0~rc=0` | implementation-defined | FreeBSD `wc` pads its count with spaces; the shells agree (a utility difference, not a shell one). Ours (`0~rc=0`): same output as the other shells |
| `echo a > f > g; cat g; wc -c < f` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `a~0~rc=0`; freebsd: `a~       0~rc=0` | implementation-defined | same (FreeBSD `wc` padding). Ours (`a~0~rc=0`): same output as the other shells |
| `for i in 1 2; do echo $i; done \| wc -l` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `2~rc=0`; freebsd: `       2~rc=0` | implementation-defined | same (FreeBSD `wc` padding). Ours (`2~rc=0`): same output as the other shells |
| `break; echo after` | dash, bash-posix, bash-as-sh, busybox-ash, yash, freebsd: `after~rc=0`; yash-posix: `rc=2` | POSIX-undefined | XCU break: outside a loop the behaviour is unspecified. Ours (`after~rc=0`): no effect, as dash |
| `for i in 1; do break 0; done; echo after` | dash, busybox-ash, yash-posix: `rc=2`; bash-posix, bash-as-sh, yash, freebsd: `after~rc=0` | POSIX-undefined | XCU break: n must be a positive integer. Ours (`rc=2`): error, as dash |
| `f() { echo $0; }; f` | dash: `/usr/bin/dash~rc=0`; bash-posix: `/usr/bin/bash~rc=0`; bash-as-sh: `/tmp/tmp.0USm1yR0th/bin/sh~rc=0`; busybox-ash: `ash~rc=0`; yash-posix, yash: `/usr/bin/yash~rc=0`; freebsd: `sh~rc=0` | implementation-defined | XCU 2.5.2 / sh: `$0` without a name operand is the shell's name; its spelling depends on how it was invoked. Ours (`sh~rc=0`): `sh` |
| `eval() { echo shadow; }; eval echo real` | dash, bash-posix, bash-as-sh: `rc=2`; busybox-ash: `shadow~rc=0`; yash-posix, yash: `real~rc=0` | POSIX-defined | XCU 2.9.5 (Issue 8): the function name shall not be that of a special built-in. Ours (`rc=2`): rejected, as dash (bash, busybox, yash accept it as an extension) |
| `echo before; set -n; echo not run` | dash, bash-posix, bash-as-sh, busybox-ash: `before~rc=0`; yash-posix, yash, freebsd: `before~not run~rc=0` | POSIX-defined | XCU 2.14 set -n: read commands but do not execute them. yash executes them: bug in yash. Ours (`before~rc=0`): stops executing, as dash |
| `set -u; echo $nothing; echo after` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | same. Ours (`rc=2`): exit 2 |
| `set -C; echo a > f; echo b > f; echo $?` | dash, yash-posix, yash, freebsd: `2~rc=0`; bash-posix, bash-as-sh, busybox-ash: `1~rc=0` | implementation-defined | XCU 2.7.2: failure status non-zero, value unspecified. Ours (`2~rc=0`): 2, as dash |
| `set -o \| grep -c .` | dash: `20~rc=0`; bash-posix, bash-as-sh: `27~rc=0`; busybox-ash: `14~rc=0`; yash-posix, yash: `45~rc=0` | implementation-defined | XCU set: the option names beyond the POSIX ones are not specified. Ours (`20~rc=0`): dash's list |
| `set -o nounset; echo $x; echo no` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | same. Ours (`rc=2`): exit 2 |
| `set +o \| grep -c "set"` | dash: `19~rc=0`; bash-posix, bash-as-sh: `27~rc=0`; busybox-ash: `14~rc=0`; yash-posix, yash: `41~rc=0` | implementation-defined | same. Ours (`19~rc=0`): dash's list |
| `set -f; echo $-` | dash: `f~rc=0`; bash-posix, bash-as-sh: `fhBc~rc=0`; busybox-ash, yash-posix, yash: `cf~rc=0` | implementation-defined | XCU 2.5.2: the letters and their order in `$-` are unspecified. Ours (`f~rc=0`): dash's |
| `set -e; echo $-` | dash: `e~rc=0`; bash-posix, bash-as-sh: `ehBc~rc=0`; busybox-ash, yash-posix, yash: `ce~rc=0` | implementation-defined | same. Ours (`e~rc=0`): dash's |
| `x=1; set \| grep "^x="` | dash, busybox-ash: `x='1'~rc=0`; bash-posix, bash-as-sh, yash-posix, yash, freebsd: `x=1~rc=0` | implementation-defined | XCU set: output "suitable for reinput"; the quoting style is free. Ours (`x='1'~rc=0`): dash's single quotes |
| `set -- a; shift 2; echo after` | dash: `rc=2`; bash-posix, bash-as-sh, busybox-ash, yash-posix, yash, freebsd: `after~rc=0` | POSIX-defined | XCU shift: n greater than `$#` is an error; special-builtin errors exit a non-interactive shell (2.8.1). bash --posix, busybox and yash only return non-zero. Ours (`rc=2`): exit 2, as dash |
| `trap "echo parent" USR1; (trap; echo in)` | dash, busybox-ash, freebsd: `in~rc=0`; bash-posix, bash-as-sh, yash-posix, yash: `trap -- 'echo parent' USR1~in~rc=0` | POSIX-defined | XCU trap (Issue 8): `trap` without operands in a subshell reports the parent's traps. Ours (`in~rc=0`): not implemented (prints nothing, as dash): a known gap, see compatibility record |
| `echo "echo \$1 \$#" > s; . ./s a b` | dash: `0~rc=0`; bash-posix, bash-as-sh, busybox-ash, yash: `a 2~rc=0`; yash-posix: `rc=2` | POSIX-defined | XCU dot (Issue 8): operands after the file become the positional parameters; dash ignores them. Ours (`a 2~rc=0`): sets them |
| `echo "echo in" > s; set -- p q; . ./s a; echo $1` | dash, bash-posix, bash-as-sh, busybox-ash, yash, freebsd: `in~p~rc=0`; yash-posix: `rc=2` | POSIX-defined | XCU dot (Issue 8): operands become positional parameters during the file and are restored after. yash --posix rejects operands (2008 text). Ours (`in~p~rc=0`): accepts them, restores afterwards |
| `. ./nosuch; echo after` | dash, busybox-ash: `rc=2`; bash-posix, bash-as-sh, yash-posix, yash: `rc=1`; freebsd: `rc=127` | implementation-defined | XCU dot / 2.8.1: a special built-in failing to open its file exits the shell; status unspecified. Ours (`rc=2`): exit 2, as dash |
| `command -v nosuchcmd; echo $?` | dash, busybox-ash, freebsd: `127~rc=0`; bash-posix, bash-as-sh, yash-posix, yash: `1~rc=0` | implementation-defined | XCU command: non-zero when not found; the value is unspecified. Ours (`127~rc=0`): 127, as dash |
| `type cd` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `cd is a shell builtin~rc=0`; yash-posix, yash: `cd: a mandatory built-in~rc=0` | implementation-defined | XCU type: output format unspecified. Ours (`cd is a shell builtin~rc=0`): dash's |
| `f() { :; }; type f` | dash, freebsd: `f is a shell function~rc=0`; bash-posix, bash-as-sh: `f is a function~f () ~{ ~    :~}~rc=0`; busybox-ash: `f is a function~rc=0`; yash-posix, yash: `f: a function~rc=0` | implementation-defined | same. Ours (`f is a shell function~rc=0`): dash's |
| `type nosuchcmd; echo $?` | dash, busybox-ash: `nosuchcmd: not found~127~rc=0`; bash-posix, bash-as-sh, yash-posix, yash: `1~rc=0`; freebsd: `127~rc=0` | implementation-defined | XCU type: non-zero status when not found. Ours (`nosuchcmd: not found~127~rc=0`): 127, as dash |
| `type if` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `if is a shell keyword~rc=0`; yash-posix, yash: `if: a shell keyword~rc=0` | implementation-defined | XCU type: output format unspecified. Ours (`if is a shell keyword~rc=0`): dash's |
| `: > /nonexistent/f; echo after` | dash, yash-posix, freebsd: `rc=2`; bash-posix, bash-as-sh, busybox-ash: `rc=1`; yash: `after~rc=0` | POSIX-defined | XCU 2.8.1: redirection error on a special built-in exits a non-interactive shell. yash (non-POSIX mode) continues: bug in yash. Ours (`rc=2`): exits 2 |
| `set -Z; echo after` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, freebsd: `rc=2`; yash: `after~rc=0` | POSIX-defined | XCU 2.8.1: special built-in utility error exits; yash continues outside POSIX mode. Ours (`rc=2`): exits 2 |
| `readonly r=1; unset r; echo after` | dash, busybox-ash: `rc=2`; bash-posix, bash-as-sh, yash-posix: `rc=1`; yash, freebsd: `after~rc=0` | POSIX-defined | XCU 2.8.1 (readonly assignment is an error): exits. Ours (`rc=2`): exit 2 |
| `readonly r=1; export r=2; echo after` | dash, busybox-ash, freebsd: `rc=2`; bash-posix, bash-as-sh, yash-posix: `rc=1`; yash: `after~rc=0` | POSIX-defined | same. Ours (`rc=2`): exit 2 |
| `shift 3; echo after` | dash: `rc=2`; bash-posix, bash-as-sh, busybox-ash, yash-posix, yash, freebsd: `after~rc=0` | POSIX-defined | same. Ours (`rc=2`): exit 2 |
| `while true; do break x; done; echo after` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, freebsd: `rc=2`; yash: `rc=124` | implementation-defined | XCU break: non-numeric operand is an error. Ours (`rc=2`): exit 2 |
| `f() { return x; }; f; echo after` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, freebsd: `rc=2`; yash: `after~rc=0` | implementation-defined | XCU return: non-numeric operand is an error. Ours (`rc=2`): exit 2 |
| `. /nonexistent; echo after` | dash, busybox-ash: `rc=2`; bash-posix, bash-as-sh, yash-posix, yash: `rc=1`; freebsd: `rc=127` | implementation-defined | same. Ours (`rc=2`): exit 2 |
| `readonly r=1; r=2; echo after` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | XCU 2.8.1: assignment to a readonly variable is an error that exits a non-interactive shell. Ours (`rc=2`): exit 2 |
| `readonly r=1; r=2 true; echo after` | dash, busybox-ash, yash-posix, yash: `rc=2`; bash-posix, bash-as-sh: `rc=1`; freebsd: `after~rc=0` | POSIX-defined | same. Ours (`rc=2`): exit 2 |
| `readonly i=1; for i in a; do :; done; echo after` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-defined | same (`for` assigns the variable). Ours (`rc=2`): exit 2 |
| `x=1; f() { :; }; unset x f; echo "[$x]"; f 2>/dev/null; echo $?` | dash, busybox-ash, yash-posix, yash, freebsd: `[]~0~rc=0`; bash-posix, bash-as-sh: `[]~127~rc=0` | POSIX-defined | XCU 2.9.5: running an unset function is "command not found" (127); bash --posix prints 127 and the status is as dash's here. Ours (`[]~0~rc=0`): status 0 from `2>/dev/null; echo $?` |
| `export ee=1; export -p \| grep " ee="` | dash, busybox-ash: `export ee='1'~rc=0`; bash-posix, bash-as-sh: `export ee="1"~rc=0`; yash-posix, yash, freebsd: `export ee=1~rc=0` | implementation-defined | XCU export -p: "suitable for reinput" quoting unspecified. Ours (`export ee='1'~rc=0`): dash's single quotes |
| `readonly rr=1; readonly -p \| grep " rr="` | dash, busybox-ash: `readonly rr='1'~rc=0`; bash-posix, bash-as-sh: `readonly rr="1"~rc=0`; yash-posix, yash, freebsd: `readonly rr=1~rc=0` | implementation-defined | same. Ours (`readonly rr='1'~rc=0`): dash's |
| `export 1x=3; echo after` | dash, busybox-ash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=1`; yash-posix, yash: `after~rc=0` | POSIX-defined | XCU export: a bad name is an error; exits. Ours (`rc=2`): exit 2 |
| `sh -c "kill -9 \$\$"; echo $?` | dash, bash-posix, bash-as-sh, busybox-ash: `137~rc=0`; yash-posix, yash: `393~rc=0` | implementation-defined | XCU 2.8.2: a signalled command has status above 128; the encoding is free (yash uses 256+n). Ours (`137~rc=0`): 128+n |
| `exit -1` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2`; bash-posix, bash-as-sh: `rc=255` | POSIX-undefined | XCU exit: n is an unsigned decimal integer; negative is unspecified. Ours (`rc=2`): rejected, as dash |
| `echo -n a; echo b` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `ab~rc=0`; yash-posix, yash: `-n a~b~rc=0` | implementation-defined | XCU echo: `-n` is implementation-defined for XSI systems (yash --posix prints it). Ours (`ab~rc=0`): option, as dash |
| `echo "a\tb\\c"` | dash, yash-posix, yash: `a	brc=0`; bash-posix, bash-as-sh, busybox-ash: `a\tb\c~rc=0` | implementation-defined | XCU echo: backslash escapes are XSI behaviour. Ours (`a	brc=0`): dash/XSI |
| `echo -e a` | dash, yash-posix, yash: `-e a~rc=0`; bash-posix, bash-as-sh, busybox-ash: `a~rc=0` | implementation-defined | XCU echo: `-e` is not an option; XSI echo prints it. Ours (`-e a~rc=0`): prints `-e a`, as dash |
| `printf "%s\|%d\|\n"` | dash, bash-posix, bash-as-sh, yash-posix, yash, freebsd: `\|0\|~rc=0`; busybox-ash: `\|0\|~rc=1` | POSIX-defined | XCU printf: missing arguments act as empty string or zero. busybox returns status 1: bug. Ours (`\|0\|~rc=0`): prints `|0|` |
| `printf "x\n" a b` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `x~rc=0`; freebsd: `x~rc=1` | implementation-defined | FreeBSD output differs only in `wc`/format-reuse spacing. Ours (`x~rc=0`): format reused once per argument, as dash |
| `printf "%d\n" 12abc; echo "rc=$?"` | dash, bash-posix, bash-as-sh, yash-posix, yash: `12~rc=1~rc=0`; busybox-ash: `0~rc=1~rc=0` | POSIX-defined | XCU printf: a diagnostic, non-zero status, but conversion continues with the leading digits; busybox prints 0: bug. Ours (`12~rc=1~rc=0`): 12 and status 1 |
| `printf "%*d\n" 5 3` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `    3~rc=0`; yash-posix, yash: `rc=1` | POSIX-undefined | XCU printf (Issue 8 adds `*`): older editions leave it unspecified; yash lacks it. Ours (`    3~rc=0`): supported |
| `echo "a\\b" \| { read -r x; echo "$x"; }` | dash, yash-posix, yash: `a~rc=0`; bash-posix, bash-as-sh, busybox-ash, freebsd: `a\b~rc=0` | implementation-defined | XCU echo: escapes (the input differs because `echo` differs). Ours (`a~rc=0`): dash's echo |
| `echo "a\\b" \| { read x; echo "$x"; }` | dash, yash-posix, yash: `a~rc=0`; bash-posix, bash-as-sh, busybox-ash, freebsd: `ab~rc=0` | implementation-defined | same. Ours (`a~rc=0`): dash's echo |
| `test 1 -eq 1 -a 2 -eq 2; echo $?; test 1 -eq 2 -o 2 -eq 2; echo $?; test 1 -eq 2 -a 2 -eq 2; echo $?` | dash, bash-posix, bash-as-sh, busybox-ash, yash, freebsd: `0~0~1~rc=0`; yash-posix: `2~2~2~rc=0` | POSIX-undefined | XCU test: `-a` and `-o` are obsolescent (XSI); yash --posix does not accept them. Ours (`0~0~1~rc=0`): supported |
| `test \( 1 -eq 1 \); echo $?; test \( 1 -eq 2 -o 1 -eq 1 \) -a 3 -eq 3; echo $?` | dash, bash-posix, bash-as-sh, busybox-ash, yash, freebsd: `0~0~rc=0`; yash-posix: `2~2~rc=0` | POSIX-undefined | same. Ours (`0~0~rc=0`): supported |
| `set -- -a -b x; while getopts ab: o; do echo "$o $OPTARG $OPTIND"; done` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `a  2~b x 4~rc=0`; yash-posix, yash: `a  1:2~b x 4~rc=0` | implementation-defined | XCU getopts: OPTIND is set to the index of the next argument; yash prints `1:2` (index:offset). Ours (`a  2~b x 4~rc=0`): as dash |
| `set -- -ab; while getopts ab o; do echo "$o $OPTIND"; done` | dash, busybox-ash, freebsd: `a 2~b 2~rc=0`; bash-posix, bash-as-sh: `a 1~b 2~rc=0`; yash-posix, yash: `a 1:2~b 1:3~rc=0` | POSIX-undefined | XCU getopts: OPTIND in the middle of a grouped argument is unspecified. Ours (`a 2~b 2~rc=0`): as dash (2 after the first option) |
| `getopts a o -a; echo $o $OPTIND` | dash, bash-posix, bash-as-sh, busybox-ash, freebsd: `a 2~rc=0`; yash-posix, yash: `a 1:2~rc=0` | implementation-defined | same. Ours (`a 2~rc=0`): as dash |
| `cd /nonexistent; echo "rc=$?"` | dash, busybox-ash, yash-posix, yash, freebsd: `rc=2~rc=0`; bash-posix, bash-as-sh: `rc=1~rc=0` | implementation-defined | XCU cd: non-zero status; the value is unspecified. Ours (`rc=2~rc=0`): 2, as dash |
| `touch f; cd f; echo "rc=$?"` | dash, busybox-ash, yash-posix, yash: `rc=2~rc=0`; bash-posix, bash-as-sh: `rc=1~rc=0` | implementation-defined | same. Ours (`rc=2~rc=0`): 2, as dash |
| `cd / /tmp; echo "rc=$?"` | dash, busybox-ash: `rc=0~rc=0`; bash-posix, bash-as-sh: `rc=2~rc=0`; yash-posix, yash: `rc=5~rc=0` | bug | XCU cd synopsis takes one operand; dash and busybox ignore the second, bash and yash report an error. Ours (`rc=0~rc=0`): ignores it, as dash |
| `sh -c "kill -s TERM \$\$"; echo $?` | dash, bash-posix, bash-as-sh, busybox-ash: `143~rc=0`; yash-posix, yash: `399~rc=0` | implementation-defined | XCU 2.8.2: status above 128. Ours (`143~rc=0`): 143 |
| `kill -s NOSUCH 1 2>/dev/null; echo $?` | dash, freebsd: `2~rc=0`; bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `1~rc=0` | implementation-defined | XCU kill: non-zero status for a bad signal; value unspecified. Ours (`2~rc=0`): 2, as dash |
| `times \| wc -l` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `2~rc=0`; freebsd: `       2~rc=0` | implementation-defined | XCU times: output format of the two lines. Ours (`2~rc=0`): two lines |
| `umask 999; echo "rc=$?"` | dash, busybox-ash, yash-posix, yash: `rc=2~rc=0`; bash-posix, bash-as-sh: `rc=1~rc=0` | implementation-defined | XCU umask: invalid mask is an error; status unspecified. Ours (`rc=2~rc=0`): 2, as dash |
| `1f() { :; }` | dash, yash-posix, yash: `rc=2`; bash-posix, bash-as-sh, busybox-ash: `rc=0` | POSIX-defined | XBD 3.216 Name: a function name is a name, which cannot start with a digit. bash and busybox accept it: bug in those. Ours (`rc=2`): syntax error, as dash |
| `echo ${x!}` | dash, busybox-ash, yash-posix, yash: `rc=2`; bash-posix, bash-as-sh: `rc=127` | POSIX-undefined | XCU 2.6.2: other forms of `${ }` are unspecified. Ours (`rc=2`): bad substitution (exit 2) |
| `if true; then fi` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix: `rc=2`; yash: `rc=0` | POSIX-defined | XCU 2.10: `then` needs a non-empty compound list. yash (non-POSIX mode) accepts it: bug in yash. Ours (`rc=2`): syntax error |
| `while do :; done` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix: `rc=2`; yash: `rc=124` | POSIX-defined | XCU 2.10: the condition is a non-empty compound list. Ours (`rc=2`): syntax error |
| `cat <<EOF body` | dash, busybox-ash: `bodyrc=0`; bash-posix, bash-as-sh: `body~rc=0`; yash-posix, yash: `rc=2` | POSIX-undefined | same. Ours (`body~rc=0`): same |
| `echo $((echo a); (echo b))` | dash, busybox-ash: `rc=2`; bash-posix, bash-as-sh, yash-posix, yash: `a b~rc=0` | POSIX-undefined | XCU 2.6.4: `$((` that starts a command substitution is ambiguous; applications must separate `$(` and `(`. Ours (`rc=2`): error, as dash |
| `echo $LINENO` | dash: `~rc=0`; bash-posix, bash-as-sh, yash-posix, yash: `1~rc=0`; busybox-ash: `0~rc=0` | POSIX-defined | XCU 2.5.3: LINENO is a shell variable holding the current line number. dash leaves it empty: bug in dash. Ours (`1~rc=0`): implemented |
| `i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done \| wc -l` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `2000~rc=0`; freebsd: `    2000~rc=0` | implementation-defined | same (FreeBSD `wc` padding). Ours (`2000~rc=0`): same output as the other shells |
| `cat <<EOF \| wc -l 1 2 3 4 5 EOF` | dash, bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `5~rc=0`; freebsd: `       5~rc=0` | implementation-defined | same (FreeBSD `wc` padding). Ours (`5~rc=0`): same output as the other shells |
| `f() { local x=1; echo $x; }; f; echo "[$x]"` | dash, bash-posix, bash-as-sh, busybox-ash, yash: `1~[]~rc=0`; yash-posix: `~[]~rc=0` | POSIX-undefined | not in POSIX. Ours (`1~[]~rc=0`): accepted (dash, bash, busybox, yash accept it) |
| `echo -e "a\tb"` | dash, yash-posix, yash: `-e a	b~rc=0`; bash-posix, bash-as-sh, busybox-ash: `a	b~rc=0` | implementation-defined | XCU echo (non-XSI): `-e` is an option. Ours (`-e a	b~rc=0`): prints `-e a b`, as dash |
| `[[ a = a ]] && echo yes` | dash: `rc=127`; bash-posix, bash-as-sh, busybox-ash, yash: `yes~rc=0`; yash-posix: `rc=2` | POSIX-undefined | not in POSIX. Ours (`rc=127`): `[[`: not found (127), as dash |
| `a=(1 2 3); echo ${a[1]}` | dash, busybox-ash, yash-posix: `rc=2`; bash-posix, bash-as-sh: `2~rc=0`; yash: `1~rc=0` | POSIX-undefined | not in POSIX. Ours (`rc=2`): syntax error, as dash |
| `echo $'a\tb\101\x41'` | dash: `$a	bA\x41~rc=0`; bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `a	bAA~rc=0` | POSIX-defined | XCU 2.2.4 (Issue 8): Dollar-Single-Quotes. dash 0.5.12 does not implement it. Ours (`a	bAA~rc=0`): implemented |
| `[ a == a ]; echo $?` | dash: `2~rc=0`; bash-posix, bash-as-sh, busybox-ash, yash-posix, yash: `0~rc=0` | POSIX-undefined | XCU test: only `=` is specified. Ours (`0~rc=0`): accepted |
| `function f { echo hi; }; f` | dash, yash-posix: `rc=2`; bash-posix, bash-as-sh, busybox-ash, yash: `hi~rc=0` | POSIX-undefined | not in POSIX. Ours (`rc=2`): syntax error, as dash |
| `echo "echo s" > s; source ./s` | dash, yash-posix, yash: `rc=127`; bash-posix, bash-as-sh, busybox-ash: `s~rc=0` | POSIX-undefined | not in POSIX. Ours (`rc=127`): not found (127), as dash |
| `x=abc; echo ${x/b/X}` | dash, yash-posix: `rc=2`; bash-posix, bash-as-sh, busybox-ash, yash: `aXc~rc=0` | POSIX-undefined | not in POSIX. Ours (`rc=2`): bad substitution, as dash |
| `x=abcdef; echo ${x:1:2}` | dash, yash-posix, yash: `rc=2`; bash-posix, bash-as-sh, busybox-ash: `bc~rc=0` | POSIX-undefined | not in POSIX. Ours (`rc=2`): bad substitution, as dash |
| `cat <(echo hi)` | dash, yash-posix: `rc=2`; bash-posix, bash-as-sh, busybox-ash, yash: `hi~rc=0` | POSIX-undefined | not in POSIX. Ours (`rc=2`): syntax error, as dash |
| `cat <<< hi` | dash, busybox-ash, yash-posix: `rc=2`; bash-posix, bash-as-sh, yash: `hi~rc=0` | POSIX-undefined | not in POSIX. Ours (`rc=2`): syntax error, as dash |
| `echo ${RANDOM:+set}` | dash, yash-posix: `~rc=0`; bash-posix, bash-as-sh, busybox-ash, yash: `set~rc=0` | POSIX-undefined | not in POSIX. Ours (`~rc=0`): unset, as dash |

# DEVIATIONS FROM THE GOLD STANDARD

Decision 0009: when dash and FreeBSD sh agree, so do we, unless there is a written reason. The reasons so far, with the POSIX.1-2024 citation:

| Behaviour | dash | FreeBSD sh | Ours | Why |
|---|---|---|---|---|
| `trap` with no operands in a subshell | prints nothing | prints nothing | the parent's traps (until the subshell sets that condition) | XCU trap: "when `trap` is invoked in a subshell ... shall report the traps of the parent shell"; bash and yash do this. Category: bug in the other shells (POSIX-defined, Issue 8) |
| `trap -l` | `Illegal option -l` | lists the signals | lists the signals, one per line | XCU trap (Issue 8) adds `-l`; dash has not caught up |
| `$'...'` | literal | literal | C-style escapes | XCU 2.2.4 (Issue 8) |
| `set -o pipefail` | no effect | accepted | works | XCU set (Issue 8) |
| an assignment error before an external command (`readonly a=; a=x cat`) | exits (status 2) | continues | exits (status 2) | XCU 2.8.1: a variable assignment error shall exit a non-interactive shell; dash and POSIX agree, FreeBSD sh is the odd one out |
| an arithmetic constant outside 64 bits | saturates | error | saturates | POSIX leaves it undefined; dash followed |
| `OPTARG` after an option that takes no argument | set to empty | unset | unset | XCU getopts: OPTARG is unset; POSIX decides (dash and FreeBSD sh disagree) |
| `umask a b` | ignores `b` | error | error | XCU umask takes one operand; dash and FreeBSD sh disagree, POSIX decides |
| `printf '%#g' 999999.5` | `1.e+06` | `1.00000e+06` | `1.00000e+06` | C says the exponent form keeps the precision; glibc deviates (our output is exact for every other value) |

The cases marked P or recorded as varying in `test/test_sh.sh` (129 in all) carry the same classification in the table above.

# INTERACTIVE USE (milestone 2)

Hand-maintained (the table above is generated). Gold standard: dash and FreeBSD sh agree, so that is what we do; where they differ POSIX, then dash, decides.

| Behaviour | dash | FreeBSD sh | Ours | Why |
|---|---|---|---|---|
| `jobs` column of the command | 33 columns | 30 | 33 (dash) | POSIX leaves the layout open; dash |
| `jobs` order | current job first, then newest first | oldest first | dash's | POSIX leaves it open |
| marker of a finished job in `jobs` | `+`/`-` | blank | `+`/`-` (dash) | POSIX 2024 `jobs`: the current/previous marker is part of the format |
| `jobs -l` for a pipeline | one line per process, text ends in `\|` | one line per process, no `\|` | dash's | open |
| `fg`, `bg` with no job | `No current job` | same | same | agree |
| `wait %9` for a missing job | error, status 127 | silent | error (dash) | POSIX: unspecified |
| `set -m` without a terminal in a script | error | accepted | accepted | POSIX 2024 `set -m`: job control is enabled; no terminal is needed for process groups |
| `fc` | not provided | provided, `%5d `-formatted | FreeBSD's | dash lacks it; POSIX requires `fc` |
| `history`, `!` expansion | absent | absent | absent | not POSIX |
| `kill %n` on a stopped job | SIGTERM stays pending until continued | same | same | agree |
| default editing mode | none (no libedit) | emacs-style (libedit) | emacs; `set -o vi` is POSIX vi mode | POSIX `set -o vi`; FreeBSD for the default |
| ESC followed at once by a key in vi mode | n/a | libedit | ESC then the key | terminals cannot tell Alt from a fast typist |

# Choices made when dash and FreeBSD sh disagree (corpus work)

Where dash and FreeBSD sh agree we agree (the gold standard rule). These are the places the third-party corpora showed them disagreeing, with what `sh` does and why (POSIX decides; where POSIX is silent we follow dash, and say so).

| Case | dash | FreeBSD sh | `sh` | Reason |
|------|------|------------|------|--------|
| `cd BAD/..` | succeeds (normalises the path) | fails | fails | POSIX.1-2024 cd step 8: a dot-dot after a component that is not a directory is an error |
| `cd -` with `OLDPWD` unset | stays in the current directory, status 0 | fails, status 2 | as dash | POSIX leaves it unspecified: dash |
| `exec -- cmd` | `--: not found` | runs cmd | runs cmd | utility syntax guideline 10: `--` ends the options |
| `trap - SIGINT`, `trap cmd SIGHUP` | bad trap | accepted | accepted | the `SIG` prefix is common practice (POSIX.1-2024 allows it for `kill -s`) |
| `trap term TERM` where `term` is a function name | action `term` | action `term` | action `term` | only an unsigned integer (or `-`, or a lone condition name such as `trap EXIT`) makes every operand a condition (POSIX trap) |
| `command -v ./file` / `type ./file` for a non-executable file | reports it | refuses | refuses | `command -v` names what the shell would run |
| a hashed command whose file disappeared | stale entry, status 127 | searches `PATH` again | searches again | POSIX leaves the cache unspecified; the stale entry only produces confusing failures |
| `ulimit -f` with a value that overflows once scaled | wraps silently | `bad number` | `bad number`, status 2 | a wrapped limit is wrong |
| `printf '%z'` (invalid directive) | status 2 | status 1 | status 2 | POSIX: non-zero; dash |
| a builtin whose output cannot be written (`type x > /dev/full`) | status 1 | status 2 | status 1 | POSIX: non-zero; dash |
| `99>file`, `>&99` (descriptors above 9) | `99` is a word; `>&99` is "Bad fd number" and ends the shell | same | same | POSIX leaves descriptors above 9 unspecified; both shells agree |
| `3>&3` with 3 closed | no-op | no-op | no-op | agree; the old code refused it |
| `sh +c cmd` | runs cmd | runs cmd | runs cmd | agree; POSIX does not define `+c` |
| `kill %%`, `wait %%` in a non-interactive shell | not supported | supported | supported | job specifiers need only the job table |
| `kill -n 9 pid` | not supported | not supported | supported | POSIX.1-2024 adds `kill -n signum` |
| a signal ignored on entry (`trap '' INT` in the parent) then `trap - INT` or `trap cmd INT` | silently has no effect | silently has no effect | silently has no effect (also for SIGPIPE, which the Zig runtime used to reset) | POSIX 2.15 trap: "cannot be trapped or reset", no error need be reported; an interactive shell keeps the ignore too |

# REPRODUCING

    sh test/test_sh.sh                       # run the suite (zig build -Dcommands=sh first)
    SH_DOC_OUT=rows.md sh test/test_sh.sh    # collect the differing cases
    SHCMP_MATRIX=1 sh test/test_sh.sh        # print the per-shell agreement of every case

Shells that are not installed are skipped. To add one, append a `name|command|args` entry to `shcmp_detect` in test/shcmp.sh.
