{
  description = "foo: a configurable Zig agent harness";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = { nixpkgs, ... }: import ./nix { inherit nixpkgs; };
}
