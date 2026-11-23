# Execution plan

This is a plan for building foo with parallel development agents. It does not add agents, scheduling, delegation, or orchestration to the foo runtime. Foo executes one configured conversation; a separate application may later coordinate multiple foo processes.

The machine-readable task inventory is [work-packages.json](work-packages.json). This dated local snapshot records F00 through F11 as `complete`. The other packages are `planned`. The reviewed F00 contracts are at `55bd327`. The [native Nightly run](https://github.com/retsu-AI/foo/actions/runs/43960887714) qualified bootstrap commit `5c53fde07c0923ce914f9139dc21f43d3e5779da`, including its 13 contract tests and bootstrap behavior in Debug and ReleaseSafe on Linux x86_64, macOS arm64, and Windows x86_64, plus Linux Nix checks. F01 implements HTTP and TLS and passed the loopback suite on Linux, macOS, and Windows in Debug and ReleaseSafe. [Native qualification results](../../src/transport/README.md#build-and-verify). F02 provides bounded stream framing and JSON-RPC correlation. [Wire handoff](../../src/wire/README.md). F03 implements the single-conversation runner. [Core handoff](../../src/core/README.md). F04 implements all three streaming provider codecs. [Provider handoff](../../src/providers/README.md). F05 implements opt-in local tools and owned child processes. [Tool handoff](../../src/tools/README.md). [Process handoff](../../src/platform/process/README.md). F07 provides in-memory sessions and a local journal. [Session handoff](../../src/session/README.md). F08 provides the ACP v1 stdio adapter. [ACP handoff](../../tests/acp/README.md). F09 resolves layered JSON settings. [Configuration handoff](../../src/config/README.md). F10 supplies the CLI adapter. [CLI handoff](../../src/cli/README.md). F11 supplies the TUI and native terminal adapters. [Native TUI fixtures](../../tests/tui/README.md).

All packages have issues in the [foo Linear project](https://linear.app/retsu-ai/project/foo-86eb1e09a2a5), ENG-1473 through ENG-1486. `dependencies` map to Linear blockers. `completion_dependencies` map to related issues and prominent completion criteria, preserving early authoring. The manifest carries the exact ID/URL mapping; Linear is authoritative for current assignment and workflow status. At creation every issue is unassigned in Backlog.

## Bootstrap constraints

The initial repository commit is `d40a049`. The reviewed F00 contract baseline is `55bd327`. Preserve unrelated local work and select an exact reviewed commit for each implementation worktree.

The bootstrap establishes shared interfaces without implementing the agent loop. Its [contract reference](../../src/contracts/README.md) records the API, test registry, and current limits. F00's native acceptance passed at `5c53fde`; follow-on work adopts that qualified baseline or a later reviewed prerequisite commit with its own affected checks.

```sh
git rev-parse --verify HEAD
git status --short
git worktree add .lane/trees/eng-1475 -b impl/F02 6e0105520ac38c1bdc60dd02a457fffbecdb82d9
```

Each active implementation agent gets one worktree and one assigned package. A worktree is not a claim of ownership: the package's path list is. Agents must not edit another package's files, inspect credentials, run live paid-provider tests without authorization, or broaden release scope because their local task has spare time.

## Non-negotiable first-release scope

The candidate must support CLI, simple TUI, MCP client over stdio and Streamable HTTP, and ACP agent over stdio on Linux, macOS, and Windows. These are implementation requirements, not stretch goals after a Linux release. The precise MCP revision profiles, ACP capabilities, and conformance fixtures are specified in [protocols.md](../protocols.md). The intended profiles are MCP 2026-07-28 and explicit legacy 2025-11-25; ACP uses stable protocol version 1, without adopting draft v2.

F00 records the concrete CPU/OS build matrix and native test hosts before implementation begins. The minimum is a native qualification host for each of the three operating systems. Additional architectures are declared separately; cross-compiling does not establish native process, terminal, TLS, or protocol support. If a required host or external test service is unavailable, the affected qualification remains incomplete rather than being silently removed.

## Shared interfaces and ownership

F00 implements the following shared contracts. The table summarizes their intended consumers; the [source contract reference](../../src/contracts/README.md) defines the current API and lifetimes.

| Contract | File | What callers must know |
| --- | --- | --- |
| Events | `src/contracts/events.zig` | IDs, byte deltas, owned final records, ordered committed events, explicit stop/error/cancel/limit outcomes |
| Provider | `src/contracts/provider.zig` | Caller-owned request preparation/context, capability validation, borrowed delta lifetimes, owned final records, usage, provider-specific opaque replay data |
| Tool and context | `src/contracts/tool.zig` | Registry/declaration, validated input, bounded output, typed outcomes, and `ContextSource` for explicit MCP resource/template/prompt access |
| I/O | `src/contracts/io.zig` | Cancellation, deadlines, bounded byte sources/sinks, backpressure, allocator/lifetime rules |
| Session | `src/contracts/session.zig` | Append/commit, transient versus committed output, resume and uncertain-effect outcomes |
| Configuration | `src/contracts/config.zig` | Resolved immutable configuration, provenance, explicit secrets references, validated protocol profile |
| JSON-RPC | `src/contracts/jsonrpc.zig` | Envelope, request IDs, response correlation, errors, lifecycle of cancellation |
| Host | `src/contracts/host.zig` | Host context ownership, ACP client filesystem/terminal/permission requests, and truthful unavailable capabilities |

The integrator owns these files, `src/main.zig`, `src/lib.zig`, all root build/toolchain files, shared fixtures in `tests/support/**`, and shared CI wiring. F00 and F12 intentionally have the same owner and run sequentially. Other packages must not modify these paths.

Each module owns its implementation and `tests/<module>/**`. Tests may use scripted provider, transport, tool, clock, journal, and ACP-client adapters from `tests/support/**`. F00 supplies only the small fakes needed for the agreed interfaces. Fakes must produce deliberate failures as well as success; they must not make an unimplemented production path look functional.

A new interface requirement becomes a narrow prerequisite change owned by the integrator: explain the concrete caller, update the contract and its tests, merge that commit, then have affected agents adopt its exact revision. Do not let each agent invent a slightly different `Event`, `CancelToken`, request ID, or buffer lifetime and reconcile it during final integration. Test-only helpers specific to one module remain in that module's test directory.

Ownership is exclusive while work is active. Shared-file overlap is allowed only through serial integrator changes. A package that needs an unowned path requests an explicit ownership update before editing it. Adding a new third-party dependency is a shared build decision and belongs to the integrator.

## Task states and dependency rules

The JSON `dependencies` array controls when a package may start. A package is ready only when it is `planned` and every dependency is `complete`. The board's Needs prerequisites filter includes only planned packages with an incomplete start dependency. Completed, active, and review packages are outside both availability filters. Recompute readiness after every accepted merge; do not infer it from a previous wave diagram.

`completion_dependencies`, when present, adds prerequisites for finishing a package. It does not prevent early fixture development. F06 can develop MCP against fake process I/O, but needs F05's real process ownership before its stdio completion gate. F13's test work may start after F00, but its final qualification cannot complete until F12's integrated candidate exists.

```text
ready(package) = package.status == planned
                 and every(package.dependencies, status == complete)

needs_prerequisites(package) = package.status == planned
                               and any(package.dependencies, status != complete)

finishable(package) = every(package.dependencies, status == complete)
                      and every(package.completion_dependencies, status == complete)
                      and every(package.acceptance, evidence accepted)
```

Use `in_progress` only after assignment and worktree creation; `review` means a concrete patch and handoff are ready; `complete` means the reviewed package was integrated and its package acceptance passed. `blocked` must name the missing prerequisite. A queued task, authored test, green fake test, merged module, cross-compiled binary, live protocol test, and qualified release are different evidence states.

The [work-package board](index.html#packages) computes availability using the manifest. F12 has its start prerequisites met. Linear holds current assignments and workflow state. F13 may author fixtures now, but remains incomplete until native and live qualification is done against F12's candidate. F12 produces a release candidate; it does not declare that release qualified or authorize publishing it.

## Build commands and remaining targets

Run project tools through `nix develop .#ci -c`. F00 establishes the command interfaces below with Zig 0.17.1. `zig build check` runs the `contracts`, `transport`, `wire`, `tools`, `platform-process`, and `mcp` suites. Add `-Dcodemode=true` to include Code Mode. The core, provider, session, ACP, configuration, CLI, and TUI suites use package-local commands pending registration. The qualification targets remain planned. An empty suite must never count as acceptance.

| Command | Owner and current status |
| --- | --- |
| `zig build check` | Integrator. Formatting, executable compilation, and all registered suites |
| `zig build test -Dmodule=contracts` | F00. Implemented shared-contract and scripted-fake tests |
| `zig build test -Dmodule=<module>` | Module owner. `contracts`, `transport`, `wire`, `tools`, and `platform-process` are available |
| `zig build acceptance` | F13. Unavailable; planned native offline fixtures and loopback peers |
| `zig build acceptance-live` | F13. Unavailable; planned opted-in interoperability with allowlist and spend cap |
| `zig build bench` | F13. Unavailable; planned repeatable measurements and raw results |
| `zig build release -Dtarget=<declared-target>` | F12. Unavailable; planned candidate archive and manifest |

F00 established the target interfaces. F01 registers the transport suite and its pinned native profile. Its module allowlist includes `contracts`, `transport`, `wire`, `core`, `providers`, `tools`, `platform-process`, `mcp`, `session`, `acp`, `config`, `cli`, `tui`, `platform-terminal`, and `integration`. The owning packages add their actual test roots; F12 completes packaging and CI. A module handoff runs its narrow suite. The integrator runs affected dependent suites after a merge and the full deterministic gate once per candidate. Live tests and benchmarks are opt-in lanes; ordinary edits must not depend on remote credentials or provider spending.

## Work packages

### F00 — Contracts and build bootstrap

**Owner:** integrator. **Start dependencies:** none. **Paths:** root Zig build/toolchain metadata, `src/main.zig`, `src/lib.zig`, `src/contracts/**`, `tests/contracts/**`, `tests/support/**`, and initial CI configuration. The existing Nix/environment files are changed only if explicitly included in reviewed implementation scope.

Deliver the pinned compiler/build setup, concrete OS/architecture matrix, shared types, ownership/lifetime rules, fake adapters, test target registration, and a minimal executable that reports unsupported operations honestly. Freeze IDs, event ordering, cancellation, stop outcomes, output limits, provider replay preservation, tool failures, configuration precedence, and journal commit meaning. Capture the initial dependency inventory; no unused frameworks or placeholder packages.

Accept when a clean clone can build the bootstrap and run contract tests on the declared native hosts; fake adapters demonstrate cancellation, failure, and bounded output; unsupported modules cannot accidentally pass acceptance. Handoff includes the exact contract commit, target/compiler identifiers, interface examples, fixture entrypoints, and the module registry. F00 is intentionally serial and should settle the minimum interfaces before expanding implementations.

### F01 — HTTP/TLS transport

**Owner:** transport agent. **Dependencies:** F00. **Paths:** `src/transport/**`, `tests/transport/**`. **Consumes:** I/O and configuration contracts.

Implement outbound HTTP with TLS validation, proxy configuration where declared, connection reuse, streamed bodies, request/body/header limits, cancellation, deadlines, and normalized transport errors. Providers and MCP own protocol retry/reconnect policy; transport must not secretly retry requests that may have effects. If a mature transport library is selected, isolate its use here and measure its release footprint rather than reimplementing cryptography.

Accept with deterministic loopback fixtures for split bodies, slow consumers, certificate failures, redirects/credentials rules, timeout, cancellation, abrupt disconnect, and bounded buffering on all operating systems. The handoff documents allocation ownership, transport shutdown, proxy and CA behavior, dependency footprint, and verification. [Transport handoff](../../src/transport/README.md).

### F02 — Wire framing and JSON-RPC envelopes

**Owner:** wire agent. **Dependencies:** F00. **Paths:** `src/wire/**`, `tests/wire/**`. **Consumes:** I/O and JSON-RPC contracts.

Implement incremental SSE, NDJSON/stdio framing, bounded JSON decoding, JSON-RPC envelopes, request correlation, and protocol-neutral error parsing. MCP/ACP method names, lifecycle state machines, capabilities, and revision rules remain with their protocol modules. Provider codecs consume SSE without importing MCP.

Accept arbitrary byte splits, UTF-8 boundaries, CR/LF variants, comments/keepalives where applicable, multiple records per read, oversized/truncated/malformed records, duplicate/unknown IDs, and clean shutdown. Fuzz parser entrypoints with explicit allocation and nesting bounds. The handoff supplies a fixture corpus, fuzz inputs, and transport examples. [Wire handoff](../../src/wire/README.md).

### F03 — Single-conversation core

**Owner:** core agent. **Dependencies:** F00. **Paths:** `src/core/**`, `tests/core/**`. **Consumes:** events, provider, tool, I/O, and session contracts.

The module landed at `cd06f29`. All 26 scripted Runner tests passed in Debug and ReleaseSafe on Linux x86_64. The suite cross-compiled for macOS arm64 and Windows x86_64. The integrator owns public facade and root suite registration. Live provider replay and durable journal recovery require their respective adapters. [Independent verification](https://github.com/retsu-AI/foo/pull/5#issuecomment-7111671496). [Core handoff and test command](../../src/core/README.md#verification).

Implement one state owner for request → streamed reply → validated tool calls → results → next request. Natural stop returns control to the caller. Support explicit user input and cancellation with documented ordering, usage accounting, request/tool/output limits, and provider-native replay data. Provider calls, tools, storage, and output are injected through the frozen interfaces. No goals, planners, subagents, worktrees, routing agents, hidden continuation, or completion classifier.

Accept scripted runs for zero tools, repeated tool use, multiple tools, malformed calls, length-limited calls, denial, tool failure, transport failure, cancellation in each phase, and exactly one terminal run result. Never execute arguments from a truncated model message. Assert committed transcript order and no automatic replay of uncertain effects. Handoff includes state-transition traces and fake-provider cases consumed by CLI, TUI, and ACP.

### F04 — Provider adapters

**Owner:** provider agent. **Dependencies:** F01, F02. **Paths:** `src/providers/**`, `tests/providers/**`. **Consumes:** provider, events, I/O, and configuration contracts.

F04 landed at `ad6f06a`. It streams OpenAI Responses, OpenAI Chat Completions, and Anthropic Messages through F01 and F02. The codecs preserve opaque reasoning and signatures, report usage and stop reasons, and bound retries to eligible unsent requests. The route guide lists explicit endpoint, model, and API-key settings for xAI, DeepSeek, LiteLLM, and Bedrock. [PR #8](https://github.com/retsu-AI/foo/pull/8) · [Provider reference](../../src/providers/README.md) · [Provider routes](../../src/providers/routes.md).

All 17 provider fixtures passed in Debug and ReleaseSafe on Linux x86_64. The suite cross-compiled for macOS arm64 and Windows x86_64. A local LiteLLM Proxy 1.110.2 sent a tool result and the original thought signature back to a simulated Gemini upstream. The integrator owns CLI wiring and root test registration in F12. F13 owns authenticated hosted-provider runs and native platform qualification. [Test and probe commands](../../tests/providers/README.md) · [Independent verification](https://github.com/retsu-AI/foo/pull/8#issuecomment-7112971557).

### F05 — Built-in tools and process ownership

**Owner:** tools/process agent. **Dependencies:** F00. **Paths:** `src/tools/**`, `src/platform/process/**`, `tests/tools/**`, `tests/platform-process/**`. **Consumes:** tool, I/O, events, and configuration contracts.

F05 supplies an opt-in coding preset with `read`, `write`, `edit`, and `exec`. A host can also enable custom executable tools through the same registry. The registry validates the arguments and applies host permission policy before dispatch. Custom executables receive JSON on stdin. The native adapter owns child handles, captures stdout and stderr separately, and provides cancellation and cleanup. The file tools validate exact replacements against one snapshot and distinguish uncertain writes from effects that never started. [Tool handoff](../../src/tools/README.md). [Process handoff](../../src/platform/process/README.md).

Run the `tools` and `platform-process` suites for package acceptance. The native matrix covers Linux, macOS, and Windows in Debug and ReleaseSafe. F12 and F13 still require integrated candidate evidence, including native process cleanup from the supported frontends. The [Code Mode adapter](../architecture.md#local-code-mode) uses the same enabled tools.

### F06 — MCP client

**Owner:** MCP agent. **Start dependencies:** F01, F02. **Completion dependency:** F05. **Paths:** `src/mcp/**`, `tests/mcp/**`. **Consumes:** tool, I/O, configuration, JSON-RPC, and events contracts; F05 process ownership through the shared I/O contract.

Implement both required transports and both explicitly configured revision profiles in [protocols.md](../protocols.md). Own discovery/initialization, capability negotiation, tool listing/calling, resources/list, resources/templates/list, resources/read, prompts/list and prompts/get, content conversion, notifications, pagination, authentication handling, cancellation, and profile-specific session/subscription behavior. Use `ContextSource` in the tool contract for explicit resource/template/prompt access. Pin advertised schemas per run; detected removals/changes block affected calls with `catalog_changed`, and replacements become visible next run. Map MCP tools into the same tool registry as local tools; avoid a second execution loop or a general plugin manager.

Accept an independent fake server matrix covering modern and legacy stdio/HTTP, malformed peers, interleaved messages, slow output, pagination, server death, auth failures, cancellation, reconnect rules, and duplicate-effect prevention. Test against the core/tool contract with fakes before the complete application exists. After F05, exercise real stdio child shutdown/reaping on all declared operating systems before completing F06. Handoff records the exact support matrix, unsupported optional features, transport assumptions, and live interoperability cases reserved for F13.

F06 implements both pinned revisions over stdio and Streamable HTTP. Its run catalog pins tool identities and schemas, and its context adapter retrieves resources and prompts on selection. Run `zig build test -Dmodule=mcp` in both build modes. The native workflow exercises real stdio on all three platforms. The Nix transport profile adds loopback HTTP and SSE. F13 owns external server interoperability. [MCP handoff](../../src/mcp/README.md).

### F07 — Append-only session journal

**Owner:** session agent. **Dependencies:** F00. **Paths:** `src/session/**`, `tests/session/**`. **Consumes:** session, events, I/O, and configuration contracts.

F07 landed at `4200b0e`. It provides bounded in-memory sessions and a versioned, single-writer JSONL journal with synchronized commits and session-relative artifacts. Recovery trims an incomplete final frame, rejects corrupt complete records, and reports unresolved tool effects. Display deltas remain provisional. [PR #7](https://github.com/retsu-AI/foo/pull/7) · [Session format and recovery](../../src/session/README.md).

All 15 session tests and five native process-crash scenarios passed in Debug and ReleaseSafe on Linux x86_64. The suite and crash probe type-checked for macOS arm64 and Windows x86_64. Native filesystem qualification on those platforms remains open. F12 owns root build registration and production wiring. [Test commands](../../src/session/README.md#verification-and-integration) · [Independent verification](https://github.com/retsu-AI/foo/pull/7#issuecomment-7112544500).

### F08 — ACP agent

**Owner:** ACP agent. **Dependencies:** F02. **Paths:** `src/acp/**`, `tests/acp/**`. **Consumes:** JSON-RPC, events, core/provider/tool contracts, and host contract.

F08 implements ACP v1 over stdio with session creation, streamed prompt updates, cancellation, and correlated errors. The adapter uses the shared runner contract and negotiates permission, filesystem, and terminal delegation with the client. [ACP handoff and native test commands](../../tests/acp/README.md).

The native pipe suite uses an independent mock editor and a scripted runner. F12 owns executable registration, the production session factory, and F06 MCP integration. F13 owns live editor interoperability.

### F09 — Configuration and explicit customization

**Owner:** configuration agent. **Dependencies:** F00. **Paths:** `src/config/**`, `tests/config/**`. **Consumes:** configuration and I/O contracts.

F09 landed at `89522cc`. Its JSON resolver applies deterministic precedence, tracks the source of each setting, and resolves paths relative to their source files. It supplies provider, prompt, tool, MCP, process, session, limit, and TUI settings. An empty prompt or tool list overrides an inherited value. Effective output redacts credential-bearing fields. [PR #10](https://github.com/retsu-AI/foo/pull/10) · [Schema and examples](../../src/config/README.md).

All 16 resolver tests passed on Linux in Debug and ReleaseSafe. The direct suite includes a redacted effective-config fixture. F10 owns CLI flag parsing, F11 consumes the TUI settings, and F12 owns root registration and runtime wiring. [Configuration test commands](../../tests/config/README.md) · [PR checks](https://github.com/retsu-AI/foo/actions/runs/45269436321).

### F10 — CLI

**Owner:** CLI agent. **Dependencies:** F03, F09. **Paths:** `src/cli/**`, `tests/cli/**`. **Consumes:** core, configuration, events, I/O, and session contracts.

F10 landed at `f09ef84`. It provides callable entrypoints for one-shot prompts, stdin, explicit journal resume, and config check and show. Its duplex JSONL protocol correlates prompt and cancel commands, rejects busy prompts, and drains a terminal result when output can deliver it. The command reader handles cancellation while stdout is blocked. [PR #11](https://github.com/retsu-AI/foo/pull/11) · [CLI commands, protocol, and exit codes](../../src/cli/README.md).

All 18 CLI subprocess tests passed on native Linux x86_64 in Debug and ReleaseSafe. The fixture cross-built for macOS arm64 and Windows x86_64. Native execution on those platforms remains open. F12 owns production wiring and root test registration. F13 exercises the integrated executable on the declared native platforms. [Real-pipe test commands](../../src/cli/README.md#integration-and-verification).

### F11 — Simple TUI and native terminal support

**Owner:** TUI agent. **Dependencies:** F03, F09. **Paths:** `src/tui/**`, `src/platform/terminal/**`, `tests/tui/**`, `tests/platform-terminal/**`. **Consumes:** core, configuration, events, and I/O contracts.

F11 provides a transcript viewport, Unicode input editing, configured keys and colors, streamed tool and status updates, cancellation, and resize. Its native backend restores POSIX terminal and Windows console state. Redirected streams use plain text. The adapter projects events from the shared runner.

The native PTY and ConPTY fixtures exercise the standalone modules with a scripted runner. The driver captures VT streams and measures visible editor feedback and rendering bytes. F12 owns executable dispatch, runtime wiring, and module registration. F13 qualifies the integrated terminal experience. [Native tests and measurement commands](../../tests/tui/README.md).

### F12 — Integration and release candidate

**Owner:** integrator. **Dependencies:** F01–F11, all complete. **Paths:** `src/main.zig`, `src/lib.zig`, `build.zig`, `build.zig.zon`, shared root toolchain metadata, `src/contracts/**`, `tests/contracts/**`, `tests/support/**`, `.github/**`, `tests/integration/**`. **Consumes:** every delivered module interface.

Wire real providers, tools, journal, MCP, CLI/TUI/ACP, configuration, and native shutdown into one binary. Complete the declared build matrix, candidate archives/checksums/manifests, dependency/license inventory, and CI lanes. Fix module defects through the owning package; the integrator must not accumulate duplicate implementations in main. Native compile and deterministic smoke failures block the candidate.

Accept clean-clone candidate builds and deterministic integrated checks on Linux/macOS/Windows with required interfaces enabled. Verify no fake adapter is reachable in production, protocol/stdout channels are clean, and feature disablement removes work rather than merely hiding UI. Handoff an exact commit plus candidate hashes to F13. This package does not claim live interoperability, final performance acceptance, release qualification, or authorization to publish.

### F13 — Acceptance corpus and final qualification

**Owner:** validation agent. **Start dependency:** F00. **Completion dependency:** F12. **Paths:** `tests/acceptance/**`, `benchmarks/**`. **Consumes:** all frozen interfaces; early work uses fake adapters.

Start the acceptance fixtures and measurement scripts as soon as contracts exist. Cover one-shot answers, repository read/edit, tool failure, stream disruption, cancellation, resume, bounded output, MCP transports/profiles, and ACP lifecycle. Fixtures assert artifacts and terminal outcomes, not only event counts. Benchmark startup, idle RSS, incremental-stream cost, tool latency, long-session memory, TUI input/rendering, and journal costs separately from provider latency.

After F12, run offline acceptance against the exact candidate, native OS checks, opt-in real-provider/MCP/ACP interoperability, and controlled performance comparisons. Record host/compiler/build/fixture identities, repeated samples, raw data, resource limits, and external service versions. A cross-compile or mocked protocol run cannot satisfy a native/live criterion. Report failures and unavailable evidence explicitly; do not relax the target silently.

Handoff an exact-head qualification report with candidate checksums, pass/fail matrix, remaining limitations, and rerunnable commands. Any code change invalidates affected candidate evidence; retest the changed path and its dependents, then issue a new candidate identity. Publication is a separate owner action after F13 is complete.

## Example schedule with four development agents

Four concurrent agents is an illustrative team capacity, not a product limit or a required staffing level. These conservative waves are a legal schedule, not a duration estimate; readiness should be recomputed continuously to avoid idle slots.

| Wave | Agent A | Agent B | Agent C | Agent D |
| --- | --- | --- | --- | --- |
| 0 | F00 integrator | Review contract examples | Review native test matrix | Review acceptance corpus |
| 1 | F01 transport | F02 wire | F03 core | F09 configuration |
| 2 | F04 providers | F06 MCP | F08 ACP | F05 tools/process |
| 3 | F07 sessions | F10 CLI | F11 TUI | F13 fixture/benchmark authoring |
| 4 | F12 integrator | Review candidate | Review native checks | F13 prepares qualification |
| 5 | Resolve defects via package owners | Native qualification support | Live protocol support | F13 final qualification |

Wave 0 reviews are read-only; only the integrator writes shared files. Wave 2 starts only after its actual dependencies have completed, not because a calendar slot arrived. F13 can start earlier when capacity allows. Agent identities may rotate; one active owner per package and path remains the rule. Any corrections to previously completed modules are assigned back to a single owner, integrated, and requalified.

The important dependency chains include F00 → transport/wire → providers/MCP → F12 → F13, F00 → wire → ACP → F12 → F13, and F00 → core/config → CLI/TUI → F12 → F13. Their duration depends on real implementation and native-platform results. More agents cannot shorten the serial contract decisions or final integration/qualification merely by creating more branches.

## Handoff and integration procedure

Every package handoff contains:

1. Package ID, branch/worktree, contract baseline commit, and proposed integration commit.
2. Exact owned paths changed and any dependency changes; no unrelated files.
3. Observable behavior delivered, accepted input/output examples, and explicit limitations.
4. Commands run, platform/compiler/build identity, observed results, and raw output paths.
5. Contract assumptions, resource limits, cancellation/cleanup semantics, and failure cases exercised.
6. Tests or live/native checks still pending; a fake test is labeled fake.

The integrator reviews the patch, checks path ownership, adopts it on the reviewed base, runs the relevant dependent suites, and records the accepted commit. Resolve shared-interface conflicts before accepting downstream implementations. Do not batch incompatible interfaces and hope the final binary will reveal the difference.

Run broader checks only when a new change, failure, or unresolved concern warrants them. Do not repeat expensive live tests on every small edit. Conversely, do not treat previous qualification as valid after changing transport, process ownership, cancellation, journal recovery, or protocol framing.

The implementation stops when the required candidate is qualified and the owner has the concrete release artifacts and limitations. Optional orchestration, additional UI, providers, remote control, plugins, or compatibility imports become separate proposals rather than extending this rebuild indefinitely.
