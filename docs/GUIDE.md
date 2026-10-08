# Ugarit Guide

Ugarit manages skill directories from Git repositories. It clones each source
once, discovers directories containing `SKILL.md`, and creates symbolic links
from agent-specific destinations to those managed skills.

## Installation

### Nix package

From the repository root:

```sh
nix build
./result/bin/ugarit --version
```

On Linux, a fully static musl build is available:

```sh
nix build .#static
file result/bin/ugarit
```

### Zig build

The native build requires Zig 0.16, libgit2, and pkg-config. The provided Nix
development shell supplies them:

```sh
nix develop --impure
make release
```

The executable is written to `zig-out/bin/ugarit`. Install it under a custom
prefix with:

```sh
make install OPTIMIZE=ReleaseSafe PREFIX="$HOME/.local"
```

`DESTDIR` is supported for package staging.

## Managed State

The managed directory is selected in this order:

1. Global `--config-dir <absolute-path>` option
2. `UGARIT_HOME`
3. `$XDG_CONFIG_HOME/ugarit`
4. `$HOME/.config/ugarit`

The selected path must be absolute. It contains:

```text
config.json    configured sources
links.json     managed-link registry
sources/       cloned repositories
.lock          advisory lock for mutating commands
```

`list` is read-only. Running it on a fresh machine does not create the managed
directory or `sources/`.

The registry includes a hostname for every link. Ugarit mutates links belonging
to the current host only, while `list --links` can report entries recorded by
other hosts.

## Skill Discovery

A skill is a real directory containing a regular file named `SKILL.md`.
Discovery scans at most four directory levels below each source root, stops at
a discovered skill, and does not follow directory symlinks. Unsafe or
unreadable entries are skipped with warnings.

Bare skill names are matched case-insensitively. If multiple sources contain
the same name, use the exact source-relative query:

```text
source-name/path/to/skill
```

Source-qualified paths are case-sensitive.

## Commands

Global options precede the command:

```text
ugarit [--config-dir <absolute-path>] [--help] [--version] <command>
```

### `source-add`

```text
ugarit source-add <url> [--name <name>] [--ref <ref>]
```

Registers and clones a source. Without `--name`, the name is derived from the
last URL or path component, with one trailing `.git` removed. Names may contain
ASCII letters, digits, `.`, `_`, and `-`; they cannot begin with `.` or `-` and
are limited to 128 bytes.

`--ref` checks out a specific branch, tag, or commit. A source name must be
unique. Reusing a URL under a different name produces a warning. Credentials
embedded in a URL are stored in `config.json`, so Ugarit warns and redacts them
from diagnostics.

The config is saved only after cloning succeeds. A failed clone does not leave
a configured source or completed clone behind.

Examples:

```sh
ugarit source-add https://github.com/acme/skills.git
ugarit source-add git@github.com:acme/private-skills.git --name private
ugarit source-add https://github.com/acme/skills.git --name stable --ref v1.2.0
```

### `source-sync`

```text
ugarit source-sync [source-name]
```

Fetches all sources, or one selected source. Attached branches advance only by
fast-forward. Dirty worktrees, changed origin URLs, and diverged histories are
reported and left unchanged. A detached checkout is treated as pinned.

After a successful sync, Ugarit examines dangling registered links. If a skill
moved and there is exactly one same-name candidate in the same source, the link
is repaired. Ambiguous or missing candidates remain dangling and are reported.
An interrupted repair is adopted on the next sync when the on-disk link already
points to the unique valid candidate.

The command continues across source failures and exits with status 1 if any
source failed.

### `link`

```text
ugarit link <skill> <dest-dir>... [--as <name>] [--force] [--mkdir] [--no-exclude]
```

Creates one link in each destination. The link name defaults to the skill's
directory name; `--as` selects another valid name. Relative destinations are
resolved from the current directory, and leading `~` or `~/` expands from
`HOME`. `~user` syntax is not supported.

Options:

- `--as <name>` changes the destination entry name.
- `--mkdir` creates missing destination directories.
- `--force` replaces a foreign symlink or a live managed symlink to another
  skill. It never replaces a real file or directory.
- `--no-exclude` disables local Git exclusion handling.

Destinations inside Ugarit's managed sources or inside the selected skill are
rejected. Existing real entries are always preserved. Repeating an identical
link is safe and reports it as unchanged.

Each destination is processed independently. Successful destinations remain
successful if another destination fails; the command exits with status 1 when
any destination fails.

Examples:

```sh
ugarit link formatter ~/.claude/skills --mkdir
ugarit link central/tools/reviewer ~/.claude/skills ~/.config/other-agent/skills
ugarit link formatter ~/.claude/skills --as zig-format
```

### Git worktree exclusion

When a destination is inside a Git worktree, Ugarit adds an anchored path such
as `/.claude/skills/formatter` to the repository's local
`commondir/info/exclude`. This file is not committed. Existing ignore rules are
respected, and duplicate lines are not added.

If the path is tracked, linking is rejected; remove it from the Git index
before retrying. If link creation fails after Ugarit appended an exclusion,
the exclusion file is restored exactly. Use `--no-exclude` when exclusion is
managed separately.

### `unlink`

```text
ugarit unlink <link-path>...
ugarit unlink --skill <name>
```

The two forms are mutually exclusive. Path mode removes the selected managed
links. Skill mode removes every current-host registry entry whose skill name
matches case-insensitively.

Ugarit removes only symlinks that point into its managed `sources/` tree. It
will not remove a foreign symlink, real file, or real directory. Missing links
are treated idempotently and stale registry entries are removed.

### `list`

```text
ugarit list [skill] [--source <source-name>] [--links]
```

Without arguments, lists discovered skills and the number of current-host
links. A skill query shows its registered links. `--source` filters by source,
and `--links` expands link details and includes orphaned registry records.

Link states include:

- `ok`: the link points to the registered skill.
- `retargeted`: the path is a symlink with another target.
- `dangling`: the target no longer exists.
- `missing`: the destination entry is absent.
- `replaced`: a foreign symlink or real entry occupies the path.
- `other-host`: the entry belongs to another hostname.

When configured sources have not been cloned on the current machine, `list`
prints warnings but does not create state.

## Configuration File

Normal source changes should use `source-add`. The JSON schema is:

```json
{
  "version": 1,
  "sources": [
    {
      "name": "central",
      "url": "https://github.com/acme/skills.git",
      "ref": "main"
    }
  ]
}
```

`ref` is optional. Duplicate names, invalid names, malformed JSON, and unknown
versions are rejected. Writes use a temporary file plus atomic rename.
`links.json` is internal state and should not be edited manually.

## Exit Status and Output

- `0`: success
- `1`: operational failure or partial failure
- `2`: invalid command usage

Machine-readable command results are written to standard output. Warnings and
diagnostics are written to standard error. Multi-item commands continue after
individual operational failures where possible.

## Safety and Recovery

- Mutating commands use an exclusive lock; concurrent invocations fail rather
  than racing.
- Ugarit refuses to write into another user's `HOME` when run as root.
- Link replacement is atomic: observers see either the old symlink or the new
  one, not an absent intermediate path.
- Registry bytes are prepared and flushed before filesystem mutation; retries
  converge after interruption.
- Reserved temporary links and clone directories are swept by later runs.
- Ugarit never overwrites real destination entries.

## Troubleshooting

### Skill name is ambiguous

Use `ugarit list` to find the exact source-relative path, then pass
`source/path/to/skill` to `link` or `list`.

### Destination entry is in the way

Inspect the existing path. Real files and directories must be moved manually.
For a symlink that may be replaced intentionally, retry with `--force`.

### Link path is tracked

Remove the path from the repository index, commit the intended repository
change if appropriate, then retry. Ugarit does not modify tracked content.

### Source is dirty or diverged

Resolve, commit, stash, or discard local changes in the managed source clone.
Ugarit performs only clean fast-forwards and does not merge or reset history.
The clone is under `<config-dir>/sources/<source-name>`.

### Authentication failed

Use the normal Git credential mechanisms available to libgit2, such as an SSH
agent for SSH URLs or configured credentials for HTTPS. Avoid embedding secrets
in source URLs because they are persisted in plain text.

### Stale or moved links

Run `ugarit source-sync`, then inspect `ugarit list --links`. Unique same-source
moves are repaired automatically; ambiguous moves require relinking explicitly.

## Development

Common Make targets:

```sh
make                    # Debug build
make run ARGS="list"    # run through Zig's build graph
make test               # unit, property, and end-to-end tests
make check              # formatting check plus tests
make fmt                # format Zig sources
make release            # ReleaseSafe build
make static             # Linux/musl static Nix package
make nix-check          # hermetic flake checks
make clean              # remove Zig build caches and output
```

Variables are deliberately overridable:

```sh
make test ZIG=/path/to/zig OPTIMIZE=ReleaseSafe
make install PREFIX=/usr DESTDIR="$pkgdir"
make static NIX_FLAKE=path:.
```

Direct equivalents include:

```sh
zig fmt --check src build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
nix build .#checks.x86_64-linux.default
nix build .#static
nix flake check
```

The property suite uses fixed seeds and shrinking. A failure reports the seed
and minimized input needed to reproduce it. The tested contracts are cataloged
in `src/test/INVARIANTS.md`.
