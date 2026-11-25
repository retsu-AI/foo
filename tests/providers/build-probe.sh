#!/bin/sh
set -eu

: "${FOO_TRANSPORT_PREFIX:?Run inside nix develop .#ci for the pinned transport}"
probe_output=${1:?Pass the output path for the provider probe}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

zig translate-c -lc -I "$FOO_TRANSPORT_PREFIX/include" \
    "$FOO_TRANSPORT_PREFIX/include/curl/curl.h" > "$scratch/curl.zig"
zig build-exe -lc -L "$FOO_TRANSPORT_PREFIX/lib" -lcurl \
    -rpath "$FOO_TRANSPORT_PREFIX/lib" "-femit-bin=$probe_output" \
    --dep foo --dep providers -Mroot=tests/providers/probe.zig \
    --dep curl -Mfoo=src/lib.zig \
    --dep foo --dep auth -Mproviders=src/providers/root.zig \
    --dep foo -Mauth=src/auth/root.zig -Mcurl="$scratch/curl.zig"
