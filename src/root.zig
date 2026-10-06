pub const paths = @import("paths.zig");
pub const config = @import("config.zig");
pub const git = @import("git.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
