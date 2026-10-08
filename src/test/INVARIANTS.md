# Invariants, properties, and design constraints

This catalogue is the single source of truth for the guarantees Ugarit's code and tests are written against, grouped here by category.

Code comments name these guarantees in words rather than by number. The identifiers below (`I1` ..., `P1` ..., `H1` ..., `PL1`/`PL2`, `D1`/`D2`) exist only so this document and the git history can cross-reference them without restating every description inline.

## Invariants (the specification)

### Filesystem safety

- **No collateral damage (`I1`)**: Across any sequence of commands, `ugarit` never creates, modifies, or deletes any path outside `sources/`, `config.json`, `links.json`, and `.lock`, except: 
    - (a) `dest/<name>` symlinks it creates or removes.
    - (b) its own reserved temp entries.
    - (c) a single appended line in a repo's `info/exclude`.
- **Ownership (`I2`)**: Ugarit removes or replaces only symlinks whose target is under `realpath(sources/)`. A real file or directory is never removed or replaced, `--force` included.
- **Atomic visibility (`I3`)**: During `link` replacement, `dest/<name>` is at every instant either the old entry or the new link; never absent or partial. After any command, including a failed one, no reserved temp entry remains.

### Link correctness

- **Confinement (`I4`)**: Every link target ugarit writes is an absolute path to a directory under `realpath(sources/<source>)` that contains a regular `SKILL.md`.
- **Fan-out coherence (`I5`)**: All registry links of one `(source, rel_path)` resolve to the same directory (same inode), so a write to the source is visible through every link.
- **Idempotence (`I6`)**: `link(s, D)` twice yields the same filesystem state and registry as once; `unlink` twice equals once; `source-sync` with no upstream change makes zero filesystem changes.
- **Inverse (`I7`)**: `unlink(link(s, D))` restores the dest directories and the registry to their prior state, modulo the `info/exclude` line, which is allowed to stay.

### Registry

- **Soundness (`I8`)** — after every successful mutating command, each registry
  entry for this host has a unique, absolute, canonical `path`, and is either
  `ok` or explicitly reported in that command's output.
- **Completeness (`I9`)** — every symlink ugarit created and has not removed is
  in the registry. Agreement holds unless the registry save itself failed, and
  that failure is reported.
- **Repair preserves identity (`I10`)** — `repair` only relinks to a skill with
  the same name in the same source, and only when that match is unique;
  otherwise it leaves the link alone.

### Git and config

- **No lost work (`I11`)** — `source-sync` never changes a source's worktree or
  HEAD unless the worktree is clean and the update is a fast-forward. Dirty or
  diverged sources are byte-for-byte unchanged.
- **Failure atomicity (`I12`)** — `source-add` changes `config.json` iff the
  clone succeeded. A failed command never leaves `config.json` or `links.json`
  half-written (atomic rename).
- **Config well-formedness (`I13`)** — source names are unique and valid. Each
  configured source directory is either absent, or a repository whose `origin`
  equals the configured URL.

### Pure functions

- **`extractRepoName` totality (`I14`)** — total over valid name × URL form;
  the result passes `validateName`, and it round-trips.
- **Discovery determinism and confinement (`I15`)** — output is sorted and a
  pure function of the tree; no result path lies outside its source root or
  traverses a symlink.
- **Exclude idempotence (`I16`)** — N links into the same repo path add at most
  one line to `info/exclude`.
- **Exit status (`I17`)** — exit 0 iff every requested item succeeded; 1 on any
  partial failure; 2 on usage error.

### Resources

- **No leaks (`I18`)** — every code path, success or error, frees all it
  allocates (checked by `std.testing.allocator`).
- **OOM-safe (`I19`)** — if any single allocation fails, the operation returns
  `error.OutOfMemory` and leaves no partial on-disk state, no temp entries, and
  no leaks.

### Module-local invariants

These are declared in a specific module's `//! Invariants:` block and are
narrower than the global list above.

- **Tilde purity (`PL1`)** — `paths.expandTilde` is a pure function of
  `(home, input)`; it only expands a leading `~` or `~/`, and rejects `~user`.
- **Canonical-destination idempotence (`PL2`)** — `paths.canonicalDest` is
  idempotent and resolves symlinks, so `canon(canon(p)) == canon(p)`.
- **Descent cap (`D1`)** — `discovery` never descends into a skill directory
  and never past `max_depth` levels below the source root.
- **Case-insensitive names (`D2`)** — bare-name lookup folds case;
  `source/rel_path` queries are exact and case-sensitive.

## Hazards (design constraints)

Guards that shape the design, each is tied to an invariant above. Listed here because code comments refer to them by name (notably `H4`).

- **`H1` Editing through a link** edits the central repo → source turns dirty (surfaced, never auto-stashed/reset).
- **`H2` Non-atomic checkout** across files → accepted and documented.
- **`H3` TOCTOU** between `classify` and `rename` → re-check before rename + `RENAME_NOREPLACE`.
- **`H4` Absolute paths don't port** across machines → registry stores `host`, other-host entries are shown as `other-host` and never acted on.
- **`H5` `sudo ugarit`** → refuse when euid=0 and `$HOME` is owned by another user.
- **`H6` `flock` on network homes** → documented; read-modify-write under the lock.
- **`H7` Case/normalisation-insensitive filesystems** → canonical parent realpath keys; case-folded discovery collisions.
- **`H8` Skill dir replaced by file or symlink upstream** → discovery requires a real dir with `SKILL.md`; `repair` re-validates before relinking.
- **`H9` libgit2 global state** → single `init`/`deinit` pair in `main` + test helper.
- **`H10` Partial libgit2 checkout** → move the ref only after checkout succeeds.
- **`H11` Ctrl-C mid-command** → reserved temp prefixes, swept on next run.
- **`H12` Agents that don't follow directory symlinks** → documented.
- **`H13` Path/name length near limits** → short fixed-length temp name `.u-<8 hex>`.

## Properties (the tests)

Each property is a property test that states its claim over generated inputs. The owner module owns the test; the invariants column names the guarantees the property exercises.

| Property | Claim | Owner module | Invariants |
|---|---|---|---|
| `P1` command state machine | Random link/unlink/tamper sequences preserve filesystem + registry invariants after every step. | `src/test/props.zig` | no-collateral-damage, ownership, atomic-visibility, confinement, fan-out, idempotence, inverse, soundness, completeness, repair, exit-status |
| `P2` URL round-trip | `extractRepoName` recovers the name from every URL form. | `config` | `extractRepoName` totality |
| `P2b` URL near-miss robustness | Near-miss/garbage URLs yield a valid name or an error, never a crash. | `config` | `extractRepoName` totality |
| `P3` validateName agreement | `validateName` agrees with an independently written name spec. | `config` | `extractRepoName` totality |
| `P3b` validateName boundaries | Boundary classes (empty, `.`, `..`, length, chars) classify correctly. | `config` | `extractRepoName` totality |
| `P4` config identity | Save→load is the identity; truncated/garbage bytes → error, never a partial config. | `config` | failure-atomicity, config-well-formedness |
| `P5` tilde + canonical-destination | Output is absolute, `..`-free, symlink-resolving, and idempotent. | `paths` | soundness (and `PL1`, `PL2`) |
| `P6` discovery on random trees | Sorted, confined, no symlink traversal, collisions case-folded. | `discovery` | discovery-determinism, confinement |
| `P7` classify × link decision table | Real entries survive; the outcome matches the table for every pre-state × force. | `symlink` | ownership, idempotence |
| `P8` interrupted link | Fault after temp creation → dest unchanged, no temp left. | `symlink` | atomic-visibility |
| `P9` exclude idempotence | N calls append at most one line; never writes outside `commondir/info/`. | `symlink` | exclude-idempotence, no-collateral-damage |
| `P10` sync respects local state | On random local states, only clean + fast-forward changes anything. | `git` | no-lost-work |
| `P11` source-add clone failure | Injected clone failure leaves config bytes unchanged. | `main`/`config` | failure-atomicity |
| `P12` repair on upstream moves | Relinks only on a unique same-name match; else reports dangling. | `Registry` | repair-preserves-identity, confinement |
| `P13` registry round-trip | Save→load round-trip; duplicates collapse; other-host entries untouched. | `Registry` | soundness, host-portability (`H4`) |
| `P14` allocation-failure safety | `checkAllAllocationFailures` over save/scan/link/repair → no leaks, no temps, byte-identical files. | all | no-leaks, OOM-safe, atomic-visibility, failure-atomicity |
| `P15` diagnostic/exit-code table | Every error has a message and an exit code (comptime-enforced). | `main` | exit-status |

## Failure injection

`P8` and `P11` use a comptime-disabled `Fault` hook (compiled in only under `builtin.is_test`) at named points: `after_tmp_symlink`, `before_rename`, `after_clone`, `before_config_save`.

## Unit-test classes

Beyond the properties, example-based unit tests are allowed only in these classes (each carries a one-line tag naming its class):

- **Pinned regression**: A minimal counterexample a property shrank to.
- **Illustrative table**: README-documented behaviour shown as a table.
- **Un-generatable**: A specific `libgit2` error code, `EACCES`, the `root`/`sudo` check, or another environment-dependent path.
