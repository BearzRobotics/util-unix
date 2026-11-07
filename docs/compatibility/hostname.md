# hostname: compatibility record

Status: implemented; 38 differential cases pass against `hostname` 3.25 (Debian) in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0006.

## References

- `hostname --help` and observed behavior of `hostname` 3.25, as installed on the development machine. There is no POSIX `hostname`.
- gethostname(2), sethostname(2), hosts(5), Linux man-pages.
- Behaviour was verified by running both binaries (`sh test/test_hostname.sh`). The upstream source of the reference implementation was not consulted; the implementation is independent.

## Supported

Display the host name; set it from an operand or `-F FILE` (first line that is neither blank nor a `#` comment); `-b`/`--boot` (use `/etc/hostname`, else `localhost`, when the name is empty or `(none)`); `-s`/`--short`; `-y`/`--yp`/`--nis` (the kernel's NIS domain name); `-f`/`--fqdn`/`--long`, `-d`/`--domain`, `-a`/`--alias` and `-i`/`--ip-address` completed from `/etc/hosts`; `-V`, `-h`/`--help`. The last display option on the line wins.

The refusals are compared too: setting without privilege ("you must be root to change the host name"), an over-long name, a missing `-F` file, and the usage errors (usage text on standard output with status 255 for bad options, on standard error for a wrong mix of operands and options, as the reference does).

## Deliberate deviations and gaps

1. **No DNS, no NSS.** `-f`, `-d`, `-a` and `-i` read `/etc/hosts` only (decision 0004's boundary). A name that is not in the file gives "Name or service not known" and status 1; `hostname` would ask the resolver.
2. **`-A` and `-I` are not supported** (they list the machine's interface addresses); they fail with a message and status 1.
3. **Not installed under the other names** (`domainname`, `ypdomainname`, `nisdomainname`, `dnsdomainname`); the multicall binary dispatches by the names in `commands.zig` only.
4. **Setting the name was not exercised as root** in the differential suite (the suite never changes the host name). The code path is `sethostname(2)`; an unprivileged run shows the kernel's refusal.
5. **`--version`** prints `hostname (util-unix) VERSION`.

## Platforms

Linux only (uses `sethostname`, `uname`). The executable is static and does not link libc. Tested on x86-64 Linux 6.18 (WSL2).
