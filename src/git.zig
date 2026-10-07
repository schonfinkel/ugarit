//! libgit2 wrapper — the only file in ugarit that talks to C.
//!
//! Invariants:
//! - **I11 (no lost work):** `sync` never changes a source's worktree or HEAD
//!   unless the worktree is clean and the update is a fast-forward. Dirty or
//!   diverged sources come out byte-for-byte unchanged (asserted by P10).
//! - **No half clones (I3-adjacent):** `clone` lands in a `.tmp-*` dir beside
//!   `sources/` and is renamed into place only on success, so an interrupted
//!   clone never leaves a broken `sources/<name>`.
//! - **Auth loops terminate:** at most 3 credential attempts per operation.
//! - **Boundary:** every libgit2 failure is translated into `Error` here; no
//!   `[*c]` type or raw libgit2 handle escapes this file.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("git2");

pub const Error = error{
    Git,
    NotFastForward,
    DirtyWorktree,
    RemoteMismatch,
    AuthFailed,
    SourceExists,
    OutOfMemory,
};

/// Result of a `sync` run.
pub const SyncResult = enum { up_to_date, fast_forwarded, pinned };

pub threadlocal var last_message: [512]u8 = undefined;
threadlocal var last_message_len: usize = 0;

/// Text of the most recent libgit2 error (empty when none was recorded).
pub fn lastMessage() []const u8 {
    return last_message[0..last_message_len];
}

fn copyMsg(msg: []const u8) void {
    const n = @min(msg.len, last_message.len);
    @memcpy(last_message[0..n], msg[0..n]);
    last_message_len = n;
}

fn fillLastMessage() void {
    const e = c.git_error_last();
    if (e == null or e.*.message == null) return copyMsg("unknown libgit2 error");
    copyMsg(std.mem.span(e.*.message));
}

/// Turns a libgit2 return code into `Error`, recording the C error text.
fn check(rc: c_int) Error!void {
    if (rc >= 0) return;
    fillLastMessage();
    if (rc == c.GIT_EAUTH) return error.AuthFailed;
    return error.Git;
}

// --- fault injection (P11): compiled out of release builds -------------------

pub const FaultPoint = enum { after_clone };

pub const FaultFn = *const fn (FaultPoint) bool;

/// Test-only crash simulation: a fault returning `true` at a fault point
/// aborts the operation through its normal error path.
pub var fault: if (builtin.is_test) ?FaultFn else void = if (builtin.is_test) null else {};

fn failAt(point: FaultPoint) Error!void {
    if (builtin.is_test) {
        if (fault) |f| {
            if (f(point)) {
                copyMsg("fault injected");
                return error.Git;
            }
        }
    }
}

// --- init / deinit -----------------------------------------------------------

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

/// Initialises libgit2; call once per process before anything else here.
/// Honours `SSL_CERT_FILE` / `NIX_SSL_CERT_FILE` (nix's libgit2 links OpenSSL
/// and does not read the env by itself). Upholds edge case 23.
pub fn init(env: ?*const std.process.Environ.Map) Error!void {
    _ = c.git_libgit2_init();
    const e = env orelse return;
    if (e.get("SSL_CERT_FILE") orelse e.get("NIX_SSL_CERT_FILE")) |cert_file| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cert_z = std.fmt.bufPrintZ(&buf, "{s}", .{cert_file}) catch {
            copyMsg("SSL cert file path too long");
            return error.Git;
        };
        try check(c.git_libgit2_opts(
            c.GIT_OPT_SET_SSL_CERT_LOCATIONS,
            @as([*:0]const u8, cert_z),
            @as(?[*:0]const u8, null),
        ));
    }
}

pub fn deinit() void {
    _ = c.git_libgit2_shutdown();
}

// --- credentials -------------------------------------------------------------

/// Credential state threaded through libgit2 callbacks. `tries` caps attempts
/// so libgit2 cannot loop forever (edge case 22).
pub const CredState = struct {
    tries: u8 = 0,
    env: ?*const std.process.Environ.Map = null,
};

/// SSH: agent, then `~/.ssh/id_ed25519`, then `~/.ssh/id_rsa`.
/// HTTPS: `UGARIT_GIT_USERNAME` / `UGARIT_GIT_TOKEN`.
fn credCb(
    out: [*c][*c]c.git_credential,
    url: [*c]const u8,
    username_from_url: [*c]const u8,
    allowed_types: c_uint,
    payload: ?*anyopaque,
) callconv(.c) c_int {
    _ = url;
    const st: *CredState = @ptrCast(@alignCast(payload orelse return c.GIT_PASSTHROUGH));
    st.tries += 1;
    if (st.tries > 3) return c.GIT_EAUTH;

    const ssh = @as(c_uint, @intCast(c.GIT_CREDENTIAL_SSH_KEY));
    const plain = @as(c_uint, @intCast(c.GIT_CREDENTIAL_USERPASS_PLAINTEXT));
    if (allowed_types & ssh != 0) {
        const user: [*c]const u8 = if (username_from_url != null)
            username_from_url
        else
            @as([*c]const u8, "git");
        if (st.tries == 1) return c.git_credential_ssh_key_from_agent(out, user);
        return sshKeyFile(out, user, st, if (st.tries == 2) "id_ed25519" else "id_rsa");
    }
    if (allowed_types & plain != 0) {
        const env = st.env orelse return c.GIT_PASSTHROUGH;
        const token = env.get("UGARIT_GIT_TOKEN") orelse return c.GIT_PASSTHROUGH;
        const username = env.get("UGARIT_GIT_USERNAME") orelse "x-access-token";
        // libgit2 copies what it needs right away; static buffers are enough
        // for this single-threaded, ≤3-try callback.
        var token_buf: [512]u8 = undefined;
        const token_z = std.fmt.bufPrintZ(&token_buf, "{s}", .{token}) catch return c.GIT_PASSTHROUGH;
        var user_buf: [256]u8 = undefined;
        const user_z = std.fmt.bufPrintZ(&user_buf, "{s}", .{username}) catch return c.GIT_PASSTHROUGH;
        return c.git_credential_userpass_plaintext_new(out, user_z, token_z);
    }
    return c.GIT_PASSTHROUGH;
}

fn sshKeyFile(
    out: [*c][*c]c.git_credential,
    user: [*c]const u8,
    st: *CredState,
    basename: [:0]const u8,
) c_int {
    const env = st.env orelse return c.GIT_PASSTHROUGH;
    const home = env.get("HOME") orelse return c.GIT_PASSTHROUGH;
    var priv_buf: [std.fs.max_path_bytes]u8 = undefined;
    const priv_z = std.fmt.bufPrintZ(&priv_buf, "{s}/.ssh/{s}", .{ home, basename }) catch
        return c.GIT_PASSTHROUGH;
    if (access(priv_z, 0) != 0) return c.GIT_PASSTHROUGH; // absent: keep trying
    var pub_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pub_z: ?[*:0]const u8 = std.fmt.bufPrintZ(&pub_buf, "{s}.pub", .{priv_z}) catch null;
    if (pub_z) |p| {
        if (access(p, 0) != 0) return c.git_credential_ssh_key_new(out, user, null, priv_z, null);
    }
    return c.git_credential_ssh_key_new(out, user, pub_z, priv_z, null);
}

fn fetchOpts(st: *CredState) c.git_fetch_options {
    var fo: c.git_fetch_options = undefined;
    _ = c.git_fetch_options_init(&fo, c.GIT_FETCH_OPTIONS_VERSION);
    fo.callbacks.credentials = credCb;
    fo.callbacks.payload = st;
    // the field is literally named `type` in the C header
    @field(fo.proxy_opts, "type") = @intCast(c.GIT_PROXY_AUTO); // HTTPS_PROXY etc.
    return fo;
}

// --- clone / sync ------------------------------------------------------------

/// Absolute, NUL-terminated path of `dir` joined with `sub`.
fn absZ(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub: []const u8) Error![:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch return error.Git;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ buf[0..n], sub }, 0) catch
        return error.OutOfMemory;
}

/// Clones `url` into `sources/<name>` (branch `ref` only for now; tags and
/// raw SHAs arrive with `checkoutRef` in a later step).
/// Upholds the no-half-clone invariant: the clone lands in a `.tmp-*` dir
/// beside `sources/` and is renamed into place only on success, so an
/// interrupted clone never leaves a broken `sources/<name>`.
pub fn clone(
    a: std.mem.Allocator,
    io: std.Io,
    sources: std.Io.Dir,
    env: ?*const std.process.Environ.Map,
    url: [:0]const u8,
    name: []const u8,
    ref: ?[:0]const u8,
) Error!void {
    var tmp_rand: [4]u8 = undefined;
    io.random(&tmp_rand);
    const tmp = std.fmt.allocPrintSentinel(
        a,
        ".tmp-{s}-{x}",
        .{ name, std.mem.readInt(u32, &tmp_rand, .little) },
        0,
    ) catch return error.OutOfMemory;
    defer a.free(tmp);
    errdefer sources.deleteTree(io, tmp) catch {};

    var st: CredState = .{ .env = env };
    var co: c.git_clone_options = undefined;
    _ = c.git_clone_options_init(&co, c.GIT_CLONE_OPTIONS_VERSION);
    co.fetch_opts = fetchOpts(&st);
    if (ref) |r| co.checkout_branch = r.ptr;

    const tmp_z = try absZ(a, io, sources, tmp);
    defer a.free(tmp_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_clone(&repo, url.ptr, tmp_z.ptr, &co));
    defer c.git_repository_free(repo);

    try failAt(.after_clone); // test-only interruption point (P11)

    sources.rename(tmp, sources, name, io) catch |e| switch (e) {
        error.DirNotEmpty => return error.SourceExists,
        else => {
            copyMsg("renaming the clone into place failed");
            return error.Git;
        },
    };
}

/// Fetches origin and fast-forwards only. Never touches a dirty or diverged
/// worktree (upholds **I11**). A missing `@{upstream}` counts as `up_to_date`
/// (edge case 21: empty upstream repo). Detached HEADs are `pinned`.
pub fn sync(
    dir_z: [:0]const u8,
    expected_url: []const u8,
    st: *CredState,
) Error!SyncResult {
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, dir_z.ptr));
    defer c.git_repository_free(repo);

    var remote: ?*c.git_remote = null;
    try check(c.git_remote_lookup(&remote, repo, "origin"));
    defer c.git_remote_free(remote);
    const current = c.git_remote_url(remote);
    if (current == null) return error.RemoteMismatch;
    if (!std.mem.eql(u8, std.mem.span(current), expected_url)) return error.RemoteMismatch;
    if (c.git_repository_head_detached(repo) == 1) return .pinned;
    if (try isDirty(repo)) return error.DirtyWorktree;

    var fo = fetchOpts(st);
    try check(c.git_remote_fetch(remote, null, &fo, null));

    // Upstream: normally `@{upstream}`. A clone of an empty origin carries no
    // `branch.<name>.remote` config, so fall back to the remote-tracking ref
    // of the current branch (edge case 21).
    var upstream: ?*c.git_annotated_commit = null;
    const rc = c.git_annotated_commit_from_revspec(&upstream, repo, "@{upstream}");
    if (rc != 0) {
        if (rc != c.GIT_ENOTFOUND) try check(rc);
        var oid: c.git_oid = undefined;
        if (!try remoteTipOid(repo, &oid)) return .up_to_date; // origin still empty
        try check(c.git_annotated_commit_lookup(&upstream, repo, &oid));
    }
    defer c.git_annotated_commit_free(upstream);

    if (c.git_repository_head_unborn(repo) == 1) {
        try fastForward(repo, c.git_annotated_commit_id(upstream));
        return .fast_forwarded;
    }

    var analysis: c.git_merge_analysis_t = 0;
    var pref: c.git_merge_preference_t = 0;
    try check(c.git_merge_analysis(&analysis, &pref, repo, @ptrCast(&upstream), 1));

    const up_to_date: c.git_merge_analysis_t = @intCast(c.GIT_MERGE_ANALYSIS_UP_TO_DATE);
    const fast_forward: c.git_merge_analysis_t = @intCast(c.GIT_MERGE_ANALYSIS_FASTFORWARD);
    const unborn: c.git_merge_analysis_t = @intCast(c.GIT_MERGE_ANALYSIS_UNBORN);
    if (analysis & up_to_date != 0) return .up_to_date;
    if (analysis & fast_forward == 0 and analysis & unborn == 0) return error.NotFastForward;
    try fastForward(repo, c.git_annotated_commit_id(upstream));
    return .fast_forwarded;
}

/// Origin's tip for the current branch, for clones without a
/// `branch.<name>.remote` config (cloned from an empty origin).
/// Returns false when the remote-tracking ref does not exist yet.
fn remoteTipOid(repo: ?*c.git_repository, out: *c.git_oid) Error!bool {
    var sym: ?*c.git_reference = null;
    try check(c.git_reference_lookup(&sym, repo, "HEAD"));
    defer c.git_reference_free(sym);
    const target = c.git_reference_symbolic_target(sym);
    if (target == null) return error.Git;
    const full = std.mem.span(target); // "refs/heads/main"
    if (!std.mem.startsWith(u8, full, "refs/heads/")) return error.Git;
    var buf: [256]u8 = undefined;
    const remote_ref = std.fmt.bufPrintZ(&buf, "refs/remotes/origin/{s}", .{full["refs/heads/".len..]}) catch
        return error.Git;
    const rc = c.git_reference_name_to_id(out, repo, remote_ref);
    if (rc == c.GIT_ENOTFOUND) return false;
    try check(rc);
    return true;
}

/// `git checkout_tree(SAFE)` + move the branch ref. An unborn HEAD (empty
/// origin that gained commits) is handled by creating the branch at the target.
fn fastForward(repo: ?*c.git_repository, target: [*c]const c.git_oid) Error!void {
    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, repo, target));
    defer c.git_commit_free(commit);
    var tree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&tree, commit));
    defer c.git_tree_free(tree);

    var co: c.git_checkout_options = undefined;
    _ = c.git_checkout_options_init(&co, c.GIT_CHECKOUT_OPTIONS_VERSION);
    co.checkout_strategy = @intCast(c.GIT_CHECKOUT_SAFE);
    try check(c.git_checkout_tree(repo, @as(?*const c.git_object, @ptrCast(tree)), &co));

    var head: ?*c.git_reference = null;
    const head_rc = c.git_repository_head(&head, repo);
    defer if (head != null) c.git_reference_free(head);
    if (head_rc == c.GIT_EUNBORNBRANCH) {
        var sym: ?*c.git_reference = null;
        try check(c.git_reference_lookup(&sym, repo, "HEAD"));
        defer c.git_reference_free(sym);
        const branch_name = c.git_reference_symbolic_target(sym);
        if (branch_name == null) return error.Git;
        var created: ?*c.git_reference = null;
        const rc2 = c.git_reference_create(&created, repo, branch_name, target, 0, "ugarit: fast-forward");
        if (created) |r| c.git_reference_free(r);
        try check(rc2);
        return;
    }
    try check(head_rc);
    var updated: ?*c.git_reference = null;
    const rc3 = c.git_reference_set_target(&updated, head, target, "ugarit: fast-forward");
    if (updated) |r| c.git_reference_free(r);
    try check(rc3);
}

/// Any modified, deleted or untracked path makes the worktree dirty; ignored
/// paths (e.g. our `info/exclude` lines) do not.
fn isDirty(repo: ?*c.git_repository) Error!bool {
    var opts: c.git_status_options = undefined;
    _ = c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION);
    opts.flags = @intCast(c.GIT_STATUS_OPT_INCLUDE_UNTRACKED |
        c.GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS);
    var list: ?*c.git_status_list = null;
    try check(c.git_status_list_new(&list, repo, &opts));
    defer c.git_status_list_free(list);
    return c.git_status_list_entrycount(list) > 0;
}

// --- enclosing-repo helpers (for the `info/exclude` integration) ------------

/// Path of the enclosing repository dir (`…/.git`) for an absolute path, or
/// null when `start` is not inside a worktree. Caller frees.
/// The start path need not exist: discovery retries on its parent (ugarit
/// excludes *before* creating the link).
pub fn discoverRepo(a: std.mem.Allocator, start: []const u8) Error!?[:0]u8 {
    if (try discoverRepoExisting(a, start)) |p| return p;
    const parent = std.fs.path.dirname(start) orelse return null;
    return discoverRepoExisting(a, parent);
}

fn discoverRepoExisting(a: std.mem.Allocator, start: []const u8) Error!?[:0]u8 {
    var start_buf: [std.fs.max_path_bytes]u8 = undefined;
    const start_z = std.fmt.bufPrintZ(&start_buf, "{s}", .{start}) catch {
        copyMsg("start path too long");
        return error.Git;
    };
    var buf: c.git_buf = .{};
    defer c.git_buf_dispose(&buf);
    const rc = c.git_repository_discover(&buf, start_z, 0, null);
    if (rc == c.GIT_ENOTFOUND) return null;
    try check(rc);
    if (buf.ptr == null) return error.Git;
    const dup: [:0]u8 = try a.dupeZ(u8, std.mem.span(buf.ptr));
    return dup;
}

/// The repository workdir as an absolute path with a trailing `/`.
pub fn repoWorkdir(a: std.mem.Allocator, repo_dir: [:0]const u8) Error![:0]u8 {
    const repo = try openRepo(repo_dir);
    defer c.git_repository_free(repo);
    const wd = c.git_repository_workdir(repo);
    if (wd == null) return error.Git; // bare repo: no worktree to link into
    return a.dupeZ(u8, std.mem.span(wd));
}

/// The common dir (`…/.git` also for linked worktrees) with a trailing `/`.
pub fn repoCommondir(a: std.mem.Allocator, repo_dir: [:0]const u8) Error![:0]u8 {
    const repo = try openRepo(repo_dir);
    defer c.git_repository_free(repo);
    const cd = c.git_repository_commondir(repo);
    if (cd == null) return error.Git;
    return a.dupeZ(u8, std.mem.span(cd));
}

fn openRepo(dir: [:0]const u8) Error!?*c.git_repository {
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, dir.ptr));
    return repo;
}

fn relZ(buf: *[std.fs.max_path_bytes]u8, rel: []const u8) Error![*:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}", .{rel}) catch {
        copyMsg("relative path too long");
        return error.Git;
    };
}

/// True when `rel` is tracked (in the index), directly or as a parent dir of
/// tracked files — edge case 44. `git_status_file` cannot answer for
/// directories, and the index only lists files, so both shapes are checked.
pub fn isPathTracked(repo_dir: [:0]const u8, rel: []const u8) Error!bool {
    const repo = try openRepo(repo_dir);
    defer c.git_repository_free(repo);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel_z = try relZ(&buf, rel);
    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo));
    defer c.git_index_free(index);
    if (c.git_index_get_bypath(index, rel_z, 0) != null) return true;
    const n = c.git_index_entrycount(index);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = c.git_index_get_byindex(index, i) orelse continue;
        if (entry.*.path == null) continue;
        const p = std.mem.span(@as([*:0]const u8, @ptrCast(entry.*.path)));
        if (p.len > rel.len + 1 and std.mem.startsWith(u8, p, rel) and p[rel.len] == '/') return true;
    }
    return false;
}

/// True when `rel` is already ignored by that repo (edge case 45).
pub fn isPathIgnored(repo_dir: [:0]const u8, rel: []const u8) Error!bool {
    const repo = try openRepo(repo_dir);
    defer c.git_repository_free(repo);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel_z = try relZ(&buf, rel);
    var ignored: c_int = 0;
    const rc = c.git_ignore_path_is_ignored(&ignored, repo, rel_z);
    if (rc == c.GIT_ENOTFOUND) return false;
    try check(rc);
    return ignored == 1;
}

// --- fixtures (test-only scaffolding; never referenced by the CLI) ------------

/// libgit2-backed fixtures. Referenced from `test` blocks and property tests
/// only, so release builds never compile it in.
pub const fixtures = struct {
    /// libgit2 requires init before use; refcounted guard.
    pub const Libgit2 = struct {
        pub fn init() Libgit2 {
            _ = c.git_libgit2_init();
            return .{};
        }
        pub fn deinit(_: Libgit2) void {
            _ = c.git_libgit2_shutdown();
        }
    };

    /// Fixed signature time keeps OIDs reproducible for a given script.
    const sig_time: i64 = 1_700_000_000;

    /// Absolute, NUL-terminated path of `parent/<name>` (caller frees).
    pub const dirZ = absZ;

    fn fixtureSignature() Error!?*c.git_signature {
        var sig: ?*c.git_signature = null;
        try check(c.git_signature_new(&sig, "ugarit fixture", "fixture@ugarit.test", sig_time, 0));
        return sig;
    }

    fn open(dir_z: [:0]const u8) Error!?*c.git_repository {
        var repo: ?*c.git_repository = null;
        try check(c.git_repository_open(&repo, dir_z.ptr));
        return repo;
    }

    /// Inits a repo with initial branch `main` at `parent/<name>` and returns
    /// its path (caller frees). `git_repository_init_ext` does not create the
    /// target dir itself (unlike the simple `git_repository_init`), so the dir
    /// is created through `std.Io` first.
    pub fn initOrigin(a: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, name: []const u8) Error![:0]u8 {
        const path_z = try dirZ(a, io, parent, name);
        errdefer a.free(path_z);
        parent.createDirPath(io, name) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return error.Git,
        };
        var opts: c.git_repository_init_options = undefined;
        _ = c.git_repository_init_options_init(&opts, c.GIT_REPOSITORY_INIT_OPTIONS_VERSION);
        opts.initial_head = "main";
        var repo: ?*c.git_repository = null;
        try check(c.git_repository_init_ext(&repo, path_z.ptr, &opts));
        c.git_repository_free(repo);
        return path_z;
    }

    const IndexOp = struct { path: []const u8, add: bool };

    fn commitIndex(repo_dir: [:0]const u8, ops: []const IndexOp) Error!void {
        const repo = try open(repo_dir);
        defer c.git_repository_free(repo);
        var index: ?*c.git_index = null;
        try check(c.git_repository_index(&index, repo));
        defer c.git_index_free(index);

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for (ops) |op| {
            const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{op.path}) catch return error.Git;
            if (op.add) {
                try check(c.git_index_add_bypath(index, path_z));
            } else {
                try check(c.git_index_remove_bypath(index, path_z));
            }
        }
        try check(c.git_index_write(index));

        var tree_id: c.git_oid = undefined;
        try check(c.git_index_write_tree(&tree_id, index));
        var tree: ?*c.git_tree = null;
        try check(c.git_tree_lookup(&tree, repo, &tree_id));
        defer c.git_tree_free(tree);

        const sig = try fixtureSignature();
        defer c.git_signature_free(sig);

        var parent: ?*c.git_commit = null;
        var head_oid: c.git_oid = undefined;
        const head_rc = c.git_reference_name_to_id(&head_oid, repo, "HEAD");
        if (head_rc == 0) {
            try check(c.git_commit_lookup(&parent, repo, &head_oid));
        } else if (head_rc != c.GIT_ENOTFOUND and head_rc != c.GIT_EUNBORNBRANCH) {
            try check(head_rc);
        }
        defer if (parent != null) c.git_commit_free(parent);

        var oid: c.git_oid = undefined;
        if (parent != null) {
            try check(c.git_commit_create_v(
                &oid,
                repo,
                "HEAD",
                sig,
                sig,
                null,
                "fixture commit",
                tree,
                1,
                @as(?*const c.git_commit, parent),
            ));
        } else {
            try check(c.git_commit_create_v(
                &oid,
                repo,
                "HEAD",
                sig,
                sig,
                null,
                "fixture commit",
                tree,
                0,
            ));
        }
    }

    /// Writes `content` to worktree file `rel` and commits it.
    pub fn commitFile(io: std.Io, repo_dir: [:0]const u8, rel: []const u8, content: []const u8) Error!void {
        var d = std.Io.Dir.openDirAbsolute(io, repo_dir, .{}) catch return error.Git;
        defer d.close(io);
        if (std.fs.path.dirname(rel)) |parent| {
            d.createDirPath(io, parent) catch return error.Git;
        }
        d.writeFile(io, .{ .sub_path = rel, .data = content }) catch return error.Git;
        try commitIndex(repo_dir, &.{.{ .path = rel, .add = true }});
    }

    /// Moves a tracked file and commits the move (upstream relocation fixture).
    pub fn moveFile(io: std.Io, repo_dir: [:0]const u8, from: []const u8, to: []const u8) Error!void {
        var d = std.Io.Dir.openDirAbsolute(io, repo_dir, .{}) catch return error.Git;
        defer d.close(io);
        if (std.fs.path.dirname(to)) |parent| {
            d.createDirPath(io, parent) catch return error.Git;
        }
        d.rename(from, d, to, io) catch return error.Git;
        try commitIndex(repo_dir, &.{
            .{ .path = to, .add = true },
            .{ .path = from, .add = false },
        });
    }

    /// Deletes a tracked file and commits the removal (dangling-link fixture).
    pub fn deleteFile(io: std.Io, repo_dir: [:0]const u8, rel: []const u8) Error!void {
        var d = std.Io.Dir.openDirAbsolute(io, repo_dir, .{}) catch return error.Git;
        defer d.close(io);
        d.deleteFile(io, rel) catch return error.Git;
        try commitIndex(repo_dir, &.{.{ .path = rel, .add = false }});
    }

    /// Puts HEAD detached at its current commit (the `pinned` state).
    pub fn detachHead(repo_dir: [:0]const u8) Error!void {
        const repo = try open(repo_dir);
        defer c.git_repository_free(repo);
        var oid: c.git_oid = undefined;
        try check(c.git_reference_name_to_id(&oid, repo, "HEAD"));
        try check(c.git_repository_set_head_detached(repo, &oid));
    }

    /// HEAD as 40 hex chars, or null when HEAD is unborn (empty origin).
    pub fn headOid(repo_dir: [:0]const u8) Error!?[40]u8 {
        const repo = try open(repo_dir);
        defer c.git_repository_free(repo);
        var oid: c.git_oid = undefined;
        const rc = c.git_reference_name_to_id(&oid, repo, "HEAD");
        if (rc == c.GIT_ENOTFOUND or rc == c.GIT_EUNBORNBRANCH) return null;
        try check(rc);
        var hex: [40]u8 = undefined;
        _ = c.git_oid_fmt(&hex, &oid);
        return hex;
    }

    /// Rewrites the `origin` URL (RemoteMismatch fixture).
    pub fn setOriginUrl(repo_dir: [:0]const u8, url: [:0]const u8) Error!void {
        const repo = try open(repo_dir);
        defer c.git_repository_free(repo);
        try check(c.git_remote_set_url(repo, "origin", url.ptr));
    }

    pub const FileEntry = struct { path: []const u8, content: []const u8 };

    fn entryLessThan(_: void, x: FileEntry, y: FileEntry) bool {
        return std.mem.order(u8, x.path, y.path) == .lt;
    }

    fn freeEntry(a: std.mem.Allocator, e: FileEntry) void {
        a.free(e.path);
        a.free(e.content);
    }

    /// Releases a snapshot taken by `snapshotWorktree`.
    pub fn freeSnapshot(a: std.mem.Allocator, snapshot: []FileEntry) void {
        for (snapshot) |e| freeEntry(a, e);
        a.free(snapshot);
    }

    /// Sorted `(path, content)` of every worktree file, skipping `.git`.
    /// The oracle half of P10's "unchanged" assertions.
    pub fn snapshotWorktree(a: std.mem.Allocator, io: std.Io, dir_abs: []const u8) Error![]FileEntry {
        var list: std.ArrayList(FileEntry) = .empty;
        errdefer {
            for (list.items) |e| freeEntry(a, e);
            list.deinit(a);
        }
        var d = std.Io.Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch return error.Git;
        defer d.close(io);
        try walk(a, io, &d, "", &list);
        const items = list.toOwnedSlice(a) catch return error.OutOfMemory;
        std.mem.sort(FileEntry, items, {}, entryLessThan);
        return items;
    }

    fn walk(
        a: std.mem.Allocator,
        io: std.Io,
        d: *std.Io.Dir,
        prefix: []const u8,
        out: *std.ArrayList(FileEntry),
    ) Error!void {
        var it = d.iterate();
        while (it.next(io) catch return error.Git) |entry| {
            if (entry.kind == .directory) {
                if (std.mem.eql(u8, entry.name, ".git")) continue;
                var sub = d.openDir(io, entry.name, .{ .iterate = true }) catch return error.Git;
                defer sub.close(io);
                const child_prefix = std.fmt.allocPrint(a, "{s}{s}/", .{ prefix, entry.name }) catch
                    return error.OutOfMemory;
                defer a.free(child_prefix);
                try walk(a, io, &sub, child_prefix, out);
            } else if (entry.kind == .file) {
                const path = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, entry.name }) catch
                    return error.OutOfMemory;
                errdefer a.free(path);
                const content = d.readFileAlloc(io, entry.name, a, .limited(1 << 20)) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.Git,
                };
                out.append(a, .{ .path = path, .content = content }) catch return error.OutOfMemory;
            }
            // symlinks and other entry kinds are skipped
        }
    }
};

// --- unit tests ---------------------------------------------------------------

test "clone refuses an existing target and cleans its temp dir (c: filesystem state)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const lg = fixtures.Libgit2.init();
    defer lg.deinit();
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    const origin = try fixtures.initOrigin(a, io, t.dir, "origin");
    defer a.free(origin);
    try fixtures.commitFile(io, origin, "SKILL.md", "v0\n");

    try t.dir.createDirPath(io, "sources");
    var sources = try t.dir.openDir(io, "sources", .{ .iterate = true });
    defer sources.close(io);
    try clone(a, io, sources, null, origin, "central", null);
    try std.testing.expectError(error.SourceExists, clone(a, io, sources, null, origin, "central", null));

    // no .tmp-* leftover from the refused clone
    var it = sources.iterate();
    var names: usize = 0;
    while (try it.next(io)) |entry| {
        names += 1;
        try std.testing.expectEqualStrings("central", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), names);
}

test "snapshotWorktree skips .git and sorts (c: pins the P10 oracle)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = std.testing.tmpDir(.{});
    defer t.cleanup();

    try t.dir.createDirPath(io, "proj");
    const root = try fixtures.dirZ(a, io, t.dir, "proj");
    defer a.free(root);

    var d = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer d.close(io);
    try d.createDirPath(io, "b");
    try d.writeFile(io, .{ .sub_path = "a.txt", .data = "aa" });
    try d.writeFile(io, .{ .sub_path = "b/z.txt", .data = "zz" });
    try d.createDirPath(io, ".git");
    try d.writeFile(io, .{ .sub_path = ".git/config", .data = "junk" });

    const snap = try fixtures.snapshotWorktree(a, io, root);
    defer fixtures.freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqualStrings("a.txt", snap[0].path);
    try std.testing.expectEqualStrings("aa", snap[0].content);
    try std.testing.expectEqualStrings("b/z.txt", snap[1].path);
    try std.testing.expectEqualStrings("zz", snap[1].content);
}
