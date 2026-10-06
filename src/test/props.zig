//! Property tests for `paths.zig` and `config.zig` (P2–P5 in PLAN.md).
//! Every property states its claim in the test name; failures print the seed
//! and the shrunk counterexample (minish).

const std = @import("std");
const minish = @import("minish");
const ugarit = @import("ugarit");

const config = ugarit.config;
const paths = ugarit.paths;
const gen = minish.gen;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ---------------------------------------------------------------------------
// P2/P2b: extractRepoName (I14)
// ---------------------------------------------------------------------------

fn urlNameRoundTrip(name: []const u8) !void {
    const forms = [_][]const u8{
        "https://h.io/o/{s}.git/",
        "git@h.io:o/{s}.git",
        "ssh://git@h.io:22/o/{s}",
        "file:///tmp/{s}",
    };
    inline for (forms) |form| {
        var buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&buf, form, .{name});
        const got = try config.extractRepoName(url);
        try expectEqualStrings(name, got);
    }
}

test "P2: extractRepoName recovers the name from every URL form" {
    try minish.check(
        std.testing.allocator,
        gen.string(.{ .min_len = 1, .max_len = 24, .charset = .alphanumeric }),
        urlNameRoundTrip,
        .{ .seed = 0x5eed, .num_runs = 300 },
    );
}

const UrlMutation = struct {
    name: []const u8,
    kind: u8,
    junk: []const u8,
    cut: u8,
};

fn parsedNameIsValid(url: []const u8) !void {
    if (config.extractRepoName(url)) |n| {
        try config.validateName(n);
    } else |_| {}
}

fn expectName(url: []const u8, name: []const u8) !void {
    const got = try config.extractRepoName(url);
    try expectEqualStrings(name, got);
}

fn urlRobustness(m: UrlMutation) !void {
    const a = std.testing.allocator;
    const base = try std.fmt.allocPrint(a, "https://h.io/o/{s}", .{m.name});
    defer a.free(base);
    switch (m.kind) {
        0 => {
            const url = try std.fmt.allocPrint(a, "{s}?q={s}", .{ base, m.junk });
            defer a.free(url);
            try expectName(url, m.name);
        },
        1 => {
            const url = try std.fmt.allocPrint(a, "{s}#{s}", .{ base, m.junk });
            defer a.free(url);
            try expectName(url, m.name);
        },
        2 => {
            const url = try std.fmt.allocPrint(a, "{s}/", .{base});
            defer a.free(url);
            try expectName(url, m.name);
        },
        3 => {
            const url = try std.fmt.allocPrint(a, "https://user:pw@h.io/o/{s}", .{m.name});
            defer a.free(url);
            try expectName(url, m.name);
        },
        4 => {
            const cut = @as(usize, m.cut) % (base.len + 1);
            try parsedNameIsValid(base[0..cut]);
        },
        5 => try parsedNameIsValid(m.junk),
        6 => {
            const url = try std.fmt.allocPrint(a, "git@h.io:{s}", .{m.junk});
            defer a.free(url);
            try parsedNameIsValid(url);
        },
        else => unreachable,
    }
}

test "P2b: extractRepoName never crashes and yields valid-or-error on near-miss URLs" {
    const url_mut_gen = gen.structure(UrlMutation, .{
        .name = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric }),
        .kind = gen.intRange(u8, 0, 6),
        .junk = gen.string(.{ .min_len = 0, .max_len = 12, .charset = .printable }),
        .cut = gen.int(u8),
    });
    try minish.check(std.testing.allocator, url_mut_gen, urlRobustness, .{
        .seed = 0x2b2b2b,
        .num_runs = 300,
    });
}

// ---------------------------------------------------------------------------
// P3/P3b: validateName (I14)
// ---------------------------------------------------------------------------

fn specValidName(n: []const u8) bool {
    if (n.len == 0 or n.len > 128) return false;
    if (n[0] == '-' or n[0] == '.') return false;
    for (n) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '.' or ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

fn validateNameMatchesSpec(n: []const u8) !void {
    const got_valid = if (config.validateName(n)) |_| true else |_| false;
    try expectEqual(specValidName(n), got_valid);
}

test "P3: validateName agrees with an independently written name spec" {
    try minish.check(
        std.testing.allocator,
        gen.string(.{ .min_len = 0, .max_len = 64, .charset = .printable }),
        validateNameMatchesSpec,
        .{ .seed = 0x5be3c, .num_runs = 300 },
    );
}

const BoundaryCase = struct { name: []const u8, valid: bool };

fn boundaryNames(i: usize) !void {
    const long_129 = [_]u8{'a'} ** 129;
    const exact_128 = [_]u8{'a'} ** 128;
    const cases = [_]BoundaryCase{
        .{ .name = "", .valid = false },
        .{ .name = ".", .valid = false },
        .{ .name = "..", .valid = false },
        .{ .name = "-x", .valid = false },
        .{ .name = ".x", .valid = false },
        .{ .name = long_129[0..], .valid = false },
        .{ .name = "a b", .valid = false },
        .{ .name = "a/b", .valid = false },
        .{ .name = "a\x01b", .valid = false },
        .{ .name = "\xc3\xa1bc", .valid = false },
        .{ .name = "ok_name-1.2", .valid = true },
        .{ .name = "A9", .valid = true },
        .{ .name = "a", .valid = true },
        .{ .name = exact_128[0..], .valid = true },
    };
    const c = cases[i];
    const got_valid = if (config.validateName(c.name)) |_| true else |_| false;
    try expectEqual(c.valid, got_valid);
}

test "P3b: validateName boundary classes" {
    try minish.check(
        std.testing.allocator,
        gen.intRange(usize, 0, 13),
        boundaryNames,
        .{ .seed = 0xb04d, .num_runs = 42 },
    );
}

// ---------------------------------------------------------------------------
// P4: config save/load (I12, I13)
// ---------------------------------------------------------------------------

const SourceSeed = struct {
    suffix: []const u8,
    url: []const u8,
    has_ref: bool,
    ref_val: []const u8,
};

const ConfigSeed = struct {
    sources: []const SourceSeed,
};

const source_seed_gen = gen.structure(SourceSeed, .{
    .suffix = gen.string(.{ .min_len = 0, .max_len = 8, .charset = .alphanumeric }),
    .url = gen.string(.{ .min_len = 0, .max_len = 24, .charset = .printable }),
    .has_ref = gen.boolean(),
    .ref_val = gen.string(.{ .min_len = 0, .max_len = 8, .charset = .printable }),
});

const config_seed_gen = gen.structure(ConfigSeed, .{
    .sources = gen.list(SourceSeed, source_seed_gen, 0, 5),
});

fn expectConfigEqual(expected: config.Config, actual: config.Config) !void {
    try expectEqual(expected.version, actual.version);
    try expectEqual(expected.sources.len, actual.sources.len);
    for (expected.sources, actual.sources) |e, o| {
        try expectEqualStrings(e.name, o.name);
        try expectEqualStrings(e.url, o.url);
        try expectEqual(e.ref == null, o.ref == null);
        if (e.ref) |er| try expectEqualStrings(er, o.ref.?);
    }
}

fn configRoundTrip(seed: ConfigSeed) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sources = try a.alloc(config.SourceRepo, seed.sources.len);
    for (seed.sources, 0..) |s, i| {
        sources[i] = .{
            .name = try std.fmt.allocPrint(a, "s{d}{s}", .{ i, s.suffix }),
            .url = s.url,
            .ref = if (s.has_ref) s.ref_val else null,
        };
    }
    const cfg: config.Config = .{ .sources = sources };

    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    const io = std.testing.io;

    try config.save(a, io, t.dir, cfg);
    var loaded = try config.load(std.testing.allocator, io, t.dir, "config.json");
    defer loaded.deinit();
    try expectConfigEqual(cfg, loaded.value);

    var again = try config.load(std.testing.allocator, io, t.dir, "config.json");
    defer again.deinit();
    try expectConfigEqual(loaded.value, again.value);
}

test "P4: config save→load is the identity" {
    try minish.check(std.testing.allocator, config_seed_gen, configRoundTrip, .{
        .seed = 0xc04f16,
        .num_runs = 200,
    });
}

fn configRejectsBadBytes(bytes: []const u8) !void {
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    const io = std.testing.io;
    try t.dir.writeFile(io, .{ .sub_path = "config.json", .data = bytes });
    var loaded = config.load(std.testing.allocator, io, t.dir, "config.json") catch return;
    defer loaded.deinit();
    try config.validate(loaded.value);
    try expectEqual(@as(u32, 1), loaded.value.version);
}

test "P4: config load of arbitrary bytes is valid-v1-or-error" {
    try minish.check(
        std.testing.allocator,
        gen.string(.{ .min_len = 0, .max_len = 64, .charset = .printable }),
        configRejectsBadBytes,
        .{ .seed = 0xdeadbeef, .num_runs = 200 },
    );
}

fn configSpecificRejections(i: usize) !void {
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    const io = std.testing.io;
    const bytes = [_][]const u8{
        "{\"version\":2}",
        "{\"version\":1,\"sources\":[{\"name\":\"a\",\"url\":\"u\"},{\"name\":\"a\",\"url\":\"v\"}]}",
        "{\"sources\":[{\"name\":\"-bad\",\"url\":\"u\"}]}",
        "{\"version\":1,\"sources\":[{\"na",
        "{\"version\":\"one\"}",
    };
    const expected = [_]?anyerror{
        error.UnsupportedConfigVersion,
        error.DuplicateSourceName,
        error.InvalidName,
        null,
        null,
    };
    try t.dir.writeFile(io, .{ .sub_path = "config.json", .data = bytes[i] });
    if (expected[i]) |e| {
        try std.testing.expectError(e, config.load(std.testing.allocator, io, t.dir, "config.json"));
    } else {
        _ = config.load(std.testing.allocator, io, t.dir, "config.json") catch return;
    }
}

test "P4: config load rejects malformed and invalid configs with the documented error" {
    try minish.check(
        std.testing.allocator,
        gen.intRange(usize, 0, 4),
        configSpecificRejections,
        .{ .seed = 0x5be1c, .num_runs = 15 },
    );
}

// ---------------------------------------------------------------------------
// P5: expandTilde and canonicalDest (PL1, PL2, I8)
// ---------------------------------------------------------------------------

const TildeSeed = struct {
    home: []const u8,
    x: []const u8,
    kind: u8,
};

fn expandTildeForms(s: TildeSeed) !void {
    const a = std.testing.allocator;
    switch (s.kind) {
        0 => {
            const r = try paths.expandTilde(a, s.home, s.x);
            defer a.free(r);
            try expectEqualStrings(s.x, r);
        },
        1 => {
            const input = try std.fmt.allocPrint(a, "~/{s}", .{s.x});
            defer a.free(input);
            const expected = try std.fmt.allocPrint(a, "{s}/{s}", .{ s.home, s.x });
            defer a.free(expected);
            const r = try paths.expandTilde(a, s.home, input);
            defer a.free(r);
            try expectEqualStrings(expected, r);
        },
        2 => {
            const r = try paths.expandTilde(a, s.home, "~");
            defer a.free(r);
            try expectEqualStrings(s.home, r);
        },
        3 => {
            const input = try std.fmt.allocPrint(a, "~{s}", .{s.x});
            defer a.free(input);
            try std.testing.expectError(
                error.UnsupportedTildeUser,
                paths.expandTilde(a, s.home, input),
            );
        },
        4 => {
            try std.testing.expectError(
                error.NoHomeDirectory,
                paths.expandTilde(a, null, "~"),
            );
        },
        else => unreachable,
    }
}

test "P5: expandTilde handles all tilde forms exactly" {
    const tilde_gen = gen.structure(TildeSeed, .{
        .home = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .printable }),
        .x = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alphanumeric }),
        .kind = gen.intRange(u8, 0, 4),
    });
    try minish.check(std.testing.allocator, tilde_gen, expandTildeForms, .{
        .seed = 0x711d3,
        .num_runs = 200,
    });
}

const CanonSeed = struct {
    names: []const []const u8,
    kind: u8,
    missing_tail: bool,
};

fn noDotComponents(p: []const u8) !void {
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |comp| {
        try expectEqual(false, std.mem.eql(u8, comp, "."));
        try expectEqual(false, std.mem.eql(u8, comp, ".."));
    }
}

fn canonicalDestForms(s: CanonSeed) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const use_missing = s.missing_tail and s.kind != 2 and s.kind != 3;
    const existing_count = if (use_missing) s.names.len - 1 else s.names.len;
    if (existing_count > 0) {
        const existing = try std.fs.path.join(a, s.names[0..existing_count]);
        defer a.free(existing);
        try t.dir.createDirPath(io, existing);
    }
    const full = try std.fs.path.join(a, s.names);
    defer a.free(full);
    const expected = try std.fs.path.join(a, &.{ root, full });
    defer a.free(expected);

    const raw: []const u8 = switch (s.kind) {
        0 => try a.dupe(u8, expected),
        1 => try std.fmt.allocPrint(a, "~/{s}", .{full}),
        2 => blk: {
            try t.dir.symLink(io, s.names[0], "alias", .{});
            const rest = try std.fs.path.join(a, s.names[1..]);
            defer a.free(rest);
            break :blk try std.fs.path.join(a, &.{ root, "alias", rest });
        },
        3 => blk: {
            const tail = s.names[s.names.len - 1];
            break :blk try std.fs.path.join(a, &.{ root, full, "..", tail });
        },
        else => unreachable,
    };
    defer a.free(raw);

    const got = try paths.canonicalDest(a, io, root, raw, use_missing);
    defer a.free(got);

    try expectEqual(true, std.fs.path.isAbsolute(got));
    try noDotComponents(got);
    try expectEqualStrings(expected, got);

    t.dir.access(io, full, .{}) catch |e| {
        std.debug.print("canonical result does not exist: {s}\n", .{got});
        return e;
    };

    const again = try paths.canonicalDest(a, io, root, got, false);
    defer a.free(again);
    try expectEqualStrings(got, again);
}

test "P5: canonicalDest is canonical, idempotent and symlink-resolving" {
    const canon_gen = gen.structure(CanonSeed, .{
        .names = gen.list([]const u8, gen.string(.{
            .min_len = 1,
            .max_len = 8,
            .charset = .alphanumeric,
        }), 1, 4),
        .kind = gen.intRange(u8, 0, 3),
        .missing_tail = gen.boolean(),
    });
    try minish.check(std.testing.allocator, canon_gen, canonicalDestForms, .{
        .seed = 0xcaa0,
        .num_runs = 200,
    });
}

// ---------------------------------------------------------------------------
// P10: git.sync respects the local state (I11)
// ---------------------------------------------------------------------------

const git = ugarit.git;
const fx = git.fixtures;

const LocalState = struct {
    ahead: u8, // local commits after the clone (0-2)
    behind: u8, // origin commits after the clone (0-3)
    dirty: u8, // 0 clean, 1 untracked file, 2 modified tracked file
    detached: bool,
    url_mismatch: bool,
    empty_origin: bool,
};

const Outcome = union(enum) { res: git.SyncResult, err: git.Error };

/// Oracle written from the spec (PLAN.md I11 + edge cases 19-21), not from
/// the implementation.
fn expectedOutcome(s: LocalState) Outcome {
    if (s.url_mismatch) return .{ .err = error.RemoteMismatch };
    if (s.detached) return .{ .res = .pinned };
    if (s.dirty != 0) return .{ .err = error.DirtyWorktree };
    if (s.behind == 0) return .{ .res = .up_to_date }; // covers empty_origin, behind == 0
    if (s.ahead == 0) return .{ .res = .fast_forwarded }; // covers unborn HEAD after empty origin
    return .{ .err = error.NotFastForward };
}

fn filesEql(x: []fx.FileEntry, y: []fx.FileEntry) bool {
    if (x.len != y.len) return false;
    for (x, y) |a_, b_| {
        if (!std.mem.eql(u8, a_.path, b_.path)) return false;
        if (!std.mem.eql(u8, a_.content, b_.content)) return false;
    }
    return true;
}

fn syncRespectsLocalState(s: LocalState) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const lg = fx.Libgit2.init();
    defer lg.deinit();
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    // origin: empty, or one initial commit
    const origin = try fx.initOrigin(a, io, t.dir, "origin");
    defer a.free(origin);
    if (!s.empty_origin) try fx.commitFile(io, origin, "SKILL.md", "v0\n");

    // local clone, through the wrapper under test
    try t.dir.createDirPath(io, "sources");
    var sources = try t.dir.openDir(io, "sources", .{});
    defer sources.close(io);
    try git.clone(a, io, sources, null, origin, "origin", null);
    const local = try fx.dirZ(a, io, sources, "origin");
    defer a.free(local);

    // an empty-origin clone with no local commits has an unborn HEAD:
    // there is nothing to detach, so that combination degrades to "attached"
    const detached = s.detached and !(s.empty_origin and s.ahead == 0);
    const state = LocalState{
        .ahead = s.ahead,
        .behind = s.behind,
        .dirty = s.dirty,
        .detached = detached,
        .url_mismatch = s.url_mismatch,
        .empty_origin = s.empty_origin,
    };

    // local state: ahead commits, dirt, detached HEAD
    var i: u8 = 0;
    while (i < s.ahead) : (i += 1) {
        const rel = try std.fmt.allocPrint(a, "local{d}.txt", .{i});
        defer a.free(rel);
        try fx.commitFile(io, local, rel, "local\n");
    }
    if (s.dirty != 0) {
        var d = try std.Io.Dir.openDirAbsolute(io, local, .{});
        defer d.close(io);
        switch (s.dirty) {
            1 => try d.writeFile(io, .{ .sub_path = "scratch.txt", .data = "untracked\n" }),
            2 => try d.writeFile(io, .{ .sub_path = "SKILL.md", .data = "modified\n" }),
            else => {},
        }
    }
    if (detached) try fx.detachHead(local);

    // origin advances after the clone
    i = 0;
    while (i < s.behind) : (i += 1) {
        const rel = try std.fmt.allocPrint(a, "up{d}.txt", .{i});
        defer a.free(rel);
        try fx.commitFile(io, origin, rel, "upstream\n");
    }
    if (s.url_mismatch) try fx.setOriginUrl(local, "file:///nowhere/repo.git");

    const before_head = try fx.headOid(local);
    const before_files = try fx.snapshotWorktree(a, io, local);
    defer fx.freeSnapshot(a, before_files);

    const expected = expectedOutcome(state);

    var st: git.CredState = .{};
    const outcome: git.Error!git.SyncResult = git.sync(local, origin, &st);
    switch (expected) {
        .err => |e| try std.testing.expectError(e, outcome),
        .res => |r| try expectEqual(r, try outcome),
    }

    const after_head = try fx.headOid(local);
    const after_files = try fx.snapshotWorktree(a, io, local);
    defer fx.freeSnapshot(a, after_files);

    if (expected == .res and expected.res == .fast_forwarded) {
        try expectEqual(try fx.headOid(origin), after_head);
        const origin_files = try fx.snapshotWorktree(a, io, origin);
        defer fx.freeSnapshot(a, origin_files);
        try std.testing.expect(filesEql(origin_files, after_files));
        try expectEqual(git.SyncResult.up_to_date, try git.sync(local, origin, &st));
    } else if (expected == .res and expected.res == .up_to_date) {
        try expectEqual(before_head, after_head);
        try std.testing.expect(filesEql(before_files, after_files));
        try expectEqual(git.SyncResult.up_to_date, try git.sync(local, origin, &st));
    } else {
        // pinned, DirtyWorktree, NotFastForward, RemoteMismatch: nothing moved
        try expectEqual(before_head, after_head);
        try std.testing.expect(filesEql(before_files, after_files));
    }
}

test "P10: sync on random local states — only clean+fast-forward changes anything" {
    const local_state_gen = gen.structure(LocalState, .{
        .ahead = gen.intRange(u8, 0, 2),
        .behind = gen.intRange(u8, 0, 3),
        .dirty = gen.intRange(u8, 0, 2),
        .detached = gen.boolean(),
        .url_mismatch = gen.boolean(),
        .empty_origin = gen.boolean(),
    });
    try minish.check(std.testing.allocator, local_state_gen, syncRespectsLocalState, .{
        .seed = 0x517c,
        .num_runs = 60,
    });
}
