{
  description = "Ugarit Development shell";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";

    flake-parts.url = "github:hercules-ci/flake-parts";

    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix.url = "github:numtide/treefmt-nix";

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mk-shell-bin.url = "github:rrbutani/nix-mk-shell-bin";
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.devenv.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      systems = nixpkgs.lib.systems.flakeExposed;

      perSystem =
        { pkgs, lib, ... }:
        let
          zonVersionPattern = ''[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*,[[:space:]]*'';
          zonVersionMatches = builtins.filter (match: match != null) (
            map (line: builtins.match zonVersionPattern line) (
              lib.splitString "\n" (builtins.readFile ./build.zig.zon)
            )
          );
          version =
            if builtins.length zonVersionMatches == 1 then
              builtins.head (builtins.head zonVersionMatches)
            else
              throw "build.zig.zon must contain exactly one .version = \"...\", line";

          zigVersion = pkgs.zig_0_16;
          zigDependencies = pkgs.callPackage ./build.zig.zon.nix { };
          staticTarget =
            lib.replaceStrings [ "-unknown-" ] [ "-" ]
              pkgs.pkgsStatic.stdenv.hostPlatform.config;

          toolPackages = with pkgs; [
            libgit2
            pkg-config
            git
            zon2nix
          ];

          # devenv wants an absolute path to the project root and cannot
          # derive one under `nix flake check`, where there is no working
          # directory. `--impure` lets it read PWD; the fallback keeps pure
          # evaluation from failing outright.
          devenvRoot =
            let
              r = builtins.getEnv "PWD";
            in
            if r != "" then r else builtins.toString ./.;
        in
        {
          # nix fmt + nix flake check (auto-wired by the treefmt-nix flakeModule)
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            programs.zig = {
              enable = true;
              package = zigVersion;
            };
          };

          # Hermetic build: Zig packages come from the generated linkFarm, not the network.
          packages = {
            default = pkgs.stdenv.mkDerivation {
              pname = "ugarit";
              inherit version;
              src = ./.;
              nativeBuildInputs = [
                zigVersion.hook
                pkgs.pkg-config
              ];
              buildInputs = [ pkgs.libgit2 ];
              zigBuildFlags = [
                "--system"
                (builtins.toString zigDependencies)
                "-Doptimize=ReleaseSafe"
              ];
            };
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            static = pkgs.pkgsStatic.stdenv.mkDerivation {
              pname = "ugarit-static";
              inherit version;
              src = ./.;
              nativeBuildInputs = [
                zigVersion
                pkgs.pkg-config
              ];
              buildInputs = [ pkgs.pkgsStatic.libgit2 ];
              dontConfigure = true;
              buildPhase = ''
                runHook preBuild
                export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
                zig build \
                  --system ${zigDependencies} \
                  -Dtarget=${staticTarget} \
                  -Dstatic=true \
                  -Doptimize=ReleaseSafe
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                install -Dm755 zig-out/bin/ugarit "$out/bin/ugarit"
                runHook postInstall
              '';
            };
          };

          checks.default = pkgs.stdenv.mkDerivation {
            pname = "ugarit-check";
            inherit version;
            src = ./.;
            nativeBuildInputs = [
              zigVersion
              pkgs.pkg-config
            ];
            buildInputs = [ pkgs.libgit2 ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR/home"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              mkdir -p "$HOME"
              zig build test \
                --system ${zigDependencies} \
                -Doptimize=ReleaseSafe \
                --summary all
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              touch "$out"
              runHook postInstall
            '';
          };

          # Bare minimum for CI. `nix develop .#ci`
          devenv.shells.ci = {
            devenv.root = devenvRoot;
            packages = [ zigVersion ] ++ toolPackages;
          };

          # The everyday shell. `nix develop --impure`, or direnv.
          devenv.shells.default = {
            devenv.root = devenvRoot;

            languages.zig = {
              enable = true;
              package = zigVersion;
              lsp.enable = true;
            };

            packages = toolPackages;

            enterShell = ''
              echo "Starting development environment..."
            '';
          };
        };
    };
}
