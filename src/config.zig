//! `config.json`: schema, load/save and pure URL/name helpers.
//! Invariants (see `src/test/INVARIANTS.md`):
//! - Failure atomicity: a failed or interrupted save never leaves a partial
//!   `config.json`; saves are tmp+rename atomic.
//! - Config well-formedness: names and labels are unique and valid, paths are
//!   relative and `..`-free; `load` rejects anything else.
//! - `extractRepoName` totality: round-trips every URL form over valid names,
//!   and its result always passes `validateName` or errors.

const std = @import("std");
const serde = @import("serde");

pub const claude_skills_dir = ".claude/skills";

pub const SourceRepo = struct {
    name: []const u8,
    /// Alias accepted wherever a source name is.
    label: ?[]const u8 = null,
    url: []const u8,
    /// Clone subdirectory to scan; overrides `default_search_path`.
    path: ?[]const u8 = null,
    /// Destination subdirectory that receives links.
    target: ?[]const u8 = null,
    /// Also link into `<dest>/.claude/skills`.
    claude_sync: bool = true,
    ref: ?[]const u8 = null,

    /// Clone-relative scan root; `""` is the clone itself.
    pub fn searchPath(self: SourceRepo, cfg: Config) []const u8 {
        return trimRelPath(self.path orelse cfg.default_search_path orelse "");
    }

    /// `target` (`""` = dest itself), plus `.claude/skills` under `claude_sync`.
    pub fn linkSubdirs(self: SourceRepo, buf: *[2][]const u8) []const []const u8 {
        const target = trimRelPath(self.target orelse "");
        buf[0] = target;
        if (!self.claude_sync or std.mem.eql(u8, target, claude_skills_dir)) return buf[0..1];
        buf[1] = claude_skills_dir;
        return buf[0..2];
    }
};

pub const Config = struct {
    version: u32 = 1,
    /// Clone subdirectory to scan when a source sets no `path`.
    default_search_path: ?[]const u8 = null,
    sources: []const SourceRepo = &.{},
};

/// A `Config` whose strings live in an arena freed by `deinit`.
pub const ManagedConfig = struct {
    arena: std.heap.ArenaAllocator,
    value: Config,

    pub fn deinit(self: *ManagedConfig) void {
        self.arena.deinit();
    }

    /// Resolves a source by name or label.
    pub fn find(self: *const ManagedConfig, key: []const u8) ?*const SourceRepo {
        for (self.value.sources) |*source| {
            if (std.mem.eql(u8, source.name, key)) return source;
            if (source.label) |label| if (std.mem.eql(u8, label, key)) return source;
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
            .label = try dupeOptional(a, source.label),
            .url = try a.dupe(u8, source.url),
            .path = try dupeOptional(a, source.path),
            .target = try dupeOptional(a, source.target),
            .claude_sync = source.claude_sync,
            .ref = try dupeOptional(a, source.ref),
        };
        self.value.sources = sources;
    }
};

fn dupeOptional(a: std.mem.Allocator, s: ?[]const u8) error{OutOfMemory}!?[]const u8 {
    return if (s) |value| try a.dupe(u8, value) else null;
}

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

/// Atomically writes an indented `config.json` into `dir` (failure atomicity).
pub fn save(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cfg: Config) !void {
    const bytes = serde.json.toSliceWith(a, cfg, .{ .pretty = true, .indent = 2 }) catch |err| switch (err) {
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
    try w.interface.writeAll("\n");
    try w.flush();
    try af.replace(io);
}

pub const ValidateError = error{
    DuplicateSourceName,
    InvalidName,
    InvalidRelPath,
};

/// Names and labels share one namespace, so `find` is unambiguous.
pub fn validate(cfg: Config) ValidateError!void {
    if (cfg.default_search_path) |p| try validateRelPath(p);
    for (cfg.sources, 0..) |s, i| {
        try validateName(s.name);
        if (s.label) |label| {
            try validateName(label);
            if (std.mem.eql(u8, label, s.name)) return error.DuplicateSourceName;
        }
        if (s.path) |p| try validateRelPath(p);
        if (s.target) |p| try validateRelPath(p);
        for (cfg.sources[0..i]) |o| {
            if (sharesKey(o, s.name)) return error.DuplicateSourceName;
            if (s.label) |label| if (sharesKey(o, label)) return error.DuplicateSourceName;
        }
    }
}

fn sharesKey(source: SourceRepo, key: []const u8) bool {
    if (std.mem.eql(u8, source.name, key)) return true;
    const label = source.label orelse return false;
    return std.mem.eql(u8, label, key);
}

/// Non-empty, relative, NUL-free, no empty/`.`/`..` component; trailing `/`
/// ignored (confinement).
pub fn validateRelPath(path: []const u8) ValidateError!void {
    const p = trimRelPath(path);
    if (p.len == 0 or p.len > 1024 or p[0] == '/') return error.InvalidRelPath;
    if (std.mem.indexOfScalar(u8, p, 0) != null) return error.InvalidRelPath;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.InvalidRelPath;
    }
}

/// Drops trailing slashes.
pub fn trimRelPath(path: []const u8) []const u8 {
    if (path.len != 0 and std.mem.allEqual(u8, path, '/')) return path[0..1];
    return std.mem.trimEnd(u8, path, "/");
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

    try managed.append(.{ .name = "skills", .label = "sk", .url = "HTTPS://host/org/skills.git/", .ref = "main" });
    try std.testing.expectEqualStrings("skills", managed.find("skills").?.name);
    try std.testing.expectEqualStrings("skills", managed.find("sk").?.name);
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

    managed.append(.{
        .name = "skills",
        .label = "sk",
        .url = "https://host/skills.git",
        .path = ".agents/skills",
        .target = ".agents/skills",
        .ref = "main",
    }) catch |e| {
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

test "validate keeps names and labels one unique namespace (b: illustrative table)" {
    const ok: []const SourceRepo = &.{
        .{ .name = "a", .label = "x", .url = "u" },
        .{ .name = "b", .url = "v" },
    };
    try validate(.{ .sources = ok });
    const clashes = [_][]const SourceRepo{
        &.{ .{ .name = "a", .url = "u" }, .{ .name = "a", .url = "v" } },
        &.{.{ .name = "a", .label = "a", .url = "u" }},
        &.{ .{ .name = "a", .label = "x", .url = "u" }, .{ .name = "x", .url = "v" } },
        &.{ .{ .name = "a", .url = "u" }, .{ .name = "b", .label = "a", .url = "v" } },
        &.{ .{ .name = "a", .label = "x", .url = "u" }, .{ .name = "b", .label = "x", .url = "v" } },
    };
    for (clashes) |sources| {
        try std.testing.expectError(error.DuplicateSourceName, validate(.{ .sources = sources }));
    }
    try std.testing.expectError(
        error.InvalidName,
        validate(.{ .sources = &.{.{ .name = "a", .label = "-x", .url = "u" }} }),
    );
}

test "validateRelPath rejects escapes and empty components (b: illustrative table)" {
    const good = [_][]const u8{ ".agents/skills", ".agents/skills/", "a", ".claude/skills", "a/.b/c" };
    for (good) |p| try validateRelPath(p);
    const bad = [_][]const u8{ "", "/", "/abs", "a/../b", "..", ".", "a//b", "./a", "a/./b", "a\x00b" };
    for (bad) |p| try std.testing.expectError(error.InvalidRelPath, validateRelPath(p));
    try std.testing.expectError(
        error.InvalidRelPath,
        validate(.{ .default_search_path = "../up" }),
    );
    try std.testing.expectError(
        error.InvalidRelPath,
        validate(.{ .sources = &.{.{ .name = "a", .url = "u", .target = "/etc" }} }),
    );
}

test "searchPath and linkSubdirs resolve defaults (b: illustrative)" {
    const cfg: Config = .{ .default_search_path = "skills/" };
    try std.testing.expectEqualStrings("skills", (SourceRepo{ .name = "a", .url = "u" }).searchPath(cfg));
    try std.testing.expectEqualStrings("own", (SourceRepo{ .name = "a", .url = "u", .path = "own" }).searchPath(cfg));
    try std.testing.expectEqualStrings("", (SourceRepo{ .name = "a", .url = "u" }).searchPath(.{}));

    var buf: [2][]const u8 = undefined;
    const both = (SourceRepo{ .name = "a", .url = "u", .target = ".agents/skills" }).linkSubdirs(&buf);
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqualStrings(".agents/skills", both[0]);
    try std.testing.expectEqualStrings(claude_skills_dir, both[1]);
    const no_sync = (SourceRepo{ .name = "a", .url = "u", .claude_sync = false }).linkSubdirs(&buf);
    try std.testing.expectEqual(@as(usize, 1), no_sync.len);
    try std.testing.expectEqualStrings("", no_sync[0]);
    const already = (SourceRepo{ .name = "a", .url = "u", .target = ".claude/skills/" }).linkSubdirs(&buf);
    try std.testing.expectEqual(@as(usize, 1), already.len);
}

test "save writes indented JSON with a trailing newline (b: illustrative)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try save(a, io, t.dir, .{ .sources = &.{.{ .name = "skills", .url = "u" }} });
    const bytes = try t.dir.readFileAlloc(io, "config.json", a, .limited(4096));
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\n  \"sources\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "}\n"));
}
