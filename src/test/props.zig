//! Property tests for every module. Each property states its claim in a
//! comment and its test name; failures print the seed and the shrunk
//! counterexample (minish). The guarantees they exercise are catalogued in
//! `INVARIANTS.md`.

const std = @import("std");
const minish = @import("minish");
const ugarit = @import("ugarit");

const config = ugarit.config;
const paths = ugarit.paths;
const gen = minish.gen;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ---------------------------------------------------------------------------
// Property: `extractRepoName` recovers the name from every URL form, and
// near-miss or garbage URLs yield a valid name or an error, never a crash
// (invariant: `extractRepoName` totality).
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

test "extractRepoName recovers the name from every URL form" {
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

test "extractRepoName never crashes and yields valid-or-error on near-miss URLs" {
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
// Property: `validateName` agrees with an independently written name spec and
// classifies boundary cases correctly (invariant: `extractRepoName` totality).
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

test "validateName agrees with an independently written name spec" {
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

test "validateName boundary classes" {
    try minish.check(
        std.testing.allocator,
        gen.intRange(usize, 0, 13),
        boundaryNames,
        .{ .seed = 0xb04d, .num_runs = 42 },
    );
}

// ---------------------------------------------------------------------------
// Property: config save→load is the identity; truncated or garbage bytes yield
// an error, never a partial config (invariants: failure atomicity, config
// well-formedness).
// ---------------------------------------------------------------------------

/// Component pool for constructively valid relative paths.
const rel_components = [_][]const u8{ ".agents", "skills", "a", "b.c", ".claude" };

/// 1–3 component indices plus a trailing-slash flag.
const RelPathSeed = struct {
    parts: []const u8,
    trailing_slash: bool,
};

const rel_path_seed_gen = gen.structure(RelPathSeed, .{
    .parts = gen.list(u8, gen.intRange(u8, 0, rel_components.len - 1), 1, 3),
    .trailing_slash = gen.boolean(),
});

fn buildRelPath(a: std.mem.Allocator, seed: RelPathSeed) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (seed.parts, 0..) |part, i| {
        if (i != 0) try out.append(a, '/');
        try out.appendSlice(a, rel_components[part]);
    }
    if (seed.trailing_slash) try out.append(a, '/');
    return out.toOwnedSlice(a);
}

const SourceSeed = struct {
    suffix: []const u8,
    url: []const u8,
    has_ref: bool,
    ref_val: []const u8,
    has_label: bool,
    has_path: bool,
    path: RelPathSeed,
    has_target: bool,
    target: RelPathSeed,
    claude_sync: bool,
};

const ConfigSeed = struct {
    has_default_search_path: bool,
    default_search_path: RelPathSeed,
    sources: []const SourceSeed,
};

const source_seed_gen = gen.structure(SourceSeed, .{
    .suffix = gen.string(.{ .min_len = 0, .max_len = 8, .charset = .alphanumeric }),
    .url = gen.string(.{ .min_len = 0, .max_len = 24, .charset = .printable }),
    .has_ref = gen.boolean(),
    .ref_val = gen.string(.{ .min_len = 0, .max_len = 8, .charset = .printable }),
    .has_label = gen.boolean(),
    .has_path = gen.boolean(),
    .path = rel_path_seed_gen,
    .has_target = gen.boolean(),
    .target = rel_path_seed_gen,
    .claude_sync = gen.boolean(),
});

const config_seed_gen = gen.structure(ConfigSeed, .{
    .has_default_search_path = gen.boolean(),
    .default_search_path = rel_path_seed_gen,
    .sources = gen.list(SourceSeed, source_seed_gen, 0, 5),
});

fn expectOptionalStrings(expected: ?[]const u8, actual: ?[]const u8) !void {
    try expectEqual(expected == null, actual == null);
    if (expected) |e| try expectEqualStrings(e, actual.?);
}

fn expectConfigEqual(expected: config.Config, actual: config.Config) !void {
    try expectEqual(expected.version, actual.version);
    try expectOptionalStrings(expected.default_search_path, actual.default_search_path);
    try expectEqual(expected.sources.len, actual.sources.len);
    for (expected.sources, actual.sources) |e, o| {
        try expectEqualStrings(e.name, o.name);
        try expectOptionalStrings(e.label, o.label);
        try expectEqualStrings(e.url, o.url);
        try expectOptionalStrings(e.path, o.path);
        try expectOptionalStrings(e.target, o.target);
        try expectEqual(e.claude_sync, o.claude_sync);
        try expectOptionalStrings(e.ref, o.ref);
    }
}

fn configRoundTrip(seed: ConfigSeed) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sources = try a.alloc(config.SourceRepo, seed.sources.len);
    for (seed.sources, 0..) |s, i| {
        // `s`/`l` prefixes keep names and labels collision-free.
        sources[i] = .{
            .name = try std.fmt.allocPrint(a, "s{d}{s}", .{ i, s.suffix }),
            .label = if (s.has_label) try std.fmt.allocPrint(a, "l{d}{s}", .{ i, s.suffix }) else null,
            .url = s.url,
            .path = if (s.has_path) try buildRelPath(a, s.path) else null,
            .target = if (s.has_target) try buildRelPath(a, s.target) else null,
            .claude_sync = s.claude_sync,
            .ref = if (s.has_ref) s.ref_val else null,
        };
    }
    const cfg: config.Config = .{
        .default_search_path = if (seed.has_default_search_path)
            try buildRelPath(a, seed.default_search_path)
        else
            null,
        .sources = sources,
    };

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

test "config save→load is the identity" {
    try minish.check(std.testing.allocator, config_seed_gen, configRoundTrip, .{
        .seed = 0xc04f16,
        .num_runs = 200,
    });
}

test "every proper prefix of a valid config is rejected" {
    const bytes = "{\"version\":1,\"sources\":[{\"name\":\"a\",\"url\":\"u\"}]}";
    for (0..bytes.len) |cut| {
        var t = std.testing.tmpDir(.{});
        defer t.cleanup();
        try t.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = bytes[0..cut] });
        if (config.load(std.testing.allocator, std.testing.io, t.dir, "config.json")) |value| {
            var loaded = value;
            loaded.deinit();
            return error.ExpectedMalformedConfig;
        } else |_| {}
    }
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
    } else if (config.load(std.testing.allocator, io, t.dir, "config.json")) |value| {
        var loaded = value;
        loaded.deinit();
        return error.ExpectedConfigError;
    } else |_| {
        return;
    }
}

test "config load rejects malformed and invalid configs with the documented error" {
    for (0..5) |i| try configSpecificRejections(i);
}

// ---------------------------------------------------------------------------
// Property: `validateRelPath` accepts exactly the relative, NUL-free paths
// that `resolvePosix` leaves unchanged under a root (invariant: confinement).
// ---------------------------------------------------------------------------

fn relPathSpec(a: std.mem.Allocator, p: []const u8) !bool {
    if (p.len == 0 or p[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, p, 0) != null) return false;
    const resolved = try std.fs.path.resolvePosix(a, &.{ "/r", p });
    defer a.free(resolved);
    const want = try std.fmt.allocPrint(a, "/r/{s}", .{std.mem.trimEnd(u8, p, "/")});
    defer a.free(want);
    return std.mem.eql(u8, resolved, want);
}

fn validateRelPathMatchesSpec(p: []const u8) !void {
    const expected = try relPathSpec(std.testing.allocator, p);
    const actual = if (config.validateRelPath(p)) |_| true else |_| false;
    if (expected != actual) {
        std.debug.print("validateRelPath({any}): spec {} impl {}\n", .{ p, expected, actual });
        return error.TestUnexpectedResult;
    }
}

test "validateRelPath agrees with POSIX resolution" {
    // Tiny alphabet: `.`, `..`, `//`, leading `/` and NUL are common.
    try minish.check(
        std.testing.allocator,
        gen.string(.{ .min_len = 0, .max_len = 10, .charset = .custom, .custom_chars = "a./\x00" }),
        validateRelPathMatchesSpec,
        .{ .seed = 0x4e1, .num_runs = 2000 },
    );
}

test "constructed relative paths always validate" {
    try minish.check(std.testing.allocator, rel_path_seed_gen, struct {
        fn prop(seed: RelPathSeed) !void {
            const p = try buildRelPath(std.testing.allocator, seed);
            defer std.testing.allocator.free(p);
            try config.validateRelPath(p);
        }
    }.prop, .{ .seed = 0x4e2, .num_runs = 300 });
}

// ---------------------------------------------------------------------------
// Property: `validate` succeeds iff all names and labels are valid and
// distinct, and then `find` maps each key to its source (invariant: config
// well-formedness).
// ---------------------------------------------------------------------------

/// Small pools force collisions; `-x` is an invalid label.
const key_pool = [_][]const u8{ "a", "b", "c" };
const label_pool = [_][]const u8{ "a", "b", "c", "-x" };

const KeySeed = struct { name: u8, has_label: bool, label: u8 };

fn namespaceModel(seeds: []const KeySeed) !void {
    var sources_buf: [4]config.SourceRepo = undefined;
    const n = @min(seeds.len, sources_buf.len);
    for (seeds[0..n], 0..) |k, i| {
        sources_buf[i] = .{
            .name = key_pool[k.name],
            .label = if (k.has_label) label_pool[k.label] else null,
            .url = "u",
        };
    }
    const sources = sources_buf[0..n];

    var keys_buf: [8][]const u8 = undefined;
    var keys_len: usize = 0;
    var any_invalid = false;
    for (sources) |s| {
        keys_buf[keys_len] = s.name;
        keys_len += 1;
        if (s.label) |l| {
            if (l[0] == '-') any_invalid = true;
            keys_buf[keys_len] = l;
            keys_len += 1;
        }
    }
    const keys = keys_buf[0..keys_len];
    var any_duplicate = false;
    for (keys, 0..) |k, i| {
        for (keys[0..i]) |o| if (std.mem.eql(u8, k, o)) {
            any_duplicate = true;
        };
    }

    const cfg: config.Config = .{ .sources = sources };
    if (config.validate(cfg)) |_| {
        try std.testing.expect(!any_invalid and !any_duplicate);
        const managed: config.ManagedConfig = .{
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .value = cfg,
        };
        for (sources) |*s| {
            try std.testing.expectEqual(s, managed.find(s.name).?);
            if (s.label) |l| try std.testing.expectEqual(s, managed.find(l).?);
        }
    } else |err| {
        try std.testing.expect(any_invalid or any_duplicate);
        if (!any_invalid) try expectEqual(error.DuplicateSourceName, err);
    }
}

const key_seed_gen = gen.structure(KeySeed, .{
    .name = gen.intRange(u8, 0, key_pool.len - 1),
    .has_label = gen.boolean(),
    .label = gen.intRange(u8, 0, label_pool.len - 1),
});

test "names and labels form one unique, resolvable namespace" {
    try minish.check(
        std.testing.allocator,
        gen.list(KeySeed, key_seed_gen, 0, 4),
        namespaceModel,
        .{ .seed = 0x1abe1, .num_runs = 500 },
    );
}

// ---------------------------------------------------------------------------
// Property: `expandTilde` handles every tilde form exactly, and `canonicalDest`
// is absolute, `..`-free, symlink-resolving and idempotent (invariants: tilde
// purity, canonical-destination idempotence, soundness).
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

test "expandTilde handles all tilde forms exactly" {
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

test "canonicalDest is canonical, idempotent and symlink-resolving" {
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
// Property: `sync` on random local states changes only a clean, fast-forward
// worktree; dirty, diverged, detached and mismatched states are byte-for-byte
// unchanged (invariant: no lost work).
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

/// Oracle written from the spec (no-lost-work + edge cases 19-21), not from
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
    const lg = try fx.Libgit2.init();
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

test "sync on random local states — only clean+fast-forward changes anything" {
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

// ---------------------------------------------------------------------------
// Property: discovery on random trees is sorted, confined, symlink-free and
// case-folded (invariants: discovery determinism and confinement, confinement).
// ---------------------------------------------------------------------------

const discovery = ugarit.discovery;

/// Entry kinds the generator places. Containers are fixed skeleton dirs
/// (`""`, `"lang/"`, `"lang/deep/"`, `"x/"`); the name pool is disjoint from
/// every skeleton name so generated paths can never collide.
const p6_names = [_][]const u8{ "zig", "Zig", "rust", "tool" };
const p6_containers = [_][]const u8{ "", "lang/", "lang/deep/", "x/" };

const TreeSpec = struct {
    root_skill: bool, // source "one" is a single-skill repo (SKILL.md at root)
    k: [2][p6_containers.len][p6_names.len]u8, // 0 absent .. 5 symlink loop
};

const ExpSkill = struct { name: []const u8, source: []const u8, rel: []const u8 };

fn expLessThan(_: void, x: ExpSkill, y: ExpSkill) bool {
    var lx: [129]u8 = undefined;
    var ly: [129]u8 = undefined;
    const nx = asciiLower(&lx, x.name);
    const ny = asciiLower(&ly, y.name);
    return switch (std.mem.order(u8, nx, ny)) {
        .lt => true,
        .gt => false,
        .eq => switch (std.mem.order(u8, x.name, y.name)) {
            .lt => true,
            .gt => false,
            .eq => switch (std.mem.order(u8, x.source, y.source)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, x.rel, y.rel) == .lt,
            },
        },
    };
}

fn asciiLower(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

fn writeSkillMd(io: std.Io, sources: std.Io.Dir, source: []const u8, rel: []const u8) !void {
    const dir = try std.fs.path.join(std.testing.allocator, &.{ source, rel });
    defer std.testing.allocator.free(dir);
    try sources.createDirPath(io, dir);
    const full = try std.fs.path.join(std.testing.allocator, &.{ dir, "SKILL.md" });
    defer std.testing.allocator.free(full);
    try sources.writeFile(io, .{ .sub_path = full, .data = "skill\n" });
}

fn scanMatchesOracle(spec: TreeSpec) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    // symlink bait outside sources/ (discovery determinism: no traversal)
    try t.dir.createDirPath(io, "outside/bait");
    try t.dir.writeFile(io, .{ .sub_path = "outside/bait/SKILL.md", .data = "bait\n" });
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_len = blk: {
        var od = try t.dir.openDir(io, "outside", .{});
        defer od.close(io);
        break :blk try od.realPath(io, &outside_buf);
    };
    const outside = outside_buf[0..outside_len];

    try t.dir.createDirPath(io, "sources");
    var sources = try t.dir.openDir(io, "sources", .{ .iterate = true });
    defer sources.close(io);
    const source_names = [_][]const u8{ "one", "two" };
    for (source_names) |s| try sources.createDirPath(io, s);

    // fixed probes in "one": depth-cap chain, hidden dirs, orphan handling
    try writeSkillMd(io, sources, "one", "d1/d2/d3/skillat4"); // 4 components: found
    try writeSkillMd(io, sources, "one", "d1/d2/d3/d4/skillat5"); // 5 components: beyond cap
    try writeSkillMd(io, sources, "one", ".git/evil"); // hidden
    try writeSkillMd(io, sources, "one", ".hidden/zig"); // hidden
    try writeSkillMd(io, sources, "orphan", "orphan_skill"); // not in config: ignored

    var expected: std.ArrayList(ExpSkill) = .empty;
    defer {
        for (expected.items) |e| a.free(e.rel);
        expected.deinit(a);
    }
    var symlink_warnings: usize = 0;

    for (source_names, 0..) |s, si| {
        // container skeletons (always exist so every container is reachable)
        for (p6_containers) |cont| {
            if (cont.len == 0) continue;
            const dir_rel = cont[0 .. cont.len - 1];
            const full = try std.fs.path.join(a, &.{ s, dir_rel });
            defer a.free(full);
            try sources.createDirPath(io, full);
        }
        if (si == 0 and spec.root_skill) {
            try sources.writeFile(io, .{ .sub_path = "one/SKILL.md", .data = "root\n" });
            try expected.append(a, .{ .name = "one", .source = "one", .rel = try a.dupe(u8, ".") });
            continue; // root SKILL.md short-circuits the walk
        }
        for (p6_containers, 0..) |cont, ci| {
            for (p6_names, 0..) |name, ni| {
                const rel = try std.fmt.allocPrint(a, "{s}{s}", .{ cont, name });
                defer a.free(rel);
                switch (spec.k[si][ci][ni]) {
                    0 => {},
                    1 => {
                        try writeSkillMd(io, sources, s, rel);
                        try expected.append(a, .{ .name = name, .source = s, .rel = try a.dupe(u8, rel) });
                    },
                    2 => { // plain dir with a non-SKILL file
                        const dir_full = try std.fs.path.join(a, &.{ s, rel });
                        defer a.free(dir_full);
                        try sources.createDirPath(io, dir_full);
                        const full = try std.fs.path.join(a, &.{ dir_full, "note.txt" });
                        defer a.free(full);
                        try sources.writeFile(io, .{ .sub_path = full, .data = "n\n" });
                    },
                    3 => { // plain file at container level
                        const full = try std.fs.path.join(a, &.{ s, rel });
                        defer a.free(full);
                        try sources.writeFile(io, .{ .sub_path = full, .data = "f\n" });
                    },
                    4 => { // symlink out of sources/
                        const full = try std.fs.path.join(a, &.{ s, rel });
                        defer a.free(full);
                        try sources.symLink(io, outside, full, .{ .is_directory = true });
                        symlink_warnings += 1;
                    },
                    5 => { // symlink loop
                        const full = try std.fs.path.join(a, &.{ s, rel });
                        defer a.free(full);
                        try sources.symLink(io, ".", full, .{ .is_directory = true });
                        symlink_warnings += 1;
                    },
                    else => unreachable,
                }
            }
        }
        if (si == 0) {
            try expected.append(a, .{
                .name = "skillat4",
                .source = "one",
                .rel = try a.dupe(u8, "d1/d2/d3/skillat4"),
            });
        }
    }

    const cfg = config.Config{
        .sources = &.{
            .{ .name = "one", .url = "file:///one" },
            .{ .name = "two", .url = "file:///two" },
            .{ .name = "ghost", .url = "file:///ghost" }, // not cloned: warning
        },
    };

    var idx = try discovery.scan(a, io, sources, cfg);
    defer idx.deinit(a);

    // discovery determinism: sorted, deterministic order
    std.mem.sort(ExpSkill, expected.items, {}, expLessThan);
    try expectEqual(expected.items.len, idx.skills.len);
    var sorted_ok = true;
    for (idx.skills, 0..) |s, i| {
        if (!std.mem.eql(u8, s.name, expected.items[i].name)) sorted_ok = false;
        if (!std.mem.eql(u8, s.source, expected.items[i].source)) sorted_ok = false;
        if (!std.mem.eql(u8, s.rel_path, expected.items[i].rel)) sorted_ok = false;
    }
    if (!sorted_ok) {
        std.debug.print("scan mismatch\nexpected:\n", .{});
        for (expected.items) |e| std.debug.print("  {s} {s} {s}\n", .{ e.name, e.source, e.rel });
        std.debug.print("got:\n", .{});
        for (idx.skills) |s| std.debug.print("  {s} {s} {s}\n", .{ s.name, s.source, s.rel_path });
        return error.TestUnexpectedResult;
    }
    if (idx.skills.len > 1) {
        for (idx.skills[1..], 0..) |s, i| {
            if (!expLessThan({}, .{ .name = idx.skills[i].name, .source = idx.skills[i].source, .rel = idx.skills[i].rel_path }, .{ .name = s.name, .source = s.source, .rel = s.rel_path }))
                return error.ScanNotSorted;
        }
    }

    // discovery determinism and confinement: abs paths are under
    // realpath(sources), `..`-free
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try sources.realPath(io, &real_buf);
    const sources_real = real_buf[0..real_len];
    for (idx.skills) |s| {
        try std.testing.expect(paths.isUnder(s.abs_path, sources_real));
        try std.testing.expect(std.mem.indexOf(u8, s.abs_path, "..") == null);
        const want_abs = if (std.mem.eql(u8, s.rel_path, "."))
            try std.fs.path.join(a, &.{ sources_real, s.source })
        else
            try std.fs.path.join(a, &.{ sources_real, s.source, s.rel_path });
        defer a.free(want_abs);
        try expectEqualStrings(want_abs, s.abs_path);
    }

    // case-insensitive names: bare-name lookup is case-insensitive; path queries are exact
    for (expected.items) |e| {
        const q = try std.fmt.allocPrint(a, "{s}/{s}", .{ e.source, e.rel });
        defer a.free(q);
        switch (idx.lookup(q)) {
            .found => |s| {
                try expectEqualStrings(e.name, s.name);
                try expectEqualStrings(e.rel, s.rel_path);
            },
            else => return error.PathLookupMissed,
        }
    }
    var zig_matches: usize = 0;
    for (expected.items) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, "zig")) zig_matches += 1;
    }
    switch (zig_matches) {
        0 => try std.testing.expect(idx.lookup("zig") == .missing),
        1 => try std.testing.expect(idx.lookup("zig") == .found),
        else => |n| switch (idx.lookup("ZIG")) {
            .ambiguous => |c| try expectEqual(n, c.len),
            else => return error.ExpectedAmbiguous,
        },
    }
    try std.testing.expect(idx.lookup("orphan/orphan_skill") == .missing);
    try std.testing.expect(idx.lookup("ghost/zig") == .missing);
    try std.testing.expect(idx.lookup("skillat5") == .missing);

    // discovery determinism: pure function of the tree — a rescan is identical
    var again = try discovery.scan(a, io, sources, cfg);
    defer again.deinit(a);
    try expectEqual(idx.skills.len, again.skills.len);
    for (idx.skills, again.skills) |x, y| {
        try expectEqualStrings(x.name, y.name);
        try expectEqualStrings(x.rel_path, y.rel_path);
    }

    // warnings: one per reachable symlink, one for the uncloned ghost
    var got_symlink_warnings: usize = 0;
    var got_ghost_warning = false;
    for (idx.warnings) |w| {
        if (std.mem.startsWith(u8, w, "skipping symlink")) got_symlink_warnings += 1;
        if (std.mem.indexOf(u8, w, "ghost") != null) got_ghost_warning = true;
    }
    try expectEqual(symlink_warnings, got_symlink_warnings);
    try std.testing.expect(got_ghost_warning);
}

// ---------------------------------------------------------------------------
// Property (metamorphic): scanning a tree nested under `path = P` equals
// scanning it at the clone root with `rel_path` prefixed by `P`; a root skill
// takes `P`'s basename (invariant: discovery determinism).
// ---------------------------------------------------------------------------

const SearchSpec = struct {
    root_skill: bool,
    path: RelPathSeed,
    k: [p6_containers.len][p6_names.len]u8, // 0 absent, 1 skill, 2 plain dir, 3 hidden skill
};

fn plantTree(io: std.Io, sources: std.Io.Dir, prefix: []const u8, spec: SearchSpec) !void {
    const a = std.testing.allocator;
    try sources.createDirPath(io, prefix);
    if (spec.root_skill) {
        const full = try std.fs.path.join(a, &.{ prefix, "SKILL.md" });
        defer a.free(full);
        try sources.writeFile(io, .{ .sub_path = full, .data = "root\n" });
    }
    for (p6_containers, 0..) |cont, ci| {
        for (p6_names, 0..) |name, ni| {
            const rel = switch (spec.k[ci][ni]) {
                0 => continue,
                1, 2 => try std.fmt.allocPrint(a, "{s}{s}", .{ cont, name }),
                3 => try std.fmt.allocPrint(a, "{s}.{s}", .{ cont, name }),
                else => unreachable,
            };
            defer a.free(rel);
            if (spec.k[ci][ni] == 2) {
                const dir = try std.fs.path.join(a, &.{ prefix, rel });
                defer a.free(dir);
                try sources.createDirPath(io, dir);
            } else try writeSkillMd(io, sources, prefix, rel);
        }
    }
}

fn searchPathIsMetamorphic(spec: SearchSpec) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    var sources = try t.dir.openDir(io, ".", .{ .iterate = true });
    defer sources.close(io);

    const search_raw = try buildRelPath(a, spec.path);
    defer a.free(search_raw);
    const search = config.trimRelPath(search_raw);
    const nested_root = try std.fs.path.join(a, &.{ "nested", search });
    defer a.free(nested_root);
    try plantTree(io, sources, "flat", spec);
    try plantTree(io, sources, nested_root, spec);

    var idx = try discovery.scan(a, io, sources, .{ .sources = &.{
        .{ .name = "flat", .url = "/f" },
        .{ .name = "nested", .url = "/n", .path = search_raw },
    } });
    defer idx.deinit(a);

    var flat_count: usize = 0;
    var nested_count: usize = 0;
    for (idx.skills) |s| {
        if (std.mem.eql(u8, s.source, "nested")) nested_count += 1 else flat_count += 1;
    }
    const base = std.fs.path.basename(search);
    const root_named = if (config.validateName(base)) |_| true else |_| false;
    const root_lost = spec.root_skill and !root_named;
    try expectEqual(flat_count - @intFromBool(root_lost), nested_count);

    for (idx.skills) |s| {
        if (!std.mem.eql(u8, s.source, "flat")) continue;
        const want_rel = if (std.mem.eql(u8, s.rel_path, "."))
            try a.dupe(u8, search)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ search, s.rel_path });
        defer a.free(want_rel);
        const want_name = if (std.mem.eql(u8, s.rel_path, ".")) base else s.name;
        if (std.mem.eql(u8, s.rel_path, ".") and !root_named) continue;
        const query = try std.fmt.allocPrint(a, "nested/{s}", .{want_rel});
        defer a.free(query);
        switch (idx.lookup(query)) {
            .found => |got| try expectEqualStrings(want_name, got.name),
            else => {
                std.debug.print("missing {s} (search '{s}')\n", .{ query, search_raw });
                return error.TestUnexpectedResult;
            },
        }
    }
    if (root_lost) {
        var warned = false;
        for (idx.warnings) |w| {
            if (std.mem.startsWith(u8, w, "invalid skill name nested/")) warned = true;
        }
        try std.testing.expect(warned);
    }
}

test "scanning under a search path is the root scan, prefixed" {
    const spec_gen = gen.structure(SearchSpec, .{
        .root_skill = gen.boolean(),
        .path = rel_path_seed_gen,
        .k = gen.array(
            [p6_names.len]u8,
            p6_containers.len,
            gen.array(u8, p6_names.len, gen.intRange(u8, 0, 3)),
        ),
    });
    try minish.check(std.testing.allocator, spec_gen, searchPathIsMetamorphic, .{
        .seed = 0x5ea4c4,
        .num_runs = 80,
    });
}

// ---------------------------------------------------------------------------
// Property: `classify` × `link` over every pre-existing entry kind × `force`
// matches the decision table; real entries survive (invariants: ownership,
// idempotence).
// ---------------------------------------------------------------------------

const symlink = ugarit.symlink;

const PreState = enum(u8) {
    absent,
    real_file,
    real_dir,
    ours_same,
    ours_dangling,
    ours_other_live,
    foreign_link,
};

const LinkExpect = union(enum) {
    ok: symlink.LinkOutcome,
    err: error{ RealEntryInTheWay, ForeignLinkInTheWay, LinkedFromOtherSource },
};

/// Oracle straight from the decision table (edge case 40).
fn expectLink(pre: PreState, force: bool) LinkExpect {
    return switch (pre) {
        .absent => .{ .ok = .created },
        .real_file, .real_dir => .{ .err = error.RealEntryInTheWay },
        .ours_same => .{ .ok = .unchanged },
        .ours_dangling => .{ .ok = .replaced },
        .ours_other_live => if (force)
            .{ .ok = .replaced }
        else
            .{ .err = error.LinkedFromOtherSource },
        .foreign_link => if (force)
            .{ .ok = .replaced }
        else
            .{ .err = error.ForeignLinkInTheWay },
    };
}

const DestEntry = struct { name: []const u8, kind: u8, target: []const u8 }; // kind: 0 absent, 1 file, 2 dir, 3 symlink

fn snapshotDest(a: std.mem.Allocator, io: std.Io, dest: std.Io.Dir) ![]DestEntry {
    var list: std.ArrayList(DestEntry) = .empty;
    errdefer {
        for (list.items) |e| a.free(e.name);
        list.deinit(a);
    }
    var it = dest.iterate();
    while (try it.next(io)) |entry| {
        const kind: u8 = switch (entry.kind) {
            .file => 1,
            .directory => 2,
            .sym_link => 3,
            else => 4,
        };
        var target: []const u8 = "";
        if (kind == 3) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = try dest.readLink(io, entry.name, &buf);
            target = try a.dupe(u8, buf[0..n]);
        }
        errdefer a.free(target);
        try list.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = kind, .target = target });
    }
    const items = try list.toOwnedSlice(a);
    std.mem.sort(DestEntry, items, {}, struct {
        fn lt(_: void, x: DestEntry, y: DestEntry) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    return items;
}

fn freeDestSnapshot(a: std.mem.Allocator, snap: []DestEntry) void {
    for (snap) |e| {
        a.free(e.name);
        if (e.kind == 3) a.free(e.target);
    }
    a.free(snap);
}

const LinkEnv = struct {
    t: *std.testing.TmpDir,
    dest: std.Io.Dir,
    root: []const u8,
    sources_real: []const u8,
    skill: discovery.Skill,
};

fn setupLinkEnv(a: std.mem.Allocator, io: std.Io) !LinkEnv {
    var t = std.testing.tmpDir(.{});
    errdefer t.cleanup();
    try t.dir.createDirPath(io, "sources/zig");
    try t.dir.writeFile(io, .{ .sub_path = "sources/zig/SKILL.md", .data = "zig skill\n" });
    try t.dir.createDirPath(io, "sources/other");
    try t.dir.writeFile(io, .{ .sub_path = "sources/other/SKILL.md", .data = "other skill\n" });
    try t.dir.createDirPath(io, "dest");

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &real_buf);
    const root = try a.dupe(u8, real_buf[0..root_len]);
    const sources_real = try std.fs.path.join(a, &.{ root, "sources" });
    const skill_abs = try std.fs.path.join(a, &.{ sources_real, "zig" });
    const dest = try t.dir.openDir(io, "dest", .{ .iterate = true });
    const tptr = try a.create(std.testing.TmpDir);
    tptr.* = t;
    return .{
        .t = tptr,
        .dest = dest,
        .root = root,
        .sources_real = sources_real,
        .skill = .{ .name = "zig", .source = "one", .rel_path = "zig", .abs_path = skill_abs },
    };
}

fn teardownLinkEnv(a: std.mem.Allocator, env: *LinkEnv, io: std.Io) void {
    env.dest.close(io);
    env.t.cleanup();
    a.destroy(env.t);
    a.free(env.root);
    a.free(env.sources_real);
    a.free(env.skill.abs_path);
}

fn seedPreState(a: std.mem.Allocator, io: std.Io, env: *LinkEnv, pre: PreState) !void {
    const other_abs = try std.fs.path.join(a, &.{ env.sources_real, "other" });
    defer a.free(other_abs);
    const gone_abs = try std.fs.path.join(a, &.{ env.sources_real, "deleted" });
    defer a.free(gone_abs);
    const foreign_abs = try std.fs.path.join(a, &.{ env.root, "foreign" });
    defer a.free(foreign_abs);
    try seedEntryPreState(io, env.dest, "zig", .{
        .skill = env.skill.abs_path,
        .other = other_abs,
        .gone = gone_abs,
        .foreign = foreign_abs,
    }, pre);
}

/// Seeds `dest/name` with a pre-existing entry of the given class (the P7/P8
/// pre-state pool, reusable in any environment).
fn seedEntryPreState(
    io: std.Io,
    dest: std.Io.Dir,
    name: []const u8,
    targets: struct {
        skill: []const u8,
        other: []const u8,
        gone: []const u8,
        foreign: []const u8,
    },
    pre: PreState,
) !void {
    switch (pre) {
        .absent => {},
        .real_file => try dest.writeFile(io, .{ .sub_path = name, .data = "keep me\n" }),
        .real_dir => {
            var buf: [128]u8 = undefined;
            const keep = try std.fmt.bufPrint(&buf, "{s}/keep.txt", .{name});
            try dest.createDirPath(io, name);
            try dest.writeFile(io, .{ .sub_path = keep, .data = "keep me\n" });
        },
        .ours_same => try dest.symLink(io, targets.skill, name, .{ .is_directory = true }),
        .ours_dangling => try dest.symLink(io, targets.gone, name, .{ .is_directory = true }),
        .ours_other_live => try dest.symLink(io, targets.other, name, .{ .is_directory = true }),
        .foreign_link => try dest.symLink(io, targets.foreign, name, .{ .is_directory = true }),
    }
}

const LinkCase = struct { pre: u8, force: bool };

fn linkDecisionTable(case: LinkCase) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env = try setupLinkEnv(a, io);
    defer teardownLinkEnv(a, &env, io);

    const pre: PreState = @enumFromInt(case.pre);
    try seedPreState(a, io, &env, pre);
    const before = try snapshotDest(a, io, env.dest);
    defer freeDestSnapshot(a, before);
    const want = expectLink(pre, case.force);

    const result = symlink.link(io, env.dest, "zig", env.skill, env.sources_real, case.force);
    switch (want) {
        .err => |e| {
            try std.testing.expectError(e, result);
            const after = try snapshotDest(a, io, env.dest);
            defer freeDestSnapshot(a, after);
            try expectEqual(before.len, after.len); // entry untouched
            for (before, after) |x, y| {
                try expectEqualStrings(x.name, y.name);
                try expectEqual(x.kind, y.kind);
                if (x.kind == 3) try expectEqualStrings(x.target, y.target);
            }
        },
        .ok => |o| try expectEqual(o, try result),
    }

    // ownership: real entries survive everything, --force included
    switch (pre) {
        .real_file => {
            const bytes = try env.dest.readFileAlloc(io, "zig", a, .limited(64));
            defer a.free(bytes);
            try expectEqualStrings("keep me\n", bytes);
        },
        .real_dir => {
            const bytes = try env.dest.readFileAlloc(io, "zig/keep.txt", a, .limited(64));
            defer a.free(bytes);
            try expectEqualStrings("keep me\n", bytes);
        },
        else => {},
    }

    if (want == .ok) {
        // entry now points at the skill (unchanged keeps its equal target)
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try env.dest.readLink(io, "zig", &buf);
        try expectEqualStrings(env.skill.abs_path, buf[0..n]);

        // idempotence: linking again is a no-op
        const snap1 = try snapshotDest(a, io, env.dest);
        defer freeDestSnapshot(a, snap1);
        try expectEqual(symlink.LinkOutcome.unchanged, try symlink.link(io, env.dest, "zig", env.skill, env.sources_real, false));
        const snap2 = try snapshotDest(a, io, env.dest);
        defer freeDestSnapshot(a, snap2);
        try expectEqual(snap1.len, snap2.len);

        // inverse: unlink restores absence
        try expectEqual(symlink.UnlinkOutcome.removed, try symlink.unlink(io, env.dest, "zig", env.sources_real));
        const final = try snapshotDest(a, io, env.dest);
        defer freeDestSnapshot(a, final);
        try expectEqual(@as(usize, 0), final.len);
    } else {
        // no temp left behind (atomic visibility)
        const after = try snapshotDest(a, io, env.dest);
        defer freeDestSnapshot(a, after);
        for (after) |e| try std.testing.expect(!std.mem.startsWith(u8, e.name, ".u-"));
    }
}

test "classify × link decision table — real entries survive, outcomes match" {
    const link_gen = gen.structure(LinkCase, .{
        .pre = gen.intRange(u8, 0, 6),
        .force = gen.boolean(),
    });
    try minish.check(std.testing.allocator, link_gen, linkDecisionTable, .{
        .seed = 0x7ab1e,
        .num_runs = 42,
    });
}

// ---------------------------------------------------------------------------
// Property: a fault after the temp symlink is created leaves the destination
// byte-identical and no reserved temp behind (invariant: atomic visibility).
// ---------------------------------------------------------------------------

var fault_at: ?symlink.FaultPoint = null;

fn symlinkFaultFn(p: symlink.FaultPoint) bool {
    return fault_at == p;
}

const FaultCase = struct { pre: u8, force: bool, point: u8 };

fn interruptedLinkIsInvisible(case: FaultCase) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env = try setupLinkEnv(a, io);
    defer teardownLinkEnv(a, &env, io);

    const pre: PreState = @enumFromInt(case.pre);
    try seedPreState(a, io, &env, pre);
    const before = try snapshotDest(a, io, env.dest);
    defer freeDestSnapshot(a, before);
    const want = expectLink(pre, case.force);

    symlink.fault = symlinkFaultFn;
    defer symlink.fault = null;
    fault_at = @enumFromInt(case.point);

    const result = symlink.link(io, env.dest, "zig", env.skill, env.sources_real, case.force);
    switch (want) {
        // the fault is never reached on these paths
        .err => |e| try std.testing.expectError(e, result),
        .ok => |o| switch (o) {
            .unchanged => try expectEqual(o, try result),
            else => try std.testing.expectError(error.FaultInjected, result),
        },
    }

    // dest byte-identical, and no reserved temp remains (atomic visibility)
    const after = try snapshotDest(a, io, env.dest);
    defer freeDestSnapshot(a, after);
    try expectEqual(before.len, after.len);
    for (before, after) |x, y| {
        try expectEqualStrings(x.name, y.name);
        try expectEqual(x.kind, y.kind);
        if (x.kind == 3) try expectEqualStrings(x.target, y.target);
        try std.testing.expect(!std.mem.startsWith(u8, y.name, ".u-"));
    }

    // recovery: with the fault cleared the link lands normally
    fault_at = null;
    switch (want) {
        .err => |e| try std.testing.expectError(e, symlink.link(io, env.dest, "zig", env.skill, env.sources_real, case.force)),
        .ok => |o| try expectEqual(o, try symlink.link(io, env.dest, "zig", env.skill, env.sources_real, case.force)),
    }
}

test "fault after temp symlink / before rename — dest unchanged, no temps" {
    const fault_gen = gen.structure(FaultCase, .{
        .pre = gen.intRange(u8, 0, 6),
        .force = gen.boolean(),
        .point = gen.intRange(u8, 0, 1),
    });
    try minish.check(std.testing.allocator, fault_gen, interruptedLinkIsInvisible, .{
        .seed = 0xfa127,
        .num_runs = 56,
    });
}

// ---------------------------------------------------------------------------
// Property: `excludeInEnclosingRepo` called N times appends at most one line
// and never writes outside `commondir/info/` (invariants: exclude idempotence,
// no collateral damage).
// ---------------------------------------------------------------------------

const ExcludeCase = struct { n: u8, scenario: u8 };

fn excludeIsIdempotent(case: ExcludeCase) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const lg = try fx.Libgit2.init();
    defer lg.deinit();
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    const proj = try fx.initOrigin(a, io, t.dir, "proj");
    defer a.free(proj);
    if (case.scenario == 1) {
        // already ignored via the repo's own .gitignore (edge case 45)
        try fx.commitFile(io, proj, ".gitignore", "/.claude/skills/zig\n");
    }
    if (case.scenario == 2) {
        // path already tracked (edge case 44)
        try fx.commitFile(io, proj, ".claude/skills/zig/SKILL.md", "tracked\n");
    }
    var proj_dir = try std.Io.Dir.openDirAbsolute(io, proj, .{});
    defer proj_dir.close(io);
    try proj_dir.createDirPath(io, ".claude/skills");

    const link_abs = try std.fs.path.join(a, &.{ proj, ".claude/skills/zig" });
    defer a.free(link_abs);

    const worktree_before = try fx.snapshotWorktree(a, io, proj);
    defer fx.freeSnapshot(a, worktree_before);

    var i: u8 = 0;
    while (i < case.n) : (i += 1) {
        const outcome = symlink.excludeInEnclosingRepo(a, io, link_abs);
        switch (case.scenario) {
            0 => if (i == 0) {
                switch (try outcome) {
                    .excluded => |x| {
                        defer a.free(x.line);
                        try expectEqualStrings("/.claude/skills/zig", x.line);
                        try std.testing.expect(!x.added_separator); // fresh exclude file ends clean
                    },
                    else => return error.TestUnexpectedResult,
                }
            } else switch (try outcome) {
                .already => {},
                else => return error.TestUnexpectedResult,
            },
            1 => switch (try outcome) {
                .already => {},
                else => return error.TestUnexpectedResult,
            },
            2 => try std.testing.expectError(error.LinkPathTrackedInRepo, outcome),
            else => unreachable,
        }
    }

    // exactly one anchored line, only in commondir/info/exclude (exclude idempotence, no collateral damage)
    var git_dir = try std.Io.Dir.openDirAbsolute(io, proj, .{}); // proj IS the workdir; .git inside
    defer git_dir.close(io);
    var info_dir = git_dir.openDir(io, ".git/info", .{}) catch |e| switch (e) {
        error.FileNotFound => {
            try std.testing.expect(case.scenario != 0); // excluded would have created it
            return;
        },
        else => return e,
    };
    defer info_dir.close(io);
    const exclude_bytes = info_dir.readFileAlloc(io, "exclude", a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => {
            try std.testing.expect(case.scenario != 0);
            return;
        },
        else => return e,
    };
    defer a.free(exclude_bytes);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, exclude_bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "/.claude/skills/zig")) count += 1;
    }
    try expectEqual(@as(usize, if (case.scenario == 0) 1 else 0), count);

    // no collateral damage: the worktree itself is untouched (info/exclude lives under .git)
    const worktree_after = try fx.snapshotWorktree(a, io, proj);
    defer fx.freeSnapshot(a, worktree_after);
    try std.testing.expect(filesEql(worktree_before, worktree_after));
}

test "excludeInEnclosingRepo appends at most one line, never writes outside" {
    const exclude_gen = gen.structure(ExcludeCase, .{
        .n = gen.intRange(u8, 1, 5),
        .scenario = gen.intRange(u8, 0, 2),
    });
    try minish.check(std.testing.allocator, exclude_gen, excludeIsIdempotent, .{
        .seed = 0x9c1ad,
        .num_runs = 45,
    });
}

// ---------------------------------------------------------------------------
// Property: a failed `link` inside a git repository leaves both the
// destination and the repo's info/exclude byte-identical — the exclude line
// appended before the link attempt is taken back out when the link does not
// land (exclude idempotence × atomic visibility).
// ---------------------------------------------------------------------------

const RepoLinkCase = struct { pre: u8, point: u8 };

fn readExcludeFile(a: std.mem.Allocator, io: std.Io, proj: []const u8) !?[]u8 {
    const exclude_abs = try std.fs.path.join(a, &.{ proj, ".git/info/exclude" });
    defer a.free(exclude_abs);
    return std.Io.Dir.cwd().readFileAlloc(io, exclude_abs, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}

fn failedRepoLinkLeavesNoTrace(case: RepoLinkCase) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const lg = try fx.Libgit2.init();
    defer lg.deinit();
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    // A real project repo; the destination lives inside its worktree.
    const proj = try fx.initOrigin(a, io, t.dir, "proj");
    defer a.free(proj);
    try fx.commitFile(io, proj, "README.md", "readme\n");
    try t.dir.createDirPath(io, "proj/.claude/skills");

    // A managed home whose single source is a plain directory (no git
    // needed on the sources side).
    try t.dir.createDirPath(io, "managed/sources/central/zig");
    try t.dir.writeFile(io, .{ .sub_path = "managed/sources/central/zig/SKILL.md", .data = "v\n" });
    try t.dir.createDirPath(io, "managed/sources/central/other");
    try t.dir.writeFile(io, .{ .sub_path = "managed/sources/central/other/SKILL.md", .data = "o\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const managed = try std.fs.path.join(a, &.{ root, "managed" });
    defer a.free(managed);
    const dest = try std.fs.path.join(a, &.{ proj, ".claude/skills" });
    defer a.free(dest);
    const skill_abs = try std.fs.path.join(a, &.{ managed, "sources/central/zig" });
    defer a.free(skill_abs);
    const other_abs = try std.fs.path.join(a, &.{ managed, "sources/central/other" });
    defer a.free(other_abs);
    const gone_abs = try std.fs.path.join(a, &.{ managed, "sources/central/deleted" });
    defer a.free(gone_abs);
    const foreign_abs = try std.fs.path.join(a, &.{ root, "foreign" });
    defer a.free(foreign_abs);
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
    var ctx = try ugarit.app.Context.init(a, io, &env, managed, &out, &err);
    defer ctx.deinit();

    {
        var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest, .{ .iterate = true });
        defer dest_dir.close(io);
        try seedEntryPreState(io, dest_dir, "zig", .{
            .skill = skill_abs,
            .other = other_abs,
            .gone = gone_abs,
            .foreign = foreign_abs,
        }, ([_]PreState{ .absent, .ours_dangling, .ours_other_live, .foreign_link })[case.pre]);
    }

    const before_exclude = try readExcludeFile(a, io, proj);
    defer if (before_exclude) |b| a.free(b);
    {
        var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest, .{ .iterate = true });
        defer dest_dir.close(io);
        const before_dest_snap = try snapshotDest(a, io, dest_dir);
        defer freeDestSnapshot(a, before_dest_snap);

        symlink.fault = symlinkFaultFn;
        defer symlink.fault = null;
        fault_at = @enumFromInt(case.point);

        const result = ugarit.app.linkOne(&ctx, skill, "zig", dest, .{ .force = true });
        fault_at = null;

        try std.testing.expectError(error.FaultInjected, result);

        // Failure: destination and info/exclude byte-identical to before.
        const after_dest = try snapshotDest(a, io, dest_dir);
        defer freeDestSnapshot(a, after_dest);
        try expectEqual(before_dest_snap.len, after_dest.len);
        for (before_dest_snap, after_dest) |x, y| {
            try expectEqualStrings(x.name, y.name);
            try expectEqual(x.kind, y.kind);
            if (x.kind == 3) try expectEqualStrings(x.target, y.target);
        }
        const after_exclude = try readExcludeFile(a, io, proj);
        defer if (after_exclude) |x| a.free(x);
        if (before_exclude == null) {
            try std.testing.expect(after_exclude == null);
        } else {
            try expectEqualStrings(before_exclude.?, after_exclude.?);
        }
    }

    // Recovery with faults cleared converges to the requested link. The repo
    // may already ignore the path via another rule, so a Ugarit-owned line is
    // not required in that case.
    try ugarit.app.linkOne(&ctx, skill, "zig", dest, .{ .force = true });
    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest, .{ .iterate = true });
    defer dest_dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dest_dir.readLink(io, "zig", &buf);
    try expectEqualStrings(skill_abs, buf[0..n]);
}

test "a failed link inside a repo leaves dest and info/exclude byte-identical" {
    const repo_link_gen = gen.structure(RepoLinkCase, .{
        .pre = gen.intRange(u8, 0, 3),
        .point = gen.intRange(u8, 0, 1),
    });
    try minish.check(std.testing.allocator, repo_link_gen, failedRepoLinkLeavesNoTrace, .{
        .seed = 0xacc7,
        .num_runs = 56,
    });
}

test "discovery on random trees — sorted, confined, symlink-free, case-folded" {
    const tree_gen = gen.structure(TreeSpec, .{
        .root_skill = gen.boolean(),
        .k = gen.array(
            [p6_containers.len][p6_names.len]u8, // element: [4][4]u8
            2,
            gen.array(
                [p6_names.len]u8, // element: [4]u8
                p6_containers.len,
                gen.array(u8, p6_names.len, gen.intRange(u8, 0, 5)),
            ),
        ),
    });
    try minish.check(std.testing.allocator, tree_gen, scanMatchesOracle, .{
        .seed = 0xd15c,
        .num_runs = 60,
    });
}

// ---------------------------------------------------------------------------
// Property: registry save→load round-trips; duplicate (host, path) entries
// collapse to the last; other-host entries are never touched (invariants:
// soundness, host portability).
// ---------------------------------------------------------------------------

const Registry = ugarit.Registry;
const RegLink = ugarit.registry.Link;
const RegState = ugarit.registry.State;

const RegSpec = struct {
    mine: u8, // entries for host "me" (path pool index bits)
    others: u8, // entries for host "other"
    dup_in_file: bool, // hand-written duplicate path
    remove_one: bool, // remove one of mine between save and reload
};

fn linkFor(path: []const u8, host: []const u8) RegLink {
    return .{ .path = path, .source = "src", .rel_path = "r", .skill = "sk", .host = host };
}

fn deepDupLinks(a: std.mem.Allocator, links: []const RegLink) ![]RegLink {
    const out = try a.alloc(RegLink, links.len);
    errdefer a.free(out);
    var done: usize = 0;
    errdefer for (out[0..done]) |l| {
        a.free(l.path);
        a.free(l.source);
        a.free(l.rel_path);
        a.free(l.skill);
        a.free(l.host);
    };
    for (links, 0..) |l, i| {
        out[i] = .{
            .path = try a.dupe(u8, l.path),
            .source = try a.dupe(u8, l.source),
            .rel_path = try a.dupe(u8, l.rel_path),
            .skill = try a.dupe(u8, l.skill),
            .host = try a.dupe(u8, l.host),
        };
        done += 1;
    }
    return out;
}

fn registryRoundTrip(spec: RegSpec) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    const pool = [_][]const u8{ "/p/a/zig", "/p/b/zig", "/p/c/zig" };
    var reg = Registry{};
    defer reg.deinit(a);

    var mine_paths: std.ArrayList([]const u8) = .empty;
    defer mine_paths.deinit(a);
    const mine_n = spec.mine % 4; // 0..3 of the pool
    for (pool[0..mine_n]) |p| {
        try reg.upsert(a, linkFor(p, "me"));
        try mine_paths.append(a, p);
    }
    for (pool[0 .. spec.others % 4]) |p| {
        try reg.upsert(a, linkFor(p, "other"));
    }

    // save → byte-identical on re-save (deterministic order)
    try reg.save(a, io, t.dir);
    const first = try t.dir.readFileAlloc(io, "links.json", a, .limited(1 << 20));
    defer a.free(first);
    try reg.save(a, io, t.dir);
    const second = try t.dir.readFileAlloc(io, "links.json", a, .limited(1 << 20));
    defer a.free(second);
    try expectEqualStrings(first, second);

    // mutation on this host never touches other-host entries (host portability)
    const others_before = try deepDupLinks(a, reg.links);
    defer {
        for (others_before) |l| {
            a.free(l.path);
            a.free(l.source);
            a.free(l.rel_path);
            a.free(l.skill);
            a.free(l.host);
        }
        a.free(others_before);
    }
    if (spec.remove_one and mine_n > 0) {
        try std.testing.expect(try reg.remove(a, pool[0], "me"));
        try std.testing.expect(!try reg.remove(a, pool[0], "other-hint"));
    }
    // upsert of a same-path entry for "me" must not consume an "other" entry
    if (mine_n == 0 and spec.others % 4 > 0) {
        try reg.upsert(a, linkFor(pool[0], "me"));
    }
    var others_after_count: usize = 0;
    var others_same = true;
    for (reg.links) |l| {
        if (std.mem.eql(u8, l.host, "other")) {
            others_after_count += 1;
            var found = false;
            for (others_before) |b| {
                if (std.mem.eql(u8, b.path, l.path)) found = true;
            }
            if (!found) others_same = false;
        }
    }
    try expectEqual(@as(usize, spec.others % 4), others_after_count);
    try std.testing.expect(others_same);

    // load(save(x)) == x as a set (save sorts; runtime order differs)
    try reg.save(a, io, t.dir);
    var loaded = try Registry.load(a, io, t.dir, "links.json");
    defer loaded.deinit(a);
    try expectEqual(@as(usize, 0), loaded.duplicates);
    try expectEqual(reg.links.len, loaded.registry.links.len);
    for (reg.links) |x| {
        var matches: usize = 0;
        for (loaded.registry.links) |y| {
            if (std.mem.eql(u8, x.path, y.path) and std.mem.eql(u8, x.host, y.host) and
                std.mem.eql(u8, x.rel_path, y.rel_path) and std.mem.eql(u8, x.skill, y.skill) and
                std.mem.eql(u8, x.source, y.source)) matches += 1;
        }
        try expectEqual(@as(usize, 1), matches);
    }

    // hand-edited duplicate (host, path): the last one wins (edge 5a)
    if (spec.dup_in_file and reg.links.len > 0) {
        var f = try t.dir.createFile(io, "links.json", .{ .truncate = true });
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.print(
            "{{\"version\":1,\"links\":[{{\"path\":\"{s}\",\"source\":\"a\",\"rel_path\":\"1\",\"skill\":\"s\",\"host\":\"me\"}}," ++
                "{{\"path\":\"{s}\",\"source\":\"b\",\"rel_path\":\"2\",\"skill\":\"s\",\"host\":\"me\"}}]}}\n",
            .{ pool[0], pool[0] },
        );
        try w.flush();
        var collapsed = try Registry.load(a, io, t.dir, "links.json");
        defer collapsed.deinit(a);
        try expectEqual(@as(usize, 1), collapsed.duplicates);
        try expectEqual(@as(usize, 1), collapsed.registry.links.len);
        try expectEqualStrings("b", collapsed.registry.links[0].source); // last wins
    }
}

test "registry round-trip, duplicate collapse, other-host immunity" {
    const reg_gen = gen.structure(RegSpec, .{
        .mine = gen.intRange(u8, 0, 7),
        .others = gen.intRange(u8, 0, 7),
        .dup_in_file = gen.boolean(),
        .remove_one = gen.boolean(),
    });
    try minish.check(std.testing.allocator, reg_gen, registryRoundTrip, .{
        .seed = 0x13ad,
        .num_runs = 60,
    });
}

// ---------------------------------------------------------------------------
// Property: `repair` relinks only on a unique same-name move and otherwise
// reports dangling (invariants: repair preserves identity, confinement).
// ---------------------------------------------------------------------------

fn repairRespectsIdentity(scenario: u8) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const lg = try fx.Libgit2.init();
    defer lg.deinit();
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    // origin: zig plus (for the ambiguous case) two same-name alternatives
    const origin = try fx.initOrigin(a, io, t.dir, "origin");
    defer a.free(origin);
    try fx.commitFile(io, origin, "zig/SKILL.md", "v0\n");
    if (scenario == 2) {
        try fx.commitFile(io, origin, "lang/zig/SKILL.md", "twin\n");
        try fx.commitFile(io, origin, "tools/zig/SKILL.md", "twin\n");
    }

    try t.dir.createDirPath(io, "home/sources");
    var sources = try t.dir.openDir(io, "home/sources", .{ .iterate = true });
    defer sources.close(io);
    try git.clone(a, io, sources, null, origin, "central", null);

    const cfg = config.Config{ .sources = &.{.{ .name = "central", .url = origin }} };
    var idx = try discovery.scan(a, io, sources, cfg);
    defer idx.deinit(a);

    // two projects link the skill
    var reg = Registry{};
    defer reg.deinit(a);
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try sources.realPath(io, &real_buf);
    const sources_real = try a.dupe(u8, real_buf[0..root_len]);
    defer a.free(sources_real);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try t.dir.realPath(io, &tmp_buf);
    const tmp_root = tmp_buf[0..tmp_len];

    const skill = switch (idx.lookup("central/zig")) {
        .found => |s| s,
        else => return error.TestUnexpectedResult,
    };
    for ([_][]const u8{ "projA", "projB" }) |proj| {
        const skills_rel = try std.fmt.allocPrint(a, "home/{s}/.claude/skills", .{proj});
        defer a.free(skills_rel);
        try t.dir.createDirPath(io, skills_rel);
        var dest = try t.dir.openDir(io, skills_rel, .{ .iterate = true });
        defer dest.close(io);
        try expectEqual(
            symlink.LinkOutcome.created,
            try symlink.link(io, dest, "zig", skill, sources_real, false),
        );
        const link_abs = try std.fmt.allocPrint(a, "{s}/home/{s}/.claude/skills/zig", .{ tmp_root, proj });
        defer a.free(link_abs);
        try Registry.upsert(&reg, a, .{
            .path = link_abs,
            .source = "central",
            .rel_path = "zig",
            .skill = "zig",
            .host = "testhost",
        });
    }

    // upstream change
    switch (scenario) {
        0 => try fx.moveFile(io, origin, "zig/SKILL.md", "lang/zig/SKILL.md"), // unique move
        1 => try fx.deleteFile(io, origin, "zig/SKILL.md"), // skill removed
        2 => try fx.deleteFile(io, origin, "zig/SKILL.md"), // name now ambiguous
        else => unreachable,
    }
    var st: git.CredState = .{};
    const central_z = try fx.dirZ(a, io, sources, "central");
    defer a.free(central_z);
    try expectEqual(git.SyncResult.fast_forwarded, try git.sync(central_z, origin, &st));

    var idx2 = try discovery.scan(a, io, sources, cfg);
    defer idx2.deinit(a);
    var report = try reg.repair(a, io, idx2, "central", "testhost", sources_real);
    defer report.deinit(a);

    // verify each link's end state against the spec (repair preserves identity)
    switch (scenario) {
        0 => {
            try expectEqual(@as(usize, 2), report.repaired.len);
            try expectEqual(@as(usize, 0), report.dangling.len);
            for (reg.links) |l| {
                try expectEqualStrings("lang/zig", l.rel_path);
                try expectEqual(RegState.ok, try ugarit.registry.status(io, l, sources_real));
            }
            // links resolve into the moved dir with the live content
            const via_rel = try std.fmt.allocPrint(a, "home/projA/.claude/skills/zig/SKILL.md", .{});
            defer a.free(via_rel);
            const via_link = try t.dir.readFileAlloc(io, via_rel, a, .limited(64));
            defer a.free(via_link);
            try expectEqualStrings("v0\n", via_link);
        },
        1, 2 => {
            try expectEqual(@as(usize, 0), report.repaired.len);
            try expectEqual(@as(usize, 2), report.dangling.len);
            for (reg.links) |l| {
                try expectEqualStrings("zig", l.rel_path); // registry untouched
                try expectEqual(RegState.dangling, try ugarit.registry.status(io, l, sources_real));
            }
            // the dangling links still point at the old (now absent) target
            for ([_][]const u8{ "projA", "projB" }) |proj| {
                const skills_rel = try std.fmt.allocPrint(a, "home/{s}/.claude/skills", .{proj});
                defer a.free(skills_rel);
                var dest = try t.dir.openDir(io, skills_rel, .{});
                defer dest.close(io);
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = try dest.readLink(io, "zig", &buf);
                try std.testing.expect(std.mem.endsWith(u8, buf[0..n], "/central/zig"));
            }
        },
        else => unreachable,
    }
}

test "repair relinks on a unique same-name move, else reports dangling" {
    try minish.check(
        std.testing.allocator,
        gen.intRange(u8, 0, 2),
        repairRespectsIdentity,
        .{ .seed = 0x12ba, .num_runs = 30 },
    );
}

// ---------------------------------------------------------------------------
// Property: generated link, unlink and tamper commands preserve the filesystem
// and registry invariants after every step (invariants: no collateral damage
// through repair preserves identity, exit status).
// ---------------------------------------------------------------------------

const AppFsState = enum { absent, linked, real };

fn appStateMachine(ops: [16]u8) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(io, "managed/sources/central/zig");
    try t.dir.writeFile(io, .{ .sub_path = "managed/sources/central/zig/SKILL.md", .data = "v1\n" });
    try t.dir.writeFile(io, .{ .sub_path = "outside", .data = "untouched\n" });
    for (0..3) |i| {
        var rel_buf: [32]u8 = undefined;
        const rel = try std.fmt.bufPrint(&rel_buf, "dest/{d}", .{i});
        try t.dir.createDirPath(io, rel);
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try t.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const managed = try std.fs.path.join(a, &.{ root, "managed" });
    defer a.free(managed);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    var out_buf: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [8192]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var ctx = try ugarit.app.Context.init(a, io, &env, managed, &out, &err);
    defer ctx.deinit();
    try ctx.cfg.append(.{ .name = "central", .url = "/unused" });
    try config.save(a, io, ctx.root_dir.?, ctx.cfg.value);

    var dests: [3][]const u8 = undefined;
    defer for (dests) |dest| a.free(dest);
    var link_paths: [3][]const u8 = undefined;
    defer for (link_paths) |path| a.free(path);
    for (0..3) |i| {
        dests[i] = try std.fmt.allocPrint(a, "{s}/dest/{d}", .{ root, i });
        link_paths[i] = try std.fs.path.join(a, &.{ dests[i], "zig" });
    }
    var fs_state = [_]AppFsState{.absent} ** 3;
    var registered = [_]bool{false} ** 3;

    for (ops) |raw| {
        const i: usize = raw % 3;
        switch ((raw / 3) % 5) {
            0, 4 => {
                const values = [_][]const u8{dests[i]};
                const ok = try ugarit.app.link(&ctx, "central", "zig", &values, .{ .no_exclude = true });
                if (fs_state[i] == .real) {
                    try std.testing.expect(!ok);
                } else {
                    try std.testing.expect(ok);
                    fs_state[i] = .linked;
                    registered[i] = true;
                }
            },
            1 => {
                const values = [_][]const u8{link_paths[i]};
                const ok = try ugarit.app.unlink(&ctx, &values, null);
                if (fs_state[i] == .real) {
                    try std.testing.expect(!ok);
                } else {
                    try std.testing.expect(ok);
                    fs_state[i] = .absent;
                    registered[i] = false;
                }
            },
            2 => {
                if (fs_state[i] == .linked) try std.Io.Dir.deleteFileAbsolute(io, link_paths[i]);
                fs_state[i] = if (fs_state[i] == .real) .real else .absent;
            },
            3 => {
                switch (fs_state[i]) {
                    .linked => {
                        try std.Io.Dir.deleteFileAbsolute(io, link_paths[i]);
                        try std.Io.Dir.createDirAbsolute(io, link_paths[i], .default_dir);
                    },
                    .real => {},
                    .absent => try std.Io.Dir.createDirAbsolute(io, link_paths[i], .default_dir),
                }
                fs_state[i] = .real;
            },
            else => unreachable,
        }

        var count: usize = 0;
        var reg_entry: ?RegLink = null;
        for (ctx.registry.links) |entry| {
            if (!std.mem.eql(u8, entry.host, ctx.host)) continue;
            if (!std.mem.eql(u8, entry.path, link_paths[i])) continue;
            count += 1;
            reg_entry = entry;
        }
        try expectEqual(@as(usize, if (registered[i]) 1 else 0), count);
        if (reg_entry) |entry| {
            const expected: RegState = switch (fs_state[i]) {
                .linked => .ok,
                .absent => .missing,
                .real => .replaced,
            };
            try expectEqual(expected, try ugarit.registry.status(io, entry, ctx.sources_real));
        }

        var dest = try std.Io.Dir.openDirAbsolute(io, dests[i], .{ .iterate = true });
        defer dest.close(io);
        var it = dest.iterate();
        while (try it.next(io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".u-"));
        }
        const outside = try t.dir.readFileAlloc(io, "outside", a, .limited(64));
        defer a.free(outside);
        try expectEqualStrings("untouched\n", outside);
    }
}

test "generated link, unlink and tamper commands preserve filesystem and registry invariants" {
    try minish.check(
        std.testing.allocator,
        gen.array(u8, 16, gen.intRange(u8, 0, 14)),
        appStateMachine,
        .{ .seed = 0x06a417, .num_runs = 24 },
    );
}
