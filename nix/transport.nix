{ pkgs }:
let
  sources = builtins.fromJSON (builtins.readFile ./transport-sources.json);
  matches =
    package: source:
    package.version == source.version && package.src.outputHash == "sha256-${source.sha256}";
  curl =
    (pkgs.curlMinimal.override {
      c-aresSupport = true;
      opensslSupport = true;
      gssSupport = false;
      http2Support = false;
      http3Support = false;
      scpSupport = false;
      zlibSupport = false;
      brotliSupport = false;
      zstdSupport = false;
      idnSupport = false;
      pslSupport = false;
    }).overrideAttrs
      (old: {
        pname = "foo-transport-curl";
        patches = (old.patches or [ ]) ++ [ ./transport-curl-no-keylog.patch ];
        configureFlags = builtins.filter (flag: flag != "--with-ca-fallback") old.configureFlags ++ [
          "--without-ca-fallback"
          "--without-ca-bundle"
          "--without-ca-path"
          "--without-apple-sectrust"
          "--disable-ca-native"
          "--disable-ca-search"
          "--disable-openssl-auto-load-config"
          "--without-nghttp2"
          "--without-zlib"
          "--without-libgsasl"
          "--disable-threaded-resolver"
          "--disable-ftp"
          "--disable-file"
          "--disable-ipfs"
          "--disable-rtsp"
          "--disable-dict"
          "--disable-telnet"
          "--disable-tftp"
          "--disable-pop3"
          "--disable-imap"
          "--disable-smtp"
          "--disable-gopher"
          "--disable-mqtt"
          "--disable-unix-sockets"
          "--disable-digest-auth"
          "--disable-negotiate-auth"
          "--disable-ntlm"
          "--disable-bearer-auth"
          "--disable-aws"
          "--disable-cookies"
          "--disable-doh"
          "--disable-mime"
          "--disable-form-api"
          "--disable-netrc"
          "--disable-alt-svc"
          "--disable-hsts"
          "--disable-libcurl-option"
        ];
      });
in
assert pkgs.lib.assertMsg (
  matches curl sources.curl
  && matches pkgs.c-aresMinimal sources.c-ares
  && matches pkgs.openssl sources.openssl
) "Review the shared transport source pins when updating nixpkgs.";
pkgs.symlinkJoin {
  name = "foo-transport-${curl.version}";
  paths = [
    curl.dev
    (pkgs.lib.getLib curl)
  ];
}
