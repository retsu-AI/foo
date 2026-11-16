{ pkgs }:
let
  zigVersion = "0.17.1";
  zlsVersion = "0.17.0";
in
{
  zig =
    assert pkgs.lib.assertMsg (
      pkgs.zig_0_17.version == zigVersion
    ) "foo requires Zig ${zigVersion}; review the toolchain before changing the nixpkgs lock.";
    pkgs.zig_0_17;
  zls =
    assert pkgs.lib.assertMsg (pkgs.zls_0_17.version == zlsVersion)
      "foo requires ZLS ${zlsVersion}, compatible with Zig 0.17; review the toolchain before upgrading.";
    pkgs.zls_0_17;
  inherit zigVersion zlsVersion;
}
