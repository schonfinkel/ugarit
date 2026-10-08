pub const paths = @import("paths.zig");
pub const config = @import("config.zig");
pub const git = @import("git.zig");
pub const discovery = @import("discovery.zig");
pub const symlink = @import("symlink.zig");
pub const registry = @import("Registry.zig");
pub const Registry = registry.Registry;
pub const app = @import("app.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
