const std = @import("std");
const git2 = @import("git2");

// git2/common.h git_feature_t bits (enum in C, so referenced numerically here)
const feature_threads: c_int = 1 << 0;
const feature_https: c_int = 1 << 1;
const feature_ssh: c_int = 1 << 2;

pub fn main(init: std.process.Init) !u8 {
    _ = git2.git_libgit2_init();
    defer _ = git2.git_libgit2_shutdown();

    var major: c_int = 0;
    var minor: c_int = 0;
    var rev: c_int = 0;
    _ = git2.git_libgit2_version(&major, &minor, &rev);
    const features = git2.git_libgit2_features();

    const stdout_file = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("ugarit 0.1.0 (libgit2 {d}.{d}.{d})\n", .{ major, minor, rev });
    try stdout.print("features: threads={}, https={}, ssh={}\n", .{
        features & feature_threads != 0,
        features & feature_https != 0,
        features & feature_ssh != 0,
    });
    try stdout.flush();
    return 0;
}
