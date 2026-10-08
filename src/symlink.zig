//! One filesystem entry, `<dest_dir>/<link_name>`: classification, atomic
//! linking and unlinking, plus the `.git/info/exclude` integration.
//!
//! Invariants (see `src/test/INVARIANTS.md`):
//! - **Ownership:** `link`/`unlink` replace or remove only symlinks whose
//!   target is under `realpath(sources/)`; a real file or dir is never
//!   touched, `--force` included.
//! - **Atomic visibility:** replacement happens via a reserved temp symlink
//!   plus `rename(2)`, so `dest/<name>` is at every instant either the old
//!   entry or the new link. No reserved temp entry remains after any return,
//!   success or error.
//! - **Confinement (asserted):** every link target written is an absolute
//!   path under `sources_real` (the realpath'd sources dir).
//! - **Idempotence:** linking an identical link again reports `unchanged` and
//!   changes nothing; `unlink` of an absent entry is `absent`.
//! - **Exclude idempotence / no collateral damage:** `excludeInEnclosingRepo`
//!   only ever appends at most one line, and only inside the enclosing repo's
//!   `commondir/info/exclude`.

const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const discovery = @import("discovery.zig");
const git = @import("git.zig");

pub const Entry = union(enum) {
    absent,
    /// Ours: target resolves under `sources_real`. `dangling` when the
    /// target does not exist. Slices point into the caller's buffer.
    ours: struct { target: []const u8, dangling: bool },
    foreign_link: []const u8,
    /// A real file or directory: never touched (ownership).
    real,
};

/// Classifies `<dest_dir>/<name>` without following symlinks (ownership's reader).
pub fn classify(
    io: std.Io,
    dest_dir: std.Io.Dir,
    name: []const u8,
    sources_real: []const u8,
    buf: []u8,
) !Entry {
    const st = dest_dir.statFile(io, name, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return .absent,
        else => return e,
    };
    if (st.kind != .sym_link) return .real;
    const len = try dest_dir.readLink(io, name, buf);
    const target = buf[0..len];
    // `..`-escaping targets never count as ours even when they share the
    // sources prefix (e.g. `…/sources/../evil`); treating them as foreign is
    // the safe side of ownership.
    if (std.mem.indexOf(u8, target, "..") != null) return .{ .foreign_link = target };
    if (!paths.isUnder(target, sources_real)) return .{ .foreign_link = target };
    const dangling = if (dest_dir.access(io, name, .{})) |_| false else |_| true;
    return .{ .ours = .{ .target = target, .dangling = dangling } };
}

pub const LinkOutcome = enum { created, unchanged, replaced };

/// Domain errors of `link` (ownership, edge case 40); io errors pass through.
pub const LinkError = error{
    RealEntryInTheWay,
    ForeignLinkInTheWay,
    LinkedFromOtherSource,
    FaultInjected,
};

// --- fault injection (interrupted link): compiled out of release builds ------

pub const FaultPoint = enum { after_tmp_symlink, before_rename };

pub const FaultFn = *const fn (FaultPoint) bool;

pub var fault: if (builtin.is_test) ?FaultFn else void = if (builtin.is_test) null else {};

fn failAt(point: FaultPoint) LinkError!void {
    if (builtin.is_test) {
        if (fault) |f| {
            if (f(point)) return error.FaultInjected;
        }
    }
}

/// Creates or atomically replaces `dest_dir/link_name` with a symlink to
/// `skill.abs_path` (ownership, atomic visibility, idempotence). Asserts the
/// confinement invariant.
pub fn link(
    io: std.Io,
    dest_dir: std.Io.Dir,
    link_name: []const u8,
    skill: discovery.Skill,
    sources_real: []const u8,
    force: bool,
) !LinkOutcome {
    std.debug.assert(paths.isUnder(skill.abs_path, sources_real)); // confinement

    sweepTemps(io, dest_dir);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const prior = try classify(io, dest_dir, link_name, sources_real, &buf);
    var outcome: LinkOutcome = undefined;
    switch (prior) {
        .absent => outcome = .created,
        .real => return error.RealEntryInTheWay, // even with --force (ownership)
        .foreign_link => {
            if (!force) return error.ForeignLinkInTheWay;
            outcome = .replaced;
        },
        .ours => |o| {
            if (std.mem.eql(u8, o.target, skill.abs_path)) return .unchanged; // idempotence
            if (!o.dangling and !force) return error.LinkedFromOtherSource;
            outcome = .replaced;
        },
    }

    // Reserved temp name, short and fixed-length (path/name length hazard): `.u-<8 hex>`.
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    var tmp_buf: [16]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, ".u-{x:0>8}", .{std.mem.readInt(u32, &rnd, .big)}) catch unreachable;
    try dest_dir.symLink(io, skill.abs_path, tmp, .{ .is_directory = true });
    errdefer dest_dir.deleteFile(io, tmp) catch {};
    try failAt(.after_tmp_symlink);

    try failAt(.before_rename);
    // TOCTOU hazard: re-check right before the rename. If the entry became
    // real, or appeared while we thought it absent, abort rather than clobber.
    {
        var re_buf: [std.fs.max_path_bytes]u8 = undefined;
        const now = try classify(io, dest_dir, link_name, sources_real, &re_buf);
        switch (prior) {
            .absent => if (now != .absent) return error.RealEntryInTheWay,
            else => if (now == .real) return error.RealEntryInTheWay,
        }
    }
    renameIntoPlace(io, dest_dir, tmp, link_name, prior == .absent) catch |e| switch (e) {
        error.PathAlreadyExists => return error.RealEntryInTheWay, // raced a creator (NOREPLACE)
        else => return e,
    };
    return outcome;
}

/// `renameat2(RENAME_NOREPLACE)` when the destination was absent (Linux);
/// a plain `rename(2)` otherwise, which atomically replaces a symlink but
/// refuses to clobber a real directory (second guard, TOCTOU/edge 41).
fn renameIntoPlace(
    io: std.Io,
    dest_dir: std.Io.Dir,
    tmp: []const u8,
    name: []const u8,
    noreplace: bool,
) !void {
    if (noreplace and builtin.os.tag == .linux) {
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_z = std.fmt.bufPrintZ(&tmp_buf, "{s}", .{tmp}) catch return error.NameTooLong;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return error.NameTooLong;
        const rc = std.os.linux.renameat2(
            @intCast(dest_dir.handle),
            tmp_z,
            @intCast(dest_dir.handle),
            name_z,
            .{ .NOREPLACE = true },
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .EXIST => return error.PathAlreadyExists,
            .INVAL => {}, // filesystem without NOREPLACE: fall back
            else => return error.Unexpected,
        }
    }
    try dest_dir.rename(tmp, dest_dir, name, io);
}

pub const UnlinkOutcome = enum { removed, absent };

/// Removes our link; never a foreign link or a real entry (ownership, inverse).
pub fn unlink(io: std.Io, dest_dir: std.Io.Dir, name: []const u8, sources_real: []const u8) !UnlinkOutcome {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return switch (try classify(io, dest_dir, name, sources_real, &buf)) {
        .absent => .absent, // idempotence
        .ours => blk: {
            try dest_dir.deleteFile(io, name);
            break :blk .removed;
        },
        .foreign_link => error.ForeignLinkInTheWay,
        .real => error.RealEntryInTheWay,
    };
}

/// Deletes leftover reserved temp links `.u-*` from an interrupted run.
fn sweepTemps(io: std.Io, dest_dir: std.Io.Dir) void {
    var it = dest_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .sym_link) continue;
        if (!isReservedTemp(entry.name)) continue;
        dest_dir.deleteFile(io, entry.name) catch {};
    }
}

fn isReservedTemp(name: []const u8) bool {
    if (name.len != 11 or !std.mem.startsWith(u8, name, ".u-")) return false;
    for (name[3..]) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

// --- git exclude integration --------------------------------------------------

pub const ExcludeOutcome = union(enum) {
    excluded,
    not_a_repo,
    /// Already ignored by that repo (`.gitignore` or a previous run).
    already,
};

pub const ExcludeError = error{LinkPathTrackedInRepo};

/// Adds the anchored repo-relative path of `link_abs` to the enclosing
/// repo's `commondir/info/exclude` (edge cases 43–47). Local-only, never
/// committed; at most one line is ever appended (exclude idempotence).
pub fn excludeInEnclosingRepo(
    a: std.mem.Allocator,
    io: std.Io,
    link_abs: []const u8,
) !ExcludeOutcome {
    const repo_dir = (try git.discoverRepo(a, link_abs)) orelse return .not_a_repo;
    defer a.free(repo_dir);

    const workdir = try git.repoWorkdir(a, repo_dir);
    defer a.free(workdir);
    const wd = workdir[0 .. workdir.len - 1]; // drop trailing '/'

    if (!paths.isUnder(link_abs, wd)) return .not_a_repo; // link_abs inside .git itself
    const rel = link_abs[wd.len + 1 ..];

    if (try git.isPathTracked(repo_dir, rel)) return error.LinkPathTrackedInRepo; // edge 44

    var pattern_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "/{s}", .{rel}) catch
        return error.NameTooLong; // anchored: "/.claude/skills/zig"

    if (try git.isPathIgnored(repo_dir, rel)) return .already; // edge 45

    const commondir = try git.repoCommondir(a, repo_dir);
    defer a.free(commondir);
    const common = commondir[0 .. commondir.len - 1];

    var git_dir = try std.Io.Dir.openDirAbsolute(io, common, .{});
    defer git_dir.close(io);
    try git_dir.createDirPath(io, "info");
    var info = try git_dir.openDir(io, "info", .{});
    defer info.close(io);

    // existing content (exclude idempotence double guard: skip if the line is already there)
    const existing = info.readFileAlloc(io, "exclude", a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => try a.dupe(u8, ""),
        else => return e,
    };
    defer a.free(existing);
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, pattern[1..])) return .already;
    }

    var af = try info.createFileAtomic(io, "exclude", .{ .replace = true });
    defer af.deinit(io);
    var wbuf: [4096]u8 = undefined;
    var w = af.file.writer(io, &wbuf);
    try w.interface.writeAll(existing);
    if (existing.len != 0 and existing[existing.len - 1] != '\n') try w.interface.writeAll("\n");
    try w.interface.writeAll(pattern);
    try w.interface.writeAll("\n");
    try w.flush();
    try af.replace(io);
    return .excluded;
}

test "link surfaces EACCES and leaves no temp (c: un-generatable, permissions)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    try t.dir.createDirPath(io, "sources/zig");
    try t.dir.writeFile(io, .{ .sub_path = "sources/zig/SKILL.md", .data = "s\n" });
    try t.dir.createDirPath(io, "dest");

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &real_buf);
    const root = real_buf[0..root_len];
    const sources_real = try std.fs.path.join(a, &.{ root, "sources" });
    defer a.free(sources_real);
    const skill_abs = try std.fs.path.join(a, &.{ sources_real, "zig" });
    defer a.free(skill_abs);
    const skill = discovery.Skill{
        .name = "zig",
        .source = "one",
        .rel_path = "zig",
        .abs_path = skill_abs,
    };

    var dest = try t.dir.openDir(io, "dest", .{ .iterate = true });
    defer dest.close(io);
    try dest.setPermissions(io, std.Io.File.Permissions.fromMode(0o555)); // r-x
    defer dest.setPermissions(io, std.Io.File.Permissions.fromMode(0o755)) catch {};

    try std.testing.expectError(
        error.AccessDenied,
        link(io, dest, "zig", skill, sources_real, false),
    );

    try dest.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    try expectLinkOutcome(.created, try link(io, dest, "zig", skill, sources_real, false));

    // no reserved temp left behind (atomic visibility)
    var it = dest.iterate();
    while (try it.next(io)) |entry| {
        try std.testing.expectEqualStrings("zig", entry.name);
    }
}

// No collateral damage: the temp sweep must remove only reserved `.u-<8 hex>`
// names and leave unrelated `.u-*` entries alone.
test "temp sweep removes only reserved names (a: pinned collateral-damage regression)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(io, "sources/zig");
    try t.dir.writeFile(io, .{ .sub_path = "sources/zig/SKILL.md", .data = "v1\n" });
    try t.dir.createDirPath(io, "dest");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const sources_real = try std.fs.path.join(a, &.{ root_buf[0..root_len], "sources" });
    defer a.free(sources_real);
    const skill_abs = try std.fs.path.join(a, &.{ sources_real, "zig" });
    defer a.free(skill_abs);
    var dest = try t.dir.openDir(io, "dest", .{ .iterate = true });
    defer dest.close(io);
    try dest.symLink(io, "/missing", ".u-backup", .{});
    try dest.symLink(io, "/missing", ".u-1234567g", .{});
    try dest.symLink(io, "/missing", ".u-12345678", .{});
    _ = try link(io, dest, "zig", .{
        .name = "zig",
        .source = "central",
        .rel_path = "zig",
        .abs_path = skill_abs,
    }, sources_real, false);
    try dest.access(io, ".u-backup", .{ .follow_symlinks = false });
    try dest.access(io, ".u-1234567g", .{ .follow_symlinks = false });
    try std.testing.expectError(
        error.FileNotFound,
        dest.access(io, ".u-12345678", .{ .follow_symlinks = false }),
    );
}

fn expectLinkOutcome(want: LinkOutcome, got: LinkOutcome) !void {
    try std.testing.expectEqual(want, got);
}

test "exclude is a no-op outside any repo (c: environment-dependent path)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    // std.testing.tmpDir lives under the ugarit repo's .zig-cache, so the
    // "no enclosing repo" case must probe outside it (c: un-generatable).
    const tmp_root = blk: {
        const v = getenvZ("TMPDIR") orelse break :blk "/tmp";
        break :blk v;
    };
    const base = try std.fs.path.join(a, &.{ tmp_root, "ugarit-test-norepo" });
    defer a.free(base);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const link_abs = try std.fs.path.join(a, &.{ base, "zig" });
    defer a.free(link_abs);
    try expectExclude(.not_a_repo, try excludeInEnclosingRepo(a, io, link_abs));
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn getenvZ(name: [*:0]const u8) ?[:0]const u8 {
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

fn expectExclude(want: ExcludeOutcome, got: ExcludeOutcome) !void {
    try std.testing.expectEqual(want, got);
}
