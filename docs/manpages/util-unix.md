# NAME

util-unix - multicall binary for the util-unix command set

# SYNOPSIS

    util-unix COMMAND [ARGUMENT]...
    util-unix --list
    util-unix --help
    COMMAND [ARGUMENT]...        (through a link named after the command)

# DESCRIPTION

`util-unix` contains every util-unix command in one executable. It runs the command named by its first operand, or by the name it was invoked as: a link or copy named `id` runs `id`.

The commands behave exactly as the standalone executables built with `zig build -Dmode=standalone`; both are the same code behind the same library (`util_unix`). Each command has its own page, for example `id(1)`.

# OPTIONS

`--list`
: Print the names of the commands this binary contains, one per line.

`--help`
: Print a short usage message and exit with status 0.

# EXIT STATUS

| Status | Meaning |
|---|---|
| the command's | The command's own exit status. |
| 127 | `COMMAND` is not one of the enabled commands (the shell's "command not found" status). |
| 2 | No command was given. |

# EXAMPLES

Run a command through the multicall binary:

    util-unix uname -a

Install links so the commands can be used by name:

    for c in $(util-unix --list); do ln -s util-unix "$c"; done

# BUILDING

`zig build -Dmode=multicall` builds only this binary, `-Dmode=standalone` only the per-command executables, and `-Dmode=all` (the default) both. `-Dcommands=a,b,c` limits the commands included.

# SEE ALSO

The page of each command; `docs/decisions/0002-library-first-architecture.md` for the library layout.

# VERSION

This manual describes util-unix 0.4.0 (see build.zig.zon).
