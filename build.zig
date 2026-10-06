const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libgit2 bindings via translate-c; include/link paths resolve through pkg-config
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.linkSystemLibrary("git2", .{});
    const git2 = translate.createModule();
    git2.linkSystemLibrary("git2", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "git2", .module = git2 },
        },
    });

    const exe = b.addExecutable(.{ .name = "ugarit", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run ugarit").dependOn(&run.step);

    const serde_mod = b.dependency("serde", .{
        .target = target,
        .optimize = optimize,
    }).module("serde");
    const minish_mod = b.dependency("minish", .{
        .target = target,
        .optimize = optimize,
    }).module("minish");

    const core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "serde", .module = serde_mod },
            .{ .name = "git2", .module = git2 },
        },
    });

    const test_step = b.step("test", "Unit and property tests");

    const core_tests = b.addTest(.{ .root_module = core });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const props_mod = b.createModule(.{
        .root_source_file = b.path("src/test/props.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ugarit", .module = core },
            .{ .name = "minish", .module = minish_mod },
        },
    });
    const props_tests = b.addTest(.{ .root_module = props_mod });
    test_step.dependOn(&b.addRunArtifact(props_tests).step);
}
