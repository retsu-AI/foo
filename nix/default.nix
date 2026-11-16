{ nixpkgs }:
let
  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];
  perSystem = nixpkgs.lib.genAttrs systems (
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      toolchain = import ./toolchain.nix { inherit pkgs; };
      tools = import ./tools.nix { inherit pkgs; };
      formatter = import ./formatter.nix { inherit pkgs; };
    in
    {
      inherit formatter;
      devShells = import ./shells.nix {
        inherit
          pkgs
          toolchain
          tools
          formatter
          ;
      };
      checks = import ./checks.nix {
        inherit
          pkgs
          toolchain
          tools
          formatter
          ;
      };
    }
  );
in
{
  devShells = nixpkgs.lib.mapAttrs (_: config: config.devShells) perSystem;
  formatter = nixpkgs.lib.mapAttrs (_: config: config.formatter) perSystem;
  checks = nixpkgs.lib.mapAttrs (_: config: config.checks) perSystem;
}
