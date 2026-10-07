//! `links.json`: the link registry — where each skill is linked. The
//! filesystem is the source of truth for *safety* (every mutation
//! re-classifies); the registry is the source of truth for *"where is this
//! skill linked"* (edge cases 48–54).
//!
//! Invariants:
//! - **I8 (soundness):** entries are keyed by `(host, path)`; within one
//!   host, paths are unique and absolute. Load collapses duplicate
//!   `(host, path)` pairs to the last entry (edge case 5a).
//! - **I9 (completeness):** every link ugarit creates is upserted before the
//!   save; saves are tmp+rename atomic (I12).
//! - **I10 (repair identity):** `repair` relinks only to a skill with the
//!   same name in the same source, and only when that match is unique.
//!   Otherwise the link is left alone and reported.
//! - **H4 (portability):** entries whose `host` is not this machine are
//!   never modified, replaced or removed by any operation here.

const std = @import("std");
const serde = @import("serde");
const symlink = @import("symlink.zig");
const discovery = @import("discovery.zig");

pub const Link = struct {
    /// Canonical absolute path of the symlink itself.
    path: []const u8,
    source: []const u8,
    /// Path of the skill inside the source: `"zig"`, `"lang/zig"` or `"."`.
    rel_path: []const u8,
    skill: []const u8,
    /// Hostname: entries from other machines are never acted on (H4).
    host: []const u8 = "",
};

pub const Registry = struct {
    version: u32 = 1,
    links: []Link = &.{},

    pub fn deinit(self: *Registry, a: std.mem.Allocator) void {
        for (self.links) |l| freeLink(a, l);
        a.free(self.links);
        self.* = .{};
    }

    /// Reads `sub_path` from `dir`. A missing file yields the defaults (first
    /// run). All strings are owned by `a`; free with `deinit`.
    pub fn load(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !Loaded {
        const bytes = dir.readFileAlloc(io, sub_path, a, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return .{ .registry = .{}, .duplicates = 0 },
            else => return e,
        };
        defer a.free(bytes);

        const parsed = try serde.json.fromSlice(Registry, a, bytes);
        if (parsed.version != 1) return error.UnsupportedRegistryVersion;

        // collapse duplicate (host, path) pairs to the last entry (I8, edge 5a)
        var unique: std.ArrayList(Link) = .empty;
        errdefer {
            for (unique.items) |l| freeLink(a, l);
            unique.deinit(a);
        }
        var duplicates: usize = 0;
        var keep = try a.alloc(bool, parsed.links.len);
        defer a.free(keep);
        for (parsed.links, 0..) |l, i| {
            keep[i] = true;
            for (parsed.links[i + 1 ..]) |m| {
                if (std.mem.eql(u8, m.host, l.host) and std.mem.eql(u8, m.path, l.path)) {
                    keep[i] = false; // a later entry with the same key wins
                    duplicates += 1;
                    break;
                }
            }
        }
        for (parsed.links, 0..) |l, i| {
            if (keep[i]) try unique.append(a, l) else freeLink(a, l);
        }
        a.free(parsed.links);
        return .{
            .registry = .{ .version = parsed.version, .links = try unique.toOwnedSlice(a) },
            .duplicates = duplicates,
        };
    }

    /// Atomically writes the registry, sorted by `(host, path)` for
    /// deterministic bytes (I12, I8).
    pub fn save(self: Registry, a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
        const sorted = try a.dupe(Link, self.links);
        defer a.free(sorted);
        std.mem.sort(Link, sorted, {}, linkLessThan);
        const bytes = try serde.json.toSlice(a, Registry{ .version = self.version, .links = sorted });
        defer a.free(bytes);

        var af = try dir.createFileAtomic(io, "links.json", .{ .replace = true });
        defer af.deinit(io);
        var buf: [4096]u8 = undefined;
        var w = af.file.writer(io, &buf);
        try w.interface.writeAll(bytes);
        try w.flush();
        try af.replace(io);
    }

    /// Inserts or replaces the entry for `(link.host, link.path)` (I9).
    /// Dupes all strings into `a`; the caller's `link` may be transient.
    pub fn upsert(self: *Registry, a: std.mem.Allocator, link: Link) !void {
        var owned: Link = undefined;
        var done: usize = 0;
        errdefer {
            const fields = [_][]const u8{ owned.path, owned.source, owned.rel_path, owned.skill, owned.host };
            for (fields[0..done]) |f| a.free(f);
        }
        owned.path = try a.dupe(u8, link.path);
        done += 1;
        owned.source = try a.dupe(u8, link.source);
        done += 1;
        owned.rel_path = try a.dupe(u8, link.rel_path);
        done += 1;
        owned.skill = try a.dupe(u8, link.skill);
        done += 1;
        owned.host = try a.dupe(u8, link.host);
        errdefer freeLink(a, owned);
        for (self.links) |*l| {
            if (std.mem.eql(u8, l.host, owned.host) and std.mem.eql(u8, l.path, owned.path)) {
                freeLink(a, l.*);
                l.* = owned;
                return;
            }
        }
        var grown = try a.realloc(self.links, self.links.len + 1);
        grown[grown.len - 1] = owned;
        self.links = grown;
    }

    /// Removes this host's entry for `path`; reports whether one existed.
    /// Other hosts' entries with the same path are untouched (H4).
    pub fn remove(self: *Registry, a: std.mem.Allocator, path: []const u8, host: []const u8) !bool {
        for (self.links, 0..) |l, i| {
            if (!std.mem.eql(u8, l.host, host) or !std.mem.eql(u8, l.path, path)) continue;
            freeLink(a, l);
            const rest = try a.alloc(Link, self.links.len - 1);
            @memcpy(rest[0..i], self.links[0..i]);
            @memcpy(rest[i..], self.links[i + 1 ..]);
            a.free(self.links);
            self.links = rest;
            return true;
        }
        return false;
    }

    /// After a sync of `source`: every *dangling* link of this host for that
    /// source is relinked when the skill name resolves uniquely inside the
    /// same source (I10); the entry's `rel_path` is updated in place.
    /// Everything else is reported, never touched (I2).
    pub fn repair(
        self: *Registry,
        a: std.mem.Allocator,
        io: std.Io,
        idx: discovery.Index,
        source: []const u8,
        host: []const u8,
        sources_real: []const u8,
    ) !RepairReport {
        var repaired: std.ArrayList(Link) = .empty;
        errdefer {
            for (repaired.items) |l| a.free(l.rel_path);
            repaired.deinit(a);
        }
        var dangling: std.ArrayList(Link) = .empty;
        errdefer {
            for (dangling.items) |l| a.free(l.rel_path);
            dangling.deinit(a);
        }

        for (self.links) |*l| {
            if (!std.mem.eql(u8, l.host, host) or !std.mem.eql(u8, l.source, source)) continue;
            if (try status(io, l.*, sources_real) != .dangling) continue;

            // I10: a unique same-name skill in the same source
            var match: ?discovery.Skill = null;
            var count: usize = 0;
            for (idx.skills) |s| {
                if (!std.mem.eql(u8, s.source, source)) continue;
                if (!std.mem.eql(u8, s.name, l.skill)) continue;
                count += 1;
                match = s;
            }
            if (count != 1) {
                try dangling.append(a, .{
                    .path = l.path,
                    .source = l.source,
                    .rel_path = try a.dupe(u8, l.rel_path),
                    .skill = l.skill,
                    .host = l.host,
                });
                continue;
            }
            const skill = match.?;
            const parent = std.fs.path.dirname(l.path) orelse return error.InvalidRegistryPath;
            var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true });
            defer dir.close(io);
            const outcome = try symlink.link(io, dir, std.fs.path.basename(l.path), skill, sources_real, false);
            std.debug.assert(outcome == .replaced); // was dangling and ours
            a.free(l.rel_path);
            l.rel_path = try a.dupe(u8, skill.rel_path);
            try repaired.append(a, .{
                .path = l.path,
                .source = l.source,
                .rel_path = try a.dupe(u8, skill.rel_path),
                .skill = l.skill,
                .host = l.host,
            });
        }
        return .{
            .repaired = try repaired.toOwnedSlice(a),
            .dangling = try dangling.toOwnedSlice(a),
        };
    }
};

/// A loaded registry plus the number of duplicate `(host, path)` entries that
/// collapsed to the last occurrence (edge case 5a).
pub const Loaded = struct {
    registry: Registry,
    duplicates: usize,

    pub fn deinit(self: *Loaded, a: std.mem.Allocator) void {
        self.registry.deinit(a);
    }
};

pub const State = enum {
    /// Link exists, points at `sources/<source>/<rel_path>`, and that exists.
    ok,
    /// Ours, but the skill dir is gone (upstream removed or moved it).
    dangling,
    /// Nothing at `path` any more (project deleted or link rm'd).
    missing,
    /// Something that isn't our link sits at `path` (user replaced it).
    replaced,
    /// Ours, but points at a different skill than recorded (hand-edited).
    retargeted,
};

/// Classifies a registry entry against the filesystem (the `list`/`repair`
/// oracle). The expected target is `sources_real/<source>/<rel_path>`.
pub fn status(io: std.Io, l: Link, sources_real: []const u8) !State {
    const parent = std.fs.path.dirname(l.path) orelse return error.InvalidRegistryPath;
    const name = std.fs.path.basename(l.path);
    var dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |e| switch (e) {
        error.FileNotFound => return .missing, // the whole project is gone
        else => return e,
    };
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return switch (try symlink.classify(io, dir, name, sources_real, &buf)) {
        .absent => .missing,
        .real, .foreign_link => .replaced,
        .ours => |o| blk: {
            var want_buf: [std.fs.max_path_bytes]u8 = undefined;
            const want = expectedTarget(l, sources_real, &want_buf) catch return error.NameTooLong;
            if (!std.mem.eql(u8, o.target, want)) break :blk .retargeted;
            break :blk if (o.dangling) .dangling else .ok;
        },
    };
}

fn expectedTarget(l: Link, sources_real: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.eql(u8, l.rel_path, ".")) {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ sources_real, l.source });
    }
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ sources_real, l.source, l.rel_path });
}

pub const RepairReport = struct {
    /// Links that were relinked; entries carry the *new* `rel_path`.
    repaired: []const Link,
    /// Links that could not be repaired (gone or ambiguous), still dangling.
    dangling: []const Link,

    pub fn deinit(self: *RepairReport, a: std.mem.Allocator) void {
        for (self.repaired) |l| a.free(l.rel_path);
        a.free(self.repaired);
        for (self.dangling) |l| a.free(l.rel_path);
        a.free(self.dangling);
        self.* = .{ .repaired = &.{}, .dangling = &.{} };
    }
};

fn freeLink(a: std.mem.Allocator, l: Link) void {
    a.free(l.path);
    a.free(l.source);
    a.free(l.rel_path);
    a.free(l.skill);
    a.free(l.host);
}

fn linkLessThan(_: void, x: Link, y: Link) bool {
    switch (std.mem.order(u8, x.host, y.host)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.order(u8, x.path, y.path) == .lt;
}

test "links.json round-trip keeps shape and order (b: illustrative — I8)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    var reg = Registry{};
    defer reg.deinit(a);
    try reg.upsert(a, .{
        .path = "/home/u/b/.claude/skills/zig",
        .source = "my-skills",
        .rel_path = "lang/zig",
        .skill = "zig",
        .host = "box",
    });
    try reg.upsert(a, .{
        .path = "/home/u/a/.claude/skills/zig",
        .source = "my-skills",
        .rel_path = "lang/zig",
        .skill = "zig",
        .host = "box",
    });
    try reg.save(a, io, t.dir);

    var loaded = try Registry.load(a, io, t.dir, "links.json");
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), loaded.duplicates);
    try std.testing.expectEqual(@as(usize, 2), loaded.registry.links.len);
    // sorted by path within the host
    try std.testing.expectEqualStrings("/home/u/a/.claude/skills/zig", loaded.registry.links[0].path);
    try std.testing.expectEqualStrings("lang/zig", loaded.registry.links[0].rel_path);
    try std.testing.expectEqualStrings("box", loaded.registry.links[0].host);
}
