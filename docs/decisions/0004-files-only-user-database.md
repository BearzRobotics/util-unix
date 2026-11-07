# 0004: User and group lookups read the files only (no NSS)

Status: accepted (recorded retroactively; the code had cited this number
since the `userdb` and `getent` libraries were added). Date: 2026-11-07

## Context

`chown`, `chgrp`, `getent`, `id` and `groups` need to turn names into ids and
back. glibc does this through NSS (`getpwnam`, `getgrgid`, ...), which loads
shared objects chosen by `/etc/nsswitch.conf` (LDAP, SSSD, systemd-userdbd,
DNS, ...). Zig's standard library has no NSS client, and linking libc just for
this would give up the static, libc-free binaries (see "Build" in
`docs/architecture.md`).

## Decision

`src/lib/userdb.zig` reads `/etc/passwd` and `/etc/group` directly and nothing
else. Lookups follow getpwnam(3)/getgrnam(3): the first matching line wins and
malformed lines are skipped. A missing file is an empty database.
`getent` supports the databases that are files (`passwd`, `group`, `services`,
...) and answers "not found" for the rest.

## Consequences

- Accounts that exist only in LDAP, SSSD, systemd-userdbd and the like are not
  seen. Commands print the numeric id where GNU would print a name, or report
  "invalid user". This is a deliberate scope limit, listed in each command's
  compatibility record.
- The library needs no libc and is testable with `Db.fromText`.
- A future NSS-capable backend would sit behind the same `Db` interface; it
  would be a new decision.

## Alternatives considered

- Link libc and call `getpwnam`: exact GNU behaviour, but loses static builds
  and ties the library to glibc/musl differences (musl has no NSS either).
- Speak the nscd or systemd-userdbd protocols: a large surface for a rarely
  needed case.
