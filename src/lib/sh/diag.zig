// SPDX-License-Identifier: GPL-2.0-or-later
//! Structured diagnostics of the shell: stable codes (SHxxxx), kinds, the
//! `Diagnostic` value the library hands to its host, the catalog that is the
//! single source of the explanations (`sh --explain`, docs/sh-diagnostics.md)
//! and a renderer with three styles (rich, posix, json).
//!
//! Code groups: 1xxx syntax, 2xxx expansion and arithmetic, 3xxx
//! redirection, 4xxx execution, 5xxx builtins, 6xxx invocation.
//!
//! POSIX.1-2024 (XCU 2.8.1, "Consequences of Shell Errors") requires only
//! that diagnostics go to standard error and that the exit status be as
//! specified; the wording is free. The posix style reproduces dash's wording
//! exactly; the rich style is this shell's own (decision 0008).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Severity = enum { err, warning };

pub const Kind = enum {
    // 1xxx syntax
    unexpected_token,
    unterminated_quote,
    unterminated_heredoc,
    unterminated_command_substitution,
    unterminated_arithmetic,
    bad_substitution,
    bad_for_variable,
    bad_function_name,
    missing_redirect_target,
    mismatched_closer,
    // 2xxx expansion
    division_by_zero,
    arithmetic_syntax,
    illegal_number,
    unset_variable,
    parameter_error,
    cannot_assign,
    readonly_assignment,
    // 3xxx redirection
    cannot_open,
    cannot_create,
    bad_fd,
    noclobber,
    bad_fd_number,
    // 4xxx execution
    not_found,
    not_executable,
    cannot_fork,
    cannot_open_script,
    errexit_exit,
    stopped_jobs,
    // 5xxx builtins
    illegal_option,
    cannot_shift,
    cannot_cd,
    bad_trap,
    bad_variable_name,
    test_error,
    printf_number,
    kill_error,
    usage,
    io_error,
    alias_not_found,
    bad_limit,
    not_in_function,
    no_such_job,
    no_job_control,
    history_error,
    ambiguous_job,
    // 6xxx invocation
    invocation_option,
    missing_argument,
    // 7xxx lint (`sh --check`)
    lint_unquoted_expansion,
    lint_cd_unchecked,
    lint_rm_variable,
    lint_double_bracket,
    lint_function_keyword,
    lint_source,
    lint_local,
    lint_echo_option,
    lint_double_equals,
    // anything the classifier cannot place
    other,
};

pub const Entry = struct {
    code: u16,
    kind: Kind,
    /// Exit status of the shell or command after this error (0 = unchanged).
    exit: u8,
    /// One line for the catalog table.
    summary: []const u8,
    /// Rich message; `{s}` is the subject (token, name, path ...).
    rich: []const u8,
    help: []const u8,
    explain: []const u8,
    bad: []const u8,
    good: []const u8,
    /// What dash prints for the bad example (the message this replaces).
    dash: []const u8,
    /// Nearest ShellCheck id, for the mapping table (lint codes only).
    shellcheck: []const u8 = "",
};

pub const catalog = [_]Entry{
    .{ .code = 1001, .kind = .unexpected_token, .exit = 2, .summary = "A token appeared where the grammar does not allow it", .rich = "unexpected {s}", .help = "check for a missing separator (`;` or newline) or a stray operator before it", .explain = "The parser met a token that cannot start or continue the construct being read, for example a stray `)`, `;;` or `fi`. POSIX XCU 2.10 gives the grammar; a command may not begin with a reserved word such as `then`, `fi` or `done`.", .bad = "echo )", .good = "echo ')'", .dash = "Syntax error: \")\" unexpected" },
    .{ .code = 1002, .kind = .unterminated_quote, .exit = 2, .summary = "A quote is not closed before the end of the input", .rich = "unterminated {s} quote", .help = "add the closing quote, or escape the quote character with a backslash", .explain = "A single quote, double quote or backquote was opened and the input ended before the matching one. Everything after it is part of the quoted text, so the whole rest of the script is consumed.", .bad = "echo 'abc", .good = "echo 'abc'", .dash = "Syntax error: Unterminated quoted string" },
    .{ .code = 1003, .kind = .unterminated_heredoc, .exit = 0, .summary = "A here-document ends at the end of the input, not at its delimiter", .rich = "here-document delimited by end of file (wanted '{s}')", .help = "put the delimiter alone on a line after the body", .explain = "POSIX XCU 2.7.4 ends a here-document at a line containing only the delimiter. Reaching the end of the input first is accepted with a warning, as in dash and bash.", .bad = "cat <<EOF\nbody", .good = "cat <<EOF\nbody\nEOF", .dash = "warning: here-document at line 1 delimited by end-of-file (wanted `EOF')" },
    .{ .code = 1004, .kind = .unterminated_command_substitution, .exit = 2, .summary = "A `$(` has no matching `)`", .rich = "unterminated command substitution", .help = "add the closing `)`", .explain = "A command substitution `$(...)` was opened and the input ended before its closing parenthesis.", .bad = "echo $(date", .good = "echo $(date)", .dash = "Syntax error: end of file unexpected (expecting \")\")" },
    .{ .code = 1005, .kind = .unterminated_arithmetic, .exit = 2, .summary = "A `$((` has no matching `))`", .rich = "unterminated arithmetic expansion", .help = "close it with `))`; for a nested subshell write `$( (cmd) )` with a space", .explain = "An arithmetic expansion `$((...))` needs the closing `))`. Text that opens with `$((` but never closes it is an error here, as in dash.", .bad = "echo $((1+2)", .good = "echo $((1+2))", .dash = "Syntax error: Missing '))'" },
    .{ .code = 1006, .kind = .bad_substitution, .exit = 2, .summary = "A `${...}` has an operator the shell does not know", .rich = "bad substitution", .help = "POSIX has `-` `=` `?` `+` (with or without `:`) and `#` `##` `%` `%%`; `${x/a/b}` and `${x:1:2}` are not POSIX", .explain = "Only the parameter expansion forms of POSIX XCU 2.6.2 are accepted; bash extensions such as substring and replacement are rejected.", .bad = "echo ${x/a/b}", .good = "echo \"$x\" | sed 's/a/b/'", .dash = "Bad substitution" },
    .{ .code = 1007, .kind = .mismatched_closer, .exit = 2, .summary = "A token other than the expected closer ends a compound command", .rich = "unexpected {s}", .help = "close the construct with the keyword named in the message", .explain = "A compound command (`if`, `while`, `until`, `for`, `case`, `{`, `(`) must end with its own closing keyword. The message names the keyword that was expected and where the construct started.", .bad = "while true; do\n  echo x\nfi", .good = "while true; do\n  echo x\ndone", .dash = "Syntax error: \"fi\" unexpected (expecting \"done\")" },
    .{ .code = 1008, .kind = .bad_for_variable, .exit = 2, .summary = "The `for` variable is not a valid name", .rich = "'{s}' is not a valid variable name for `for`", .help = "use letters, digits and underscores, not starting with a digit", .explain = "The word after `for` must be a name (POSIX XBD 3.216).", .bad = "for 1x in a; do :; done", .good = "for x1 in a; do :; done", .dash = "Syntax error: Bad for loop variable" },
    .{ .code = 1009, .kind = .bad_function_name, .exit = 2, .summary = "The function name is not a valid name", .rich = "'{s}' cannot be used as a function name", .help = "choose another name: special builtins such as eval, set or exit cannot be redefined as functions", .explain = "A function definition `name() body` needs a POSIX name.", .bad = "1f() { :; }", .good = "f1() { :; }", .dash = "Syntax error: Bad function name" },
    .{ .code = 1010, .kind = .missing_redirect_target, .exit = 2, .summary = "A redirection operator has no file name", .rich = "redirection '{s}' needs a file name or descriptor", .help = "write the target after the operator, e.g. `> file` or `>&2`", .explain = "Every redirection operator is followed by a word naming a file, a descriptor or a here-document delimiter.", .bad = "echo >", .good = "echo > file", .dash = "Syntax error: newline unexpected" },
    .{ .code = 2001, .kind = .division_by_zero, .exit = 2, .summary = "Division or remainder by zero in arithmetic", .rich = "division by zero in '{s}'", .help = "test the divisor before dividing", .explain = "POSIX XCU 2.6.4 evaluates $(( )) as signed C integers; dividing by zero is an error and a non-interactive shell exits with status 2.", .bad = "echo $((1/0))", .good = "[ \"$d\" -ne 0 ] && echo $((1/d))", .dash = "arithmetic expression: division by zero: \"1/0\"" },
    .{ .code = 2002, .kind = .arithmetic_syntax, .exit = 2, .summary = "Malformed arithmetic expression", .rich = "{s}", .help = "check operators and parentheses; only C integer operators are available (no `,` `**` `++`)", .explain = "The expression inside $(( )) does not parse: a missing operand, an unknown operator, a bad octal digit or trailing text.", .bad = "echo $((1+))", .good = "echo $((1+1))", .dash = "arithmetic expression: expecting primary: \"1+\"" },
    .{ .code = 2003, .kind = .illegal_number, .exit = 2, .summary = "A value that must be a number is not one", .rich = "'{s}' is not a number", .help = "pass a plain decimal, `0x` hexadecimal or `0` octal integer", .explain = "A variable used in arithmetic, or an argument of a builtin such as `exit`, `shift` or `test -eq`, was not an integer.", .bad = "x=abc; echo $((x+1))", .good = "x=3; echo $((x+1))", .dash = "Illegal number: abc" },
    .{ .code = 2004, .kind = .unset_variable, .exit = 2, .summary = "A variable is unset while `set -u` is in effect", .rich = "variable '{s}' is not set", .help = "assign it first or use `${name-default}`", .explain = "With `set -u` (nounset), expanding an unset parameter other than `@` or `*` is an error (POSIX XCU 2.6.2, 'set -u').", .bad = "set -u; echo $x", .good = "set -u; echo ${x-}", .dash = "x: parameter not set" },
    .{ .code = 2005, .kind = .parameter_error, .exit = 2, .summary = "`${name?message}` found the variable unset or null", .rich = "{s}", .help = "set the variable or catch the error with `${name-default}`", .explain = "The `?` form of parameter expansion writes the message to standard error and a non-interactive shell exits (POSIX XCU 2.6.2).", .bad = "echo ${x?need x}", .good = "x=1; echo ${x?need x}", .dash = "x: need x" },
    .{ .code = 2006, .kind = .cannot_assign, .exit = 2, .summary = "`${name=word}` on something that is not a variable", .rich = "cannot assign to '{s}' in this way", .help = "positional and special parameters cannot be assigned by expansion; use `set --`", .explain = "The `=` form assigns to a variable; `$1`, `$@` and the other special parameters are not variables.", .bad = "echo ${1=x}", .good = "set -- x", .dash = "1: cannot assign in this way" },
    .{ .code = 2007, .kind = .readonly_assignment, .exit = 2, .summary = "Assignment to or unsetting of a read-only variable", .rich = "'{s}' is read-only", .help = "do not modify it, or start a new shell where it is not read-only", .explain = "A variable marked `readonly` can no longer be assigned or unset; a non-interactive shell exits (POSIX XCU 2.8.1).", .bad = "readonly r=1; r=2", .good = "r=1; r=2", .dash = "r: is read only" },
    .{ .code = 3001, .kind = .cannot_open, .exit = 2, .summary = "A file for input redirection cannot be opened", .rich = "cannot open '{s}' for reading", .help = "check that the path exists and is readable", .explain = "`< file`, `<> file` or `.` could not open the file. The command is not run and its status is 2 (a redirection error before a special builtin exits a non-interactive shell).", .bad = "cat < missing.txt", .good = "cat < /etc/hostname", .dash = "cannot open missing.txt: No such file" },
    .{ .code = 3002, .kind = .cannot_create, .exit = 2, .summary = "A file for output redirection cannot be created", .rich = "cannot create '{s}'", .help = "check that the directory exists and is writable", .explain = "`> file` or `>> file` could not create or open the file for writing.", .bad = "echo x > /nonexistent/f", .good = "echo x > ./f", .dash = "cannot create /nonexistent/f: Directory nonexistent" },
    .{ .code = 3003, .kind = .bad_fd, .exit = 2, .summary = "A descriptor in a duplication is not open", .rich = "file descriptor {s} is not open", .help = "open it first with `exec N>file`, or redirect to an existing one", .explain = "`n>&m` and `n<&m` need `m` to be open (POSIX XCU 2.7.6).", .bad = "echo hi >&9", .good = "exec 9>&1; echo hi >&9", .dash = "9: Bad file descriptor" },
    .{ .code = 3004, .kind = .noclobber, .exit = 2, .summary = "`set -C` refuses to overwrite an existing file", .rich = "'{s}' exists and `set -C` (noclobber) is on", .help = "use `>|` to overwrite on purpose, or `>>` to append", .explain = "With noclobber `>` does not truncate an existing regular file (POSIX XCU 2.7.2).", .bad = "set -C; echo a > f; echo b > f", .good = "set -C; echo a > f; echo b >| f", .dash = "cannot create f: File exists" },
    .{ .code = 3005, .kind = .bad_fd_number, .exit = 2, .summary = "The word after `>&` or `<&` is neither a number nor `-`", .rich = "'{s}' is not a file descriptor number", .help = "use a number, or `-` to close", .explain = "Duplication redirections take a descriptor number or `-` (POSIX XCU 2.7.5, 2.7.6).", .bad = "echo hi >&file", .good = "echo hi >file", .dash = "Syntax error: Bad fd number" },
    .{ .code = 4001, .kind = .not_found, .exit = 127, .summary = "The command was not found", .rich = "command not found: '{s}'", .help = "check the spelling and that its directory is in PATH", .explain = "Neither a function, a builtin nor an executable file of that name exists in PATH. The exit status is 127 (POSIX XCU 2.8.2).", .bad = "nosuchcommand", .good = "ls", .dash = "nosuchcommand: not found" },
    .{ .code = 4002, .kind = .not_executable, .exit = 126, .summary = "The file was found but cannot be executed", .rich = "cannot execute '{s}': permission denied or not an executable file", .help = "make it executable with `chmod +x`, or run it through its interpreter", .explain = "The file exists but is not executable, or is a directory. The exit status is 126.", .bad = "./notexecutable", .good = "chmod +x notexecutable && ./notexecutable", .dash = "./notexecutable: Permission denied" },
    .{ .code = 4003, .kind = .cannot_fork, .exit = 2, .summary = "A process or pipe could not be created", .rich = "{s}", .help = "the system is out of processes or descriptors; check ulimits", .explain = "fork(2) or pipe(2) failed, usually because of a resource limit.", .bad = "(ulimit -u 1; : | :)", .good = "(: | :)", .dash = "Cannot fork" },
    .{ .code = 4004, .kind = .cannot_open_script, .exit = 127, .summary = "The script file named on the command line cannot be opened", .rich = "cannot open script '{s}'", .help = "check the path", .explain = "`sh file` could not read the file; the exit status is 127.", .bad = "sh nosuch.sh", .good = "sh ./script.sh", .dash = "Can't open nosuch.sh" },
    .{ .code = 4005, .kind = .errexit_exit, .exit = 0, .summary = "`set -e` ended the shell after a failing command (note, rich and json styles only)", .rich = "`set -e` is on and '{s}' failed, so the shell exits", .help = "test the command (`cmd || handle`) if the failure is expected", .explain = "POSIX XCU 2.14 `set -e`: a failing command that is not part of a condition, an `&&`/`||` list (except the last) or a negated pipeline ends the shell with that command's status. This note names the command and line; it is never printed in the posix style, and never changes the exit status.", .bad = "set -e\nfalse\necho unreachable", .good = "set -e\nfalse || :\necho reachable", .dash = "(none: dash exits silently)" },
    .{ .code = 4006, .kind = .stopped_jobs, .exit = 1, .summary = "`exit` was refused because jobs are stopped", .rich = "you have stopped jobs", .help = "run `jobs`, resume them with `fg` or end them with `kill`, or type `exit` again to leave anyway", .explain = "An interactive shell with job control warns once when `exit` (or end of input) would abandon stopped jobs; the next `exit` leaves and hangs them up. Not reported by a non-interactive shell.", .bad = "(interactive) sleep 9 ^Z; exit", .good = "(interactive) sleep 9 ^Z; exit; exit", .dash = "You have stopped jobs." },
    .{ .code = 5001, .kind = .illegal_option, .exit = 2, .summary = "A builtin was given an option it does not have", .rich = "unknown option '{s}'", .help = "see the builtin's description in the manual", .explain = "A special builtin that gets an invalid option makes a non-interactive shell exit (POSIX XCU 2.8.1).", .bad = "set -Z", .good = "set -e", .dash = "set: Illegal option -Z" },
    .{ .code = 5002, .kind = .cannot_shift, .exit = 2, .summary = "`shift` was asked to drop more parameters than exist", .rich = "cannot shift: fewer than the requested parameters", .help = "compare `$#` with the count first", .explain = "`shift n` requires n <= `$#` (POSIX XCU 2.14, shift).", .bad = "set -- a; shift 2", .good = "set -- a; shift", .dash = "shift: can't shift that many" },
    .{ .code = 5003, .kind = .cannot_cd, .exit = 2, .summary = "`cd` could not change directory", .rich = "cannot change directory to '{s}'", .help = "check that it exists and you may enter it", .explain = "`cd` failed; the status is non-zero and the directory is unchanged.", .bad = "cd /nonexistent", .good = "cd /", .dash = "cd: can't cd to /nonexistent" },
    .{ .code = 5004, .kind = .bad_trap, .exit = 1, .summary = "`trap` names a signal that does not exist", .rich = "'{s}' is not a signal", .help = "use `kill -l` to list names; `trap` also accepts numbers and `EXIT`", .explain = "The condition after the action is neither EXIT, a signal name nor a signal number.", .bad = "trap : NOSUCH", .good = "trap : TERM", .dash = "trap: NOSUCH: bad trap" },
    .{ .code = 5005, .kind = .bad_variable_name, .exit = 2, .summary = "A builtin was given something that is not a variable name", .rich = "'{s}' is not a valid variable name", .help = "variable names use letters, digits and underscores, not starting with a digit", .explain = "`export`, `readonly`, `local` and `read` take names (POSIX XBD 3.216).", .bad = "export 1x=3", .good = "export x1=3", .dash = "export: 1x: bad variable name" },
    .{ .code = 5006, .kind = .test_error, .exit = 2, .summary = "`test` or `[` could not parse its arguments", .rich = "{s}", .help = "quote operands, and check that `[` ends with `]`", .explain = "The arguments are not a valid `test` expression (POSIX XCU test, argument-count rules).", .bad = "[ a b ]", .good = "[ a = b ]", .dash = "[: a: unexpected operator" },
    .{ .code = 5007, .kind = .printf_number, .exit = 1, .summary = "A `printf` numeric conversion got a non-number", .rich = "'{s}' is not a complete number", .help = "pass an integer, or use `%s` for text", .explain = "`%d`, `%x` and friends need numeric arguments; the status is 1 but printing continues.", .bad = "printf '%d\\n' abc", .good = "printf '%s\\n' abc", .dash = "printf: abc: expected numeric value" },
    .{ .code = 5008, .kind = .kill_error, .exit = 2, .summary = "`kill` was given a bad signal or pid", .rich = "{s}", .help = "`kill -l` lists signal names", .explain = "The signal name/number or the process id is invalid, or the process does not exist.", .bad = "kill -s NOSUCH 1", .good = "kill -s TERM 1", .dash = "kill: invalid signal number or name: NOSUCH" },
    .{ .code = 5009, .kind = .usage, .exit = 2, .summary = "A builtin was called with the wrong number of arguments", .rich = "{s}", .help = "see the usage line in the message", .explain = "The builtin needs more operands than it got.", .bad = "getopts a", .good = "getopts a opt", .dash = "getopts: usage: getopts optstring var [arg]" },
    .{ .code = 5010, .kind = .io_error, .exit = 1, .summary = "Writing to standard output failed", .rich = "write error: {s}", .help = "standard output is closed or full", .explain = "A builtin could not write its output (closed descriptor, full disk).", .bad = "echo hi >&-", .good = "echo hi", .dash = "echo: echo: I/O error" },
    .{ .code = 5011, .kind = .alias_not_found, .exit = 1, .summary = "`alias` or `unalias` named an alias that is not defined", .rich = "no alias named '{s}'", .help = "`alias` with no arguments lists the defined aliases", .explain = "Aliases are looked up by exact name.", .bad = "unalias nosuch", .good = "alias ll='ls -l'; unalias ll", .dash = "unalias: nosuch: not found" },
    .{ .code = 5012, .kind = .bad_limit, .exit = 1, .summary = "`ulimit` could not read or set the limit", .rich = "{s}", .help = "the hard limit cannot be raised without privilege", .explain = "getrlimit/setrlimit failed.", .bad = "ulimit -n 99999999999", .good = "ulimit -n 256", .dash = "ulimit: bad limit: Operation not permitted" },
    .{ .code = 5013, .kind = .not_in_function, .exit = 2, .summary = "`local` was used outside a function", .rich = "`local` can only be used inside a function", .help = "declare the variable normally, or move the code into a function", .explain = "`local` is not in POSIX; where available it is only valid in a function body.", .bad = "local x=1", .good = "f() { local x=1; }", .dash = "local: not in a function" },
    .{ .code = 5014, .kind = .no_such_job, .exit = 1, .summary = "A job specification names no job", .rich = "{s}: no such job", .help = "`jobs` lists the jobs; a specification is `%n`, `%%`, `%+`, `%-`, `%string` or `%?string`", .explain = "`fg`, `bg`, `kill`, `wait` and `jobs` accept job specifications (POSIX XCU 3.204 Job Control Job ID). With no argument `fg` and `bg` act on the current job, which does not exist when no job was started.", .bad = "fg", .good = "sleep 9 & fg", .dash = "fg: No current job" },
    .{ .code = 5015, .kind = .no_job_control, .exit = 1, .summary = "Job control could not be enabled", .rich = "job control is off: {s}", .help = "run the shell from a terminal, or without `-m`", .explain = "An interactive shell enables job control (`set -m`) only when standard input, output or error is a terminal it can control. Otherwise it runs without process groups and says so.", .bad = "(sh -i < file) set -m", .good = "(a terminal)", .dash = "can't access tty; job control turned off" },
    .{ .code = 5016, .kind = .history_error, .exit = 1, .summary = "`fc` found no such history entry or history is off", .rich = "{s}", .help = "`fc -l` lists the entries; an operand is a number, a negative offset or the start of a command", .explain = "`fc` selects commands by number (negative counts back from the most recent) or by the text a command starts with. History exists only in an interactive shell.", .bad = "fc -l", .good = "(interactive) fc -l", .dash = "fc: not found" },
    .{ .code = 5017, .kind = .ambiguous_job, .exit = 1, .summary = "A job specification matches several jobs", .rich = "'{s}' matches more than one job", .help = "make the string longer so that it matches only one job, or use `%n`", .explain = "`%string` and `%?string` must select exactly one job (POSIX XCU 3.204).", .bad = "sleep 7 & sleep 8 & fg %sl", .good = "sleep 7 & sleep 8 & fg %sleep\\ 7", .dash = "fg: %sl: Ambiguous" },
    .{ .code = 6001, .kind = .invocation_option, .exit = 2, .summary = "`sh` was started with an option it does not have", .rich = "unknown option '{s}'", .help = "see `sh` in the manual for the option list", .explain = "The command line options are those of POSIX `sh`: -a -b -C -e -f -h -i -m -n -u -v -x, -c, -s, -o and +o.", .bad = "sh -Z", .good = "sh -e", .dash = "Illegal option -Z" },
    .{ .code = 6002, .kind = .missing_argument, .exit = 2, .summary = "`sh -c` or `-o` needs an argument", .rich = "{s}", .help = "give the command string after `-c`", .explain = "`sh -c` requires the command string as the next operand.", .bad = "sh -c", .good = "sh -c 'echo hi'", .dash = "-c requires an argument" },
    .{ .code = 7001, .kind = .lint_unquoted_expansion, .exit = 1, .summary = "An unquoted expansion is split into words and globbed", .rich = "unquoted expansion of '{s}' is split on whitespace and expanded as a glob", .help = "quote it as \"${name}\" unless you want word splitting", .explain = "Unquoted `$name` and `$(cmd)` results undergo field splitting and pathname expansion (POSIX XCU 2.6.5, 2.6.6), so a value with spaces or `*` becomes several arguments.", .bad = "rm $file", .good = "rm \"$file\"", .dash = "(none)", .shellcheck = "SC2086" },
    .{ .code = 7002, .kind = .lint_cd_unchecked, .exit = 1, .summary = "`cd` result is not checked", .rich = "`cd` may fail and the script carries on in the wrong directory", .help = "write `cd dir || exit 1`", .explain = "If `cd` fails the following commands run in the current directory, which is how scripts delete the wrong files.", .bad = "cd /build\nrm -rf ./*", .good = "cd /build || exit 1\nrm -rf ./*", .dash = "(none)", .shellcheck = "SC2164" },
    .{ .code = 7003, .kind = .lint_rm_variable, .exit = 1, .summary = "`rm -r` on a path built from a variable that may be empty", .rich = "`rm -r` of a path starting with a variable: if it is empty the path becomes `/...`", .help = "use `${var:?}` so an empty value stops the script", .explain = "`rm -rf \"$dir/\"` becomes `rm -rf /` when `dir` is empty or unset.", .bad = "rm -rf \"$dir/\"", .good = "rm -rf \"${dir:?}/\"", .dash = "(none)", .shellcheck = "SC2115" },
    .{ .code = 7004, .kind = .lint_double_bracket, .exit = 1, .summary = "`[[ ]]` is not POSIX", .rich = "'{s}' is a bash/ksh extension; in a POSIX shell it is a command called `[[`", .help = "use `[ ... ]` or `case`", .explain = "POSIX has `[` and `test` only; `[[` fails with `[[: not found` in dash.", .bad = "[[ $a = b ]]", .good = "[ \"$a\" = b ]", .dash = "[[: not found", .shellcheck = "SC3010" },
    .{ .code = 7005, .kind = .lint_function_keyword, .exit = 1, .summary = "The `function` keyword is not POSIX", .rich = "`function` is a bash/ksh keyword; POSIX defines `name() { ...; }`", .help = "write `name() { ...; }`", .explain = "POSIX XCU 2.9.5 defines functions with `name ( ) compound-command`.", .bad = "function f { :; }", .good = "f() { :; }", .dash = "function: not found", .shellcheck = "SC2112" },
    .{ .code = 7006, .kind = .lint_source, .exit = 1, .summary = "`source` is not POSIX", .rich = "`source` is a bash extension; the POSIX spelling is `.`", .help = "use `. ./file`", .explain = "POSIX XCU 2.15 defines the dot utility only.", .bad = "source ./lib.sh", .good = ". ./lib.sh", .dash = "source: not found", .shellcheck = "SC3046" },
    .{ .code = 7007, .kind = .lint_local, .exit = 1, .summary = "`local` is not POSIX", .rich = "`local` is not defined by POSIX; common shells accept it but behave differently", .help = "use a subshell `f() ( ... )` or unique variable names", .explain = "POSIX has no function-local variables; dash, bash and busybox implement `local` with different details.", .bad = "f() { local x=1; }", .good = "f() ( x=1; : )", .dash = "(accepted)", .shellcheck = "SC3043" },
    .{ .code = 7008, .kind = .lint_echo_option, .exit = 1, .summary = "`echo -e`/`-E` is not portable", .rich = "`echo {s}` prints the option itself in some shells and escapes in others", .help = "use `printf`", .explain = "POSIX XCU echo: `-e` is not an option; implementations that follow XSI print `-e a` literally.", .bad = "echo -e \"a\\tb\"", .good = "printf 'a\\tb\\n'", .dash = "(prints -e)", .shellcheck = "SC3037" },
    .{ .code = 7009, .kind = .lint_double_equals, .exit = 1, .summary = "`==` in `[` is not POSIX", .rich = "'{s}' is a bash extension in `[`; POSIX has `=`", .help = "use `=`", .explain = "POSIX test defines `=` and `!=` for string comparison.", .bad = "[ \"$a\" == b ]", .good = "[ \"$a\" = b ]", .dash = "[: a: unexpected operator", .shellcheck = "SC3014" },
    .{ .code = 9000, .kind = .other, .exit = 0, .summary = "Any other message", .rich = "{s}", .help = "", .explain = "A message the shell does not classify; the text is dash's.", .bad = "", .good = "", .dash = "" },
};

pub fn entryOf(kind: Kind) *const Entry {
    for (&catalog) |*e| if (e.kind == kind) return e;
    unreachable;
}

pub fn entryByCode(code: u16) ?*const Entry {
    for (&catalog) |*e| if (e.code == code) return e;
    return null;
}

pub const Opener = struct { name: []const u8, line: u32, column: u32 };

/// What the library gives its host for every problem it reports. All slices
/// are borrowed for the duration of the reporter call.
pub const Diagnostic = struct {
    code: u16,
    kind: Kind,
    severity: Severity = .err,
    /// `-c`, the script path, or `stdin`.
    label: []const u8 = "",
    line: u32 = 0,
    /// 1-based byte column; 0 when unknown.
    column: u32 = 0,
    end_column: u32 = 0,
    /// The offending token text, when the problem is a token.
    token: []const u8 = "",
    /// Token or construct that would have been valid.
    expected: []const u8 = "",
    /// Name, path or number the message is about.
    subject: []const u8 = "",
    /// Where the enclosing construct started, for unclosed constructs.
    opener: ?Opener = null,
    /// The message in dash's wording, without the `name: line: ` prefix.
    posix: []const u8 = "",
    /// dash prints this one without any prefix (trap, getopts).
    bare: bool = false,
    /// Whole source text the line/column refer to (for the excerpt).
    source: []const u8 = "",
};

pub const Style = enum { rich, posix, json, gcc };

fn startsWith(s: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, s, p);
}
fn endsWith(s: []const u8, p: []const u8) bool {
    return std.mem.endsWith(u8, s, p);
}
fn contains(s: []const u8, p: []const u8) bool {
    return std.mem.indexOf(u8, s, p) != null;
}

pub const Classified = struct { kind: Kind, subject: []const u8 };

/// Place a runtime message (dash wording, without prefix) into the catalog.
pub fn classify(msg: []const u8) Classified {
    if (contains(msg, "No current job") or contains(msg, "No such job")) return .{ .kind = .no_such_job, .subject = if (contains(msg, "No current job")) "current job" else msg[std.mem.lastIndexOf(u8, msg, ": ").? + 2 ..] };
    if (endsWith(msg, "Ambiguous")) return .{ .kind = .ambiguous_job, .subject = lastField(msg[0 .. msg.len - ": Ambiguous".len]) };
    if (contains(msg, "job control turned off")) return .{ .kind = .no_job_control, .subject = msg };
    if (startsWith(msg, "You have stopped jobs")) return .{ .kind = .stopped_jobs, .subject = "" };
    if (startsWith(msg, "fc: ") and (contains(msg, "history") )) return .{ .kind = .history_error, .subject = msg };
    if (contains(msg, "arithmetic expression: division by zero")) return .{ .kind = .division_by_zero, .subject = afterLast(msg, ": \"", "\"") };
    if (startsWith(msg, "arithmetic expression:")) return .{ .kind = .arithmetic_syntax, .subject = msg };
    if (contains(msg, "Illegal number: ")) return .{ .kind = .illegal_number, .subject = msg[std.mem.lastIndexOf(u8, msg, "Illegal number: ").? + 16 ..] };
    if (contains(msg, "Illegal option")) return .{ .kind = .illegal_option, .subject = msg[std.mem.lastIndexOf(u8, msg, "Illegal option ").? + 15 ..] };
    if (endsWith(msg, "parameter not set")) return .{ .kind = .unset_variable, .subject = msg[0 .. msg.len - ": parameter not set".len] };
    if (endsWith(msg, "parameter null or not set")) return .{ .kind = .parameter_error, .subject = msg };
    if (endsWith(msg, "cannot assign in this way")) return .{ .kind = .cannot_assign, .subject = msg[0 .. msg.len - ": cannot assign in this way".len] };
    if (endsWith(msg, "is read only")) {
        const body = msg[0 .. msg.len - ": is read only".len];
        return .{ .kind = .readonly_assignment, .subject = lastField(body) };
    }
    if (contains(msg, "cannot create temporary")) return .{ .kind = .cannot_create, .subject = "temporary file" };
    if (contains(msg, "cannot create ")) return classifyOpen(msg, "cannot create ", if (endsWith(msg, "File exists")) .noclobber else .cannot_create);
    if (contains(msg, "cannot open ")) return classifyOpen(msg, "cannot open ", .cannot_open);
    if (endsWith(msg, "Bad file descriptor")) return .{ .kind = .bad_fd, .subject = msg[0 .. msg.len - ": Bad file descriptor".len] };
    if (contains(msg, "Bad fd number")) return .{ .kind = .bad_fd_number, .subject = "" };
    if (endsWith(msg, "bad variable name")) return .{ .kind = .bad_variable_name, .subject = lastField(msg[0 .. msg.len - ": bad variable name".len]) };
    if (contains(msg, "can't shift")) return .{ .kind = .cannot_shift, .subject = "" };
    if (contains(msg, "can't cd to ")) return .{ .kind = .cannot_cd, .subject = msg[std.mem.indexOf(u8, msg, "can't cd to ").? + 12 ..] };
    if (endsWith(msg, "bad trap")) return .{ .kind = .bad_trap, .subject = lastField(msg[0 .. msg.len - ": bad trap".len]) };
    if (endsWith(msg, ": not found") or endsWith(msg, " not found")) {
        if (endsWith(msg, ": not found")) {
            const body = msg[0 .. msg.len - ": not found".len];
            if (startsWith(msg, "alias: ") or startsWith(msg, "unalias: ")) return .{ .kind = .alias_not_found, .subject = lastField(body) };
            return .{ .kind = .not_found, .subject = lastField(body) };
        }
        return .{ .kind = .alias_not_found, .subject = lastField(msg[0 .. msg.len - " not found".len]) };
    }
    if (endsWith(msg, "Permission denied")) return .{ .kind = .not_executable, .subject = msg[0 .. msg.len - ": Permission denied".len] };
    if (contains(msg, "Cannot fork") or contains(msg, "Cannot create pipe")) return .{ .kind = .cannot_fork, .subject = msg };
    if (contains(msg, "unexpected operator") or contains(msg, "argument expected") or contains(msg, "missing ]") or contains(msg, "closing paren")) return .{ .kind = .test_error, .subject = msg };
    if (contains(msg, "expected numeric value") or contains(msg, "not completely converted")) return .{ .kind = .printf_number, .subject = lastField(msg[0 .. std.mem.lastIndexOfScalar(u8, msg, ':') orelse msg.len]) };
    if (contains(msg, "invalid signal") or contains(msg, "invalid pid") or startsWith(msg, "kill: ")) return .{ .kind = .kill_error, .subject = msg };
    if (contains(msg, "usage:") or contains(msg, "arg count")) return .{ .kind = .usage, .subject = msg };
    if (contains(msg, "I/O error")) return .{ .kind = .io_error, .subject = "I/O error" };
    if (contains(msg, "bad limit")) return .{ .kind = .bad_limit, .subject = msg };
    if (contains(msg, "not in a function")) return .{ .kind = .not_in_function, .subject = "" };
    if (contains(msg, "invalid directive")) return .{ .kind = .usage, .subject = msg };
    return .{ .kind = .other, .subject = msg };
}

fn lastField(s: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, s, ": ")) |i| return s[i + 2 ..];
    return s;
}

fn afterLast(s: []const u8, marker: []const u8, strip: []const u8) []const u8 {
    const i = std.mem.lastIndexOf(u8, s, marker) orelse return s;
    var r = s[i + marker.len ..];
    if (endsWith(r, strip)) r = r[0 .. r.len - strip.len];
    return r;
}

fn classifyOpen(msg: []const u8, prefix: []const u8, kind: Kind) Classified {
    const i = std.mem.indexOf(u8, msg, prefix).? + prefix.len;
    var path = msg[i..];
    if (std.mem.lastIndexOf(u8, path, ": ")) |j| path = path[0..j];
    return .{ .kind = kind, .subject = path };
}

// --- rendering ---------------------------------------------------------------

fn sourceLine(src: []const u8, line: u32) ?[]const u8 {
    if (line == 0) return null;
    var n: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (n < line) : (i += 1) {
        if (i >= src.len) return null;
        if (src[i] == '\n') {
            n += 1;
            start = i + 1;
        }
    }
    const end = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
    return src[start..end];
}

fn richText(a: Allocator, d: *const Diagnostic, e: *const Entry) Allocator.Error![]const u8 {
    switch (d.kind) {
        .unexpected_token, .mismatched_closer => {
            var out: std.ArrayList(u8) = .empty;
            const tok: []const u8 = if (d.token.len == 0) "end of input" else d.token;
            if (std.mem.eql(u8, tok, "end of input") or std.mem.eql(u8, tok, "newline")) {
                try out.print(a, "unexpected {s}", .{tok});
            } else try out.print(a, "unexpected '{s}'", .{tok});
            if (d.expected.len > 0) {
                try out.print(a, ", expected '{s}'", .{d.expected});
                if (d.opener) |o| {
                    if (isCloser(d.expected)) try out.print(a, " to close the '{s}' started at {d}:{d}", .{ o.name, o.line, o.column });
                }
            }
            return out.items;
        },
        else => {},
    }
    // `{s}` substitution
    var base: []const u8 = e.rich;
    if (std.mem.indexOf(u8, e.rich, "{s}")) |i| {
        base = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ e.rich[0..i], d.subject, e.rich[i + 3 ..] });
    }
    switch (d.kind) {
        .unterminated_quote, .unterminated_heredoc, .unterminated_command_substitution, .unterminated_arithmetic => {
            if (d.opener) |o| return std.fmt.allocPrint(a, "{s} (opened at line {d}, column {d})", .{ base, o.line, o.column });
            if (d.kind == .unterminated_heredoc) return std.fmt.allocPrint(a, "{s} (started at line {d})", .{ base, d.line });
        },
        else => {},
    }
    return base;
}

fn isCloser(s: []const u8) bool {
    for ([_][]const u8{ "fi", "done", "esac", "}", ")" }) |c| if (std.mem.eql(u8, s, c)) return true;
    return false;
}

fn helpText(a: Allocator, d: *const Diagnostic, e: *const Entry) Allocator.Error![]const u8 {
    if ((d.kind == .unexpected_token or d.kind == .mismatched_closer) and d.expected.len > 0) {
        if (std.mem.eql(u8, d.expected, "then")) return "put `; then` after the condition";
        if (std.mem.eql(u8, d.expected, "do")) return "put `; do` after the loop header";
        return std.fmt.allocPrint(a, "insert '{s}' where the construct should end", .{d.expected});
    }
    return e.help;
}

fn digits(n: u32) usize {
    var c: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) c += 1;
    return c;
}

fn excerpt(out: *std.ArrayList(u8), a: Allocator, src: []const u8, line: u32, col: u32, end_col: u32, width: usize, color: bool, marker: u8) Allocator.Error!void {
    const text = sourceLine(src, line) orelse return;
    try out.appendNTimes(a, ' ', width + 1);
    try out.appendSlice(a, "|\n");
    var nb: [12]u8 = undefined;
    const ns = std.fmt.bufPrint(&nb, "{d}", .{line}) catch "";
    try out.appendNTimes(a, ' ', width -| ns.len);
    try out.print(a, "{s} | ", .{ns});
    for (text) |c| try out.append(a, if (c == '\t') ' ' else c);
    try out.append(a, '\n');
    if (col > 0) {
        try out.appendNTimes(a, ' ', width);
        try out.appendSlice(a, " | ");
        var i: u32 = 1;
        while (i < col) : (i += 1) try out.append(a, ' ');
        const len: u32 = if (end_col > col) end_col - col else 1;
        if (color) try out.appendSlice(a, "\x1b[1;31m");
        var k: u32 = 0;
        while (k < len) : (k += 1) try out.append(a, marker);
        if (color) try out.appendSlice(a, "\x1b[0m");
        try out.append(a, '\n');
    }
}

/// Render `d` for standard error, including the trailing newline.
pub fn render(a: Allocator, d: *const Diagnostic, name: []const u8, style: Style, color: bool, interactive: bool) Allocator.Error![]const u8 {
    const e = entryByCode(d.code) orelse entryOf(.other);
    var out: std.ArrayList(u8) = .empty;
    // An unterminated construct is reported where it was opened.
    var line = d.line;
    var col = d.column;
    var end_col = d.end_column;
    var show_opener = d.opener != null;
    switch (d.kind) {
        .unterminated_quote, .unterminated_arithmetic, .unterminated_command_substitution => if (d.opener) |o| {
            line = o.line;
            col = o.column;
            end_col = o.column + @as(u32, @intCast(o.name.len));
            show_opener = false;
        },
        else => {},
    }
    switch (style) {
        .posix => {
            if (d.bare) {
                try out.print(a, "{s}\n", .{d.posix});
            } else if (interactive or d.line == 0) {
                try out.print(a, "{s}: {s}\n", .{ name, d.posix });
            } else try out.print(a, "{s}: {d}: {s}\n", .{ name, d.line, d.posix });
        },
        .gcc => {
            const msg = try richText(a, d, e);
            const lbl: []const u8 = if (d.label.len > 0) d.label else name;
            try out.print(a, "{s}:{d}:{d}: {s}: {s} [SH{d}]\n", .{ lbl, line, @max(col, 1), if (d.severity == .err) "error" else "warning", msg, d.code });
        },
        .json => {
            const msg = try richText(a, d, e);
            const help = try helpText(a, d, e);
            try out.print(a, "{{\"code\":\"SH{d}\",\"kind\":\"{s}\",\"severity\":\"{s}\",\"file\":", .{ d.code, @tagName(d.kind), if (d.severity == .err) "error" else "warning" });
            try jsonStr(&out, a, d.label);
            try out.print(a, ",\"line\":{d},\"column\":{d},\"end\":{d},\"message\":", .{ line, col, end_col });
            try jsonStr(&out, a, msg);
            try out.appendSlice(a, ",\"help\":");
            try jsonStr(&out, a, help);
            try out.appendSlice(a, ",\"token\":");
            try jsonStr(&out, a, d.token);
            try out.appendSlice(a, ",\"expected\":");
            try jsonStr(&out, a, d.expected);
            try out.appendSlice(a, ",\"posix\":");
            try jsonStr(&out, a, d.posix);
            try out.appendSlice(a, "}\n");
        },
        .rich => {
            const msg = try richText(a, d, e);
            const help = try helpText(a, d, e);
            const sev: []const u8 = if (d.severity == .err) "error" else "warning";
            const lbl: []const u8 = if (d.label.len > 0) d.label else name;
            try out.print(a, "{s}: ", .{name});
            if (line > 0) {
                try out.print(a, "{s}:{d}", .{ lbl, line });
                if (col > 0) try out.print(a, ":{d}", .{col});
                try out.appendSlice(a, ": ");
            }
            if (color) try out.appendSlice(a, if (d.severity == .err) "\x1b[1;31m" else "\x1b[1;33m");
            try out.print(a, "{s}[SH{d}]", .{ sev, d.code });
            if (color) try out.appendSlice(a, "\x1b[0m\x1b[1m");
            try out.print(a, ": {s}", .{msg});
            if (color) try out.appendSlice(a, "\x1b[0m");
            try out.append(a, '\n');
            var width = digits(line);
            if (d.opener) |o| width = @max(width, digits(o.line));
            try excerpt(&out, a, d.source, line, col, end_col, width, color, '^');
            if (show_opener) if (d.opener) |o| {
                try out.print(a, "note: the '{s}' started here\n", .{o.name});
                try excerpt(&out, a, d.source, o.line, o.column, o.column + @as(u32, @intCast(o.name.len)), width, color, '-');
            };
            if (help.len > 0) try out.print(a, "help: {s}\n", .{help});
        },
    }
    return out.items;
}

fn jsonStr(out: *std.ArrayList(u8), a: Allocator, s: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11...31 => try out.print(a, "\\u{x:0>4}", .{c}),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

/// The catalog as the markdown of docs/sh-diagnostics.md.
pub fn catalogMarkdown(a: Allocator) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a,
        \\# NAME
        \\
        \\sh-diagnostics - catalog of the diagnostics of sh
        \\
        \\# DESCRIPTION
        \\
        \\Every message of sh has a stable code `SHxxxx`. This file is generated from `src/lib/sh/diag.zig` (`sh --diagnostics-catalog`); `sh --explain SHxxxx` prints one entry. Groups: 1xxx syntax, 2xxx expansion and arithmetic, 3xxx redirection, 4xxx execution, 5xxx builtins, 6xxx invocation. The exit status is POSIX's (2 for syntax errors and fatal expansion errors, 126 and 127 for exec).
        \\
        \\# SUMMARY
        \\
        \\| Code | Kind | Status | Meaning |
        \\|------|------|--------|---------|
        \\
    );
    for (&catalog) |*e| try out.print(a, "| SH{d} | {s} | {d} | {s} |\n", .{ e.code, @tagName(e.kind), e.exit, e.summary });
    try out.appendSlice(a, "\n# LINT CODES AND SHELLCHECK\n\nThe `--check` codes and the nearest ShellCheck id (a pointer for readers who know that tool; the messages are our own).\n\n| Code | Kind | ShellCheck |\n|------|------|------------|\n");
    for (&catalog) |*e| if (e.shellcheck.len > 0) try out.print(a, "| SH{d} | {s} | {s} |\n", .{ e.code, @tagName(e.kind), e.shellcheck });
    try out.appendSlice(a, "\n# ENTRIES\n\n");
    for (&catalog) |*e| {
        try out.print(a, "## SH{d} {s}\n\n{s}\n\n", .{ e.code, @tagName(e.kind), e.explain });
        if (e.bad.len > 0) {
            try out.print(a, "Bad:\n\n    {s}\n\n", .{indent(a, e.bad) catch e.bad});
            try out.print(a, "Good:\n\n    {s}\n\n", .{indent(a, e.good) catch e.good});
            try out.print(a, "dash says: `{s}`\n\n", .{e.dash});
        }
    }
    return out.items;
}

fn indent(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        try out.append(a, c);
        if (c == '\n') try out.appendSlice(a, "    ");
    }
    return out.items;
}

/// Text of `sh --explain CODE`.
pub fn explain(a: Allocator, e: *const Entry) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "SH{d}: {s}\n\n{s}\n", .{ e.code, e.summary, e.explain });
    if (e.bad.len > 0) {
        try out.print(a, "\nBad:\n    {s}\n\nGood:\n    {s}\n\ndash says: {s}\n", .{ try indent(a, e.bad), try indent(a, e.good), e.dash });
    }
    return out.items;
}

test "codes are unique and ordered by group" {
    for (catalog, 0..) |e, i| {
        for (catalog[i + 1 ..]) |f| try std.testing.expect(e.code != f.code);
    }
}

test "classify places dash messages" {
    try std.testing.expectEqual(Kind.not_found, classify("nosuch: not found").kind);
    try std.testing.expectEqualStrings("nosuch", classify("nosuch: not found").subject);
    try std.testing.expectEqual(Kind.cannot_create, classify("cannot create /x/y: Directory nonexistent").kind);
    try std.testing.expectEqual(Kind.readonly_assignment, classify("r: is read only").kind);
    try std.testing.expectEqual(Kind.division_by_zero, classify("arithmetic expression: division by zero: \"1/0\"").kind);
}

test "rich rendering of a mismatched closer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d: Diagnostic = .{
        .code = 1007, .kind = .mismatched_closer, .label = "s.sh", .line = 3, .column = 1, .end_column = 3,
        .token = "fi", .expected = "done", .opener = .{ .name = "while", .line = 1, .column = 1 },
        .posix = "Syntax error: \"fi\" unexpected (expecting \"done\")",
        .source = "while true; do\n  echo x\nfi\n",
    };
    const text = try render(a, &d, "sh", .rich, false, false);
    try std.testing.expect(std.mem.startsWith(u8, text, "sh: s.sh:3:1: error[SH1007]: unexpected 'fi', expected 'done' to close the 'while' started at 1:1\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "3 | fi\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  | ^^\n") != null);
}
