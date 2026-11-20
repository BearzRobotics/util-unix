# NAME

sh-diagnostics - catalog of the diagnostics of sh

# DESCRIPTION

Every message of sh has a stable code `SHxxxx`. This file is generated from `src/lib/sh/diag.zig` (`sh --diagnostics-catalog`); `sh --explain SHxxxx` prints one entry. Groups: 1xxx syntax, 2xxx expansion and arithmetic, 3xxx redirection, 4xxx execution, 5xxx builtins, 6xxx invocation. The exit status is POSIX's (2 for syntax errors and fatal expansion errors, 126 and 127 for exec).

# SUMMARY

| Code | Kind | Status | Meaning |
|------|------|--------|---------|
| SH1001 | unexpected_token | 2 | A token appeared where the grammar does not allow it |
| SH1002 | unterminated_quote | 2 | A quote is not closed before the end of the input |
| SH1003 | unterminated_heredoc | 0 | A here-document ends at the end of the input, not at its delimiter |
| SH1004 | unterminated_command_substitution | 2 | A `$(` has no matching `)` |
| SH1005 | unterminated_arithmetic | 2 | A `$((` has no matching `))` |
| SH1006 | bad_substitution | 2 | A `${...}` has an operator the shell does not know |
| SH1007 | mismatched_closer | 2 | A token other than the expected closer ends a compound command |
| SH1008 | bad_for_variable | 2 | The `for` variable is not a valid name |
| SH1009 | bad_function_name | 2 | The function name is not a valid name |
| SH1010 | missing_redirect_target | 2 | A redirection operator has no file name |
| SH2001 | division_by_zero | 2 | Division or remainder by zero in arithmetic |
| SH2002 | arithmetic_syntax | 2 | Malformed arithmetic expression |
| SH2003 | illegal_number | 2 | A value that must be a number is not one |
| SH2004 | unset_variable | 2 | A variable is unset while `set -u` is in effect |
| SH2005 | parameter_error | 2 | `${name?message}` found the variable unset or null |
| SH2006 | cannot_assign | 2 | `${name=word}` on something that is not a variable |
| SH2007 | readonly_assignment | 2 | Assignment to or unsetting of a read-only variable |
| SH3001 | cannot_open | 2 | A file for input redirection cannot be opened |
| SH3002 | cannot_create | 2 | A file for output redirection cannot be created |
| SH3003 | bad_fd | 2 | A descriptor in a duplication is not open |
| SH3004 | noclobber | 2 | `set -C` refuses to overwrite an existing file |
| SH3005 | bad_fd_number | 2 | The word after `>&` or `<&` is neither a number nor `-` |
| SH4001 | not_found | 127 | The command was not found |
| SH4002 | not_executable | 126 | The file was found but cannot be executed |
| SH4003 | cannot_fork | 2 | A process or pipe could not be created |
| SH4004 | cannot_open_script | 127 | The script file named on the command line cannot be opened |
| SH4005 | errexit_exit | 0 | `set -e` ended the shell after a failing command (note, rich and json styles only) |
| SH5001 | illegal_option | 2 | A builtin was given an option it does not have |
| SH5002 | cannot_shift | 2 | `shift` was asked to drop more parameters than exist |
| SH5003 | cannot_cd | 2 | `cd` could not change directory |
| SH5004 | bad_trap | 1 | `trap` names a signal that does not exist |
| SH5005 | bad_variable_name | 2 | A builtin was given something that is not a variable name |
| SH5006 | test_error | 2 | `test` or `[` could not parse its arguments |
| SH5007 | printf_number | 1 | A `printf` numeric conversion got a non-number |
| SH5008 | kill_error | 2 | `kill` was given a bad signal or pid |
| SH5009 | usage | 2 | A builtin was called with the wrong number of arguments |
| SH5010 | io_error | 1 | Writing to standard output failed |
| SH5011 | alias_not_found | 1 | `alias` or `unalias` named an alias that is not defined |
| SH5012 | bad_limit | 2 | `ulimit` could not read or set the limit |
| SH5013 | not_in_function | 2 | `local` was used outside a function |
| SH6001 | invocation_option | 2 | `sh` was started with an option it does not have |
| SH6002 | missing_argument | 2 | `sh -c` or `-o` needs an argument |
| SH7001 | lint_unquoted_expansion | 1 | An unquoted expansion is split into words and globbed |
| SH7002 | lint_cd_unchecked | 1 | `cd` result is not checked |
| SH7003 | lint_rm_variable | 1 | `rm -r` on a path built from a variable that may be empty |
| SH7004 | lint_double_bracket | 1 | `[[ ]]` is not POSIX |
| SH7005 | lint_function_keyword | 1 | The `function` keyword is not POSIX |
| SH7006 | lint_source | 1 | `source` is not POSIX |
| SH7007 | lint_local | 1 | `local` is not POSIX |
| SH7008 | lint_echo_option | 1 | `echo -e`/`-E` is not portable |
| SH7009 | lint_double_equals | 1 | `==` in `[` is not POSIX |
| SH9000 | other | 0 | Any other message |

# SHELLCHECK MAPPING

The nearest ShellCheck id of each code that has one (a pointer for readers who know that tool, verified by running `shellcheck -s dash` on the bad example of the entry; only the numbers are referenced, the messages are our own). The JSON diagnostic has the same value in its `shellcheck` field, `sh --explain` prints it, `sh --list-diagnostics --diagnostics=json` lists it.

| Code | Kind | ShellCheck |
|------|------|------------|
| SH1001 | unexpected_token | SC1089 |
| SH1002 | unterminated_quote | SC1073 |
| SH1003 | unterminated_heredoc | SC1044 |
| SH1004 | unterminated_command_substitution | SC1073 |
| SH1005 | unterminated_arithmetic | SC1073 |
| SH1007 | mismatched_closer | SC1061 |
| SH1008 | bad_for_variable | SC1073 |
| SH1010 | missing_redirect_target | SC1073 |
| SH2002 | arithmetic_syntax | SC1102 |
| SH2004 | unset_variable | SC2154 |
| SH3005 | bad_fd_number | SC3021 |
| SH5013 | not_in_function | SC2168 |
| SH7001 | lint_unquoted_expansion | SC2086 |
| SH7002 | lint_cd_unchecked | SC2164 |
| SH7003 | lint_rm_variable | SC2115 |
| SH7004 | lint_double_bracket | SC3010 |
| SH7005 | lint_function_keyword | SC2112 |
| SH7006 | lint_source | SC3046 |
| SH7007 | lint_local | SC3043 |
| SH7008 | lint_echo_option | SC3037 |
| SH7009 | lint_double_equals | SC3014 |

# ENTRIES

## SH1001 unexpected_token

The parser met a token that cannot start or continue the construct being read, for example a stray `)`, `;;` or `fi`. POSIX XCU 2.10 gives the grammar; a command may not begin with a reserved word such as `then`, `fi` or `done`.

Bad:

    echo )

Good:

    echo ')'

dash says: `Syntax error: ")" unexpected`

## SH1002 unterminated_quote

A single quote, double quote or backquote was opened and the input ended before the matching one. Everything after it is part of the quoted text, so the whole rest of the script is consumed.

Bad:

    echo 'abc

Good:

    echo 'abc'

dash says: `Syntax error: Unterminated quoted string`

## SH1003 unterminated_heredoc

POSIX XCU 2.7.4 ends a here-document at a line containing only the delimiter. Reaching the end of the input first is accepted with a warning, as in dash and bash.

Bad:

    cat <<EOF
    body

Good:

    cat <<EOF
    body
    EOF

dash says: `warning: here-document at line 1 delimited by end-of-file (wanted `EOF')`

## SH1004 unterminated_command_substitution

A command substitution `$(...)` was opened and the input ended before its closing parenthesis.

Bad:

    echo $(date

Good:

    echo $(date)

dash says: `Syntax error: end of file unexpected (expecting ")")`

## SH1005 unterminated_arithmetic

An arithmetic expansion `$((...))` needs the closing `))`. Text that opens with `$((` but never closes it is an error here, as in dash.

Bad:

    echo $((1+2)

Good:

    echo $((1+2))

dash says: `Syntax error: Missing '))'`

## SH1006 bad_substitution

Only the parameter expansion forms of POSIX XCU 2.6.2 are accepted; bash extensions such as substring and replacement are rejected.

Bad:

    echo ${x/a/b}

Good:

    echo "$x" | sed 's/a/b/'

dash says: `Bad substitution`

## SH1007 mismatched_closer

A compound command (`if`, `while`, `until`, `for`, `case`, `{`, `(`) must end with its own closing keyword. The message names the keyword that was expected and where the construct started.

Bad:

    while true; do
      echo x
    fi

Good:

    while true; do
      echo x
    done

dash says: `Syntax error: "fi" unexpected (expecting "done")`

## SH1008 bad_for_variable

The word after `for` must be a name (POSIX XBD 3.216).

Bad:

    for 1x in a; do :; done

Good:

    for x1 in a; do :; done

dash says: `Syntax error: Bad for loop variable`

## SH1009 bad_function_name

A function definition `name() body` needs a POSIX name.

Bad:

    1f() { :; }

Good:

    f1() { :; }

dash says: `Syntax error: Bad function name`

## SH1010 missing_redirect_target

Every redirection operator is followed by a word naming a file, a descriptor or a here-document delimiter.

Bad:

    echo >

Good:

    echo > file

dash says: `Syntax error: newline unexpected`

## SH2001 division_by_zero

POSIX XCU 2.6.4 evaluates $(( )) as signed C integers; dividing by zero is an error and a non-interactive shell exits with status 2.

Bad:

    echo $((1/0))

Good:

    [ "$d" -ne 0 ] && echo $((1/d))

dash says: `arithmetic expression: division by zero: "1/0"`

## SH2002 arithmetic_syntax

The expression inside $(( )) does not parse: a missing operand, an unknown operator, a bad octal digit or trailing text.

Bad:

    echo $((1+))

Good:

    echo $((1+1))

dash says: `arithmetic expression: expecting primary: "1+"`

## SH2003 illegal_number

A variable used in arithmetic, or an argument of a builtin such as `exit`, `shift` or `test -eq`, was not an integer.

Bad:

    x=abc; echo $((x+1))

Good:

    x=3; echo $((x+1))

dash says: `Illegal number: abc`

## SH2004 unset_variable

With `set -u` (nounset), expanding an unset parameter other than `@` or `*` is an error (POSIX XCU 2.6.2, 'set -u').

Bad:

    set -u; echo $x

Good:

    set -u; echo ${x-}

dash says: `x: parameter not set`

## SH2005 parameter_error

The `?` form of parameter expansion writes the message to standard error and a non-interactive shell exits (POSIX XCU 2.6.2).

Bad:

    echo ${x?need x}

Good:

    x=1; echo ${x?need x}

dash says: `x: need x`

## SH2006 cannot_assign

The `=` form assigns to a variable; `$1`, `$@` and the other special parameters are not variables.

Bad:

    echo ${1=x}

Good:

    set -- x

dash says: `1: cannot assign in this way`

## SH2007 readonly_assignment

A variable marked `readonly` can no longer be assigned or unset; a non-interactive shell exits (POSIX XCU 2.8.1).

Bad:

    readonly r=1; r=2

Good:

    r=1; r=2

dash says: `r: is read only`

## SH3001 cannot_open

`< file`, `<> file` or `.` could not open the file. The command is not run and its status is 2 (a redirection error before a special builtin exits a non-interactive shell).

Bad:

    cat < missing.txt

Good:

    cat < /etc/hostname

dash says: `cannot open missing.txt: No such file`

## SH3002 cannot_create

`> file` or `>> file` could not create or open the file for writing.

Bad:

    echo x > /nonexistent/f

Good:

    echo x > ./f

dash says: `cannot create /nonexistent/f: Directory nonexistent`

## SH3003 bad_fd

`n>&m` and `n<&m` need `m` to be open (POSIX XCU 2.7.6).

Bad:

    echo hi >&9

Good:

    exec 9>&1; echo hi >&9

dash says: `9: Bad file descriptor`

## SH3004 noclobber

With noclobber `>` does not truncate an existing regular file (POSIX XCU 2.7.2).

Bad:

    set -C; echo a > f; echo b > f

Good:

    set -C; echo a > f; echo b >| f

dash says: `cannot create f: File exists`

## SH3005 bad_fd_number

Duplication redirections take a descriptor number or `-` (POSIX XCU 2.7.5, 2.7.6).

Bad:

    echo hi >&file

Good:

    echo hi >file

dash says: `Syntax error: Bad fd number`

## SH4001 not_found

Neither a function, a builtin nor an executable file of that name exists in PATH. The exit status is 127 (POSIX XCU 2.8.2).

Bad:

    nosuchcommand

Good:

    ls

dash says: `nosuchcommand: not found`

## SH4002 not_executable

The file exists but is not executable, or is a directory. The exit status is 126.

Bad:

    ./notexecutable

Good:

    chmod +x notexecutable && ./notexecutable

dash says: `./notexecutable: Permission denied`

## SH4003 cannot_fork

fork(2) or pipe(2) failed, usually because of a resource limit.

Bad:

    (ulimit -n 3; : | :)

Good:

    (: | :)

dash says: `Pipe call failed`

## SH4004 cannot_open_script

`sh file` could not read the file; the exit status is 127.

Bad:

    sh nosuch.sh

Good:

    sh ./script.sh

dash says: `Can't open nosuch.sh`

## SH4005 errexit_exit

POSIX XCU 2.14 `set -e`: a failing command that is not part of a condition, an `&&`/`||` list (except the last) or a negated pipeline ends the shell with that command's status. This note names the command and line; it is never printed in the posix style, and never changes the exit status.

Bad:

    set -e
    false
    echo unreachable

Good:

    set -e
    false || :
    echo reachable

dash says: `(none: dash exits silently)`

## SH5001 illegal_option

A special builtin that gets an invalid option makes a non-interactive shell exit (POSIX XCU 2.8.1).

Bad:

    set -Z

Good:

    set -e

dash says: `set: Illegal option -Z`

## SH5002 cannot_shift

`shift n` requires n <= `$#` (POSIX XCU 2.14, shift).

Bad:

    set -- a; shift 2

Good:

    set -- a; shift

dash says: `shift: can't shift that many`

## SH5003 cannot_cd

`cd` failed; the status is non-zero and the directory is unchanged.

Bad:

    cd /nonexistent

Good:

    cd /

dash says: `cd: can't cd to /nonexistent`

## SH5004 bad_trap

The condition after the action is neither EXIT, a signal name nor a signal number.

Bad:

    trap : NOSUCH

Good:

    trap : TERM

dash says: `trap: NOSUCH: bad trap`

## SH5005 bad_variable_name

`export`, `readonly`, `local` and `read` take names (POSIX XBD 3.216).

Bad:

    export 1x=3

Good:

    export x1=3

dash says: `export: 1x: bad variable name`

## SH5006 test_error

The arguments are not a valid `test` expression (POSIX XCU test, argument-count rules).

Bad:

    [ a b ]

Good:

    [ a = b ]

dash says: `[: a: unexpected operator`

## SH5007 printf_number

`%d`, `%x` and friends need numeric arguments; the status is 1 but printing continues.

Bad:

    printf '%d\n' abc

Good:

    printf '%s\n' abc

dash says: `printf: abc: expected numeric value`

## SH5008 kill_error

The signal name/number or the process id is invalid, or the process does not exist.

Bad:

    kill -s NOSUCH 1

Good:

    kill -s TERM 1

dash says: `kill: invalid signal number or name: NOSUCH`

## SH5009 usage

The builtin needs more operands than it got.

Bad:

    getopts a

Good:

    getopts a opt

dash says: `getopts: usage: getopts optstring var [arg]`

## SH5010 io_error

A builtin could not write its output (closed descriptor, full disk).

Bad:

    echo hi >&-

Good:

    echo hi

dash says: `echo: echo: I/O error`

## SH5011 alias_not_found

Aliases are looked up by exact name.

Bad:

    unalias nosuch

Good:

    alias ll='ls -l'; unalias ll

dash says: `unalias: nosuch: not found`

## SH5012 bad_limit

getrlimit/setrlimit failed.

Bad:

    ulimit -n 2000000000

Good:

    ulimit -n 256

dash says: `ulimit: error setting limit (Operation not permitted)`

## SH5013 not_in_function

`local` is not in POSIX; where available it is only valid in a function body.

Bad:

    local x=1

Good:

    f() { local x=1; }

dash says: `local: not in a function`

## SH6001 invocation_option

The command line options are those of POSIX `sh`: -a -b -C -e -f -h -i -m -n -u -v -x, -c, -s, -o and +o.

Bad:

    sh -Z

Good:

    sh -e

dash says: `Illegal option -Z`

## SH6002 missing_argument

`sh -c` requires the command string as the next operand.

Bad:

    sh -c

Good:

    sh -c 'echo hi'

dash says: `-c requires an argument`

## SH7001 lint_unquoted_expansion

Unquoted `$name` and `$(cmd)` results undergo field splitting and pathname expansion (POSIX XCU 2.6.5, 2.6.6), so a value with spaces or `*` becomes several arguments.

Bad:

    rm $file

Good:

    rm "$file"

dash says: `(none)`

## SH7002 lint_cd_unchecked

If `cd` fails the following commands run in the current directory, which is how scripts delete the wrong files.

Bad:

    cd /build
    rm -rf ./*

Good:

    cd /build || exit 1
    rm -rf ./*

dash says: `(none)`

## SH7003 lint_rm_variable

`rm -rf "$dir/"` becomes `rm -rf /` when `dir` is empty or unset.

Bad:

    rm -rf "$dir/"

Good:

    rm -rf "${dir:?}/"

dash says: `(none)`

## SH7004 lint_double_bracket

POSIX has `[` and `test` only; `[[` fails with `[[: not found` in dash.

Bad:

    [[ $a = b ]]

Good:

    [ "$a" = b ]

dash says: `[[: not found`

## SH7005 lint_function_keyword

POSIX XCU 2.9.5 defines functions with `name ( ) compound-command`.

Bad:

    function f { :; }

Good:

    f() { :; }

dash says: `function: not found`

## SH7006 lint_source

POSIX XCU 2.15 defines the dot utility only.

Bad:

    source ./lib.sh

Good:

    . ./lib.sh

dash says: `source: not found`

## SH7007 lint_local

POSIX has no function-local variables; dash, bash and busybox implement `local` with different details.

Bad:

    f() { local x=1; }

Good:

    f() ( x=1; : )

dash says: `(accepted)`

## SH7008 lint_echo_option

POSIX XCU echo: `-e` is not an option; implementations that follow XSI print `-e a` literally.

Bad:

    echo -e "a\tb"

Good:

    printf 'a\tb\n'

dash says: `(prints -e)`

## SH7009 lint_double_equals

POSIX test defines `=` and `!=` for string comparison.

Bad:

    [ "$a" == b ]

Good:

    [ "$a" = b ]

dash says: `[: a: unexpected operator`

## SH9000 other

A message the shell does not classify; the text is dash's.

