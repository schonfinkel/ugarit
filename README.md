# Ugarit

[![Built with Nix](https://builtwithnix.org/badge.svg)](https://builtwithnix.org)
[![\[Nix\] Build and Test](https://github.com/schonfinkel/ugarit/actions/workflows/build.yml/badge.svg)](https://github.com/schonfinkel/ugarit/actions/workflows/build.yml)

Ugarit is a small CLI for discovering skills in Git repositories and linking them into the directories used by coding agents. It keeps one managed clone of each source, records links per host, and repairs links after upstream moves.

## Quick Start

Build with Nix:

```sh
nix build
./result/bin/ugarit --version
```

Try it without installing:

```sh
nix run github:schonfinkel/ugarit -- --help
```

### NixOS / Home Manager

Add the flake as an input (`ugarit.url = "github:schonfinkel/ugarit";`), then either
install it system-wide:

```nix
{
  imports = [ inputs.ugarit.nixosModules.default ];
  programs.ugarit.enable = true;
}
```

or per user, optionally managing `config.json` declaratively (`ugarit source-sync`
clones newly declared sources):

```nix
{
  imports = [ inputs.ugarit.homeManagerModules.default ];
  programs.ugarit = {
    enable = true;
    settings = {
      version = 1;
      default_search_path = ".agents/skills";
      sources = [{
        name = "skills";
        url = "ssh://git@my-awesome-forge.com/some-urser/some-repo.git";
        target = ".agents/skills";
      }];
    };
  };
}
```

`overlays.default` adds `pkgs.ugarit` for any other setup.

Or enter the development shell and build with Zig 0.16:

```sh
nix develop --impure
make
./zig-out/bin/ugarit --version
```

After changing `build.zig.zon`, regenerate and commit the Nix dependency lock:

```sh
nix run .#zig2nix -- zon2lock build.zig.zon
```

Register a skill repository, inspect its skills, and link one:

```sh
ugarit source-add https://github.com/example/skills.git
ugarit list
ugarit link skills my-skill ~/.claude/skills --mkdir
ugarit list my-skill --links
```

Update sources and repair links whose skill directories moved:

```sh
ugarit source-sync
```

Remove links by path or by skill name:

```sh
ugarit unlink ~/.claude/skills/my-skill
ugarit unlink --skill my-skill
```

### Properties

- Ugarit will not replace real files or directories. 
    - `--force` permits replacing another symlink, but never a real entry. 
- Links created inside a Git worktree are added to the repository's local `.git/info/exclude` unless `--no-exclude` is used, tracked paths are rejected.

## Commands

```text
source-add <url> [--name <name>] [--label <label>] [--path <dir>] [--target <dir>] [--no-claude-sync] [--ref <ref>]
source-sync [name]
link <source|label> <skill> <dest-dir...> [--as <name>] [--force] [--mkdir] [--no-exclude]
unlink <link-path>...
unlink --skill <name>
list [skill] [--source <name>] [--links]
```

See [`docs/GUIDE.md`](docs/GUIDE.md) for configuration, command semantics, Git behavior, troubleshooting, and development workflows.
