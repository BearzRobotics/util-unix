# util-unix

Unix/POSIX utilities in Zig, as a **library** (`util_unix`) plus thin
command-line wrappers. Spec: `ai/SPECS.md`. Engineering rules: `ai/AGENTS.md`.

Implemented: `chmod`, `chown`, `chgrp`, `getent`, `id`, `groups`, `tty`, `uname`
(ownership: `docs/decisions/0005-unix-only-commands-belong-here.md`) and
`stty`, `who`, `pinky`, `chcon`, `runcon`, `hostname`
(`docs/decisions/0006-unix-commands-beyond-util-linux-and-raw-ioctl.md`).
Each command's compatibility record (`docs/compatibility/`) lists what was
compared with the reference program and what was not; `runcon`'s transition and
`pinky`'s short format are the unverified parts.

## Build, test, benchmark

```
zig build                      # one binary per command in zig-out/bin, plus util-unix (multicall)
zig build test                 # library and wrapper unit tests
sh test/run_all_tests.sh       # differential tests against the GNU binaries in /usr/bin
OURS_MULTICALL=1 sh test/test_chmod.sh   # same tests through `util-unix chmod`
sh test/vm/run.sh              # QEMU guest tests: terminal, root-only changes, many groups
sh bench/run.sh                # poop comparison with GNU (needs ../poop)
```

## Use as a library (e.g. from DKDE)

`build.zig.zon`:

```zig
.dependencies = .{ .util_unix = .{ .path = "../util-unix" } },  // or .url/.hash
```

`build.zig`:

```zig
const uu = b.dependency("util_unix", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("util_unix", uu.module("util_unix"));
```

Code:

```zig
const uu = @import("util_unix");

// chmod -R go-rwx dir
const Sink = struct {
    fn on(_: ?*anyopaque, ev: uu.chmod.Event) void { _ = ev; } // report or ignore
};
const ok = try uu.chmod.run(io, gpa, "dir", .{
    .change = .{ .mode_text = "go-rwx" },
    .recurse = true,
    .umask = uu.proc.umask(),
    .reporter = .{ .on_event = Sink.on },
});
```

The library takes `std.Io`, parses no arguments, prints nothing and changes no
process state. Failures and progress come back as return values and events.
See decision 0002 and the header comment of each `src/lib/*.zig`.

## Layout

See `docs/architecture.md`.

## License

Copyright (c) 2026 Dakota Keeler and the util-unix contributors.

util-unix is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version (SPDX: `GPL-2.0-or-later`). It is distributed in the hope that it will
be useful, but WITHOUT ANY WARRANTY. The full text is in `LICENSE`. This is an
independent implementation: it does not contain code from GNU coreutils, which
was used only as a behavioural reference.
