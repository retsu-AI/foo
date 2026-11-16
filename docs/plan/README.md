# foo implementation plan

foo is a small, configurable agent harness written in Zig. It ships a CLI, a simple TUI, an MCP client for external tools and context, and an ACP agent interface for editors. The same engine powers every interface. Linux, macOS, and Windows are first-release targets.

The core runs one active model/tool loop at a time. Workflow policy, task verification, multi-agent coordination, worktrees, scheduling, and retries across independent attempts belong to applications around foo. Several engineering agents may build foo in parallel; that development workflow does not add orchestration to foo itself.

Status: implementation plan, prepared 2026-11-16. The repository has no harness implementation yet. Work-package status in this directory is authoritative only for this planning snapshot; acceptance criteria are future requirements, not passed checks.

## Read the plan

Open [the complete HTML view](index.html) locally. It contains all six documents, a searchable work-package board, a dependency map, and links to source material. It works without a web server, network connection, or JavaScript dependencies. JavaScript adds filtering and package selection; the full document remains available without it.

| Document | Purpose |
| --- | --- |
| [Design](design.md) | Product scope, module interfaces, configuration, engine behavior, tools, storage, memory ownership, and dependency decisions |
| [Protocols](protocols.md) | MCP client and ACP agent roles, pinned revisions, transport and capability contracts, authentication, and interoperability |
| [Parallel execution](execution.md) | Work-package dependencies, path ownership, worktrees, integration, and agent handoffs |
| [Testing and release](testing.md) | Behavioral fixtures, native platform coverage, performance methodology, and first-release acceptance |
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

Begin with [F00 / ENG-1473](https://linear.app/retsu-ai/issue/ENG-1473/f00-contracts-and-build-bootstrap) in [the execution plan](execution.md). F00 establishes shared contracts, the test fixtures, build targets, and the initial integration point. After it lands, several independent packages become ready. The integrator owns shared contracts and build registration; module agents own disjoint source and test paths. Every packet in `work-packages.json` includes its Linear ID and URL, also shown on the HTML board.

At the planning snapshot, `main` has no commit, and the existing Nix/environment files and root README contain user work. Worktrees require an actual initial commit. The integrator must review and preserve that work when establishing the first commit; these documentation changes do not create it or change the environment.

The first delivered slice is a fake-provider-driven loop plus a real streaming request, one executable tool, and working cancellation. The first release also requires the remaining provider adapters, MCP, ACP, sessions, and TUI. A successful early slice is not first-release completion.

## Maintain the plan and HTML

Edit the Markdown documents and `work-packages.json`, then regenerate the page. Do not edit generated `index.html` directly. The builder validates identifiers, dependency cycles, completion prerequisites, and exclusive implementation-path ownership before writing the page.

```sh
uv run docs/plan/build.py
uv run docs/plan/build.py --check
```

The builder uses Python and a pinned Markdown package solely for documentation generation. Those are not foo build or runtime dependencies. The generated HTML contains its own styles, script, documents, and work-package data. `--check` verifies that the committed page matches its sources without writing files.

Implementation acceptance commands shown elsewhere in this plan are proposed build targets that F00 must add. They are not available in the repository yet. Publishing a release or changing existing project infrastructure is a separate implementation action.
