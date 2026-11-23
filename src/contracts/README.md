# Shared contracts

Import the public Zig module as `@import("foo")`. Module implementations depend on these contracts; the contracts do not import implementations. Shared changes belong to the integrator. Request a narrow prerequisite when an actual caller needs a change.

## Lifetimes and effects

`io.Context` borrows a host I/O implementation, monotonic clock, cancellation source, and absolute deadline. Install the cancellation wake callback before sharing the source. Requesting cancellation sets the flag once and wakes adapter-owned waits independently of output. The callback must be nonblocking and thread-safe. Adapters must wire it into their native I/O waits and join or explicitly transfer tasks before returning; merely setting the flag does not stop an operating-system call.

Configuration, requests, declarations, and prepared operations are immutable borrowed inputs until the adapter returns. Delta and HTTP callbacks borrow their data only for that callback. Consumers that retain data must copy within their resource budget.

Provider, tool, context-source, filesystem-read, process-output, and session-load results allocate all dynamic returned slices with the caller's result allocator. Use a caller-owned arena for each operation and destroy it after copying retained history. `provider.copyMessage` deep-copies completed blocks, including replay/signature bytes, into that arena. On allocation failure, discard the arena; no partial result is published. Static slices are also allowed. An adapter never returns decoder scratch or stores the result allocator beyond the operation.

Provider replay is tagged with family, endpoint, and model. Changing any requires a supported conversion or rejection. Unknown usage remains null. Normal completion, refusal, output limit, cancellation, and errors are distinct.

`session.Store.commit_fn` succeeds only after journal and referenced artifact synchronization. Its sequence identifies a committed semantic record. Display deltas have no sequence. Commit dispatch intent before an effect; commit the result before publishing it or admitting dependent effects. An intent without an outcome is uncertain and never automatically replayed. A failed outcome commit stops subsequent effects. The memory-only test journal exercises this ordering but does not claim disk durability.

Tool declarations are pinned for a run; a detected removal/schema change rejects affected calls with `catalog_changed`. Remote failures after possible delivery are uncertain results. Do not automatically retry tool dispatch. File/terminal host adapters do not silently fall back to local effects after a client denial or disconnection.

Cleanup uses a separate bounded I/O context so cancelling a run does not cancel its cleanup. Remote terminal cleanup after disconnection can be unconfirmed. The host owns that distinction.

## HTTP request bodies

`io.HttpRequest.body` is an `io.HttpBody`. `.bytes` borrows the complete byte slice and has an implicit length equal to the slice length. The default body is an empty byte slice. `.stream` borrows a `ByteSource` and has an optional `content_length` in bytes. The request, source context, and source-owned state remain alive until `HttpTransport.exchange_fn` returns.

The transport calls `ByteSource.read_fn` with nonempty caller storage. The source writes at most the supplied slice length and returns the number of bytes written. Zero means EOF, including when the stream is empty. The source must not retain the buffer or access it after the callback returns. The transport consumes or copies each chunk before reusing that storage.

A declared `content_length` is the exact wire body length. The transport never asks for more than the remaining length, stops without another source call when that length is reached, and leaves any later source bytes unread. A zero length makes no source calls. EOF before the declared length returns `error.IoFailure`. With no declared length, the transport reads until EOF. Source errors pass through unchanged. The transport does not materialize the entire stream or retain unbounded upload data.

An exchange consumes the source once. The transport never rewinds it or automatically replays a request, including byte bodies. The caller cannot reuse a partially consumed source without explicitly preparing a new operation. Cancellation and deadline checks apply to source reads and response callbacks. Source and sink callbacks must honor the supplied context and propagate failures. A failed or cancelled exchange can have consumed a prefix and can have reached the peer; `Delivery` records that uncertainty. After any exchange return, no source or sink callbacks or borrowed-buffer accesses remain active.

## Modules and fakes

| Export | Consumers | Meaning |
| --- | --- | --- |
| `io` | Transport, tools, sessions, protocols | Cancellation, time, byte bounds, sinks, HTTP exchange and delivery certainty |
| `config` | Every module | Immutable mechanical defaults, model/secret references, explicit precedence and protocol revisions |
| `provider` | Providers, core, sessions | Messages, tools, reasoning/replay, usage, streamed deltas and completed response |
| `tool` | Tools, MCP, core | Immutable tool generation, invocation/result/effect state, context discovery/retrieval |
| `events` | Core, frontends, sessions | Stable typed IDs, provisional deltas, committed records, terminal outcome |
| `session` | Sessions, core | Semantic commit/load and uncertainty report |
| `jsonrpc` | Wire, MCP, ACP | Typed IDs, envelopes, errors; absent ID is a notification |
| `host` | ACP, tools, core/frontends | Exact-operation permissions, file/terminal adapters, runner and request preparation |

`tests/support/root.zig` exports scripted `Clock`, `Bytes`, `Provider`, `Tools`, `Journal`, `Http`, `Process`, and `Editor` adapters. Templates and journal intent IDs are borrowed from the fixture and must outlive it. These are deterministic test collaborators, not production adapters. Their inputs must be bounded test fixtures; they are not schema validators or models of real process/network behavior.

`Http.upload` captures request bytes into caller-supplied `Bytes.buffer` storage and fails with `error.LimitExceeded` when that storage is full. Its default empty storage accepts only empty uploads. Stream reads use a fixed-size scratch buffer. The fake propagates upload source, capture, response head, and response body failures. It does not simulate networking, TLS, framing, or peer delivery.

The core is still absent. `host.RunInput.services` explicitly injects the provider, optional store, host capabilities, and request preparation. The runner receives a result allocator. `io.Spawner` supplies owned independent stdin/stdout/stderr for MCP and executable tools; `host.Processes` models client terminal operations. MCP discovery, ACP negotiation, persistence files, configuration parsing, provider codecs, and process execution land in their assigned implementation modules.

`tests/contracts/protocol-pins.json` pins the selected MCP/ACP schema sources to immutable upstream commit URLs and SHA-256 hashes. These references are developer inputs for the protocol owners, not runtime downloads or a conformance claim. No upstream source is vendored here; preserve the upstream license if a later adapter vendors or generates code from those sources.

## Build and test registry

```sh
nix develop .#ci -c zig build
nix develop .#ci -c zig build check
nix develop .#ci -c zig build test -Dmodule=contracts
nix develop .#ci -c python tests/contracts/bootstrap.py
```

`zig build check` checks Zig formatting, compiles the executable, and runs the contracts and transport suites. Use `zig build check-bootstrap` for contract checks without the transport profile. `zig build test-compile -Dtarget=...` compiles tests without running them and must be reported as compilation only. Debug and ReleaseSafe tests use the same contracts.

The module allowlist is in `build.zig`. `contracts` and `transport` are implemented. Other named suites fail as unavailable; unknown names fail distinctly. `acceptance`, `acceptance-live`, `bench`, and `release` remain explicit failing targets until their owners supply real behavior. Future module owners provide a test root under `tests/<module>/`; the integrator registers it in the build and aggregate check. Test fakes are imported only by test roots, never by the executable/library.

Native qualification hosts are Linux x86_64 (`ubuntu-24.04`), macOS arm64 (`macos-15`), and Windows x86_64 (`windows-2022`). `.github/zig.json` records the official compiler archives and SHA-256 hashes. The CI installer verifies both archive content and compiler version, with no provider credentials. The [Nightly workflow](../../.github/workflows/nightly.yml) runs native contract tests and real executable checks. The [F00 qualification run](https://github.com/retsu-AI/foo/actions/runs/43960887714) passed the 13-test bootstrap baseline at `5c53fde` in Debug and ReleaseSafe on all three hosts. The streamed-upload prerequisite landed at `23e40cd` with 19 tests verified by Linux checks; its [additional native run](https://github.com/retsu-AI/foo/actions/runs/43963806689) records the separate platform results. These contract tests do not qualify production networking or TLS. [The CI guide](../../docs/ci.md) describes the fast pull-request and broader qualification lanes.

## Dependency inventory

The Zig package has no external package dependencies and uses the Zig standard library. The bootstrap executable imports no test fakes and links no third-party library. Nix supplies development tooling; Python standard-library scripts install Zig in CI and verify the executable. Documentation generation uses Python Markdown separately. F01 links the transport module to libcurl when a caller uses it. [Transport handoff](../transport/README.md).
