//! `config.json`: schema, load/save and pure URL/name helpers.
//! Invariants: I12 (a failed or interrupted save never leaves a partial
//! `config.json`; saves are tmp+rename atomic), I13 (source names are unique
//! and valid; `load` rejects duplicate names and unknown versions),
//! I14 (`extractRepoName` round-trips every URL form over valid names and its
//! result always passes `validateName` or errors).

const std = @import("std");
const serde = @import("serde");

pub const SourceRepo = struct {
    name: []const u8,
    url: []const u8,
    ref: ?[]const u8 = null,
};

pub const Config = struct {
    version: u32 = 1,
    sources: []const SourceRepo = &.{},
};

/// A `Config` whose strings live in an arena freed by `deinit`.
pub const ManagedConfig = struct {
    arena: std.heap.ArenaAllocator,
    value: Config,

    pub fn deinit(self: *ManagedConfig) void {
        self.arena.deinit();
    }
};

/// Reads `sub_path` from `dir`. A missing file yields the defaults (I13);
/// a present file must be a valid v1 config.
pub fn load(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !ManagedConfig {
    const bytes = dir.readFileAlloc(io, sub_path, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return .{ .arena = std.heap.ArenaAllocator.init(a), .value = .{} },
        else => return e,
    };
    defer a.free(bytes);

    var managed = ManagedConfig{
        .arena = std.heap.ArenaAllocator.init(a),
        .value = undefined,
    };
    errdefer managed.arena.deinit();
    managed.value = try serde.json.fromSlice(Config, managed.arena.allocator(), bytes);
    if (managed.value.version != 1) return error.UnsupportedConfigVersion;
    try validate(managed.value);
    return managed;
}

/// Atomically writes `config.json` into `dir` (I12).
pub fn save(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cfg: Config) !void {
    const bytes = try serde.json.toSlice(a, cfg);
    defer a.free(bytes);

    var af = try dir.createFileAtomic(io, "config.json", .{ .replace = true });
    defer af.deinit(io);
    var buf: [4096]u8 = undefined;
    var w = af.file.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.flush();
    try af.replace(io);
}

pub const ValidateError = error{
    DuplicateSourceName,
    InvalidName,
};

pub fn validate(cfg: Config) ValidateError!void {
    for (cfg.sources, 0..) |s, i| {
        try validateName(s.name);
        for (cfg.sources[0..i]) |o| {
            if (std.mem.eql(u8, o.name, s.name)) return error.DuplicateSourceName;
        }
    }
}

/// `[A-Za-z0-9._-]+`, not `.` or `..`, must not start with `-` or `.`,
/// at most 128 bytes (I14).
pub fn validateName(name: []const u8) ValidateError!void {
    if (name.len == 0 or name.len > 128 or name[0] == '-' or name[0] == '.') {
        return error.InvalidName;
    }
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) {
            return error.InvalidName;
        }
    }
}

/// Derives a source name from a repository URL (I14). https/scp/ssh/file and
/// local forms, optional query/fragment, trailing `/` and `.git` suffix.
pub fn extractRepoName(url: []const u8) ![]const u8 {
    var s = url;
    if (std.mem.indexOfAny(u8, s, "?#")) |i| s = s[0..i];
    s = std.mem.trimEnd(u8, s, "/");
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];
    const cut = std.mem.lastIndexOfAny(u8, s, "/:") orelse return error.CannotDeriveName;
    const name = s[cut + 1 ..];
    try validateName(name);
    return name;
}

/// True when a scheme URL carries `user:password@` credentials.
pub fn hasCredentials(url: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    var rest = url[scheme_end + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return false;
    return std.mem.indexOfScalar(u8, rest[0..at], ':') != null;
}

test "extractRepoName URL table (b: illustrative, README forms — I14)" {
    const cases = [_]struct { url: []const u8, name: []const u8 }{
        .{ .url = "https://host.io/org/repo.git/", .name = "repo" },
        .{ .url = "git@host.io:org/repo.git", .name = "repo" },
        .{ .url = "ssh://git@host.io:22/org/repo", .name = "repo" },
        .{ .url = "file:///p/r", .name = "r" },
        .{ .url = "/p/r", .name = "r" },
        .{ .url = "https://host.io/org/repo?query=1#frag", .name = "repo" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.name, try extractRepoName(c.url));
    }
    try std.testing.expectError(error.CannotDeriveName, extractRepoName("noseparator"));
    try std.testing.expectError(error.InvalidName, extractRepoName("https://h/o/-bad"));
}

test "load defaults and unknown fields (b: illustrative, hand-editable config — I13)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    var dflt = try load(a, io, t.dir, "config.json");
    defer dflt.deinit();
    try std.testing.expectEqual(@as(u32, 1), dflt.value.version);
    try std.testing.expectEqual(@as(usize, 0), dflt.value.sources.len);

    try t.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{}" });
    var empty = try load(a, io, t.dir, "config.json");
    defer empty.deinit();
    try std.testing.expectEqual(@as(u32, 1), empty.value.version);
    try std.testing.expectEqual(@as(usize, 0), empty.value.sources.len);

    try t.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"version\":1,\"future\":true}" });
    var future = try load(a, io, t.dir, "config.json");
    defer future.deinit();
    try std.testing.expectEqual(@as(u32, 1), future.value.version);
}
