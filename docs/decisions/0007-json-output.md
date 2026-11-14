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
- The wrappers gain a non-GNU `--json` long option. It has no short form.
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
