# getent: compatibility record

Status: implemented; 64 differential cases pass against glibc 2.43 getent in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0005.

## References

- getent(1), Linux man-pages; glibc manual (NSS and the database file formats); passwd(5), group(5), shadow(5), gshadow(5), hosts(5), networks(5), protocols(5), services(5), rpc(5), ethers(5), aliases(5).
- glibc 2.43 `getent` (`getent (Ubuntu GLIBC 2.43-2ubuntu2.4) 2.43`) run on the development machine as the behavioural reference. POSIX does not specify getent.
- Behaviour was verified by running both binaries (`sh test/test_getent.sh`),
  not by reading alone. The upstream source of the reference implementation was
  not consulted for this record; the implementation is independent.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| Everything | glibc (not in POSIX) |

## Supported

Lookups by name or number in the files backend for every database listed in `getent --help`, enumeration where glibc supports it, exit statuses 0/1/2/3/64, `--service` and the accepted-and-ignored `-A`/`-i`. The tests draw keys from the files themselves.

## Deliberate deviations and gaps

1. **Files backend only** (decision 0004). Anything glibc answers from DNS, LDAP, NIS, systemd-userdb or another NSS module is "not found" here, and `nsswitch.conf` is not read. Entries that exist only in such sources are untested by design.
2. **`-s`/`--service`:** only "files" returns anything; any other service answers as an empty source.
3. **Shadow databases** read as empty for an unprivileged user, as glibc's files backend does.
4. **Numbers too large for an id** (`passwd 4294967296`) are not found. glibc 2.43 wraps them, so that key prints root's entry. As in glibc, a passwd, group or services key is a number only when it is all digits, after optional blanks and "+"; "-0", which glibc reads as 0, is looked up as a name here.

## Platforms

Linux only so far (tested on 6.18, WSL2, against the reference binary named
above). The executable is static and does not link libc, so musl and glibc
differ only in the host's account files. Built with `-Dtarget=x86_64-linux-musl`, the
unit tests and the full differential suite (748 cases) passed on a glibc host
(2026-11-07). On 2026-11-26 the build and the unit tests also passed natively on Alpine 3.22 (musl), which CI repeats (scripts/ci-musl.sh); it has no reference command for this one, so the comparison suite runs on glibc only.
Other Unix-like systems are not supported: `proc.zig` and `fsown.zig` return
neutral values or `error.Unsupported` there (decision 0003).
