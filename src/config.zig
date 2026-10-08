//! `config.json`: schema, load/save and pure URL/name helpers.
//! Invariants (see `src/test/INVARIANTS.md`):
//! - Failure atomicity: a failed or interrupted save never leaves a partial
//!   `config.json`; saves are tmp+rename atomic.
//! - Config well-formedness: source names are unique and valid; `load`
//!   rejects duplicate names and unknown versions.
//! - `extractRepoName` totality: round-trips every URL form over valid names,
//!   and its result always passes `validateName` or errors.

const std = @import("std");
const serde = @import("serde");

pub const SourceRepo = struct {
    name: []const u8,
    url: []const u8,
    ref: ?[]const u8 = null,
};

pub const Config = struct {
    version: u32 = 1,
    default_path: ?[]const u8 = null,
    sources: []const SourceRepo = &.{},
};

/// A `Config` whose strings live in an arena freed by `deinit`.
pub const ManagedConfig = struct {
    arena: std.heap.ArenaAllocator,
    value: Config,

    pub fn deinit(self: *ManagedConfig) void {
        self.arena.deinit();
    }

    pub fn find(self: *const ManagedConfig, name: []const u8) ?*const SourceRepo {
        for (self.value.sources) |*source| {
            if (std.mem.eql(u8, source.name, name)) return source;
        }
        return null;
    }

    pub fn findUrl(self: *const ManagedConfig, url: []const u8) ?*const SourceRepo {
        for (self.value.sources) |*source| {
            if (sameUrl(source.url, url)) return source;
        }
        return null;
    }

    /// Copies `source` and its strings into this config's arena. On OOM the
    /// visible config is unchanged; any completed allocations remain arena-owned.
    pub fn append(self: *ManagedConfig, source: SourceRepo) error{OutOfMemory}!void {
        const a = self.arena.allocator();
        const sources = try a.alloc(SourceRepo, self.value.sources.len + 1);
        @memcpy(sources[0..self.value.sources.len], self.value.sources);
        sources[sources.len - 1] = .{
            .name = try a.dupe(u8, source.name),
            .url = try a.dupe(u8, source.url),
            .ref = if (source.ref) |ref| try a.dupe(u8, ref) else null,
        };
        self.value.sources = sources;
    }
};

/// Reads `sub_path` from `dir`. A missing file yields the defaults (config
/// well-formedness); a present file must be a valid v1 config.
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

/// Atomically writes `config.json` into `dir` (failure atomicity).
pub fn save(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cfg: Config) !void {
    const bytes = serde.json.toSlice(a, cfg) catch |err| switch (err) {
        // serde's allocating writer erases allocator failure to WriteFailed.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
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
/// at most 128 bytes (`extractRepoName` totality).
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

/// Derives a source name from a repository URL (`extractRepoName` totality).
/// https/scp/ssh/file and local forms, optional query/fragment, trailing `/`
/// and `.git` suffix.
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
    return credentialRange(url) != null;
}

/// Compares repository URLs after lowercasing the scheme for comparison and
/// removing trailing slashes and one trailing `.git` suffix.
pub fn sameUrl(a: []const u8, b: []const u8) bool {
    const x = normalizedUrl(a);
    const y = normalizedUrl(b);
    const x_scheme = std.mem.indexOf(u8, x, "://");
    const y_scheme = std.mem.indexOf(u8, y, "://");
    if (x_scheme != null and y_scheme != null) {
        const xi = x_scheme.?;
        const yi = y_scheme.?;
        return std.ascii.eqlIgnoreCase(x[0..xi], y[0..yi]) and
            std.mem.eql(u8, x[xi..], y[yi..]);
    }
    return std.mem.eql(u8, x, y);
}

/// Writes `url`, replacing a scheme URL's password with `***`.
pub fn redact(writer: *std.Io.Writer, url: []const u8) std.Io.Writer.Error!void {
    const range = credentialRange(url) orelse return writer.writeAll(url);
    try writer.writeAll(url[0 .. range.colon + 1]);
    try writer.writeAll("***");
    try writer.writeAll(url[range.at..]);
}

fn normalizedUrl(url: []const u8) []const u8 {
    var result = std.mem.trimEnd(u8, url, "/");
    if (std.mem.endsWith(u8, result, ".git")) result = result[0 .. result.len - 4];
    return result;
}

fn credentialRange(url: []const u8) ?struct { colon: usize, at: usize } {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const authority_start = scheme_end + 3;
    const rest = url[authority_start..];
    const authority_len = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_len];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return null;
    const colon = std.mem.indexOfScalar(u8, authority[0..at], ':') orelse return null;
    return .{ .colon = authority_start + colon, .at = authority_start + at };
}

test "extractRepoName URL table (b: illustrative, README forms)" {
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

test "source lookup uses names and normalized URLs" {
    var managed = ManagedConfig{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .value = .{},
    };
    defer managed.deinit();

    try managed.append(.{ .name = "skills", .url = "HTTPS://host/org/skills.git/", .ref = "main" });
    try std.testing.expectEqualStrings("skills", managed.find("skills").?.name);
    try std.testing.expect(managed.find("missing") == null);
    try std.testing.expectEqualStrings("skills", managed.findUrl("https://host/org/skills").?.name);
    try std.testing.expect(managed.findUrl("ssh://host/org/skills") == null);
}

test "redact hides only scheme URL passwords" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try redact(&writer, "https://user:p@ss@host/repo.git?token=visible");
    try std.testing.expectEqualStrings(
        "https://user:***@host/repo.git?token=visible",
        writer.buffered(),
    );
    try std.testing.expect(hasCredentials("https://user:secret@host/repo"));
    try std.testing.expect(!hasCredentials("git@host:org/repo.git"));
}

fn appendAllocationFailures(a: std.mem.Allocator) !void {
    var managed = ManagedConfig{
        .arena = std.heap.ArenaAllocator.init(a),
        .value = .{},
    };
    defer managed.deinit();

    managed.append(.{ .name = "skills", .url = "https://host/skills.git", .ref = "main" }) catch |e| {
        try std.testing.expectEqual(@as(usize, 0), managed.value.sources.len);
        return e;
    };
    try std.testing.expectEqual(@as(usize, 1), managed.value.sources.len);
    try std.testing.expectEqualStrings("skills", managed.value.sources[0].name);
}

test "append remains valid on every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        appendAllocationFailures,
        .{},
    );
}

const SaveOomContext = struct { io: std.Io, dir: std.Io.Dir };

fn saveAllocationFailures(a: std.mem.Allocator, context: SaveOomContext) !void {
    const original = "{\"version\":1,\"sources\":[]}";
    try context.dir.writeFile(context.io, .{ .sub_path = "config.json", .data = original });
    save(a, context.io, context.dir, .{ .sources = &.{.{
        .name = "central",
        .url = "https://example.test/central.git",
    }} }) catch |err| {
        const bytes = try context.dir.readFileAlloc(
            context.io,
            "config.json",
            std.testing.allocator,
            .limited(1024),
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(original, bytes);
        return err;
    };
}

test "save preserves config bytes under every OOM (a: exhaustive allocation failures)" {
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        saveAllocationFailures,
        .{SaveOomContext{ .io = io, .dir = t.dir }},
    );
}

test "load defaults and unknown fields (b: illustrative, hand-editable config)" {
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
