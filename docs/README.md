# foo documentation

## Current implementation

The F00 bootstrap is committed at `55bd327`. It supplies shared Zig contracts, scripted test adapters, a minimal executable, build gates, and 13 contract tests. Only the `contracts` module has an implemented test suite. The agent loop, providers, tools, sessions, MCP, ACP, CLI, and TUI remain planned.

Native macOS and Windows qualification is pending. The configured CI matrix and cross-compilation do not establish native runtime acceptance or first-release completion.

| Document | Purpose |
| --- | --- |
| [Project README](../README.md) | Project entry point |
| [Shared contracts](../src/contracts/README.md) | Implemented interfaces, lifetimes, effect ordering, test commands, and current limits |
| [Nix environment](../nix/README.md) | Development shells, toolchain versions, and environment checks |
| [Continuous integration](ci.md) | Fast pull-request checks, nightly native coverage, and toolchain caches |

See [the agent workflow guide](pstack.md) for installation, usage, and maintenance of the shared pstack skills.

## Target design and decisions

These documents describe the accepted direction and proposed v1 behavior. They do not claim that the runtime exists.

| Document | Purpose |
| --- | --- |
| [Architecture](architecture.md) | Product boundaries, module ownership, and target runtime behavior |
| [Protocols](protocols.md) | Proposed MCP and ACP roles, pinned revisions, and capability requirements |
| [Testing and qualification](testing.md) | Proposed behavioral fixtures and first-release acceptance |
| [Architecture decisions](adr/README.md) | Lasting decisions, their alternatives, and consequences |

## Active v1 implementation plan

The [v1 plan](plan/README.md) remains active. It contains [execution and ownership rules](plan/execution.md), [reference evidence](plan/evidence.md), and the [work-package manifest](plan/work-packages.json). The [offline HTML view](plan/index.html) includes the complete plan documents, this index, the ADRs, and the package board.

Linear holds live assignments and workflow status. The local manifest records F00 as `review` because native qualification remains pending. F01 through F13 remain `planned`; their dependencies do not pass until F00 acceptance completes. The board is a dated local snapshot rather than a live Linear synchronization.

After the v1 candidate passes its required qualification, freeze the whole v1 plan and its self-contained HTML under `docs/archive/v1-plan/`. Snapshot every source in the builder's `DOCS` registry, including the architecture, protocol, testing, index, and decision documents. Preserve source-relative paths or record exact source paths and revisions in an archive manifest. Freeze those sources and the generated HTML together so later edits cannot rewrite the historical plan. Keep current documentation and later decisions outside the archive. No archive is created before qualification.
