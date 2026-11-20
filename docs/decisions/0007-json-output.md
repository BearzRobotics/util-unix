# 0007: `--json` output for uname, id and who

Status: proposed (branch `structured-output`). Date: 2026-11-14

## Context

The maintainer wants the utilities to hand structured data to a shell (dksh)
that has maps and arrays, instead of text that must be re-parsed. dksh may
call the library directly or run the binaries and parse their output.

## Decision

- Each command's library module gets a `writeJson` beside its text `write`.
  The text path is untouched: its output, option parsing and diagnostics stay
  byte-identical to GNU, so the differential tests keep their meaning.
  (Checked by building `main` and comparing the text output of 19 invocations.)
- The wrappers gain a non-GNU `--json` long option. It has no short form. It
  was first kept out of `--help`; since 2026-11-19 it is listed there (rule 7).
- Shared escaping is in `lib/json.zig` (RFC 8259). Input that is not valid
  UTF-8 is written as U+FFFD, one per bad byte, so output always parses.
- Shapes, chosen for jq and `jsonParse` ease:
  - `uname --json`: one object. No field option selects every field; field
    options select only those (the text form prints only the kernel name).
  - `id --json [USER]...`: one object per line per operand (JSON Lines).
    euid/egid are always present. It is refused with -u -g -G -n -r -z -Z.
  - `who --json`: one array, one record per line, the same records the text
    form would print for the same options. Column options do not apply.
    `-q` gives `{"users":[...],"count":n}`. Times are epoch seconds.
- Library consumers need no JSON: the data types the text writers already
  take (`proc.Uname`, `identity.Ids`, `utmp.Record`) are the structured form.

## Conventions for every `--json` command (util-unix and util-core)

These apply to all later commands so that scripts can rely on them.

1. **When a command gets `--json`:** only when its output is records or a
   structured value (stat, ls, df, du, find, who, id, ...). Byte-stream
   filters (cat, sort, sed, cut) and actions (cp, rm, chmod) do not get one.
   Commands whose whole output is one string or number (whoami, nproc) do not
   either: `$(cmd)` already is that value.
2. **Framing:** a command that reports on each operand (id, stat) prints one
   JSON object per operand, one per line, so a failed operand costs only its
   own line. A command whose output is a listing (who, df, ls, du) prints one
   JSON array. A streaming `--json=lines` may be added later for
   `find`/`locate`; it is not part of this decision.
3. **Keys:** snake_case, stable, never localized, never reordered between
   releases within a major version. Add keys freely; never repurpose one.
4. **Values keep their type:** sizes, counts, ids, pids and modes are numbers
   (modes also as an octal string under `mode_octal`); times are integer
   seconds since the epoch, with `_nsec` for the fraction where the source has
   it; booleans are true/false; text is a UTF-8 string (invalid bytes are
   U+FFFD, see `lib/json.zig`); an unknown or absent value is `null`, never
   an empty string or a made-up number.
5. **Raw bytes are not lost:** where a name may not be UTF-8 (file names), the
   entry also carries `name_bytes`, the name in hex, only when it differs from
   the UTF-8 form.
6. **Errors:** diagnostics go to stderr in the normal text form and the exit
   status is the command's usual one. Standard output still holds valid JSON
   for the part that succeeded.
7. **No effect without the flag:** `--json` is a long option only and the text
   path stays byte-identical to GNU. Update 2026-11-19: it is listed in
   `--help` as a line marked "(not in GNU)" and in the man page; differential
   `--help` tests drop that one line before comparing.

## Alternatives considered

- Build an entries list first and format both text and JSON from it. Cleaner
  for `ls`/`stat`, but it would rewrite the GNU-verified text path of three
  commands for no gain yet. Revisit for util-core's `ls`.
- A global `--format=json`. Rejected: one flag, same effect, and it invites
  GNU-option collisions.

## Consequences

- `--json` is an extension and is documented as not GNU. `id --j` now
  abbreviates `--json` where it used to be an unknown option.
- `who`'s record selection is written twice (text path and `selected`); a
  unit test pins them together, but they can drift.
- No differential test is possible; `test/test_json.sh` checks that the JSON
  parses and agrees with the plain output.
