//! Skill discovery: turns the cloned trees under `sources/` into a lookup
//! index.
//!
//! Invariants (see `src/test/INVARIANTS.md`):
//! - **Discovery determinism and confinement:** the index is a pure, sorted
//!   function of the tree. No `abs_path` leaves its source root and no result
//!   path traverses a symlink (symlink entries are warned about and skipped,
//!   and directories are opened with `follow_symlinks = false`).
//! - **Confinement's discovery half:** a skill is a real directory containing
//!   a regular `SKILL.md`; a `SKILL.md` that is itself a dir or symlink never
//!   makes a skill.
//! - **Descent cap (local):** discovery never descends into a skill directory
//!   and never past `max_depth` levels below the source root.
//! - **Case-insensitive names (local):** bare-name lookup folds case (edge
//!   case 29); `source/rel_path` queries are exact and case-sensitive.
//! - **No hidden borrows:** the index owns every string it returns; `deinit`
//!   frees them all.

const std = @import("std");
const config = @import("config.zig");
const paths = @import("paths.zig");

pub const max_depth = 4;

pub const Skill = struct {
    name: []const u8,
    source: []const u8,
    rel_path: []const u8,
    abs_path: []const u8,
};

pub const Lookup = union(enum) {
    found: Skill,
    missing,
    /// Case-variants of one name; a contiguous slice into `Index.skills`.
    ambiguous: []const Skill,
};

pub const SourceLookup = union(enum) {
    found: Skill,
    missing,
    ambiguous,
};

pub const Index = struct {
    skills: []Skill,
    warnings: [][]const u8,

    /// Resolves `"skill"`, `"source/skill"` or `"source/path/to/skill"`
    /// (case-insensitive names). Ambiguity is only possible for bare names.
    pub fn lookup(self: Index, query: []const u8) Lookup {
        if (std.mem.indexOfScalar(u8, query, '/') != null) {
            for (self.skills) |s| {
                if (s.source.len + 1 + s.rel_path.len != query.len) continue;
                if (query[s.source.len] != '/') continue;
                if (!std.mem.eql(u8, query[0..s.source.len], s.source)) continue;
                if (!std.mem.eql(u8, query[s.source.len + 1 ..], s.rel_path)) continue;
                return .{ .found = s };
            }
            return .missing;
        }
        var lower_buf: [129]u8 = undefined;
        const needle = asciiLowerInto(&lower_buf, query);
        var first: ?usize = null;
        var count: usize = 0;
        for (self.skills, 0..) |s, i| {
            var sbuf: [129]u8 = undefined;
            const sname = asciiLowerInto(&sbuf, s.name);
            if (!std.mem.eql(u8, sname, needle)) continue;
            if (first == null) first = i;
            count += 1;
        }
        return switch (count) {
            0 => .missing,
            1 => .{ .found = self.skills[first.?] },
            else => .{ .ambiguous = self.skills[first.? .. first.? + count] },
        };
    }

    /// Resolves a skill name or source-relative path within one source. Bare
    /// names are case-insensitive; relative paths are exact and case-sensitive.
    pub fn lookupInSource(self: Index, source: []const u8, query: []const u8) SourceLookup {
        const is_path = std.mem.indexOfScalar(u8, query, '/') != null;
        var lower_buf: [129]u8 = undefined;
        const needle = if (is_path) query else asciiLowerInto(&lower_buf, query);
        var first: ?usize = null;
        var count: usize = 0;
        for (self.skills, 0..) |skill, i| {
            if (!std.mem.eql(u8, skill.source, source)) continue;
            const matches = if (is_path)
                std.mem.eql(u8, skill.rel_path, needle)
            else blk: {
                var name_buf: [129]u8 = undefined;
                break :blk std.mem.eql(u8, asciiLowerInto(&name_buf, skill.name), needle);
            };
            if (!matches) continue;
            if (first == null) first = i;
            count += 1;
        }
        return switch (count) {
            0 => .missing,
            1 => .{ .found = self.skills[first.?] },
            else => .ambiguous,
        };
    }

    pub fn deinit(self: *Index, a: std.mem.Allocator) void {
        for (self.skills) |s| {
            a.free(s.name);
            a.free(s.source);
            a.free(s.rel_path);
            a.free(s.abs_path);
        }
        a.free(self.skills);
        for (self.warnings) |w| a.free(w);
        a.free(self.warnings);
        self.* = .{ .skills = &.{}, .warnings = &.{} };
    }
};

/// Scans every configured source under `sources_dir` (discovery determinism
/// and confinement). A null `sources_dir` yields no skills and one
/// "not cloned" warning per configured source.
pub fn scan(a: std.mem.Allocator, io: std.Io, sources_dir: ?std.Io.Dir, cfg: config.Config) !Index {
    const dir = sources_dir orelse {
        var warnings: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (warnings.items) |w| a.free(w);
            warnings.deinit(a);
        }
        for (cfg.sources) |src| {
            const msg = try std.fmt.allocPrint(a, "source '{s}' not cloned; run source-sync", .{src.name});
            errdefer a.free(msg);
            try warnings.append(a, msg);
        }
        return .{ .skills = &.{}, .warnings = try warnings.toOwnedSlice(a) };
    };

    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sources_real_len = try dir.realPath(io, &rp_buf);
    const sources_real = rp_buf[0..sources_real_len];

    var skills: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills.items) |s| freeSkill(a, s);
        skills.deinit(a);
    }
    var warnings: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (warnings.items) |w| a.free(w);
        warnings.deinit(a);
    }

    for (cfg.sources) |src| {
        var root = dir.openDir(io, src.name, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound => {
                try warn(a, &warnings, "source '{s}' not cloned; run source-sync", .{src.name});
                continue;
            },
            error.NotDir => {
                try warn(a, &warnings, "source '{s}' is not a directory", .{src.name});
                continue;
            },
            else => return e,
        };
        defer root.close(io);
        const search = src.searchPath(cfg);
        var search_root = openSearchRoot(io, root, search) catch |e| switch (e) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => {
                try warn(a, &warnings, "source '{s}' has no directory '{s}'", .{ src.name, search });
                continue;
            },
            else => return e,
        };
        defer if (search.len != 0) search_root.close(io);
        if (try isRegularFile(io, search_root, "SKILL.md")) { // single-skill root (edge case 25)
            if (search.len == 0) {
                try addSkill(a, &skills, sources_real, src.name, src.name, ".");
                continue;
            }
            const name = std.fs.path.basename(search);
            config.validateName(name) catch {
                try warn(a, &warnings, "invalid skill name {s}/{s}", .{ src.name, search });
                continue;
            };
            try addSkill(a, &skills, sources_real, src.name, name, search);
            continue;
        }
        try walk(a, io, search_root, sources_real, src.name, search, 0, &skills, &warnings);
    }

    const owned = try skills.toOwnedSlice(a);
    std.mem.sort(Skill, owned, {}, skillLessThan);
    // Discovery confinement holds by construction; assert it in safety-checked builds.
    for (owned) |s| std.debug.assert(paths.isUnder(s.abs_path, sources_real));
    return .{
        .skills = owned,
        .warnings = try warnings.toOwnedSlice(a),
    };
}

/// Opens `search` component-wise without following symlinks (confinement).
/// Hidden components are allowed. `""` returns `root` itself.
fn openSearchRoot(io: std.Io, root: std.Io.Dir, search: []const u8) !std.Io.Dir {
    if (search.len == 0) return root;
    var it = std.mem.splitScalar(u8, search, '/');
    var current = root;
    var owned = false;
    errdefer if (owned) current.close(io);
    while (it.next()) |component| {
        const next = try current.openDir(io, component, .{ .iterate = true, .follow_symlinks = false });
        if (owned) current.close(io);
        current = next;
        owned = true;
    }
    return current;
}

fn walk(
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sources_real: []const u8,
    source: []const u8,
    rel: []const u8,
    depth: u8,
    skills: *std.ArrayList(Skill),
    warnings: *std.ArrayList([]const u8),
) !void {
    if (depth >= max_depth) return;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name[0] == '.') continue; // .git, hidden entries (edge case 26)
        switch (entry.kind) {
            .sym_link => { // never followed (edge case 27)
                try warn(a, warnings, "skipping symlink {s}/{s}/{s}", .{ source, rel, entry.name });
                continue;
            },
            .directory => {},
            else => continue, // plain files at container level
        }
        var sub = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
        defer sub.close(io);
        const child_rel = if (rel.len == 0)
            try a.dupe(u8, entry.name)
        else
            try std.fs.path.join(a, &.{ rel, entry.name });
        defer a.free(child_rel);
        if (try isRegularFile(io, sub, "SKILL.md")) { // a skill: no descent below it (descent cap)
            config.validateName(entry.name) catch {
                try warn(a, warnings, "invalid skill name {s}/{s}", .{ source, child_rel });
                continue;
            };
            try addSkill(a, skills, sources_real, source, entry.name, child_rel);
        } else {
            try walk(a, io, sub, sources_real, source, child_rel, depth + 1, skills, warnings);
        }
    }
}

/// A `SKILL.md` that is a regular file (not a dir, not a symlink — edge
/// case 28).
fn isRegularFile(io: std.Io, dir: std.Io.Dir, sub: []const u8) !bool {
    const st = dir.statFile(io, sub, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .file;
}

fn addSkill(
    a: std.mem.Allocator,
    skills: *std.ArrayList(Skill),
    sources_real: []const u8,
    source: []const u8,
    name: []const u8,
    rel_path: []const u8,
) !void {
    const abs = if (std.mem.eql(u8, rel_path, "."))
        try std.fs.path.join(a, &.{ sources_real, source })
    else
        try std.fs.path.join(a, &.{ sources_real, source, rel_path });
    errdefer a.free(abs);
    const name_dup = try a.dupe(u8, name);
    errdefer a.free(name_dup);
    const source_dup = try a.dupe(u8, source);
    errdefer a.free(source_dup);
    const rel_dup = try a.dupe(u8, rel_path);
    errdefer a.free(rel_dup);
    try skills.append(a, .{
        .name = name_dup,
        .source = source_dup,
        .rel_path = rel_dup,
        .abs_path = abs,
    });
}

fn freeSkill(a: std.mem.Allocator, s: Skill) void {
    a.free(s.name);
    a.free(s.source);
    a.free(s.rel_path);
    a.free(s.abs_path);
}

fn warn(
    a: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(a, fmt, args);
    errdefer a.free(msg);
    try warnings.append(a, msg);
}

/// Sort key: (lowercase name, name, source, rel_path) — keeps case-variants
/// adjacent so `lookup` can hand out a contiguous ambiguous slice (discovery
/// determinism, case-insensitive names).
fn skillLessThan(_: void, x: Skill, y: Skill) bool {
    var lx: [129]u8 = undefined;
    var ly: [129]u8 = undefined;
    const nx = asciiLowerInto(&lx, x.name);
    const ny = asciiLowerInto(&ly, y.name);
    switch (std.mem.order(u8, nx, ny)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, x.name, y.name)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, x.source, y.source)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.order(u8, x.rel_path, y.rel_path) == .lt;
}

fn asciiLowerInto(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

test "lookup query forms (b: illustrative table)" {
    const a = std.testing.allocator;
    // Index owns every string, so the literals are duped into it.
    const raw = [_]Skill{
        .{ .name = "rust", .source = "one", .rel_path = "rust", .abs_path = "/r/one/rust" },
        .{ .name = "zig", .source = "one", .rel_path = "lang/zig", .abs_path = "/r/one/lang/zig" },
        .{ .name = "Zig", .source = "two", .rel_path = "Zig", .abs_path = "/r/two/Zig" },
    };
    var skills = try a.alloc(Skill, raw.len);
    for (raw, 0..) |s, i| {
        skills[i] = .{
            .name = try a.dupe(u8, s.name),
            .source = try a.dupe(u8, s.source),
            .rel_path = try a.dupe(u8, s.rel_path),
            .abs_path = try a.dupe(u8, s.abs_path),
        };
    }
    var idx = Index{ .skills = skills, .warnings = &.{} };
    defer idx.deinit(a);

    switch (idx.lookup("zig")) {
        .ambiguous => |c| try std.testing.expectEqual(@as(usize, 2), c.len),
        else => return error.TestUnexpectedResult,
    }
    switch (idx.lookup("ZIG")) {
        .ambiguous => |c| try std.testing.expectEqual(@as(usize, 2), c.len),
        else => return error.TestUnexpectedResult,
    }
    switch (idx.lookup("one/lang/zig")) {
        .found => |s| try std.testing.expectEqualStrings("/r/one/lang/zig", s.abs_path),
        else => return error.TestUnexpectedResult,
    }
    switch (idx.lookup("two/Zig")) {
        .found => |s| try std.testing.expectEqualStrings("Zig", s.rel_path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(idx.lookup("rust") == .found);
    try std.testing.expect(idx.lookup("ghost") == .missing);
    try std.testing.expect(idx.lookup("one/zig") == .missing); // exact path only
    switch (idx.lookupInSource("one", "ZIG")) {
        .found => |s| try std.testing.expectEqualStrings("lang/zig", s.rel_path),
        else => return error.TestUnexpectedResult,
    }
    switch (idx.lookupInSource("two", "zig")) {
        .found => |s| try std.testing.expectEqualStrings("Zig", s.rel_path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(idx.lookupInSource("one", "lang/zig") == .found);
    try std.testing.expect(idx.lookupInSource("two", "lang/zig") == .missing);
}

const ScanOomContext = struct { io: std.Io, sources: std.Io.Dir };

fn scanAllocationFailures(a: std.mem.Allocator, context: ScanOomContext) !void {
    var idx = try scan(a, context.io, context.sources, .{ .sources = &.{.{
        .name = "central",
        .url = "/unused",
    }} });
    defer idx.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), idx.skills.len);
}

test "scan releases partial results under every OOM (a: exhaustive allocation failures)" {
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(io, "central/zig");
    try t.dir.createDirPath(io, "central/rust");
    try t.dir.writeFile(io, .{ .sub_path = "central/zig/SKILL.md", .data = "z\n" });
    try t.dir.writeFile(io, .{ .sub_path = "central/rust/SKILL.md", .data = "r\n" });
    var sources = try t.dir.openDir(io, ".", .{ .iterate = true });
    defer sources.close(io);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        scanAllocationFailures,
        .{ScanOomContext{ .io = io, .sources = sources }},
    );
}

test "search paths reach hidden skill roots and stay confined (b: illustrative)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(io, "central/.agents/skills/zig");
    try t.dir.writeFile(io, .{ .sub_path = "central/.agents/skills/zig/SKILL.md", .data = "z\n" });
    try t.dir.createDirPath(io, "single/tools/one");
    try t.dir.writeFile(io, .{ .sub_path = "single/tools/one/SKILL.md", .data = "o\n" });
    try t.dir.createDirPath(io, "outside/bait");
    try t.dir.writeFile(io, .{ .sub_path = "outside/bait/SKILL.md", .data = "b\n" });
    try t.dir.createDirPath(io, "esc");
    try t.dir.symLink(io, "../outside", "esc/escape", .{ .is_directory = true });
    var sources = try t.dir.openDir(io, ".", .{ .iterate = true });
    defer sources.close(io);

    // Without a search path the hidden `.agents` tree is invisible.
    var hidden = try scan(a, io, sources, .{ .sources = &.{.{ .name = "central", .url = "/u" }} });
    defer hidden.deinit(a);
    try std.testing.expect(hidden.lookupInSource("central", "zig") == .missing);

    var idx = try scan(a, io, sources, .{
        .default_search_path = ".agents/skills",
        .sources = &.{
            .{ .name = "central", .url = "/u" },
            .{ .name = "single", .url = "/v", .path = "tools/one/" },
            .{ .name = "esc", .url = "/w", .path = "escape" },
        },
    });
    defer idx.deinit(a);
    switch (idx.lookupInSource("central", "zig")) {
        .found => |s| try std.testing.expectEqualStrings(".agents/skills/zig", s.rel_path),
        else => return error.TestUnexpectedResult,
    }
    switch (idx.lookupInSource("single", "one")) {
        .found => |s| try std.testing.expectEqualStrings("tools/one", s.rel_path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 2), idx.skills.len);
    // A symlinked search root is refused.
    try std.testing.expectEqual(@as(usize, 1), idx.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, idx.warnings[0], "'esc' has no directory") != null);
}
