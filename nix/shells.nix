{
  pkgs,
  toolchain,
  tools,
  formatter,
  transport,
}:
let
  common = [
    toolchain.zig
    tools.docs
    formatter
  ]
  ++ tools.workflow
  ++ tools.nix;
  cacheEnvironment = ''
    export ZIG_GLOBAL_CACHE_DIR="''${ZIG_GLOBAL_CACHE_DIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/zig}"
    export ZIG_LOCAL_CACHE_DIR="''${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache}"
  '';
in
{
  default = pkgs.mkShellNoCC {
    name = "foo-dev";
    packages = common ++ [ toolchain.zls ] ++ tools.interactive;
    FOO_TRANSPORT_PREFIX = transport;
    shellHook = cacheEnvironment;
  };
  ci = pkgs.mkShellNoCC {
    name = "foo-ci";
    packages = common;
    FOO_TRANSPORT_PREFIX = transport;
    shellHook = cacheEnvironment;
  };
}
