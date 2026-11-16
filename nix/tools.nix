{ pkgs }:
{
  workflow = with pkgs; [
    git
    ripgrep
    jq
  ];
  nix = with pkgs; [
    nixfmt
    deadnix
    statix
  ];
  docs = pkgs.python3.withPackages (python: [ python.markdown ]);
  interactive = with pkgs; [
    gh
    uv
    hyperfine
  ];
}
