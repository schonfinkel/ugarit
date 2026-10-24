//! Command orchestration shared by the executable and state-machine tests.
//!
//! Invariants (see `src/test/INVARIANTS.md`):
//! - No collateral damage, ownership, atomic visibility, confinement:
//!   commands delegate entry mutation to `symlink.zig`, reject destinations
//!   inside sources, and persist only canonical absolute paths.
//! - Fan-out coherence through repair-preserves-identity: link and unlink
//!   update the filesystem and this host's registry together; sync repairs
//!   only unique same-name moves in the same source.
//! - Failure atomicity: source-add saves config only after a successful clone
//!   and removes a completed clone if config persistence fails.
//! - Exit status: multi-item commands continue after item failures and report
//!   partial failure to the caller.

const std = @import("std");
const builtin = @import("builtin");
const paths_mod = @import("paths.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const discovery = @import("discovery.zig");
const symlink = @import("symlink.zig");
const registry_mod = @import("Registry.zig");

pub const Registry = registry_mod.Registry;
pub const version = "0.1.0";

pub const Error = error{
    Usage,
    SourceExists,
    SourceNotFound,
    SkillNotFound,
    AmbiguousSkill,
    DestInsideSources,
    DestInsideSkill,
    InvalidLinkPath,
    FaultInjected,
};

pub const Diagnostic = enum {
    usage,
    source_exists,
    source_not_found,
    skill_not_found,
    ambiguous_skill,
    destination_inside_sources,
    destination_inside_skill,
    invalid_name,
    entry_in_the_way,
    tracked_link_path,
    concurrent_process,
    running_as_root,
    dirty_worktree,
    diverged_history,
    remote_mismatch,
    authentication_failed,
    invalid_config,
    out_of_memory,
    io,
};

pub fn diagnostic(err: anyerror) Diagnostic {
    return switch (err) {
        error.Usage => .usage,
        error.SourceExists => .source_exists,
        error.SourceNotFound => .source_not_found,
        error.SkillNotFound => .skill_not_found,
        error.AmbiguousSkill => .ambiguous_skill,
        error.DestInsideSources => .destination_inside_sources,
        error.DestInsideSkill => .destination_inside_skill,
        error.InvalidName => .invalid_name,
        error.RealEntryInTheWay,
        error.ForeignLinkInTheWay,
        error.LinkedFromOtherSource,
        => .entry_in_the_way,
        error.LinkPathTrackedInRepo => .tracked_link_path,
        error.AnotherUgaritRunning => .concurrent_process,
        error.RunningAsRootForUser => .running_as_root,
        error.DirtyWorktree => .dirty_worktree,
        error.NotFastForward => .diverged_history,
        error.RemoteMismatch => .remote_mismatch,
        error.AuthFailed => .authentication_failed,
        error.UnsupportedConfigVersion,
        error.UnsupportedRegistryVersion,
        error.DuplicateSourceName,
        error.InvalidRelPath,
        => .invalid_config,
        error.OutOfMemory => .out_of_memory,
        else => .io,
    };
}

pub fn diagnosticMessage(kind: Diagnostic) []const u8 {
    return switch (kind) {
        .usage => "invalid command usage",
        .source_exists => "source name already exists",
        .source_not_found => "source not found",
        .skill_not_found => "skill not found",
        .ambiguous_skill => "skill name is ambiguous; use source/path",
        .destination_inside_sources => "destination is inside ugarit's sources directory",
        .destination_inside_skill => "destination is inside the selected skill",
        .invalid_name => "invalid name",
        .entry_in_the_way => "destination contains an entry ugarit will not replace",
        .tracked_link_path => "link path is tracked; remove it from the index first",
        .concurrent_process => "another ugarit process is running",
        .running_as_root => "refusing to write into another user's HOME as root",
        .dirty_worktree => "source worktree is dirty",
        .diverged_history => "source history is not a fast-forward",
        .remote_mismatch => "source origin does not match config",
        .authentication_failed => "Git authentication failed",
        .invalid_config => "invalid ugarit configuration",
        .out_of_memory => "out of memory",
        .io => "I/O operation failed",
    };
}

pub fn diagnosticExitCode(kind: Diagnostic) u8 {
    return switch (kind) {
        .usage => 2,
        .source_exists,
        .source_not_found,
        .skill_not_found,
        .ambiguous_skill,
        .destination_inside_sources,
        .destination_inside_skill,
        .invalid_name,
        .entry_in_the_way,
        .tracked_link_path,
        .concurrent_process,
        .running_as_root,
        .dirty_worktree,
        .diverged_history,
        .remote_mismatch,
        .authentication_failed,
        .invalid_config,
        .out_of_memory,
        .io,
        => 1,
    };
}

pub const FaultPoint = enum { before_config_save, before_registry_commit, before_registry_save };
pub const FaultFn = *const fn (FaultPoint) bool;
pub var fault: if (builtin.is_test) ?FaultFn else void = if (builtin.is_test) null else {};

fn failAt(point: FaultPoint) Error!void {
    if (builtin.is_test) {
        if (fault) |f| if (f(point)) return error.FaultInjected;
    }
}

/// How a context touches the managed tree. Mutating contexts create and open
/// the managed root and sources directory; read-only contexts open only what
/// already exists and create nothing (read-only purity).
pub const Mode = enum { mutating, read_only };

pub const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    paths: paths_mod.Paths,
    /// Null only in read-only mode when the managed root does not exist.
    root_dir: ?std.Io.Dir,
    /// Null only in read-only mode when the sources directory does not exist.
    sources_dir: ?std.Io.Dir,
    cfg: config.ManagedConfig,
    registry: Registry,
    host: []const u8,
    home: ?[]const u8,
    /// Realpath of sources when it exists; otherwise the logical path (used
    /// only for `list` classification).
    sources_real: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,

    /// Creates the managed root and sources directory, then loads both JSON
    /// documents. The returned context owns every field except the writers and
    /// environment map. Both directory handles are non-null.
    pub fn init(
        a: std.mem.Allocator,
        io: std.Io,
        env: ?*const std.process.Environ.Map,
        config_dir: ?[]const u8,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
    ) !Context {
        return initInMode(a, io, env, config_dir, out, err, .mutating);
    }

    /// Like `init`, but never creates the managed root or sources directory:
    /// a missing root yields the default config and an empty registry, and a
    /// missing sources directory yields per-source "not cloned" warnings.
    pub fn initReadOnly(
        a: std.mem.Allocator,
        io: std.Io,
        env: ?*const std.process.Environ.Map,
        config_dir: ?[]const u8,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
    ) !Context {
        return initInMode(a, io, env, config_dir, out, err, .read_only);
    }

    fn initInMode(
        a: std.mem.Allocator,
        io: std.Io,
        env: ?*const std.process.Environ.Map,
        config_dir: ?[]const u8,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
        mode: Mode,
    ) !Context {
        const empty_env = std.process.Environ.Map.init(a);
        var owned_empty = empty_env;
        defer owned_empty.deinit();
        const environ = env orelse &owned_empty;
        try paths_mod.refuseRootForUser(io, environ.get("HOME"));

        const resolved = try paths_mod.Paths.resolve(a, environ, config_dir);
        errdefer resolved.deinit(a);
        if (mode == .mutating) {
            try std.Io.Dir.cwd().createDirPath(io, resolved.root);
            try std.Io.Dir.cwd().createDirPath(io, resolved.sources);
        }

        var root_dir: ?std.Io.Dir = openOptional(io, resolved.root, .{}) catch |e| switch (e) {
            error.FileNotFound => if (mode == .mutating) return e else null,
            else => return e,
        };
        errdefer if (root_dir) |*d| d.close(io);

        var cfg: config.ManagedConfig = undefined;
        var loaded: registry_mod.Loaded = undefined;
        if (root_dir) |rd| {
            cfg = try config.load(a, io, rd, "config.json");
            loaded = try Registry.load(a, io, rd, "links.json");
        } else {
            cfg = .{ .arena = std.heap.ArenaAllocator.init(a), .value = .{} };
            loaded = .{ .registry = .{}, .duplicates = 0 };
        }
        errdefer cfg.deinit();
        errdefer loaded.deinit(a);

        var sources_dir: ?std.Io.Dir = openOptional(io, resolved.sources, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => if (mode == .mutating) return e else null,
            else => return e,
        };
        errdefer if (sources_dir) |*d| d.close(io);

        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const host = try a.dupe(u8, try std.posix.gethostname(&host_buf));
        errdefer a.free(host);
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_len = if (sources_dir) |sd|
            try sd.realPath(io, &real_buf)
        else
            0;
        const sources_real = try a.dupe(u8, if (sources_dir != null)
            real_buf[0..real_len]
        else
            resolved.sources);
        errdefer a.free(sources_real);

        if (loaded.duplicates != 0) {
            try err.print("warning: collapsed {d} duplicate registry entries\n", .{loaded.duplicates});
        }
        return .{
            .a = a,
            .io = io,
            .env = env,
            .paths = resolved,
            .root_dir = root_dir,
            .sources_dir = sources_dir,
            .cfg = cfg,
            .registry = loaded.registry,
            .host = host,
            .home = environ.get("HOME"),
            .sources_real = sources_real,
            .out = out,
            .err = err,
        };
    }

    /// The managed root handle. Assumes a mutating context, which always
    /// creates and opens the root (see `init`).
    fn rootDir(self: *Context) std.Io.Dir {
        return self.root_dir.?;
    }

    /// The sources directory handle. Assumes a mutating context.
    fn sourcesDir(self: *Context) std.Io.Dir {
        return self.sources_dir.?;
    }

    pub fn deinit(self: *Context) void {
        self.a.free(self.sources_real);
        self.a.free(self.host);
        self.registry.deinit(self.a);
        self.cfg.deinit();
        if (self.sources_dir) |*d| d.close(self.io);
        if (self.root_dir) |*d| d.close(self.io);
        self.paths.deinit(self.a);
        self.* = undefined;
    }

    fn reload(self: *Context) !void {
        const rd = self.rootDir();
        var cfg = try config.load(self.a, self.io, rd, "config.json");
        errdefer cfg.deinit();
        var loaded = try Registry.load(self.a, self.io, rd, "links.json");
        errdefer loaded.deinit(self.a);
        self.cfg.deinit();
        self.registry.deinit(self.a);
        self.cfg = cfg;
        self.registry = loaded.registry;
        if (loaded.duplicates != 0) {
            try self.err.print("warning: collapsed {d} duplicate registry entries\n", .{loaded.duplicates});
        }
    }

    fn scan(self: *Context) !discovery.Index {
        return discovery.scan(self.a, self.io, self.sources_dir, self.cfg.value);
    }

    fn report(self: *Context, operand: ?[]const u8, err: anyerror) !void {
        if (operand) |value| try self.err.print("ugarit: {s}: ", .{value}) else try self.err.writeAll("ugarit: ");
        try self.err.writeAll(diagnosticMessage(diagnostic(err)));
        if (err == error.Git and git.lastMessage().len != 0) {
            try self.err.writeAll(": ");
            try config.redact(self.err, git.lastMessage());
        }
        try self.err.writeAll("\n");
    }
};

/// Opens `abs` with `options`, mapping a missing path to `error.FileNotFound`
/// unchanged (the caller decides whether absence is expected).
fn openOptional(io: std.Io, abs: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io, abs, options);
}

pub const SourceAddOptions = struct {
    name: ?[]const u8 = null,
    label: ?[]const u8 = null,
    path: ?[]const u8 = null,
    target: ?[]const u8 = null,
    claude_sync: bool = true,
    ref: ?[]const u8 = null,
};

pub fn sourceAdd(ctx: *Context, url: []const u8, options: SourceAddOptions) !void {
    var lock_file = try paths_mod.lock(ctx.io, ctx.rootDir());
    defer lock_file.close(ctx.io);
    try ctx.reload();

    const name = options.name orelse try config.extractRepoName(url);
    try config.validateName(name);
    if (ctx.cfg.find(name) != null) return error.SourceExists;
    if (ctx.cfg.findUrl(url)) |other| {
        try ctx.err.print("warning: URL already registered as '{s}'\n", .{other.name});
    }
    if (config.hasCredentials(url)) {
        try ctx.err.writeAll("warning: URL contains credentials and is stored in plain text\n");
    }

    try sweepCloneTemps(ctx);
    const old_sources = ctx.cfg.value.sources;
    try ctx.cfg.append(.{
        .name = name,
        .label = options.label,
        .url = url,
        .path = options.path,
        .target = options.target,
        .claude_sync = options.claude_sync,
        .ref = options.ref,
    });
    var config_persisted = false;
    errdefer {
        if (!config_persisted) ctx.cfg.value.sources = old_sources;
    }
    // Reject clashing labels and bad paths before cloning.
    try config.validate(ctx.cfg.value);

    const url_z = try ctx.a.dupeZ(u8, url);
    defer ctx.a.free(url_z);
    const ref_z = if (options.ref) |ref| try ctx.a.dupeZ(u8, ref) else null;
    defer if (ref_z) |ref| ctx.a.free(ref);
    try git.clone(ctx.a, ctx.io, ctx.sourcesDir(), ctx.env, url_z, name, ref_z);
    var persisted = false;
    errdefer if (!persisted) ctx.sourcesDir().deleteTree(ctx.io, name) catch {};
    try failAt(.before_config_save);
    try config.save(ctx.a, ctx.io, ctx.rootDir(), ctx.cfg.value);
    config_persisted = true;
    persisted = true;

    try ctx.out.writeAll("added ");
    try config.redact(ctx.out, url);
    try ctx.out.print(" as {s}\n", .{name});
}

pub fn sourceSync(ctx: *Context, selected: ?[]const u8) !bool {
    var lock_file = try paths_mod.lock(ctx.io, ctx.rootDir());
    defer lock_file.close(ctx.io);
    try ctx.reload();
    const selected_name = if (selected) |key|
        (ctx.cfg.find(key) orelse return error.SourceNotFound).name
    else
        null;

    const synced = try ctx.a.alloc(bool, ctx.cfg.value.sources.len);
    defer ctx.a.free(synced);
    @memset(synced, false);
    var all_ok = true;
    for (ctx.cfg.value.sources, 0..) |source, i| {
        if (selected_name) |name| if (!std.mem.eql(u8, name, source.name)) continue;
        const repo_z = try std.fmt.allocPrintSentinel(ctx.a, "{s}/{s}", .{ ctx.sources_real, source.name }, 0);
        defer ctx.a.free(repo_z);
        var credentials: git.CredState = .{ .env = ctx.env };
        const result = git.sync(repo_z, source.url, &credentials) catch |err| {
            try ctx.report(source.name, err);
            all_ok = false;
            continue;
        };
        synced[i] = true;
        try ctx.out.print("{s}  {s}\n", .{ source.name, switch (result) {
            .up_to_date => "up-to-date",
            .fast_forwarded => "updated",
            .pinned => "pinned",
        } });
    }

    var idx = try ctx.scan();
    defer idx.deinit(ctx.a);
    for (ctx.cfg.value.sources, 0..) |source, i| {
        if (!synced[i]) continue;
        var repair = ctx.registry.repair(
            ctx.a,
            ctx.io,
            idx,
            source.name,
            ctx.host,
            ctx.sources_real,
        ) catch |err| {
            try ctx.report(source.name, err);
            all_ok = false;
            continue;
        };
        defer repair.deinit(ctx.a);
        for (repair.repaired) |entry| try ctx.out.print("repaired {s}\n", .{entry.path});
        for (repair.dangling) |entry| try ctx.err.print("dangling {s}\n", .{entry.path});
    }
    try failAt(.before_registry_save);
    try ctx.registry.save(ctx.a, ctx.io, ctx.rootDir());
    return all_ok;
}

pub const LinkOptions = struct {
    as: ?[]const u8 = null,
    force: bool = false,
    mkdir: bool = false,
    no_exclude: bool = false,
};

/// Links a skill into each destination's `linkSubdirs`.
pub fn link(
    ctx: *Context,
    source_key: []const u8,
    query: []const u8,
    destinations: anytype,
    options: LinkOptions,
) !bool {
    if (destinations.len == 0) return error.Usage;
    var lock_file = try paths_mod.lock(ctx.io, ctx.rootDir());
    defer lock_file.close(ctx.io);
    try ctx.reload();
    const source = ctx.cfg.find(source_key) orelse return error.SourceNotFound;
    var idx = try ctx.scan();
    defer idx.deinit(ctx.a);
    const skill = switch (idx.lookupInSource(source.name, query)) {
        .found => |skill| skill,
        .missing => return error.SkillNotFound,
        .ambiguous => {
            try ctx.err.print("ugarit: '{s}/{s}' is ambiguous:\n", .{ source.name, query });
            try ctx.err.writeAll("  use the source-relative skill path\n");
            return error.AmbiguousSkill;
        },
    };
    const name = options.as orelse skill.name;
    try config.validateName(name);

    var subdirs_buf: [2][]const u8 = undefined;
    const subdirs = source.linkSubdirs(&subdirs_buf);
    var all_ok = true;
    for (destinations) |raw| {
        // Subdirs resolving to the same directory are linked once.
        var seen: [subdirs_buf.len]?[]u8 = @splat(null);
        defer for (seen) |s| if (s) |path| ctx.a.free(path);
        for (subdirs, 0..) |subdir, i| {
            // A destination that already is `.claude/skills` gets no nested copy.
            if (std.mem.eql(u8, subdir, config.claude_skills_dir) and isClaudeSkillsDir(ctx, raw)) continue;
            const dest = if (subdir.len == 0)
                try ctx.a.dupe(u8, raw)
            else
                try std.fs.path.join(ctx.a, &.{ raw, subdir });
            defer ctx.a.free(dest);
            if (paths_mod.canonicalDestPath(ctx.a, ctx.io, ctx.home, dest)) |canonical| {
                seen[i] = canonical;
                const duplicate = for (seen[0..i]) |prior| {
                    if (prior) |p| if (std.mem.eql(u8, p, canonical)) break true;
                } else false;
                if (duplicate) continue;
            } else |_| {} // `linkOne` reports the same failure below

            var one = options;
            // Subdirs are created on demand; the destination itself is not.
            if (subdir.len != 0) {
                requireDestRoot(ctx, raw, options.mkdir) catch |err| {
                    try ctx.report(raw, err);
                    all_ok = false;
                    break;
                };
                one.mkdir = true;
            }
            linkOne(ctx, skill, name, dest, one) catch |err| {
                try ctx.report(dest, err);
                all_ok = false;
            };
        }
    }
    return all_ok;
}

fn isClaudeSkillsDir(ctx: *Context, raw: []const u8) bool {
    const canonical = paths_mod.canonicalDestPath(ctx.a, ctx.io, ctx.home, raw) catch return false;
    defer ctx.a.free(canonical);
    return std.mem.endsWith(u8, canonical, "/" ++ config.claude_skills_dir);
}

/// `FileNotFound` unless `raw` exists or `mkdir` is set.
fn requireDestRoot(ctx: *Context, raw: []const u8, mkdir: bool) !void {
    if (mkdir) return;
    const root = try paths_mod.canonicalDestPath(ctx.a, ctx.io, ctx.home, raw);
    defer ctx.a.free(root);
    var dir = try std.Io.Dir.openDirAbsolute(ctx.io, root, .{});
    dir.close(ctx.io);
}

pub fn linkOne(
    ctx: *Context,
    skill: discovery.Skill,
    name: []const u8,
    raw: []const u8,
    options: LinkOptions,
) !void {
    const dest = try paths_mod.canonicalDestPath(ctx.a, ctx.io, ctx.home, raw);
    defer ctx.a.free(dest);
    if (paths_mod.isUnder(dest, ctx.sources_real)) return error.DestInsideSources;
    if (paths_mod.isUnder(dest, skill.abs_path)) return error.DestInsideSkill;
    if (options.mkdir) try std.Io.Dir.cwd().createDirPath(ctx.io, dest);
    const link_abs = try std.fs.path.join(ctx.a, &.{ dest, name });
    defer ctx.a.free(link_abs);

    // Prepare every registry allocation before touching the destination. If
    // allocation fails, both disk and live registry remain unchanged.
    var candidate = try cloneRegistry(ctx.a, ctx.registry);
    var candidate_owned = true;
    errdefer if (candidate_owned) candidate.deinit(ctx.a);
    try candidate.upsert(ctx.a, .{
        .path = link_abs,
        .source = skill.source,
        .rel_path = skill.rel_path,
        .skill = skill.name,
        .host = ctx.host,
    });
    const registry_bytes = try candidate.encode(ctx.a);
    defer ctx.a.free(registry_bytes);

    var dir = try std.Io.Dir.openDirAbsolute(ctx.io, dest, .{ .iterate = true });
    defer dir.close(ctx.io);
    try preflightLink(ctx, dir, name, skill, options.force);

    // Failure atomicity: write and flush the registry bytes *before* touching
    // the destination, so every fallible registry I/O happens while both
    // sides are still untouched; only the atomic rename comes after the link.
    var prepared = try Registry.PreparedSave.prepare(ctx.io, ctx.rootDir(), registry_bytes);
    errdefer prepared.deinit(ctx.io);

    // Exclude idempotence: remember exactly what this call appended so a
    // failed link can put info/exclude back byte-for-byte.
    var exclusion: ?symlink.Exclusion = null;
    defer if (exclusion) |x| ctx.a.free(x.line);
    if (!options.no_exclude) switch (try symlink.excludeInEnclosingRepo(ctx.a, ctx.io, link_abs)) {
        .excluded => |x| exclusion = x,
        else => {},
    };

    const outcome = symlink.link(ctx.io, dir, name, skill, ctx.sources_real, options.force) catch |e| {
        if (exclusion) |x| {
            symlink.revertExcludeLine(ctx.a, ctx.io, link_abs, x) catch {};
        }
        return e;
    };

    try failAt(.before_registry_commit);
    try prepared.commit(ctx.io);
    replaceRegistry(ctx, candidate);
    candidate_owned = false;
    try ctx.out.print("{s} {s} -> {s}/{s}\n", .{
        @tagName(outcome),
        link_abs,
        skill.source,
        skill.rel_path,
    });
}

pub fn unlink(ctx: *Context, raw_paths: anytype, skill_name: ?[]const u8) !bool {
    if ((skill_name == null and raw_paths.len == 0) or (skill_name != null and raw_paths.len != 0)) {
        return error.Usage;
    }
    var lock_file = try paths_mod.lock(ctx.io, ctx.rootDir());
    defer lock_file.close(ctx.io);
    try ctx.reload();

    var selected: std.ArrayList([]const u8) = .empty;
    defer {
        for (selected.items) |path| ctx.a.free(path);
        selected.deinit(ctx.a);
    }
    if (skill_name) |name| {
        for (ctx.registry.links) |entry| {
            if (!std.mem.eql(u8, entry.host, ctx.host)) continue;
            if (!std.ascii.eqlIgnoreCase(entry.skill, name)) continue;
            try selected.append(ctx.a, try ctx.a.dupe(u8, entry.path));
        }
    } else {
        for (raw_paths) |path| try selected.append(ctx.a, try ctx.a.dupe(u8, path));
    }

    var all_ok = true;
    for (selected.items) |raw| {
        unlinkOne(ctx, raw) catch |err| {
            try ctx.report(raw, err);
            all_ok = false;
        };
    }
    return all_ok;
}

fn unlinkOne(ctx: *Context, raw: []const u8) !void {
    const link_path = paths_mod.canonicalLinkPath(ctx.a, ctx.io, ctx.home, raw) catch |err| blk: {
        if (err != error.FileNotFound or !std.fs.path.isAbsolute(raw) or !hasLocalEntry(ctx, raw)) return err;
        break :blk try ctx.a.dupe(u8, raw);
    };
    defer ctx.a.free(link_path);
    const registered = hasLocalEntry(ctx, link_path);

    var candidate = try cloneRegistry(ctx.a, ctx.registry);
    var candidate_owned = true;
    errdefer if (candidate_owned) candidate.deinit(ctx.a);
    _ = try candidate.remove(ctx.a, link_path, ctx.host);
    const registry_bytes = try candidate.encode(ctx.a);
    defer ctx.a.free(registry_bytes);

    const parent = std.fs.path.dirname(link_path) orelse return error.InvalidLinkPath;
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, parent, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            if (!registered) return err;
            // The whole project is gone; no filesystem mutation happens, so
            // ordering is irrelevant here.
            try Registry.saveBytes(ctx.io, ctx.rootDir(), registry_bytes);
            replaceRegistry(ctx, candidate);
            candidate_owned = false;
            try ctx.out.print("absent {s}\n", .{link_path});
            return;
        },
        else => return err,
    };
    defer dir.close(ctx.io);

    // Failure atomicity: flush the registry bytes before removing the link;
    // only the atomic rename remains after the filesystem mutation.
    var prepared = try Registry.PreparedSave.prepare(ctx.io, ctx.rootDir(), registry_bytes);
    errdefer prepared.deinit(ctx.io);
    const outcome = try symlink.unlink(ctx.io, dir, std.fs.path.basename(link_path), ctx.sources_real);
    try failAt(.before_registry_commit);
    try prepared.commit(ctx.io);
    replaceRegistry(ctx, candidate);
    candidate_owned = false;
    try ctx.out.print("{s} {s}\n", .{ @tagName(outcome), link_path });
}

pub const ListOptions = struct {
    source: ?[]const u8 = null,
    links: bool = false,
};

pub fn list(ctx: *Context, query: ?[]const u8, list_options: ListOptions) !void {
    var options = list_options;
    if (options.source) |key| if (ctx.cfg.find(key)) |source| {
        options.source = source.name;
    };
    var idx = try ctx.scan();
    defer idx.deinit(ctx.a);
    for (idx.warnings) |warning| try ctx.err.print("warning: {s}\n", .{warning});

    var only: ?discovery.Skill = null;
    if (query) |value| {
        only = switch (idx.lookup(value)) {
            .found => |skill| skill,
            .missing => if (options.links) null else return error.SkillNotFound,
            .ambiguous => return error.AmbiguousSkill,
        };
    }
    for (idx.skills) |skill| {
        if (only) |wanted| if (!std.mem.eql(u8, wanted.abs_path, skill.abs_path)) continue;
        if (options.source) |source| if (!std.mem.eql(u8, source, skill.source)) continue;
        var count: usize = 0;
        for (ctx.registry.links) |entry| {
            if (!std.mem.eql(u8, entry.host, ctx.host)) continue;
            if (std.mem.eql(u8, entry.source, skill.source) and
                std.mem.eql(u8, entry.rel_path, skill.rel_path)) count += 1;
        }
        try ctx.out.print("{s}/{s}  {d} links\n", .{ skill.source, skill.rel_path, count });
        if (query != null or options.links) {
            for (ctx.registry.links) |entry| {
                if (!std.mem.eql(u8, entry.source, skill.source) or
                    !std.mem.eql(u8, entry.rel_path, skill.rel_path)) continue;
                if (!std.mem.eql(u8, entry.host, ctx.host)) {
                    try ctx.out.print("  {s}  other-host ({s})\n", .{ entry.path, entry.host });
                    continue;
                }
                const state = try registry_mod.status(ctx.io, entry, ctx.sources_real);
                try ctx.out.print("  {s}  {s}\n", .{ entry.path, @tagName(state) });
            }
        }
    }
    if (options.links) {
        for (ctx.registry.links) |entry| {
            if (options.source) |source| if (!std.mem.eql(u8, source, entry.source)) continue;
            if (query) |value| if (!entryMatchesQuery(entry, value)) continue;
            if (entryIsDiscovered(idx, entry)) continue;
            if (!std.mem.eql(u8, entry.host, ctx.host)) {
                try ctx.out.print("{s}/{s}  orphan\n  {s}  other-host ({s})\n", .{
                    entry.source,
                    entry.rel_path,
                    entry.path,
                    entry.host,
                });
                continue;
            }
            const state = try registry_mod.status(ctx.io, entry, ctx.sources_real);
            try ctx.out.print("{s}/{s}  orphan\n  {s}  {s}\n", .{
                entry.source,
                entry.rel_path,
                entry.path,
                @tagName(state),
            });
        }
    }
}

fn preflightLink(
    ctx: *Context,
    dir: std.Io.Dir,
    name: []const u8,
    skill: discovery.Skill,
    force: bool,
) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    switch (try symlink.classify(ctx.io, dir, name, ctx.sources_real, &buf)) {
        .absent => {},
        .real => return error.RealEntryInTheWay,
        .foreign_link => if (!force) return error.ForeignLinkInTheWay,
        .ours => |entry| {
            if (std.mem.eql(u8, entry.target, skill.abs_path)) return;
            if (!entry.dangling and !force) return error.LinkedFromOtherSource;
        },
    }
}

fn entryIsDiscovered(idx: discovery.Index, entry: registry_mod.Link) bool {
    for (idx.skills) |skill| {
        if (std.mem.eql(u8, skill.source, entry.source) and
            std.mem.eql(u8, skill.rel_path, entry.rel_path)) return true;
    }
    return false;
}

fn entryMatchesQuery(entry: registry_mod.Link, query: []const u8) bool {
    if (std.mem.indexOfScalar(u8, query, '/') == null) {
        return std.ascii.eqlIgnoreCase(entry.skill, query);
    }
    if (query.len != entry.source.len + 1 + entry.rel_path.len) return false;
    return std.mem.eql(u8, query[0..entry.source.len], entry.source) and
        query[entry.source.len] == '/' and
        std.mem.eql(u8, query[entry.source.len + 1 ..], entry.rel_path);
}

fn cloneRegistry(a: std.mem.Allocator, source: Registry) !Registry {
    var result: Registry = .{ .version = source.version };
    errdefer result.deinit(a);
    for (source.links) |entry| try result.upsert(a, entry);
    return result;
}

fn replaceRegistry(ctx: *Context, replacement: Registry) void {
    var old = ctx.registry;
    ctx.registry = replacement;
    old.deinit(ctx.a);
}

fn hasLocalEntry(ctx: *const Context, path: []const u8) bool {
    for (ctx.registry.links) |entry| {
        if (std.mem.eql(u8, entry.host, ctx.host) and std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

fn sweepCloneTemps(ctx: *Context) !void {
    var it = ctx.sourcesDir().iterate();
    while (try it.next(ctx.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, ".tmp-")) continue;
        try ctx.sourcesDir().deleteTree(ctx.io, entry.name);
    }
}

fn injectGitAfterClone(point: git.FaultPoint) bool {
    return point == .after_clone;
}

fn injectBeforeConfigSave(point: FaultPoint) bool {
    return point == .before_config_save;
}

fn expectNoCloneTrace(ctx: *Context, source_name: []const u8) !void {
    try std.testing.expectError(
        error.FileNotFound,
        ctx.sourcesDir().access(ctx.io, source_name, .{ .follow_symlinks = false }),
    );
    var it = ctx.sourcesDir().iterate();
    while (try it.next(ctx.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".tmp-"));
    }
}

const LinkOomContext = struct {
    io: std.Io,
    env: *const std.process.Environ.Map,
    ugarit_home: []const u8,
    dest: []const u8,
    sources_real: []const u8,
    skill_abs: []const u8,
};

fn checkLinkOneAllocationFailures(a: std.mem.Allocator, fixture: LinkOomContext) !void {
    const link_abs = try std.fs.path.join(std.testing.allocator, &.{ fixture.dest, "zig" });
    defer std.testing.allocator.free(link_abs);
    const links_json = try std.fs.path.join(std.testing.allocator, &.{ fixture.ugarit_home, "links.json" });
    defer std.testing.allocator.free(links_json);
    std.Io.Dir.deleteFileAbsolute(fixture.io, link_abs) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.deleteFileAbsolute(fixture.io, links_json) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var out_buf: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [8192]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var ctx = Context.init(a, fixture.io, fixture.env, fixture.ugarit_home, &out, &err) catch |failure| {
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.accessAbsolute(fixture.io, link_abs, .{ .follow_symlinks = false }),
        );
        return failure;
    };
    defer ctx.deinit();

    linkOne(&ctx, .{
        .name = "zig",
        .source = "central",
        .rel_path = "zig",
        .abs_path = fixture.skill_abs,
    }, "zig", fixture.dest, .{ .no_exclude = true }) catch |failure| {
        try std.testing.expectEqual(@as(usize, 0), ctx.registry.links.len);
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.accessAbsolute(fixture.io, link_abs, .{ .follow_symlinks = false }),
        );
        return failure;
    };
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.links.len);
    try std.Io.Dir.accessAbsolute(fixture.io, link_abs, .{ .follow_symlinks = false });
}

// Atomic visibility, completeness, OOM safety: a failed `linkOne` must leave
// the destination absent and the registry empty, regardless of which single
// allocation fails.
test "linkOne leaves no half-state under every OOM (a: exhaustive allocation failures)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(io, "managed/sources/central/zig");
    try t.dir.writeFile(io, .{ .sub_path = "managed/sources/central/zig/SKILL.md", .data = "v1\n" });
    try t.dir.createDirPath(io, "dest");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const managed = try std.fs.path.join(a, &.{ root, "managed" });
    defer a.free(managed);
    const dest = try std.fs.path.join(a, &.{ root, "dest" });
    defer a.free(dest);
    const sources_real = try std.fs.path.join(a, &.{ managed, "sources" });
    defer a.free(sources_real);
    const skill_abs = try std.fs.path.join(a, &.{ sources_real, "central/zig" });
    defer a.free(skill_abs);
    const link_abs = try std.fs.path.join(a, &.{ dest, "zig" });
    defer a.free(link_abs);
    defer std.Io.Dir.deleteFileAbsolute(io, link_abs) catch {};

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try std.testing.checkAllAllocationFailures(
        a,
        checkLinkOneAllocationFailures,
        .{LinkOomContext{
            .io = io,
            .env = &env,
            .ugarit_home = managed,
            .dest = dest,
            .sources_real = sources_real,
            .skill_abs = skill_abs,
        }},
    );
}

// Failure atomicity: a registry commit failure after the link lands leaves
// the link on disk, the registry untouched and no temp file in the managed
// root; re-running the same link converges (atomic visibility residue).
test "link commit failure is reported and a re-run converges (a: fault injection)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(io, "managed/sources/central/zig");
    try t.dir.writeFile(io, .{ .sub_path = "managed/sources/central/zig/SKILL.md", .data = "v1\n" });
    try t.dir.createDirPath(io, "dest");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const managed = try std.fs.path.join(a, &.{ root, "managed" });
    defer a.free(managed);
    const dest = try std.fs.path.join(a, &.{ root, "dest" });
    defer a.free(dest);
    const skill_abs = try std.fs.path.join(a, &.{ managed, "sources/central/zig" });
    defer a.free(skill_abs);
    const link_abs = try std.fs.path.join(a, &.{ dest, "zig" });
    defer a.free(link_abs);
    const links_json = try std.fs.path.join(a, &.{ managed, "links.json" });
    defer a.free(links_json);
    const skill = discovery.Skill{
        .name = "zig",
        .source = "central",
        .rel_path = "zig",
        .abs_path = skill_abs,
    };

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var ctx = try Context.init(a, io, &env, managed, &out, &err);
    defer ctx.deinit();

    fault = injectBeforeRegistryCommit;
    defer fault = null;
    try std.testing.expectError(
        error.FaultInjected,
        linkOne(&ctx, skill, "zig", dest, .{ .no_exclude = true }),
    );

    // The link landed but nothing else did: no registry file, no entry, and
    // no leftover temp file in the managed root (the prepared save was
    // discarded).
    try std.Io.Dir.accessAbsolute(io, link_abs, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(usize, 0), ctx.registry.links.len);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, links_json, .{}));
    {
        var root_iter = try std.Io.Dir.openDirAbsolute(io, managed, .{ .iterate = true });
        defer root_iter.close(io);
        var it = root_iter.iterate();
        while (try it.next(io)) |entry| {
            try std.testing.expectEqualStrings("sources", entry.name);
        }
    }

    // Recovery: the same link command converges — `unchanged` on disk,
    // registered in the file — and a third run is a full no-op.
    fault = null;
    const unchanged_line = try std.fmt.allocPrint(a, "unchanged {s} -> central/zig\n", .{link_abs});
    defer a.free(unchanged_line);
    out = std.Io.Writer.fixed(&out_buf);
    ctx.out = &out;
    try linkOne(&ctx, skill, "zig", dest, .{ .no_exclude = true });
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.links.len);
    try std.Io.Dir.accessAbsolute(io, links_json, .{});
    try std.testing.expectEqualStrings(unchanged_line, out.buffered());

    out = std.Io.Writer.fixed(&out_buf);
    ctx.out = &out;
    try linkOne(&ctx, skill, "zig", dest, .{ .no_exclude = true });
    try std.testing.expectEqualStrings(unchanged_line, out.buffered());
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.links.len);
}

fn injectBeforeRegistryCommit(point: FaultPoint) bool {
    return point == .before_registry_commit;
}

fn injectBeforeRegistrySave(point: FaultPoint) bool {
    return point == .before_registry_save;
}

// Repair convergence: a source-sync interrupted before the registry save
// leaves links repaired on disk but the registry stale; the next sync adopts
// reality (no relink) and everything reads `ok` again (failure atomicity
// residue; repair preserves identity).
test "source-sync interrupted before the registry save converges on re-run (a: fault injection)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    var libgit = try git.fixtures.Libgit2.init();
    defer libgit.deinit();
    const origin = try git.fixtures.initOrigin(a, io, t.dir, "origin");
    defer a.free(origin);
    try git.fixtures.commitFile(io, origin, "zig/SKILL.md", "v1\n");
    try t.dir.createDirPath(io, "dest");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const ugarit_home = try std.fs.path.join(a, &.{ root, "home" });
    defer a.free(ugarit_home);
    const dest = try std.fs.path.join(a, &.{ root, "dest" });
    defer a.free(dest);
    const skill_abs = try std.fs.path.join(a, &.{ ugarit_home, "sources/central/zig" });
    defer a.free(skill_abs);
    const link_abs = try std.fs.path.join(a, &.{ dest, "zig" });
    defer a.free(link_abs);
    const links_json = try std.fs.path.join(a, &.{ ugarit_home, "links.json" });
    defer a.free(links_json);
    const skill = discovery.Skill{
        .name = "zig",
        .source = "central",
        .rel_path = "zig",
        .abs_path = skill_abs,
    };

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    var out_buf: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [8192]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var ctx = try Context.init(a, io, &env, ugarit_home, &out, &err);
    defer ctx.deinit();

    try sourceAdd(&ctx, origin, .{ .name = "central" });
    try linkOne(&ctx, skill, "zig", dest, .{ .no_exclude = true });

    // Upstream moves the skill; the interrupted sync repairs the disk link
    // but never persists the registry.
    try git.fixtures.moveFile(io, origin, "zig/SKILL.md", "lang/zig/SKILL.md");
    fault = injectBeforeRegistrySave;
    try std.testing.expectError(error.FaultInjected, sourceSync(&ctx, null));
    {
        var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest, .{});
        defer dest_dir.close(io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try dest_dir.readLink(io, "zig", &buf);
        try std.testing.expect(std.mem.endsWith(u8, buf[0..n], "/central/lang/zig"));
    }
    const stale = try std.Io.Dir.cwd().readFileAlloc(io, links_json, a, .limited(1 << 20));
    defer a.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "\"rel_path\":\"zig\"") != null);

    // The re-run adopts the already-repaired link (no relink, one report).
    fault = null;
    out = std.Io.Writer.fixed(&out_buf);
    ctx.out = &out;
    try std.testing.expect(try sourceSync(&ctx, null));
    try std.testing.expectStringStartsWith(out.buffered(), "central  up-to-date\nrepaired ");
    try std.testing.expectEqual(@as(usize, 1), ctx.registry.links.len);
    try std.testing.expectEqualStrings("lang/zig", ctx.registry.links[0].rel_path);
    try std.testing.expectEqual(
        registry_mod.State.ok,
        try registry_mod.status(io, ctx.registry.links[0], ctx.sources_real),
    );
    const converged = try std.Io.Dir.cwd().readFileAlloc(io, links_json, a, .limited(1 << 20));
    defer a.free(converged);
    try std.testing.expect(std.mem.indexOf(u8, converged, "\"rel_path\":\"lang/zig\"") != null);

    // A third sync is a full no-op.
    out = std.Io.Writer.fixed(&out_buf);
    ctx.out = &out;
    try std.testing.expect(try sourceSync(&ctx, null));
    try std.testing.expectEqualStrings("central  up-to-date\n", out.buffered());
    try std.testing.expectEqualStrings("lang/zig", ctx.registry.links[0].rel_path);
}

// Failure atomicity: an injected fault after the clone (or before the config
// save) must leave config bytes unchanged and no `.tmp-*` clone trace behind.
test "source-add failures preserve config and leave no clone trace (a: fault injection)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    var libgit = try git.fixtures.Libgit2.init();
    defer libgit.deinit();
    const origin = try git.fixtures.initOrigin(a, io, t.dir, "origin");
    defer a.free(origin);
    try git.fixtures.commitFile(io, origin, "zig/SKILL.md", "v1\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const ugarit_home = try std.fs.path.join(a, &.{ root_buf[0..root_len], "home" });
    defer a.free(ugarit_home);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root_buf[0..root_len]);
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var ctx = try Context.init(a, io, &env, ugarit_home, &out, &err);
    defer ctx.deinit();
    const original = "{\"version\":1,\"sources\":[]}";
    try ctx.root_dir.?.writeFile(io, .{ .sub_path = "config.json", .data = original });

    git.fault = injectGitAfterClone;
    defer git.fault = null;
    try std.testing.expectError(
        error.Git,
        sourceAdd(&ctx, origin, .{ .name = "central" }),
    );
    try expectNoCloneTrace(&ctx, "central");
    var bytes = try ctx.root_dir.?.readFileAlloc(io, "config.json", a, .limited(1024));
    defer a.free(bytes);
    try std.testing.expectEqualStrings(original, bytes);

    git.fault = null;
    fault = injectBeforeConfigSave;
    defer fault = null;
    try std.testing.expectError(
        error.FaultInjected,
        sourceAdd(&ctx, origin, .{ .name = "central" }),
    );
    try expectNoCloneTrace(&ctx, "central");
    a.free(bytes);
    bytes = try ctx.root_dir.?.readFileAlloc(io, "config.json", a, .limited(1024));
    try std.testing.expectEqualStrings(original, bytes);

    fault = null;
    var no_output_buf: [0]u8 = .{};
    var no_output = std.Io.Writer.fixed(&no_output_buf);
    ctx.out = &no_output;
    if (sourceAdd(&ctx, origin, .{ .name = "central" })) |_| {
        return error.ExpectedWriteFailure;
    } else |_| {}
    try ctx.sources_dir.?.access(io, "central", .{});
    try ctx.reload();
    try std.testing.expect(ctx.cfg.find("central") != null);
}

// No collateral damage + confinement: `--mkdir` must reject a destination
// inside sources *before* creating it, so the rejected path never exists.
test "link --mkdir rejects a destination inside sources before creation (a: pinned ordering regression)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const managed = try std.fs.path.join(a, &.{ root_buf[0..root_len], "managed" });
    defer a.free(managed);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root_buf[0..root_len]);
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var ctx = try Context.init(a, io, &env, managed, &out, &err);
    defer ctx.deinit();
    try ctx.sources_dir.?.createDirPath(io, "central/zig");
    try ctx.sources_dir.?.writeFile(io, .{ .sub_path = "central/zig/SKILL.md", .data = "v1\n" });
    const skill_abs = try std.fs.path.join(a, &.{ ctx.sources_real, "central/zig" });
    defer a.free(skill_abs);
    const rejected = try std.fs.path.join(a, &.{ skill_abs, "nested/dest" });
    defer a.free(rejected);
    try std.testing.expectError(
        error.DestInsideSources,
        linkOne(&ctx, .{
            .name = "zig",
            .source = "central",
            .rel_path = "zig",
            .abs_path = skill_abs,
        }, "zig", rejected, .{ .mkdir = true, .no_exclude = true }),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, rejected, .{ .follow_symlinks = false }),
    );
}

// Exit status: every diagnostic category maps to a non-empty message and an
// exit code of 1 or 2.
test "diagnostic table covers every category (b: exhaustive CLI contract)" {
    inline for (std.meta.tags(Diagnostic)) |kind| {
        try std.testing.expect(diagnosticMessage(kind).len != 0);
        const code = diagnosticExitCode(kind);
        try std.testing.expect(code == 1 or code == 2);
    }
}

// Read-only purity: `list` never creates the managed root or sources
// directory, whether both are missing, only the root exists, or both exist.
test "read-only list creates no directories (c: un-generatable, absent-tree states)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);

    // Case 1: nothing exists yet — defaults, no warnings, nothing created.
    {
        var ctx = try Context.initReadOnly(a, io, &env, null, &out, &err);
        defer ctx.deinit();
        try list(&ctx, null, .{});
        try std.testing.expect(ctx.root_dir == null);
        try std.testing.expect(ctx.sources_dir == null);
        try std.testing.expectEqual(@as(usize, 0), ctx.registry.links.len);
    }
    const case1_root = try std.fs.path.join(a, &.{ root, ".config/ugarit" });
    defer a.free(case1_root);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, case1_root, .{ .follow_symlinks = false }),
    );

    // Case 2: root exists with a config, sources missing — per-source warning.
    try t.dir.createDirPath(io, "home/.config/ugarit");
    try t.dir.writeFile(io, .{
        .sub_path = "home/.config/ugarit/config.json",
        .data = "{\"version\":1,\"sources\":[{\"name\":\"central\",\"url\":\"/unused\"}]}",
    });
    const home = try std.fs.path.join(a, &.{ root, "home" });
    defer a.free(home);
    try env.put("HOME", home);
    {
        var ctx = try Context.initReadOnly(a, io, &env, null, &out, &err);
        defer ctx.deinit();
        try list(&ctx, null, .{});
        try std.testing.expect(ctx.root_dir != null);
        try std.testing.expect(ctx.sources_dir == null);
    }
    const case2_sources = try std.fs.path.join(a, &.{ home, ".config/ugarit/sources" });
    defer a.free(case2_sources);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, case2_sources, .{ .follow_symlinks = false }),
    );

    // Mutating init still creates both, and list over a real tree works.
    {
        var ctx = try Context.init(a, io, &env, null, &out, &err);
        defer ctx.deinit();
        try std.testing.expect(ctx.root_dir != null);
        try std.testing.expect(ctx.sources_dir != null);
        try list(&ctx, null, .{});
    }
    try std.Io.Dir.accessAbsolute(io, case2_sources, .{ .follow_symlinks = false });
}
