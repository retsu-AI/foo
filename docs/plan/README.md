# foo implementation plan

foo is a small, configurable agent harness written in Zig. The v1 target includes a CLI, a simple TUI, an MCP client for external tools and context, and an ACP agent interface for editors. One engine is planned to power every interface. Linux, macOS, and Windows are first-release targets.

The core runs one active model/tool loop at a time. Workflow policy, task verification, multi-agent coordination, worktrees, scheduling, and retries across independent attempts belong to applications around foo. Several engineering agents may build foo in parallel; that development workflow does not add orchestration to foo itself.

The v1 plan is active as of 2026-11-16. F00's bootstrap is committed at `55bd327`, with shared contracts, a minimal executable, scripted adapters, build gates, and 13 contract tests. The agent loop and remaining implementation packages are planned. Native macOS and Windows qualification is pending. See [the documentation index](../README.md) for current implementation boundaries and [the shared contracts](../../src/contracts/README.md) for the implemented API.

The local board records F00 as `review` and F01 through F13 as `planned`. F00 is not complete while required native qualification remains pending. Acceptance criteria are requirements, not passed checks. Linear holds live status.

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

The reviewed F00 contract baseline is `55bd327`. [F00 / ENG-1473](https://linear.app/retsu-ai/issue/ENG-1473/f00-contracts-and-build-bootstrap) remains in review until its remaining native qualification evidence passes. Follow-on packages start when their dependencies are complete, as defined in [the execution plan](execution.md). The integrator owns shared contracts and build registration; module agents own disjoint source and test paths. Every packet in `work-packages.json` includes its Linear ID and URL, also shown on the HTML board.

The repository has an initial commit at `d40a049` and the F00 bootstrap at `55bd327`. Create worktrees from an exact reviewed commit and preserve unrelated local work. Do not infer hosted CI success from committed workflow configuration.

The first runtime slice must deliver a fake-provider-driven loop plus a real streaming request, one executable tool, and working cancellation. The first release also requires the remaining provider adapters, MCP, ACP, sessions, and TUI. A successful early slice is not first-release completion.

## Maintain the plan and HTML

Edit the Markdown documents and `work-packages.json`, then regenerate the page. Do not edit generated `index.html` directly. The builder validates identifiers, dependency cycles, completion prerequisites, and exclusive implementation-path ownership before writing the page.

```sh
nix develop .#ci -c python docs/plan/build.py
nix develop .#ci -c python docs/plan/build.py --check
nix develop .#ci -c python docs/plan/test_build.py
```

The builder uses Python and a pinned Markdown package solely for documentation generation. Those are not foo build or runtime dependencies. The generated HTML contains its own styles, script, documents, and work-package data. `--check` verifies that the committed page matches its sources without writing files.

The bootstrap implements `zig build`, `zig build check`, and the `contracts` test suite. Other registered module suites, `acceptance`, `acceptance-live`, `bench`, and `release` fail explicitly as unavailable. Publishing a release requires separate authorization and qualification.

After required v1 qualification, freeze the whole v1 plan, every included source snapshot, and the self-contained HTML under `docs/archive/v1-plan/`. Until then this plan stays active. See [the documentation lifecycle](../README.md#active-v1-implementation-plan) for source paths and revision records.
