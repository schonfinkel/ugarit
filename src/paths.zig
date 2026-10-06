//! Path resolution, tilde expansion and the config-dir lock.
//! Invariants: I8 (paths stored in the registry are absolute, canonical and
//! `..`-free — upheld by `canonicalDest`), plus the local invariants
//! PL1 (`expandTilde` is a pure function of `(home, input)`; it only expands a
//! leading `~` or `~/`, and rejects `~user`), and PL2 (`canonicalDest` is
//! idempotent and resolves symlinks, so `canon(canon(p)) == canon(p)`).

const std = @import("std");

pub const Paths = struct {
    root: []const u8,
    config: []const u8,
    sources: []const u8,
    links: []const u8,

    /// Precedence: `flag` > `UGARIT_HOME` > `$XDG_CONFIG_HOME/ugarit` > `$HOME/.config/ugarit`.
    pub fn resolve(
        a: std.mem.Allocator,
        env: *const std.process.Environ.Map,
        flag: ?[]const u8,
    ) !Paths {
        const root = if (flag) |f| try a.dupe(u8, f) else if (env.get("UGARIT_HOME")) |h|
            try a.dupe(u8, h)
        else if (env.get("XDG_CONFIG_HOME")) |x|
            try std.fs.path.join(a, &.{ x, "ugarit" })
        else if (env.get("HOME")) |h|
            try std.fs.path.join(a, &.{ h, ".config", "ugarit" })
        else
            return error.NoHomeDirectory;
        if (!std.fs.path.isAbsolute(root)) {
            a.free(root);
            return error.ConfigDirNotAbsolute;
        }
        return .{
            .root = root,
            .config = try std.fs.path.join(a, &.{ root, "config.json" }),
            .sources = try std.fs.path.join(a, &.{ root, "sources" }),
            .links = try std.fs.path.join(a, &.{ root, "links.json" }),
        };
    }

    pub fn deinit(self: Paths, a: std.mem.Allocator) void {
        a.free(self.root);
        a.free(self.config);
        a.free(self.sources);
        a.free(self.links);
    }
};

pub const TildeError = error{
    UnsupportedTildeUser,
    NoHomeDirectory,
    OutOfMemory,
};

/// Expands a leading `~` or `~/` only; `~user` is rejected (PL1).
pub fn expandTilde(a: std.mem.Allocator, home: ?[]const u8, p: []const u8) TildeError![]u8 {
    if (p.len == 0 or p[0] != '~') return a.dupe(u8, p);
    if (p.len > 1 and p[1] != '/') return error.UnsupportedTildeUser;
    const h = home orelse return error.NoHomeDirectory;
    return std.mem.concat(a, u8, &.{ h, p[1..] });
}

/// Resolves a user-given destination to a canonical absolute path (PL2, I8).
/// The dir must exist unless `mkdir` is set, in which case it is created.
pub fn canonicalDest(
    a: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    raw: []const u8,
    mkdir: bool,
) ![]u8 {
    const expanded = try expandTilde(a, home, raw);
    defer a.free(expanded);

    const abs: []const u8 = if (std.fs.path.isAbsolute(expanded))
        try a.dupe(u8, expanded)
    else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf);
        break :blk try std.fs.path.join(a, &.{ cwd_buf[0..cwd_len], expanded });
    };
    defer a.free(abs);

    if (mkdir) try std.Io.Dir.cwd().createDirPath(io, abs);

    var dir = try std.Io.Dir.openDirAbsolute(io, abs, .{});
    defer dir.close(io);
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp_len = try dir.realPath(io, &rp_buf);
    return a.dupe(u8, rp_buf[0..rp_len]);
}

/// True when `path` equals `base` or lies directly or indirectly under it.
pub fn isUnder(path: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, path, base)) return false;
    if (path.len == base.len) return true;
    if (base.len > 0 and base[base.len - 1] == '/') return true;
    return path[base.len] == '/';
}

/// Exclusive advisory lock on `root/.lock` for mutating commands.
pub fn lock(io: std.Io, root: std.Io.Dir) !std.Io.File {
    return root.createFile(io, ".lock", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |e| switch (e) {
        error.WouldBlock => error.AnotherUgaritRunning,
        else => e,
    };
}

test "resolve precedence (c: un-generatable, hand-built environment)" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    try std.testing.expectError(error.NoHomeDirectory, Paths.resolve(a, &env, null));

    try env.put("HOME", "/home/u");
    var p1 = try Paths.resolve(a, &env, null);
    defer p1.deinit(a);
    try std.testing.expectEqualStrings("/home/u/.config/ugarit", p1.root);

    try env.put("XDG_CONFIG_HOME", "/xdg");
    var p2 = try Paths.resolve(a, &env, null);
    defer p2.deinit(a);
    try std.testing.expectEqualStrings("/xdg/ugarit", p2.root);

    try env.put("UGARIT_HOME", "/ugarit-home");
    var p3 = try Paths.resolve(a, &env, null);
    defer p3.deinit(a);
    try std.testing.expectEqualStrings("/ugarit-home", p3.root);

    var p4 = try Paths.resolve(a, &env, "/flag");
    defer p4.deinit(a);
    try std.testing.expectEqualStrings("/flag", p4.root);
    try std.testing.expectEqualStrings("/flag/sources", p4.sources);

    try std.testing.expectError(
        error.ConfigDirNotAbsolute,
        Paths.resolve(a, &env, "relative"),
    );
}

test "lock is exclusive and non-blocking (c: un-generatable, flock)" {
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    {
        var first = try lock(io, t.dir);
        try std.testing.expectError(error.AnotherUgaritRunning, lock(io, t.dir));
        first.close(io);
    }
    var second = try lock(io, t.dir);
    second.close(io);
}

test "canonicalDest resolves relative paths against cwd (c: no cwd sandbox)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    try t.dir.createDirPath(io, "nested/deep");
    const rel = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/nested", .{t.sub_path});
    defer a.free(rel);

    const got = try canonicalDest(a, io, null, rel, false);
    defer a.free(got);

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const expected = try std.fmt.allocPrint(a, "{s}/nested", .{root_buf[0..root_len]});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, got);
}

test "isUnder (b: illustrative table)" {
    try std.testing.expect(isUnder("/a/b/c", "/a"));
    try std.testing.expect(isUnder("/a", "/a"));
    try std.testing.expect(isUnder("/a/b", "/a/"));
    try std.testing.expect(!isUnder("/ab", "/a"));
    try std.testing.expect(!isUnder("/a", "/a/b"));
}
