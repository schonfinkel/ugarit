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

test "binary link resolves labels, search paths, targets and claude_sync" {
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
    try ugarit.git.fixtures.commitFile(io, personal_origin, ".agents/skills/zig/SKILL.md", "personal\n");
    const team_origin = try ugarit.git.fixtures.initOrigin(a, io, t.dir, "team-origin");
    defer a.free(team_origin);
    try ugarit.git.fixtures.commitFile(io, team_origin, "zig/SKILL.md", "team\n");
    try t.dir.createDirPath(io, "home");
    try t.dir.createDirPath(io, "project");
    try t.dir.createDirPath(io, "plain");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const home = try std.fs.path.join(a, &.{ root, "home" });
    defer a.free(home);
    const ugarit_home = try std.fs.path.join(a, &.{ home, "ugarit" });
    defer a.free(ugarit_home);
    const project = try std.fs.path.join(a, &.{ root, "project" });
    defer a.free(project);
    const plain = try std.fs.path.join(a, &.{ root, "plain" });
    defer a.free(plain);
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(missing);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("UGARIT_HOME", ugarit_home);

    {
        const result = try run(a, io, exe, &env, &.{
            "source-add", personal_origin,  "--name",   "personal",       "--label", "me",
            "--path",     ".agents/skills", "--target", ".agents/skills",
        });
        defer result.deinit(a);
        try expectExit(0, result);
    }
    {
        const result = try run(a, io, exe, &env, &.{
            "source-add", team_origin, "--name", "team", "--no-claude-sync",
        });
        defer result.deinit(a);
        try expectExit(0, result);
    }
    {
        // A label colliding with a name is rejected.
        const result = try run(a, io, exe, &env, &.{ "source-add", team_origin, "--name", "x", "--label", "team" });
        defer result.deinit(a);
        try expectExit(1, result);
    }

    {
        // A destination is required.
        const result = try run(a, io, exe, &env, &.{ "link", "me", "zig" });
        defer result.deinit(a);
        try expectExit(2, result);
    }
    {
        // A missing destination is not created.
        const result = try run(a, io, exe, &env, &.{ "link", "me", "zig", missing, "--no-exclude" });
        defer result.deinit(a);
        try expectExit(1, result);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, missing, .{}));
    }
    {
        const result = try run(a, io, exe, &env, &.{ "link", "me", "zig", project, "--no-exclude" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.stdout, "created "));
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "-> personal/.agents/skills/zig") != null);
    }
    {
        const result = try run(a, io, exe, &env, &.{ "link", "me", "zig", project, "--no-exclude" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.stdout, "unchanged "));
    }
    {
        const result = try run(a, io, exe, &env, &.{ "link", "team", "zig", plain, "--no-exclude" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stdout, "created "));
    }

    {
        // `.claude/skills` aliasing `.agents/skills` gets a single link.
        try t.dir.createDirPath(io, "aliased/.agents/skills");
        try t.dir.createDirPath(io, "aliased/.claude");
        try t.dir.symLink(io, "../.agents/skills", "aliased/.claude/skills", .{ .is_directory = true });
        const aliased = try std.fs.path.join(a, &.{ root, "aliased" });
        defer a.free(aliased);
        const result = try run(a, io, exe, &env, &.{ "link", "me", "zig", aliased, "--no-exclude" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqualStrings("created ", result.stdout[0..8]);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stdout, "\n"));
    }

    for ([_]struct { rel: []const u8, content: []const u8 }{
        .{ .rel = "project/.agents/skills/zig/SKILL.md", .content = "personal\n" },
        .{ .rel = "project/.claude/skills/zig/SKILL.md", .content = "personal\n" },
        .{ .rel = "plain/zig/SKILL.md", .content = "team\n" },
    }) |expected| {
        const full = try std.fs.path.join(a, &.{ root, expected.rel });
        defer a.free(full);
        const content = try std.Io.Dir.cwd().readFileAlloc(io, full, a, .limited(64));
        defer a.free(content);
        try std.testing.expectEqualStrings(expected.content, content);
    }
    const plain_claude = try std.fs.path.join(a, &.{ plain, ".claude" });
    defer a.free(plain_claude);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, plain_claude, .{}));

    {
        const result = try run(a, io, exe, &env, &.{ "list", "--source", "me", "--links" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, result.stdout, "  ok\n"));
    }
    {
        const result = try run(a, io, exe, &env, &.{ "source-sync", "me" });
        defer result.deinit(a);
        try expectExit(0, result);
        try std.testing.expectStringStartsWith(result.stdout, "personal  up-to-date\n");
    }
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
