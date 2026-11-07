# util-unix

Unix/POSIX utilities in Zig, as a **library** (`util_unix`) plus thin
command-line wrappers. Spec: `ai/SPECS.md`. Engineering rules: `ai/AGENTS.md`.

Implemented: `split` (see `docs/decisions/0001-split-ownership-exception.md`).

## Build, test, benchmark

```
zig build                      # zig-out/bin/split and zig-out/bin/util-unix (multicall)
zig build test                 # library and wrapper unit tests
sh test/run_all_tests.sh       # differential tests against the GNU binaries in /usr/bin
OURS_MULTICALL=1 sh test/test_split.sh   # same tests through `util-unix split`
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
const split = @import("util_unix").split;

var diag: split.Diagnostic = .{};
split.run(io, gpa, .{
    .mode = .{ .lines = 2 },
    .prefix = "part-",
    .alphabet = .decimal,
    .dir = out_dir, // null = current directory
}, input_file, std.Io.File.stdout(), &diag) catch {
    // diag.kind, diag.name(), diag.cause say what failed.
};
```

The library takes `std.Io`, parses no arguments, prints nothing and changes no
process state. See decision 0002 and the header of `src/lib/split.zig`.

## Layout

See `docs/architecture.md`.
