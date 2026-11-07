//! chown: thin wrapper; see src/ownership_cli.zig and src/lib/ownership.zig.
const cli = @import("../cli.zig");
const shared = @import("../ownership_cli.zig");

pub fn main(ctx: cli.Context) u8 {
    return shared.main(ctx, .chown);
}
