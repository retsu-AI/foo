{ pkgs }:
pkgs.writeShellApplication {
  name = "foo-fmt";
  runtimeInputs = [
    pkgs.findutils
    pkgs.nixfmt
  ];
  text = ''
    nixfmt "$@" flake.nix
    find nix -type f -name '*.nix' -exec nixfmt "$@" {} +
  '';
}
