# HTTP transport

F01 implements `foo.io.HttpTransport` for providers and MCP. It uses a caller-driven
libcurl multi handle and HTTP/1.1. The caller supplies the method, URL, headers,
body, response sink, and operation context. The caller interprets HTTP status
codes and decides whether to retry or follow a redirect.

## Ownership

Initialize one `Runtime` for the process and hold it until all clients have shut
down. Create a `Client` with `runtime.client(allocator, io, options)`. Each client
copies its CA and proxy settings and keeps a pool of up to four idle
connections. Keep the client at a stable address after obtaining
`client.interface()`. Use one active exchange per client.

```zig
const runtime = try foo.transport.Runtime.init();
defer runtime.deinit();
var client = try runtime.client(allocator, io, .{});
defer client.deinit();

const transport = client.interface();
var delivery: foo.io.Delivery = .unsent;
try transport.exchange_fn(transport.context, operation, request, sink, &delivery);
```

The request and its source live through the exchange. The response sink borrows
the headers and body chunks for the duration of each callback. A blocking sink
applies backpressure directly. The transport reads an upload source into
libcurl's buffer and passes response chunks directly to the sink. A known-length
source must supply the declared bytes. An unknown-length source ends at EOF.

Call `Client.deinit` after the exchange returns. To stop an active exchange,
request cancellation and wait for it to return before shutting down the client.
The event loop checks cancellation and the absolute deadline between network
operations and at callbacks. Each network poll uses a timeout of at most 20 ms.
The caller must also honor the context during blocking callbacks. Exchange cleanup removes
the easy handle before freeing callback state. Client shutdown closes the pool.

## HTTP behavior and limits

- Methods are GET, POST, and DELETE. The request-byte limit applies to the
  upload payload. The request supplies the maximum response payload size.
- Request header limits apply to caller-supplied fields. Response header limits
  include proxy CONNECT headers, interim and final headers, status lines, and trailers. The sink
  receives one final response head, then the body. libcurl removes transfer
  framing and leaves content encodings for the caller.
- The transport accepts absolute HTTP and HTTPS URLs up to 8 KiB. It rejects
  embedded credentials, fragments, and caller-supplied framing or hop-by-hop
  headers. The transport owns the authority and framing headers.
- A redirect reaches the sink as a 3xx response. Every exchange permits one
  origin request attempt, including on reused connections. `Delivery` becomes
  `possibly_sent` just before the origin request can leave the client. A
  connection or TLS failure before that point leaves it `unsent`.
- Request validation returns `InvalidInput`. Size limits return
  `LimitExceeded`. `Client.init` returns `Unavailable` when the platform
  root store is empty.
  Connection loss and premature EOF return `Disconnected`. TLS validation and
  other backend failures return `IoFailure`. The adapter passes through errors
  from the caller's source and sink. It returns no native error text.

## Proxy and TLS

| Option | Behavior |
| --- | --- |
| Direct | The default. Proxy environment variables are ignored. |
| Explicit HTTP proxy | Uses CONNECT, with optional Basic credentials scoped to the proxy. The caller receives only the origin response. Basic credentials travel in plaintext to an HTTP proxy. |
| Platform trust | The default, `.trust = .platform`. `Client.init` reads the platform root store once with `std.crypto.Certificate.Bundle.rescan`: the Linux bundle paths, the macOS system keychain, or the Windows `ROOT` store. The client checks both certificate trust and hostname. |
| Explicit PEM trust bundle | `.trust = .{ .pem = bytes }` replaces the platform roots. The client accepts at most 2 MiB. |
| Environment CA overrides | The transport ignores them. The app calls `trust.override`, which picks `FOO_CA_FILE`, then `SSL_CERT_FILE`, and passes that file as a PEM bundle. The focused OpenSSL build uses only the roots the client holds. |

## Build and verify

Use Zig 0.17.1. The Nix shell sets `FOO_TRANSPORT_PREFIX` to the pinned native
dependency profile. Run both transport build modes against loopback peers.

```sh
nix develop .#ci -c zig build test -Dmodule=transport
nix develop .#ci -c zig build test -Dmodule=transport -Doptimize=ReleaseSafe
nix develop .#ci -c zig build check
```

Outside Nix, use the same dependency pins and the native profile builder.
The Nightly workflow provisions the compiler and runs the suite on native Linux
x86_64, macOS arm64, and Windows x86_64. The bootstrap-only gate is
`zig build check-bootstrap`. [Native CI workflow](../../.github/workflows/nightly.yml).

Each native job passed all 14 transport fixtures in Debug and ReleaseSafe.
The suite covers fixed-length and chunked uploads, TLS trust and hostname
checks, proxy scoping, lost replies, stalled TLS and body reads, deadlines,
and bounded buffering.

| Target | Tested revision | Evidence |
| --- | --- | --- |
| Linux x86_64 | `26caf4f8886bed6629253540dac5a8c35d5aa774` | [Native Linux job](https://github.com/retsu-AI/foo/actions/runs/45228122873/job/137880050699) |
| macOS arm64 | `26caf4f8886bed6629253540dac5a8c35d5aa774` | [Native macOS job](https://github.com/retsu-AI/foo/actions/runs/45228122873/job/137880051290) |
| Windows x86_64 | `f92d89ee27520b4bb49f24eda862f3f2db6b08ee` | [Native Windows job](https://github.com/retsu-AI/foo/actions/runs/45224884469/job/137868793238) |

The revisions have identical transport source and build settings. The later
revision closes the ephemeral socket before testing connection refusal.
[Fixture diff](https://github.com/retsu-AI/foo/compare/f92d89e...26caf4f).

The native library profile pins libcurl 8.23.0 (curl license), c-ares 1.34.9
(MIT), and OpenSSL 3.5.9 (Apache-2.0). Update the pins together with the focused
build settings and renew the native fixtures after a change. Release packaging
owns redistribution notices and the finally shipped dependency footprint.
[Source pins](../../nix/transport-sources.json).

On Linux x86_64, the focused Nix `libcurl.so.4.8.0` is 715,256 bytes. The linked
c-ares, libssl, and libcrypto files add 9,396,984 bytes. The libcurl runtime
output has a 48,692,320-byte Nix closure including glibc and its dependencies.
The development prefix also has headers, tools, and documentation. These
numbers describe the Nix profile. The release candidate has its own footprint.

```sh
nix develop .#ci -c sh -c '
  lib=$(readlink -f "$FOO_TRANSPORT_PREFIX/lib/libcurl.so")
  stat -c "%s %n" "$lib"
  sha256sum "$lib"
  ldd "$lib"
  nix path-info --json-format 2 --json --closure-size "$(dirname "$(dirname "$lib")")"
'
```
