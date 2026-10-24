# Guide

Ugarit manages skill directories from Git repositories. It clones each source once, discovers directories containing `SKILL.md`, and creates symbolic links from agent-specific destinations to those managed skills.

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

The native build requires Zig 0.16, libgit2, and pkg-config. The provided Nix development shell supplies them:

```sh
nix develop --impure
make release
```

The executable is written to `zig-out/bin/ugarit`. Install it under a custom prefix with:

```sh
make install OPTIMIZE=ReleaseSafe PREFIX="$HOME/.local"
```

- `DESTDIR` is supported for package staging.

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

## Skill Discovery

A skill is a real directory containing a regular file named `SKILL.md`. Discovery scans at most four directory levels below each source root, stops at a discovered skill, and does not follow directory symlinks. Unsafe or unreadable entries are skipped with warnings.

Bare skill names are matched case-insensitively. If multiple sources contain the same name, use the exact source-relative query:

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
ugarit source-add <url> [--name <name>] [--label <label>] [--path <dir>] [--target <dir>] [--no-claude-sync] [--ref <ref>]
```

- Registers and clones a source. Without `--name`, the name is derived from the last URL or path component, with one trailing `.git` removed. Names may contain ASCII letters, digits, `.`, `_`, and `-`; they cannot begin with `.` or `-` and are limited to 128 bytes.
- `--label` adds an alias accepted wherever the source name is.
- `--path` is the clone directory scanned for skills (overrides `default_search_path`).
- `--target` is the subdirectory of each `link` destination that receives links.
- `--no-claude-sync` stops `link` from also linking into `<dest>/.claude/skills`.
- `--ref` checks out a specific branch, tag, or commit. A source name must be unique. Reusing a URL under a different name produces a warning. Credentials embedded in a URL are stored in `config.json`, so Ugarit warns and redacts them from diagnostics.

The config is saved only after cloning succeeds. A failed clone does not leave a configured source or completed clone behind.

Examples:

```sh
ugarit source-add https://github.com/acme/skills.git
ugarit source-add git@github.com:acme/private-skills.git --name private
ugarit source-add https://github.com/acme/skills.git --name stable --ref v1.2.0
```

### `source-sync`

```text
ugarit source-sync [source-name|label]
```

Fetches all sources, or one selected source. Sources present in `config.json` but not yet cloned (declared by hand, by Home Manager, or on another host) are cloned. Attached branches advance only by fast-forward. Dirty worktrees, changed origin URLs, and diverged histories are reported and left unchanged. A detached checkout is treated as pinned.

After a successful sync, Ugarit examines dangling registered links. If a skill moved and there is exactly one same-name candidate in the same source, the link is repaired. Ambiguous or missing candidates remain dangling and are reported. An interrupted repair is adopted on the next sync when the on-disk link already points to the unique valid candidate.

The command continues across source failures and exits with status 1 if any source failed.

### `link`

```text
ugarit link <source|label> <skill> <dest-dir...> [--as <name>] [--force] [--mkdir] [--no-exclude]
```

Selects a skill from the named source and creates one link in each destination. The skill operand may be a case-insensitive skill name or an exact, source-relative path. Requiring the source makes same-named skills in different repositories unambiguous.

Each destination receives a link in its source's `target` subdirectory (the destination itself when unset) and, unless `claude_sync` is false, in `.claude/skills`. Both subdirectories are created on demand; the destination itself must exist unless `--mkdir` is given. Subdirectories that resolve to the same directory, such as `.claude/skills` symlinked to `.agents/skills`, are linked once, and a destination that already is a `.claude/skills` directory gets no nested copy. The link name defaults to the skill's directory name; `--as` selects another valid name. Relative destinations are resolved from the current directory, and leading `~` or `~/` expands from `HOME`. `~user` syntax is not supported.

Options:

- `--as <name>` changes the destination entry name.
- `--mkdir` creates missing destination directories.
- `--force` replaces a foreign symlink or a live managed symlink to another
  skill. It never replaces a real file or directory.
- `--no-exclude` disables local Git exclusion handling.

Destinations inside Ugarit's managed sources or inside the selected skill are rejected. Existing real entries are always preserved. Repeating an identical link is safe and reports it as unchanged.

Each destination is processed independently. Successful destinations remain successful if another destination fails; the command exits with status 1 when any destination fails.

Examples:

```sh
ugarit link central formatter ~/Code/project
ugarit link central tools/reviewer ~/.claude/skills ~/.config/other-agent/skills
ugarit link team formatter ~/.claude/skills --as team-formatter
```

### `unlink`

```text
ugarit unlink <link-path>...
ugarit unlink --skill <name>
```

The two forms are mutually exclusive. Path mode removes the selected managed links. Skill mode removes every current-host registry entry whose skill name matches case-insensitively.

Ugarit removes only symlinks that point into its managed `sources/` tree. It will not remove a foreign symlink, real file, or real directory. Missing links are treated idempotently and stale registry entries are removed.

### `list`

```text
ugarit list [skill] [--source <source-name>] [--links]
```

Without arguments, lists discovered skills and the number of current-host links. A skill query shows its registered links. `--source` filters by source, and `--links` expands link details and includes orphaned registry records.

Link states include:

- `ok`: the link points to the registered skill.
- `retargeted`: the path is a symlink with another target.
- `dangling`: the target no longer exists.
- `missing`: the destination entry is absent.
- `replaced`: a foreign symlink or real entry occupies the path.
- `other-host`: the entry belongs to another hostname.

When configured sources have not been cloned on the current machine, `list` prints warnings but does not create state.

## Configuration File

Normal source changes should use `source-add`. The JSON schema is:

```json
{
  "version": 1,
  "default_search_path": ".agents/skills",
  "sources": [
    {
      "name": "central",
      "label": "c",
      "url": "https://github.com/acme/skills.git",
      "path": ".agents/skills",
      "target": ".agents/skills",
      "claude_sync": true,
      "ref": "main"
    }
  ]
}
```

Every field except `name` and `url` is optional; `claude_sync` defaults to `true`. `path` (or `default_search_path`) is the clone directory scanned for skills; hidden directories are only reachable this way. `path`, `target` and `default_search_path` must be relative without `.`/`..` components, and symlinked search roots are refused. Names and labels share one namespace. Duplicate names or labels, invalid names, malformed JSON, and unknown versions are rejected. Writes use a temporary file plus atomic rename. `links.json` is internal state and should not be edited manually.

## Troubleshooting

### Skill name is ambiguous

Use `ugarit list` to find the exact source-relative path. Pass the source and relative path separately to `link`, or `source/path/to/skill` to `list`.

### Destination entry is in the way

Inspect the existing path. Real files and directories must be moved manually. For a symlink that may be replaced intentionally, retry with `--force`.

### Link path is tracked

Remove the path from the repository index, commit the intended repository change if appropriate, then retry. Ugarit does not modify tracked content.

### Source is dirty or diverged

Resolve, commit, stash, or discard local changes in the managed source clone. Ugarit performs only clean fast-forwards and does not merge or reset history. The clone is under `<config-dir>/sources/<source-name>`.

### Authentication failed

Use the normal Git credential mechanisms available to libgit2, such as an SSH agent for SSH URLs or configured credentials for HTTPS. Avoid embedding secrets in source URLs because they are persisted in plain text.

### Stale or moved links

Run `ugarit source-sync`, then inspect `ugarit list --links`. Unique same-source moves are repaired automatically; ambiguous moves require relinking explicitly.
