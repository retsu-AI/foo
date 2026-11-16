{
  pkgs,
  toolchain,
  tools,
  formatter,
}:
let
  source = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.unions [
      ../flake.nix
      ./.
    ];
  };
in
{
  formatting = pkgs.runCommand "foo-nix-formatting" { nativeBuildInputs = [ formatter ]; } ''
    cd ${source}
    foo-fmt --check
    touch "$out"
  '';
  lint = pkgs.runCommand "foo-nix-lint" { nativeBuildInputs = tools.nix; } ''
    cd ${source}
    deadnix --fail flake.nix nix
    statix check .
    touch "$out"
  '';
  toolchain =
    pkgs.runCommand "foo-zig-toolchain"
      {
        nativeBuildInputs = [
          toolchain.zig
          toolchain.zls
        ];
      }
      ''
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
        export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
        test "$(zig version)" = '${toolchain.zigVersion}'
        test "$(zls --version)" = '${toolchain.zlsVersion}'
        zig test ${./tests/toolchain.zig}
        touch "$out"
      '';
  docs-tooling = pkgs.runCommand "foo-docs-tooling" { nativeBuildInputs = [ tools.docs ]; } ''
    python -c 'import markdown; assert "<table>" in markdown.markdown("| A | B |\n|---|---|\n| 1 | 2 |", extensions=["tables"])'
    touch "$out"
  '';
}
