util-unix — Specification
Status: Draft 0.2
Implementation language: Zig
Engineering policy: AGENTS.md
Scope: Unix/POSIX-specific system utilities
1. Purpose
util-unix is an independent collection of Unix-oriented system utilities written in Zig. It complements, but does not depend on, the portable Core Utils project.

Unlike Core Utils, util-unix targets operations whose useful semantics depend on Unix/POSIX facilities. It does not duplicate commands maintained by upstream util-linux. The project is not required to run on Windows, and Linux-only utilities are permitted when their interfaces are explicitly identified.

The project complements rather than replaces upstream util-linux. Its name does not imply affiliation with that project. Command ownership is determined by function and existing upstream maintenance, not historical GNU package boundaries.
2. Goals
1. Implement useful Unix/POSIX-specific commands in Zig that are not already maintained by upstream util-linux or assigned to Core Utils.
2. Preserve established command-line interfaces and behavior where practical, documenting deliberate deviations.
3. Separate portable Unix/POSIX functionality from Linux-specific backends and commands.
4. Support Linux as the initial target, including musl- and glibc-based environments where practical.
5. Support other Unix-like systems only for commands with meaningful implementations on those platforms.
6. Provide reusable native Zig modules for Unix-specific operations when justified by actual command implementations.
7. Support individual command executables by default and optional multicall builds.
8. Provide clear diagnostics, safe failure behavior, and extensive tests for privileged or destructive operations.
3. Non-goals
- Supporting Windows as a general target.
- Reimplementing commands whose primary semantics are portable and belong in Core Utils.
- Reimplementing or replacing commands maintained by upstream util-linux, including their Linux-specific administration tools.
- Reimplementing a shell, init system, login manager, or device manager as an incidental part of this project.
- Hiding Linux-specific functionality behind misleading claims of universal POSIX support.
- Requiring DKBuilder, DKDE, or a particular distribution.
4. Scope and command classification
A proposed command MUST be checked against the current upstream util-linux command inventory and the Core Utils project before implementation. Command names already maintained by util-linux are out of scope, even if they would otherwise fit util-unix's Unix-specific theme. Reevaluate ownership if an upstream project changes its inventory; do not assume this document is an exhaustive or permanent catalog.
Category	Scope	Examples for evaluation
Unix identities and permissions	Unix ownership, group membership, and permission semantics not owned by util-linux	chmod, chown, chgrp, id, groups
Unix account/database lookup	System databases and identity lookup	getent
Terminal and OS identity	Unix-oriented commands not owned by util-linux or Core Utils	tty, uname (ownership to resolve)
Account administration	Optional, security-sensitive scope; avoid duplicating established implementations without a documented reason	useradd, userdel, usermod (deferred)


These examples are candidates, not a commitment to implement them. A command also needs an explicit ownership decision and a useful, maintainable implementation scope.
4.1 Relationship with upstream util-linux
- util-unix MUST NOT intentionally duplicate commands maintained by upstream util-linux.
- util-unix MUST NOT duplicate commands assigned to the Core Utils project.
- Before approving a command, check the upstream util-linux source or official command inventory, record the checked version/revision, and document its intended owner.
- If a name conflicts with an existing command, resolve the conflict before implementation; an exception requires an explicit architectural decision and must not silently violate the no-overlap policy.
- Reuse of common operating-system interfaces, algorithms, or Zig modules is allowed; the prohibition concerns duplicated commands, not shared technical concepts.
- Linux-specific tools already maintained by util-linux remain outside this project. Examples include mount, umount, lsblk, fdisk, blkid, dmesg, losetup, flock, setsid, and taskset.
5. Boundary with Core Utils
- Core Utils owns the portable cross-platform commands selected in its SPEC.md, including portable file, text, stream, and general-purpose operations.
- util-unix owns approved Unix/POSIX-specific commands only when they are not maintained by util-linux and not assigned to Core Utils.
- A command MUST have one authoritative owner among these projects; do not maintain competing implementations.
- Classification is based on semantics and existing command ownership, not on historical GNU package membership alone.
- Shared parsing or data structures MAY become independent Zig libraries when justified; neither project is required to depend on the other.
Initial ownership proposal: chmod, chown, and chgrp belong in util-unix because of their Unix permission/ownership semantics, subject to a final cross-project inventory review. find, grep, sed, and diff remain in Core Utils. tty and uname needed an explicit decision because they have historically been included in GNU coreutils; decision 0005 assigns them (with id and groups) to util-unix, and they must not appear in both projects.
6. Compatibility and portability
6.1 Reference behavior
For each command, identify the relevant upstream manual and version, POSIX standard if applicable, Linux manual pages, kernel documentation, and any deliberate deviations.
- Default flags, argument parsing, output, and exit codes SHOULD match a documented reference implementation.
- Linux-specific options MUST be identified as such.
- Unsupported functionality MUST fail clearly; do not silently emulate privileged operations.
- Do not claim POSIX compliance for commands or options outside POSIX.
6.2 Platform support
Platform	Initial policy
Linux (musl)	Primary target
Linux (glibc)	Primary target
FreeBSD / other BSD	Optional, per-command
macOS	Optional, per-command
Windows	Out of scope


Per-command support MUST be documented; successful compilation alone does not establish behavioral compatibility.
6.3 Terminal color policy
Few util-unix commands are expected to colorize output, but any command that does (including future ones) MUST follow this policy.
- Reference policy: Core Utils SPEC §5.4 (~/de/core-utils/ai/SPECS.md). The rules below restate what this project must implement; if the two ever differ, resolve the difference deliberately rather than letting them drift.
- NO_COLOR: when the NO_COLOR environment variable is set to a non-empty string (any value, including "0"), color MUST NOT be added by default. An empty value is treated as unset. (Convention: https://no-color.org; wording paraphrased from memory, to be checked against the site at the next review.)
- Precedence, highest first: an explicit option (--color=always forces color, --color=never forbids it); configuration; NO_COLOR; automatic detection. Automatic detection enables color only when the output stream is a terminal and TERM is not "dumb".
- The decision is made per output stream: stderr is judged by whether stderr is a terminal, independently of stdout.
- NO_COLOR removes color only, as the convention says. Text styles that are not colors (bold, faint, italic, underline, reverse) are not affected by NO_COLOR and follow terminal detection. "Color" means any SGR parameter that sets a foreground or background color (30-37, 38, 39, 40-47, 48, 49, 90-97, 100-107). An explicit --color=never disables every SGR sequence, color and styles alike, because it is the explicit request for plain output (project decision, as bat does); TERM=dumb and a non-terminal stream under auto also get none. Where a tool uses color to tell things apart (for example gray for secondary text) it falls back to a non-color style such as faint when only color is off. Non-escape decorations such as line numbers and grids are controlled by their own options, not by NO_COLOR.
- Deliberate deviation from upstream: where an upstream tool offers --color=auto, ours also honor NO_COLOR under auto. Explicit --color=always still forces color. Record this in the command's compatibility record.
- Tests: each part that can emit SGR sequences needs tests for NO_COLOR set, set to empty, TERM=dumb, and overridden by an explicit option, with a terminal on the output stream.
7. Architecture
7.1 Native Zig implementation
- Library first (decision 0002): each command's logic lives in the Zig module `util_unix` (src/lib/, exported from build.zig) and takes std.Io; the executables in src/commands/ are thin wrappers that parse arguments, call the library, and format diagnostics. Other projects (for example DKDE) depend on the module.
- Use Zig modules for reusable system operations where useful.
- Separate command-line parsing from privileged operations and system interfaces.
- Keep Linux-specific implementations behind explicit backend boundaries where cross-Unix support is intended.
- Avoid speculative abstraction for commands that are inherently Linux-specific.
- Explicitly document allocator ownership, file-descriptor lifetimes, cleanup, and error propagation.
7.2 Privilege boundaries
- Prefer unprivileged inspection paths whenever possible.
- Privileged operations MUST check inputs and report failure clearly.
- Never infer authorization from a successful path lookup alone.
- Use explicit confirmation or dry-run support for destructive operations where suitable; document cases where automation requires noninteractive operation.
- Do not log secrets, credentials, or sensitive kernel data unnecessarily.
- Separate read-only inspection from mutation when practical.
7.3 Optional C interface
- Zig modules are the native API for Zig consumers.
- Optional C static/shared library targets MAY expose reusable operations when cross-language use justifies them.
- The C API and ABI MUST be labeled experimental and unstable until a separately documented stability decision is made.
- FFI design MUST define ownership, error codes, and platform availability; do not export raw internal Zig structures.
8. Executable build modes
1. Individual executables (default): one binary per selected command.
2. Multicall by invocation name: dispatch using argv[0] and installed links/copies.
3. Multicall by subcommand: util-unix <command> [arguments...] (binary name `util-unix`; no final decision yet).
All applicable modes MUST invoke the same command implementation. The build SHOULD permit selecting commands and disabling Linux-only tools on unsupported targets.
9. Safety, reliability, and diagnostics
- Treat device metadata, mount tables, paths, environment variables, and user-supplied arguments as untrusted.
- Validate sizes, offsets, identifiers, and integer conversions.
- Avoid destructive operations on ambiguous filesystem targets, users, or groups; identify the intended target clearly.
- Prefer atomic or recoverable operations when the underlying OS supports them.
- Use stderr for diagnostics; preserve stdout for normal command results.
- Provide clear error codes and actionable messages for permission failures and unsupported kernel features.
- Rate-limit or disable verbose diagnostics in hot paths.
10. Performance and resource behavior
- Avoid expensive filesystem traversals or repeated account/database lookups when a cheaper reliable method exists.
- Prefer bounded buffers and streaming output.
- Do not spawn background services as an incidental consequence of invoking a utility.
- Keep startup overhead small for frequently invoked commands.
- Benchmark relevant operations before claiming superiority over upstream tools.
11. Testing
- Provide unit tests for parsing, conversion, validation, and data structures.
- Provide command integration tests for exit codes, stdout/stderr, and option compatibility.
- Use Linux containers, VMs, temporary filesystems, and synthetic fixtures where appropriate; use disposable devices only if an approved command genuinely requires them.
- Destructive tests MUST run only against isolated disposable resources, never arbitrary host devices.
- Privilege-requiring tests MUST be explicitly gated and skipped safely when prerequisites are absent.
- Test both supported libc environments where feasible.
- Verify commands in each supported executable packaging mode.
- Track platform and kernel feature limitations explicitly.
12. Documentation
- AGENTS.md: portable Zig engineering rules.
- SPEC.md: this project's requirements and command scope.
- docs/architecture.md: implemented components and OS boundaries.
- docs/decisions/: reasons behind architectural and compatibility decisions.
- docs/manpages/: per-command manuals following docs/manpages/template.md.
- docs/compatibility/: recommended command-level references, supported platforms, and deviations.
Each command's manual page MUST document supported operating systems, privilege requirements, relevant side effects, and failure behavior.
13. Proposed inventory for review
This is a small initial candidate list, not a promise of coverage. None of these commands may be implemented until their ownership is checked against the current upstream util-linux inventory and Core Utils specification.
Command	Category	Status
split	Output splitting	Not here — portable; owned by Core Utils (removed from util-unix in 4f2ba4c)
chgrp	Group ownership	Implemented — decision 0005
chmod	File permissions	Implemented — decision 0005
chown	File ownership	Implemented — decision 0005
getent	System database lookup	Implemented (files backend only, decision 0004) — portability to other Unix systems not yet reviewed
groups	User identity	Implemented — decision 0005
id	User identity	Implemented — decision 0005
tty	Terminal identity	Implemented — decision 0005
uname	OS identity	Implemented — decision 0005
useradd	Account management	Deferred — scope/security review; consider existing shadow utilities
userdel	Account management	Deferred — scope/security review; consider existing shadow utilities
usermod	Account management	Deferred — scope/security review; consider existing shadow utilities


13.1 Explicit exclusions: upstream util-linux
The following are examples of excluded util-linux commands, not implementation candidates: arch, blkid, blockdev, chrt, dmesg, fdisk, findmnt, flock, fsck, kill, logger, login, losetup, lsblk, lscpu, lsmem, mount, mountpoint, nsenter, partx, prlimit, renice, sfdisk, setpriv, setsid, su, swapoff, swapon, taskset, umount, unshare, and wipefs.

This exclusion list is illustrative and MUST NOT substitute for checking the current upstream inventory. Additional commands owned by util-linux are excluded even if not named here.
14. Open design decisions
0. (Resolved: `split` is portable and owned by Core Utils; removed here.)
1. (Resolved by decision 0005: chmod, chown, chgrp, id, groups, tty and uname belong to util-unix. Open follow-up: remove the duplicate copies from Core Utils.)
2. Whether account-management commands belong here or should remain with an established project such as shadow.
3. Which approved commands are Linux-only versus portable across Unix-like systems.
4. Whether the approved inventory warrants a shared native Zig library, and which APIs are genuinely reusable.
5. How to test privileged and potentially destructive commands safely in CI.
6. Whether C FFI builds are included in early releases.
7. Which platform-specific interfaces and minimum versions are needed by approved commands.
8. How to keep the ownership inventory synchronized with changes in upstream util-linux and Core Utils.
15. Initial acceptance criteria
- At least one approved read-only Unix utility builds and passes tests on Linux with musl and glibc, or the unverified target is documented.
- Command behavior, platform scope, and deviations are documented.
- Individual and applicable multicall builds share a tested implementation.
- Privileged and destructive tests cannot accidentally target real host devices.
- No dependency on Core Utils, DKBuilder, DKDE, or a particular distribution is required.
- No implemented command overlaps the verified upstream util-linux inventory or Core Utils ownership list.
- Documentation identifies authoritative references and limitations.
References to consult during implementation: POSIX Shell and Utilities; Linux man-pages; Linux kernel documentation; official util-linux command inventory/source (for exclusion checks); relevant BSD/macOS manuals for supported commands. This draft does not claim that each candidate command has been verified against those sources.