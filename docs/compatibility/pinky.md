# pinky: compatibility record

Status: implemented. The long format (`-l`) has 32 differential cases against GNU pinky 9.7; the short format has 7 golden tests only, because the reference could not be compared on it (below). All 39 cases pass in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0006.

## References

- GNU coreutils 9.7 manual, node "pinky invocation" and `pinky --help`, as installed (`pinky (GNU coreutils) 9.7`). pinky is not in POSIX.
- utmp(5), passwd(5), Linux man-pages.
- Behaviour was verified by running GNU pinky on synthetic account files and home directories inside a user and mount namespace (`unshare -rm`, `sh test/test_pinky.sh`). The upstream source of the reference implementation was not consulted.

## Supported

Short format with `-s -f -w -i -q`, long format with `-l -b -h -p`, user arguments (a login-name filter in short format), `--lookup` (ignored), `--help`, `--version`. Long format is compared for: real names from the GECOS field (first comma field, `&` expanded to the capitalized login), unknown accounts, accounts without a shell, a home directory longer than its column, `.project` and `.plan` files with and without a trailing newline and empty ones, every combination of `-b -h -p`, several users, and the option-order rules (`-l -s` and `-s -l`).

## Deliberate deviations and gaps

1. **Short format is unverified against GNU.** The GNU build available here reads systemd-logind sessions for the default utmp path and has no option to read another file, so its short output could not be produced from a controlled utmp file. The row and heading layout are reconstructed from what it printed for one real session plus the documented columns. The idle text (blank under a minute, `HH:MM` under a day, `Nd` beyond), the `*`/space/`?` message column and the `???` for an unknown account are from memory of the documented behavior and are covered by golden tests that only check that the program does what this record says. Treat the short format as unverified.
2. **Reads the utmp file, never systemd-logind**, so on a systemd machine the short format shows `/var/run/utmp` and not the logind sessions GNU shows. No pid liveness check is made on utmp entries.
3. **No DNS** (`--lookup` does nothing); the account lookup reads `/etc/passwd` only (decision 0004).
4. **`.pgpkey`** is not shown, matching GNU 9.7 as observed.
5. **`--version`** prints `pinky (util-unix) VERSION`.

## Platforms

Linux only. The executable is static and does not link libc. Tested on x86-64 Linux 6.18 (WSL2).
