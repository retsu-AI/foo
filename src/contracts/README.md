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

The core is still absent. `host.RunInput.services` explicitly injects the provider, optional store, host capabilities, and request preparation. The runner receives a result allocator. `io.Spawner` supplies owned independent stdin/stdout/stderr for MCP and executable tools; `host.Processes` models client terminal operations. MCP discovery, ACP negotiation, persistence files, configuration parsing, provider codecs, and process execution land in their assigned implementation modules.

`tests/contracts/protocol-pins.json` pins the selected MCP/ACP schema sources to immutable upstream commit URLs and SHA-256 hashes. These references are developer inputs for the protocol owners, not runtime downloads or a conformance claim. No upstream source is vendored here; preserve the upstream license if a later adapter vendors or generates code from those sources.

## Build and test registry

```sh
nix develop .#ci -c zig build
nix develop .#ci -c zig build check
nix develop .#ci -c zig build test -Dmodule=contracts
nix develop .#ci -c python tests/contracts/bootstrap.py
```

`zig build check` checks Zig formatting, compiles the executable, and runs the contracts suite. `zig build test-compile -Dtarget=...` compiles tests without running them and must be reported as compilation only. Debug and ReleaseSafe tests use the same contracts.

The module allowlist is in `build.zig`. Only `contracts` is implemented. All other named suites fail as unavailable; unknown names fail distinctly. `acceptance`, `acceptance-live`, `bench`, and `release` remain explicit failing targets until their owners supply real behavior. Future module owners provide a test root under `tests/<module>/`; the integrator registers it in the build and aggregate check. Test fakes are imported only by test roots, never by the executable/library.

Native qualification hosts are Linux x86_64 (`ubuntu-24.04`), macOS arm64 (`macos-15`), and Windows x86_64 (`windows-2022`). `.github/zig.json` records the official compiler archives and SHA-256 hashes. The CI installer verifies both archive content and compiler version, with no provider credentials. The native workflow runs contract tests and real executable checks; a configured workflow is not a successful hosted run. No remote is currently configured for this checkout, so hosted macOS/Windows results must be recorded separately when available.

## Dependency inventory

The Zig package has no external package dependencies and uses the Zig standard library. The bootstrap executable imports no test fakes and links no third-party library. Nix supplies development tooling; Python standard-library scripts install Zig in CI and verify the executable. Documentation generation uses Python Markdown separately. Native process, transport, and terminal dependencies remain decisions of the owning work packages, not bootstrap additions.
