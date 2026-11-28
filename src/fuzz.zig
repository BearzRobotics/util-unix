// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz-test root (decision 0010). `zig build fuzz` runs every fuzz test once on its
//! corpus; `zig build fuzz` (through tools/fuzz.sh) is the campaign; never pass --fuzz.
//! `zig build test` also runs them once, as regression tests.
//!
//! One file per area under src/fuzz/, each owned by one author so edits do not
//! collide; add a file by adding a line here.

test {
    _ = @import("fuzz/engine.zig");
    _ = @import("fuzz/limits.zig");
    _ = @import("fuzz/userdb.zig");
    _ = @import("fuzz/getent.zig");
    _ = @import("fuzz/utmp.zig");
    _ = @import("fuzz/pinky.zig");
    _ = @import("fuzz/stty.zig");
    _ = @import("fuzz/mode.zig");
    _ = @import("fuzz/userspec.zig");
    _ = @import("fuzz/ownership.zig");
    _ = @import("fuzz/identity.zig");
    _ = @import("fuzz/system.zig");
    _ = @import("fuzz/selinux.zig");
    _ = @import("fuzz/json.zig");
    _ = @import("fuzz/sh.zig");
}
