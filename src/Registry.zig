//! `links.json`: the link registry — where each skill is linked. The
//! filesystem is the source of truth for *safety* (every mutation
//! re-classifies); the registry is the source of truth for *"where is this
//! skill linked"* (edge cases 48–54).
//!
//! Invariants (see `src/test/INVARIANTS.md`):
//! - **Soundness:** entries are keyed by `(host, path)`; within one host,
//!   paths are unique and absolute. Load collapses duplicate `(host, path)`
//!   pairs to the last entry (edge case 5a).
//! - **Completeness:** every link ugarit creates is upserted before the save;
//!   saves are tmp+rename atomic (failure atomicity).
//! - **Repair preserves identity:** `repair` relinks only to a skill with the
//!   same name in the same source, and only when that match is unique.
//!   Otherwise the link is left alone and reported.
//! - **Host portability:** entries whose `host` is not this machine are
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
    /// Hostname: entries from other machines are never acted on (host portability).
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

        // collapse duplicate (host, path) pairs to the last entry (soundness, edge 5a)
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
    /// deterministic bytes (failure atomicity, soundness).
    pub fn save(self: Registry, a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
        const bytes = try self.encode(a);
        defer a.free(bytes);
        try saveBytes(io, dir, bytes);
    }

    /// Serializes a deterministic registry snapshot. The caller owns the
    /// returned bytes and may prepare them before a filesystem transaction.
    pub fn encode(self: Registry, a: std.mem.Allocator) ![]u8 {
        const sorted = try a.dupe(Link, self.links);
        defer a.free(sorted);
        std.mem.sort(Link, sorted, {}, linkLessThan);
        return serde.json.toSlice(a, Registry{ .version = self.version, .links = sorted }) catch |err| switch (err) {
            // serde's allocating writer erases allocator failure to WriteFailed.
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    }

    /// Atomically persists already-serialized bytes without allocating.
    pub fn saveBytes(io: std.Io, dir: std.Io.Dir, bytes: []const u8) !void {
        var af = try dir.createFileAtomic(io, "links.json", .{ .replace = true });
        defer af.deinit(io);
        var buf: [4096]u8 = undefined;
        var w = af.file.writer(io, &buf);
        try w.interface.writeAll(bytes);
        try w.flush();
        try af.replace(io);
    }

    /// Inserts or replaces the entry for `(link.host, link.path)` (completeness).
    /// Dupes all strings into `a`; the caller's `link` may be transient.
    pub fn upsert(self: *Registry, a: std.mem.Allocator, link: Link) !void {
        const owned = candidate: {
            const path = try a.dupe(u8, link.path);
            errdefer a.free(path);
            const source = try a.dupe(u8, link.source);
            errdefer a.free(source);
            const rel_path = try a.dupe(u8, link.rel_path);
            errdefer a.free(rel_path);
            const skill = try a.dupe(u8, link.skill);
            errdefer a.free(skill);
            const host = try a.dupe(u8, link.host);
            errdefer a.free(host);
            break :candidate Link{
                .path = path,
                .source = source,
                .rel_path = rel_path,
                .skill = skill,
                .host = host,
            };
        };
        errdefer freeLink(a, owned);

        for (self.links) |*l| {
            if (std.mem.eql(u8, l.host, owned.host) and std.mem.eql(u8, l.path, owned.path)) {
                const replaced = l.*;
                l.* = owned;
                freeLink(a, replaced);
                return;
            }
        }
        var grown = try a.realloc(self.links, self.links.len + 1);
        grown[grown.len - 1] = owned;
        self.links = grown;
    }

    /// Removes this host's entry for `path`; reports whether one existed.
    /// Other hosts' entries with the same path are untouched (host portability).
    pub fn remove(self: *Registry, a: std.mem.Allocator, path: []const u8, host: []const u8) !bool {
        for (self.links, 0..) |l, i| {
            if (!std.mem.eql(u8, l.host, host) or !std.mem.eql(u8, l.path, path)) continue;
            const rest = try a.alloc(Link, self.links.len - 1);
            @memcpy(rest[0..i], self.links[0..i]);
            @memcpy(rest[i..], self.links[i + 1 ..]);
            freeLink(a, l);
            a.free(self.links);
            self.links = rest;
            return true;
        }
        return false;
    }

    /// After a sync of `source`: every *dangling* link of this host for that
    /// source is relinked when the skill name resolves uniquely inside the
    /// same source (repair preserves identity); the entry's `rel_path` is
    /// updated in place. Everything else is reported, never touched (ownership).
    pub fn repair(
        self: *Registry,
        a: std.mem.Allocator,
        io: std.Io,
        idx: discovery.Index,
        source: []const u8,
        host: []const u8,
        sources_real: []const u8,
    ) !RepairReport {
        const PendingRepair = struct {
            link_index: usize,
            skill: discovery.Skill,
            rel_path: ?[]u8,
        };

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
        var pending: std.ArrayList(PendingRepair) = .empty;
        defer {
            for (pending.items) |p| if (p.rel_path) |rel_path| a.free(rel_path);
            pending.deinit(a);
        }

        // Build every owned result and replacement before changing a link or
        // publishing registry state. OOM therefore leaves the operation inert.
        for (self.links, 0..) |l, link_index| {
            if (!std.mem.eql(u8, l.host, host) or !std.mem.eql(u8, l.source, source)) continue;
            if (try status(io, l, sources_real) != .dangling) continue;

            // repair preserves identity: a unique same-name skill in the same source
            var match: ?discovery.Skill = null;
            var count: usize = 0;
            for (idx.skills) |s| {
                if (!std.mem.eql(u8, s.source, source)) continue;
                if (!std.mem.eql(u8, s.name, l.skill)) continue;
                count += 1;
                match = s;
            }
            if (count != 1) {
                try dangling.ensureUnusedCapacity(a, 1);
                {
                    const rel_path = try a.dupe(u8, l.rel_path);
                    errdefer a.free(rel_path);
                    dangling.appendAssumeCapacity(.{
                        .path = l.path,
                        .source = l.source,
                        .rel_path = rel_path,
                        .skill = l.skill,
                        .host = l.host,
                    });
                }
                continue;
            }
            const skill = match.?;
            try pending.ensureUnusedCapacity(a, 1);
            try repaired.ensureUnusedCapacity(a, 1);
            {
                const registry_rel_path = try a.dupe(u8, skill.rel_path);
                errdefer a.free(registry_rel_path);
                const report_rel_path = try a.dupe(u8, skill.rel_path);
                errdefer a.free(report_rel_path);
                pending.appendAssumeCapacity(.{
                    .link_index = link_index,
                    .skill = skill,
                    .rel_path = registry_rel_path,
                });
                repaired.appendAssumeCapacity(.{
                    .path = l.path,
                    .source = l.source,
                    .rel_path = report_rel_path,
                    .skill = l.skill,
                    .host = l.host,
                });
            }
        }

        const repaired_out = try repaired.toOwnedSlice(a);
        errdefer freeReportLinks(a, repaired_out);
        const dangling_out = try dangling.toOwnedSlice(a);
        errdefer freeReportLinks(a, dangling_out);

        for (pending.items) |*p| {
            const l = &self.links[p.link_index];
            const parent = std.fs.path.dirname(l.path) orelse return error.InvalidRegistryPath;
            var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true });
            defer dir.close(io);
            const outcome = try symlink.link(io, dir, std.fs.path.basename(l.path), p.skill, sources_real, false);
            std.debug.assert(outcome == .replaced); // was dangling and ours
            const replaced_rel_path = l.rel_path;
            l.rel_path = p.rel_path.?;
            p.rel_path = null;
            a.free(replaced_rel_path);
        }
        return .{
            .repaired = repaired_out,
            .dangling = dangling_out,
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

fn freeReportLinks(a: std.mem.Allocator, links: []const Link) void {
    for (links) |l| a.free(l.rel_path);
    a.free(links);
}

fn linkLessThan(_: void, x: Link, y: Link) bool {
    switch (std.mem.order(u8, x.host, y.host)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.order(u8, x.path, y.path) == .lt;
}

test "links.json round-trip keeps shape and order (b: illustrative)" {
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

fn checkUpsertAllocationFailures(a: std.mem.Allocator) !void {
    var reg: Registry = .{};
    defer reg.deinit(a);
    try reg.upsert(a, .{
        .path = "/dest/zig",
        .source = "old-source",
        .rel_path = "old/zig",
        .skill = "zig",
        .host = "box",
    });

    reg.upsert(a, .{
        .path = "/dest/zig",
        .source = "new-source",
        .rel_path = "new/zig",
        .skill = "zig",
        .host = "box",
    }) catch |e| {
        try std.testing.expectEqual(@as(usize, 1), reg.links.len);
        try std.testing.expectEqualStrings("old-source", reg.links[0].source);
        try std.testing.expectEqualStrings("old/zig", reg.links[0].rel_path);
        return e;
    };
    try std.testing.expectEqualStrings("new-source", reg.links[0].source);

    reg.upsert(a, .{
        .path = "/dest/other",
        .source = "new-source",
        .rel_path = "other",
        .skill = "other",
        .host = "box",
    }) catch |e| {
        try std.testing.expectEqual(@as(usize, 1), reg.links.len);
        try std.testing.expectEqualStrings("new-source", reg.links[0].source);
        try std.testing.expectEqualStrings("new/zig", reg.links[0].rel_path);
        return e;
    };
    try std.testing.expectEqual(@as(usize, 2), reg.links.len);
}

test "upsert is transactional under every OOM (a: exhaustive allocation failures)" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkUpsertAllocationFailures,
        .{},
    );
}

fn checkRemoveAllocationFailures(a: std.mem.Allocator) !void {
    var reg: Registry = .{};
    defer reg.deinit(a);
    try reg.upsert(a, .{
        .path = "/dest/zig",
        .source = "source",
        .rel_path = "zig",
        .skill = "zig",
        .host = "box",
    });
    try reg.upsert(a, .{
        .path = "/dest/other",
        .source = "source",
        .rel_path = "other",
        .skill = "other",
        .host = "box",
    });

    const removed = reg.remove(a, "/dest/zig", "box") catch |e| {
        try std.testing.expectEqual(@as(usize, 2), reg.links.len);
        try std.testing.expectEqualStrings("/dest/zig", reg.links[0].path);
        try std.testing.expectEqualStrings("/dest/other", reg.links[1].path);
        return e;
    };
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 1), reg.links.len);
    try std.testing.expectEqualStrings("/dest/other", reg.links[0].path);
}

test "remove is transactional under every OOM (a: exhaustive allocation failures)" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRemoveAllocationFailures,
        .{},
    );
}

const SaveOomContext = struct { io: std.Io, dir: std.Io.Dir };

fn checkSaveAllocationFailures(a: std.mem.Allocator, context: SaveOomContext) !void {
    const original = "{\"version\":1,\"links\":[]}";
    try context.dir.writeFile(context.io, .{ .sub_path = "links.json", .data = original });
    var links = [_]Link{.{
        .path = "/dest/zig",
        .source = "central",
        .rel_path = "zig",
        .skill = "zig",
        .host = "box",
    }};
    var reg = Registry{ .links = links[0..] };
    reg.save(a, context.io, context.dir) catch |err| {
        const bytes = try context.dir.readFileAlloc(
            context.io,
            "links.json",
            std.testing.allocator,
            .limited(1024),
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(original, bytes);
        return err;
    };
}

test "save preserves registry bytes under every OOM (a: exhaustive allocation failures)" {
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSaveAllocationFailures,
        .{SaveOomContext{ .io = io, .dir = t.dir }},
    );
}

const RepairOomContext = struct {
    io: std.Io,
    dest: std.Io.Dir,
    dangling_path: []const u8,
    repair_path: []const u8,
    old_target: []const u8,
    repaired_target: []const u8,
    sources_real: []const u8,
};

fn checkRepairAllocationFailures(a: std.mem.Allocator, context: RepairOomContext) !void {
    context.dest.deleteFile(context.io, "repair") catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    try context.dest.symLink(context.io, context.old_target, "repair", .{ .is_directory = true });

    var reg: Registry = .{};
    defer reg.deinit(a);
    try reg.upsert(a, .{
        .path = context.dangling_path,
        .source = "source",
        .rel_path = "gone/zig",
        .skill = "zig",
        .host = "box",
    });
    try reg.upsert(a, .{
        .path = context.repair_path,
        .source = "source",
        .rel_path = "gone/repair",
        .skill = "repair",
        .host = "box",
    });

    var skills = [_]discovery.Skill{.{
        .name = "repair",
        .source = "source",
        .rel_path = "repaired",
        .abs_path = context.repaired_target,
    }};

    var report = reg.repair(
        a,
        context.io,
        .{ .skills = &skills, .warnings = &.{} },
        "source",
        "box",
        context.sources_real,
    ) catch |e| {
        try std.testing.expectEqual(@as(usize, 2), reg.links.len);
        try std.testing.expectEqualStrings("gone/zig", reg.links[0].rel_path);
        try std.testing.expectEqualStrings("gone/repair", reg.links[1].rel_path);
        try std.testing.expectEqual(State.dangling, try status(context.io, reg.links[1], context.sources_real));
        return e;
    };
    defer report.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), report.repaired.len);
    try std.testing.expectEqual(@as(usize, 1), report.dangling.len);
    try std.testing.expectEqualStrings("repaired", report.repaired[0].rel_path);
    try std.testing.expectEqualStrings("gone/zig", report.dangling[0].rel_path);
    try std.testing.expectEqualStrings("repaired", reg.links[1].rel_path);
    try std.testing.expectEqual(State.ok, try status(context.io, reg.links[1], context.sources_real));
}

test "repair reporting preserves ownership under every OOM (a: exhaustive allocation failures)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(io, "sources/source/repaired");
    try t.dir.createDirPath(io, "dest");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const sources_real = try std.fs.path.join(a, &.{ root, "sources" });
    defer a.free(sources_real);
    const dangling_path = try std.fs.path.join(a, &.{ root, "dest", "zig" });
    defer a.free(dangling_path);
    const dangling_target = try std.fs.path.join(a, &.{ sources_real, "source", "gone", "zig" });
    defer a.free(dangling_target);
    const repair_path = try std.fs.path.join(a, &.{ root, "dest", "repair" });
    defer a.free(repair_path);
    const old_target = try std.fs.path.join(a, &.{ sources_real, "source", "gone", "repair" });
    defer a.free(old_target);
    const repaired_target = try std.fs.path.join(a, &.{ sources_real, "source", "repaired" });
    defer a.free(repaired_target);

    var dest = try t.dir.openDir(io, "dest", .{});
    defer dest.close(io);
    try dest.symLink(io, dangling_target, "zig", .{ .is_directory = true });

    try std.testing.checkAllAllocationFailures(
        a,
        checkRepairAllocationFailures,
        .{RepairOomContext{
            .io = io,
            .dest = dest,
            .dangling_path = dangling_path,
            .repair_path = repair_path,
            .old_target = old_target,
            .repaired_target = repaired_target,
            .sources_real = sources_real,
        }},
    );
}
