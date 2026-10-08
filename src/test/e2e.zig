const std = @import("std");
const ugarit = @import("ugarit");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Result, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn run(
    a: std.mem.Allocator,
    io: std.Io,
    exe: []const u8,
    env: *const std.process.Environ.Map,
    argv_tail: []const []const u8,
) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, exe);
    try argv.appendSlice(a, argv_tail);
    const result = try std.process.run(a, io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

fn expectExit(expected: u8, result: Result) !void {
    switch (result.term) {
        .exited => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.UnexpectedTermination,
    }
}

test "binary core flow fans out, syncs, repairs and unlinks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const exe_ptr = getenv("UGARIT_EXE") orelse return error.MissingUgaritExe;
    const exe = std.mem.span(exe_ptr);
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    var libgit = try ugarit.git.fixtures.Libgit2.init();
    defer libgit.deinit();

    const origin = try ugarit.git.fixtures.initOrigin(a, io, t.dir, "origin");
    defer a.free(origin);
    try ugarit.git.fixtures.commitFile(io, origin, "zig/SKILL.md", "v1\n");
    try t.dir.createDirPath(io, "home");
    try t.dir.createDirPath(io, "projects/a");
    try t.dir.createDirPath(io, "projects/b");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const home = try std.fs.path.join(a, &.{ root, "home" });
    defer a.free(home);
    const ugarit_home = try std.fs.path.join(a, &.{ home, "ugarit" });
    defer a.free(ugarit_home);
    const dest_a = try std.fs.path.join(a, &.{ root, "projects/a/.claude/skills" });
    defer a.free(dest_a);
    const dest_b = try std.fs.path.join(a, &.{ root, "projects/b/.claude/skills" });
    defer a.free(dest_b);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("UGARIT_HOME", ugarit_home);

    {
        const result = try run(a, io, exe, &env, &.{ "source-add", origin });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectStringStartsWith(result.stdout, "added ");
    }
    {
        const result = try run(a, io, exe, &env, &.{
            "link",
            "origin",
            "zig",
            dest_a,
            dest_b,
            "--mkdir",
            "--no-exclude",
        });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.stdout, "created "));
    }

    try ugarit.git.fixtures.commitFile(io, origin, "zig/SKILL.md", "v2\n");
    {
        const result = try run(a, io, exe, &env, &.{"source-sync"});
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "updated") != null);
    }
    const linked_a = try std.fs.path.join(a, &.{ dest_a, "zig/SKILL.md" });
    defer a.free(linked_a);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, linked_a, a, .limited(64));
    defer a.free(content);
    try std.testing.expectEqualStrings("v2\n", content);

    try ugarit.git.fixtures.moveFile(io, origin, "zig/SKILL.md", "lang/zig/SKILL.md");
    {
        const result = try run(a, io, exe, &env, &.{"source-sync"});
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.stdout, "repaired "));
    }
    {
        const result = try run(a, io, exe, &env, &.{ "list", "--links", "zig" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.stdout, "  ok\n"));
    }
    try ugarit.git.fixtures.deleteFile(io, origin, "lang/zig/SKILL.md");
    {
        const result = try run(a, io, exe, &env, &.{"source-sync"});
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.stderr, "dangling "));
    }
    {
        const result = try run(a, io, exe, &env, &.{ "list", "--links", "zig" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.stdout, "  dangling\n"));
    }
    {
        const result = try run(a, io, exe, &env, &.{ "unlink", "--skill", "zig" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.stdout, "removed "));
    }
}

test "binary usage errors exit two" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const exe_ptr = getenv("UGARIT_EXE") orelse return error.MissingUgaritExe;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/tmp");
    try env.put("UGARIT_HOME", "/tmp/ugarit-e2e-unused");
    const result = try run(a, io, std.mem.span(exe_ptr), &env, &.{ "link", "zig" });
    defer result.deinit(a);
    try expectExit(2, result);
}

test "binary link selects a source and uses the configured default path" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const exe_ptr = getenv("UGARIT_EXE") orelse return error.MissingUgaritExe;
    const exe = std.mem.span(exe_ptr);
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    var libgit = try ugarit.git.fixtures.Libgit2.init();
    defer libgit.deinit();

    const personal_origin = try ugarit.git.fixtures.initOrigin(a, io, t.dir, "personal-origin");
    defer a.free(personal_origin);
    try ugarit.git.fixtures.commitFile(io, personal_origin, "zig/SKILL.md", "personal\n");
    const team_origin = try ugarit.git.fixtures.initOrigin(a, io, t.dir, "team-origin");
    defer a.free(team_origin);
    try ugarit.git.fixtures.commitFile(io, team_origin, "zig/SKILL.md", "team\n");
    try t.dir.createDirPath(io, "home");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const home = try std.fs.path.join(a, &.{ root, "home" });
    defer a.free(home);
    const ugarit_home = try std.fs.path.join(a, &.{ home, "ugarit" });
    defer a.free(ugarit_home);
    const default_dest = try std.fs.path.join(a, &.{ root, "default/.claude/skills" });
    defer a.free(default_dest);
    const explicit_dest = try std.fs.path.join(a, &.{ root, "explicit/.claude/skills" });
    defer a.free(explicit_dest);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("UGARIT_HOME", ugarit_home);

    for ([_]struct { name: []const u8, origin: []const u8 }{
        .{ .name = "personal", .origin = personal_origin },
        .{ .name = "team", .origin = team_origin },
    }) |source| {
        const result = try run(a, io, exe, &env, &.{ "source-add", source.origin, "--name", source.name });
        defer result.deinit(a);
        try expectExit(0, result);
    }

    {
        const result = try run(a, io, exe, &env, &.{ "link", "personal", "zig", "--no-exclude" });
        defer result.deinit(a);
        try expectExit(1, result);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "default_path is not configured") != null);
    }

    {
        var root_dir = try std.Io.Dir.openDirAbsolute(io, ugarit_home, .{});
        defer root_dir.close(io);
        var cfg = try ugarit.config.load(a, io, root_dir, "config.json");
        defer cfg.deinit();
        cfg.value.default_path = default_dest;
        try ugarit.config.save(a, io, root_dir, cfg.value);
    }

    {
        const result = try run(a, io, exe, &env, &.{ "link", "personal", "zig", "--mkdir", "--no-exclude" });
        defer result.deinit(a);
        try expectExit(0, result);
    }
    {
        const result = try run(a, io, exe, &env, &.{ "link", "team", "zig", explicit_dest, "--mkdir", "--no-exclude" });
        defer result.deinit(a);
        try expectExit(0, result);
    }

    const default_skill = try std.fs.path.join(a, &.{ default_dest, "zig/SKILL.md" });
    defer a.free(default_skill);
    const default_content = try std.Io.Dir.cwd().readFileAlloc(io, default_skill, a, .limited(64));
    defer a.free(default_content);
    try std.testing.expectEqualStrings("personal\n", default_content);

    const explicit_skill = try std.fs.path.join(a, &.{ explicit_dest, "zig/SKILL.md" });
    defer a.free(explicit_skill);
    const explicit_content = try std.Io.Dir.cwd().readFileAlloc(io, explicit_skill, a, .limited(64));
    defer a.free(explicit_content);
    try std.testing.expectEqualStrings("team\n", explicit_content);
}

test "binary list on a fresh home creates nothing" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const exe_ptr = getenv("UGARIT_EXE") orelse return error.MissingUgaritExe;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(io, "home");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const home = try std.fs.path.join(a, &.{ root_buf[0..root_len], "home" });
    defer a.free(home);
    const fresh = try std.fs.path.join(a, &.{ home, ".config/ugarit" });
    defer a.free(fresh);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    const result = try run(a, io, std.mem.span(exe_ptr), &env, &.{"list"});
    defer result.deinit(a);
    try expectExit(0, result);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, fresh, .{ .follow_symlinks = false }),
    );
}
