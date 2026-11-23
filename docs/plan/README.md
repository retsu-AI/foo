# foo implementation plan

foo is a small, configurable agent harness written in Zig. The v1 target includes a CLI, a simple TUI, an MCP client for external tools and context, and an ACP agent interface for editors. One engine is planned to power every interface. Linux, macOS, and Windows are first-release targets.

The core runs one active model/tool loop at a time. Workflow policy, task verification, multi-agent coordination, worktrees, scheduling, and retries across independent attempts belong to applications around foo. Several engineering agents may build foo in parallel; that development workflow does not add orchestration to foo itself.

The v1 plan is active as of 2026-11-16. The reviewed F00 contract baseline is `55bd327`, with shared contracts, a minimal executable, scripted adapters, and build gates. The [native Nightly run](https://github.com/retsu-AI/foo/actions/runs/43960887714) qualified the bootstrap at `5c53fde07c0923ce914f9139dc21f43d3e5779da`, including its 13 contract tests and bootstrap behavior in Debug and ReleaseSafe on Linux x86_64, macOS arm64, and Windows x86_64. Linux Nix checks passed too. See [the documentation index](../README.md) for current implementation boundaries and [the shared contracts](../../src/contracts/README.md) for the implemented API.

The local board records F00 through F05, F07, and F09 as `complete`. The other packages are `planned`. F01 implements streaming HTTP and TLS. Its loopback suite passed in Debug and ReleaseSafe on all three native targets. [Transport handoff](../../src/transport/README.md). F02 provides bounded framing, JSON-RPC, and request correlation. [Wire handoff](../../src/wire/README.md). F03 provides the single-conversation runner. Its 26 scripted cases passed on Linux in Debug and ReleaseSafe. [Core handoff](../../src/core/README.md). F04 adds all three streaming provider codecs. Its 17 tests passed on Linux in Debug and ReleaseSafe. [Provider handoff](../../src/providers/README.md) · [Provider routes](../../src/providers/routes.md). F05 provides opt-in coding tools, configured executables, and native process ownership. [Tool handoff](../../src/tools/README.md). [Process handoff](../../src/platform/process/README.md). F07 adds bounded session storage and journal recovery. [Session handoff](../../src/session/README.md). F09 adds layered JSON configuration and redacted effective output. [Configuration handoff](../../src/config/README.md). Linear holds live status.

## Read the plan

Open [the complete HTML view](index.html) locally. It contains all six original plan documents, the documentation index, the ADRs, a searchable work-package board, a dependency map, and links to source material. It works without a web server, network connection, or JavaScript dependencies. JavaScript adds filtering and package selection; the full document remains available without it.

| Document | Purpose |
| --- | --- |
| [Architecture](../architecture.md) | Proposed product scope, module interfaces, configuration, engine behavior, tools, storage, memory ownership, and dependency decisions |
| [Protocols](../protocols.md) | Proposed MCP client and ACP agent roles, pinned revisions, transport and capability contracts, authentication, and interoperability |
| [Parallel execution](execution.md) | Work-package dependencies, path ownership, worktrees, integration, and agent handoffs |
| [Testing and release](../testing.md) | Proposed behavioral fixtures, native platform coverage, performance methodology, and first-release acceptance |
| [Evidence](evidence.md) | QQ, FX, and PI findings and the historical problems this design addresses |
| [Work-package data](work-packages.json) | Machine-readable task packets used by the HTML board |

## First-release scope

- One executable named `foo` and a reusable Zig module, sharing one execution engine.
- CLI, simple TUI, structured process input/output, and ACP over stdio.
- OpenAI Responses, OpenAI Chat Completions, and Anthropic Messages adapters, with configurable endpoints and xAI coverage.
- MCP servers over stdio and Streamable HTTP, with revision-specific behavior described in the protocol plan.
- Explicit JSON configuration, optional coding preset, configurable executable tools, bounded output, owned processes, cancellation, and optional durable sessions.
- Native qualification on Linux, macOS, and Windows.

MCP and ACP are required deliverables. Supported capability subsets are stated explicitly; optional protocol features are advertised only after implementation and qualification. Compatibility with an API family does not certify every vendor dialect or every optional feature.

## Start implementation

The [foo Linear project](https://linear.app/retsu-ai/project/foo-86eb1e09a2a5) contains all 14 work packages as ENG-1473 through ENG-1486. They were created unassigned in Backlog after the full plan was reviewed. Start dependencies are linked as blockers; F06/F05 and F13/F12 completion prerequisites are related issues with explicit acceptance requirements so early authoring can proceed. Linear holds live assignments and status; the local board is a planning snapshot, not a live synchronization.

[F00 / ENG-1473](https://linear.app/retsu-ai/issue/ENG-1473/f00-contracts-and-build-bootstrap), [F01 / ENG-1474](https://linear.app/retsu-ai/issue/ENG-1474/f01-http-and-tls-transport), and [F02 / ENG-1475](https://linear.app/retsu-ai/issue/ENG-1475/f02-sse-ndjson-and-json-rpc-framing) are complete. [F03 / ENG-1476](https://linear.app/retsu-ai/issue/ENG-1476/f03-single-conversation-core) landed in [PR #5](https://github.com/retsu-AI/foo/pull/5). [F04 / ENG-1477](https://linear.app/retsu-ai/issue/ENG-1477/f04-provider-adapters) landed in [PR #8](https://github.com/retsu-AI/foo/pull/8). [F05 / ENG-1478](https://linear.app/retsu-ai/issue/ENG-1478/f05-built-in-tools-and-process-ownership) adds local tools and process ownership in [PR #9](https://github.com/retsu-AI/foo/pull/9). [F07 / ENG-1480](https://linear.app/retsu-ai/issue/ENG-1480/f07-append-only-session-journal) landed in [PR #7](https://github.com/retsu-AI/foo/pull/7). [F09 / ENG-1482](https://linear.app/retsu-ai/issue/ENG-1482/f09-configuration-and-explicit-customization) landed in [PR #10](https://github.com/retsu-AI/foo/pull/10). Use **Ready to start** on the board to find packages with completed start prerequisites. F10 and F11 have their start prerequisites met. F12 waits for the remaining implementation packages. See [the execution plan](execution.md) for ownership and acceptance gates. Every packet in `work-packages.json` includes its Linear ID and URL, also shown on the HTML board.

The repository has an initial commit at `d40a049`, the reviewed F00 contracts at `55bd327`, and the natively qualified bootstrap at `5c53fde`. Create worktrees from an exact reviewed commit and preserve unrelated local work. New work requires its own check results; the baseline's 13-test result is evidence for that revision.

The first runtime slice must deliver a fake-provider-driven loop plus a real streaming request, one executable tool, and working cancellation. The first release also requires all three provider protocols in the integrated runtime, along with MCP, ACP, sessions, and the TUI. A successful early slice is not first-release completion.

## Maintain the plan and HTML

When a package lands, record its status and handoff in `work-packages.json`. Update the Markdown summaries and regenerate the page. Do not edit generated `index.html` directly. The builder validates identifiers, dependency cycles, completion prerequisites, and exclusive implementation-path ownership before writing the page.

```sh
nix develop .#ci -c python docs/plan/build.py
nix develop .#ci -c python docs/plan/build.py --check
nix develop .#ci -c python docs/plan/test_build.py
```

The builder uses Python and a pinned Markdown package solely for documentation generation. Those are not foo build or runtime dependencies. The generated HTML contains its own styles, script, documents, and work-package data. `--check` verifies that the committed page matches its sources without writing files.

`zig build check` runs the `contracts`, `transport`, `wire`, `tools`, `platform-process`, and `codemode` suites. The [testing plan](../testing.md#build-and-test-commands) lists commands for each suite. The core, provider, session, and configuration suites use package-local commands pending registration. The `acceptance`, `acceptance-live`, `bench`, and `release` targets are unavailable. Publishing a release requires separate authorization and qualification.

After required v1 qualification, freeze the whole v1 plan, every included source snapshot, and the self-contained HTML under `docs/archive/v1-plan/`. Until then this plan stays active. See [the documentation lifecycle](../README.md#active-v1-implementation-plan) for source paths and revision records.
