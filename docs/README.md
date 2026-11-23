# foo documentation

## Current implementation

The reviewed F00 contract baseline is `55bd327`. It supplies shared Zig contracts, scripted test adapters, a minimal executable, and build gates. F01 adds a production HTTP and TLS transport, with a loopback suite and an explicit trust bundle. F02 adds bounded wire framing and JSON-RPC correlation. F03 adds the single-conversation core and its scripted suite. F04 adds streaming provider adapters for Responses, Chat Completions, and Anthropic Messages. F07 adds bounded in-memory sessions and a local append-only journal. The integrator owns registration of the core, provider, and session suites in the root build.

The [successful native Nightly run](https://github.com/retsu-AI/foo/actions/runs/43960887714) qualified the F00 bootstrap at `5c53fde07c0923ce914f9139dc21f43d3e5779da`. Its 13 contract tests and bootstrap behavior passed in Debug and ReleaseSafe on Linux x86_64, macOS arm64, and Windows x86_64. The Linux Nix checks also passed. This evidence completes F00; it does not qualify the planned runtime modules or the first release. Later contract changes require their own affected checks.

| Document | Purpose |
| --- | --- |
| [Project README](../README.md) | Project entry point |
| [Shared contracts](../src/contracts/README.md) | Implemented interfaces, lifetimes, effect ordering, test commands, and current limits |
| [HTTP transport](../src/transport/README.md) | Streaming, cancellation, proxy and TLS options, test commands, and dependencies |
| [Wire framing](../src/wire/README.md) | SSE, NDJSON, bounded JSON, and request correlation |
| [Conversation core](../src/core/README.md) | Run admission, tool and journal order, cancellation, and verification commands |
| [Provider adapters](../src/providers/README.md) | Streaming codecs, tool replay, usage, and retry policy |
| [Provider routes](../src/providers/routes.md) | Endpoints and credential settings for OpenAI, Anthropic, xAI, DeepSeek, LiteLLM, and Bedrock |
| [Session store](../src/session/README.md) | Journal format, writer ownership, recovery, artifact limits, and test commands |
| [Nix environment](../nix/README.md) | Development shells, toolchain versions, and environment checks |
| [Continuous integration](ci.md) | Fast pull-request checks, nightly native coverage, and toolchain caches |

See [the agent workflow guide](pstack.md) for installation, usage, and maintenance of the shared pstack skills.

## Target design and decisions

These documents describe the accepted direction and the remaining work for v1.

| Document | Purpose |
| --- | --- |
| [Architecture](architecture.md) | Product boundaries, module ownership, and target runtime behavior |
| [Protocols](protocols.md) | Proposed MCP and ACP roles, pinned revisions, and capability requirements |
| [Testing and qualification](testing.md) | Proposed behavioral fixtures and first-release acceptance |
| [Architecture decisions](adr/README.md) | Lasting decisions, their alternatives, and consequences |

## Active v1 implementation plan

The [v1 plan](plan/README.md) remains active. It contains [execution and ownership rules](plan/execution.md), [reference evidence](plan/evidence.md), and the [work-package manifest](plan/work-packages.json). The [offline HTML view](plan/index.html) includes the complete plan documents, this index, the ADRs, and the package board.

Linear holds live assignments and workflow status. The local manifest records F00 through F04 and F07 as `complete`. The other packages are `planned`. F05, F06, F08, F09, and F13 are ready to start. F10 and F11 still depend on F09. F12 waits for the remaining implementation packages.

After the v1 candidate passes its required qualification, freeze the whole v1 plan and its self-contained HTML under `docs/archive/v1-plan/`. Snapshot every source in the builder's `DOCS` registry, including the architecture, protocol, testing, index, and decision documents. Preserve source-relative paths or record exact source paths and revisions in an archive manifest. Freeze those sources and the generated HTML together so later edits cannot rewrite the historical plan. Keep current documentation and later decisions outside the archive. No archive is created before qualification.
