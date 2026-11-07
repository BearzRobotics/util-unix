# who: compatibility record

Status: implemented; 89 differential cases pass against GNU who 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0006.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `who`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/who.html (cited; the page was not re-read when this record was written).
- GNU coreutils 9.7 manual, node "who invocation" and `who --help`, as installed (`who (GNU coreutils) 9.7`).
- utmp(5), Linux man-pages.
- Behaviour was verified by running both binaries on synthetic utmp files (`sh test/test_who.sh`). The upstream source of the reference implementation was not consulted; the column layout was derived from its output.

## What is POSIX and what is an extension

POSIX has `-a -b -d -H -l -m -p -q -r -s -t -T -u`; `--lookup` and the long options are GNU.

## Supported

Every option of GNU who 9.7 except the name lookup: all record kinds (users, boot, run level, clock change, init processes, login processes, dead processes), `-H` headings, `-T` message status, the idle column (`.`, `HH:MM`, `old`, `?`), `-q` counts, `-m`/`am i`, an explicit FILE, and the time column in both styles. Compared: all option letters and combinations, long options and unique abbreviations, short and truncated files, user names longer than 8 characters, lines with and without `/dev/`, three time zones, and the ISO/classic time styles.

## Deliberate deviations and gaps

1. **Reads the utmp file, never systemd-logind.** The GNU build on a systemd machine shows logind sessions when asked for the default file; this program shows the contents of `/var/run/utmp`, so on such a machine the two differ (the tests give an explicit FILE). A missing default file shows nothing.
2. **`--lookup` is accepted and does nothing** (no DNS).
3. **The time style depends on the locale variables only by name:** `LC_ALL`, then `LC_TIME`, then `LANG`; the value `C` or `POSIX` (or none set) gives `Nov  7 13:39`, anything else `2025-11-07 13:39`. GNU asks the C library whether that locale exists, so a variable naming an uninstalled locale gives the classic style there and the ISO style here.
4. **A missing, empty or short FILE shows nothing and exits 0**, as GNU 9.7 does here.
5. **`--version`** prints `who (util-unix) VERSION`.

## Platforms

Linux only (the Linux `struct utmp` layout, 384 bytes). The executable is static and does not link libc. Tested on x86-64 Linux 6.18 (WSL2).
