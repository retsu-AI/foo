# Reference evidence and lessons

This is a source-based comparison made on 2026-11-16 for the foo rebuild plan. It describes local checkouts, not current upstream releases. No reference binary was built, benchmarked, or exercised against a live provider during this analysis. Performance implications are hypotheses to test, not measured speed comparisons.

The task is to build a small configurable Zig harness, with Linux/macOS/Windows support, CLI, a simple TUI, the requested API families, MCP client support and an ACP agent. The references help identify useful mechanisms and costly scope. They are not feature-parity targets.

## Inspected snapshots

| Project | Local checkout | Git HEAD | State observed |
| --- | --- | --- | --- |
| QQ | `/home/zmeyer/Development/repos/github.com/retsu-AI/qq` | `a88eec8421c822cbeaa7d8333a1a0a04f7ddc908` | Clean; latest commit dated 2026-11-15 |
| FX | `/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/fx` | `f4d94b8acd3470d69a075ef4abe8c3c5a3c4cf7f` | Clean |
| PI | `/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/pi` | `742d49fcd8c51c90bbef704dc0f1a1c326bef728` | Clean |

Links below point to the inspected local files. Line anchors describe those snapshots and may drift after updates. These external absolute links are evidence-navigation aids for this workspace; the plan itself is portable without them.

## Scope measurements

Physical line counts include blank lines and comments. The scopes differ, so the table is deliberately not a normalized language-efficiency comparison.

| Scope | Files | Physical lines | Method and qualification |
| --- | ---: | ---: | --- |
| QQ tracked Rust | 361 | 287,318 | `git ls-files '*.rs'`, exclude `.source/`, `wc -l`; includes tests and benches |
| QQ core crate | — | 140,284 | Same inventory, filter `crates/qq-core/`; includes tests |
| QQ TUI crate | — | 36,723 | Same inventory, filter `crates/qq-tui/`; includes tests |
| QQ configuration crate | — | 12,197 | Same inventory, filter `crates/qq-config/`; includes tests |
| QQ provider crate | — | 19,446 | Same inventory, filter `crates/qq-provider/`; includes tests |
| FX `src` Zig | 740 | 822,212 | Tracked `src/*.zig` and `src/**/*.zig`; includes inline tests, comments and generated data |
| PI `packages/agent/src` | 6 | 2,548 | TypeScript source only; excludes separate tests |
| PI `packages/coding-agent/src` | 265 | 78,804 | TypeScript source only; excludes separate tests |
| PI `packages/tui/src` | 46 | 20,062 | TypeScript source only; excludes native code/assets and separate tests |
| PI `packages/ai/src` | 211 | 29,105 | TypeScript source including generated model metadata; excludes separate tests |

QQ's lockfile contains 513 package records, 500 with external sources. These include optional features, platform variants and development dependencies; they are not 500 runtime dependencies. FX declares no Zig package dependencies in [build.zig.zon](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/fx/build.zig.zon:28), but that does not count code it implements or vendors itself. PI's small agent package and much larger coding application demonstrate why comparing monorepo totals would obscure the actual harness.

These counts identify maintenance surface and investigation scope. They do not establish allocation rate, startup time, task success or runtime efficiency. Tests are valuable code, and generated tables are not equivalent to handwritten product logic.

## QQ: useful reliability work inside a much broader product

QQ is a local-first Rust application with a shared runtime, TUI, CLI and HTTP/SSE server. Its default local TUI uses the same network interface as remote clients. The code reserves or discovers a server, opens a runtime, starts a server and starts the TUI client in [main.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/src/main.rs:719). This supports QQ's product, but foo does not need that local network seam.

The current runtime owns run admissions, side-query permits, checkpoints, worktree paths, child permits, approvals, steering, cancellations and lifecycle locks in [sessions/runtime.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-core/src/sessions/runtime.rs:333). The 3,416-line turn loop directly handles child delivery, final-answer audits and child budgets in [run_loop.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-core/src/runtime/run_loop.rs:2419). This is concrete evidence of orchestration responsibilities in the implementation, not a claim that every feature is enabled on every run.

Configuration spans nine precedence layers, including organization manifests, directory fragments, managed files and MDM in [configuration.md](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/docs/guide/configuration.md:22). The TUI carries Markdown parsing and numerous syntax-highlighting grammars in its [manifest](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-tui/Cargo.toml:9). The binary enables AWS Bedrock by default in [Cargo.toml](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/Cargo.toml:165). Those capabilities are valid product choices; they are unnecessary compulsory scope for foo.

QQ also already documents a useful external-host contract: a supervisor owns scheduling, isolation, repository setup, independent verification and retries across attempts, while the harness exposes argv/environment inputs and JSONL/exit-status outputs. See [headless-contract.md](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/docs/design/headless-contract.md:25). foo should make that separation stricter and remove the internal multi-agent product concepts.

### What went wrong historically

QQ's current plan explicitly says the listed pre-v0.1.10 gaps have since been fixed: [README.md](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/docs/plans/README.md:41). The following are historical findings recorded by the repository, not newly reproduced defects in the inspected HEAD.

- The former copied workspace omitted `.git` and ignored build caches, disabled networking, made HOME read-only and deferred publication of edits. The model did not receive a concrete explanation of those restrictions. Ordinary Git, dependency fetching and cached builds therefore behaved differently from the user's terminal. Evidence: [README.md](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/docs/plans/README.md:46).
- The former reviewer did not receive the user's actual request. It could reject a push the user had authorized because it lacked that context. Historical mixed-build records counted 127 of 490 runs paused for approval, mostly around Git/GitHub operations. These are diagnostic counts, not task-success rates. Evidence: [README.md](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/docs/plans/README.md:69).
- Approximately 28k containment-related lines including tests were later removed. This is a repository-reported historical size, not a fresh count of deleted source. Evidence: [README.md](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/docs/plans/README.md:94).
- Argument-shape failures, repeated identical errors, long-command timeouts, stale/ambiguous edits and DiskFull appeared in the historical records. They show why tool contracts and lifecycle correctness matter to completed work. They do not prove that additional orchestration caused every failure.

The interpretation for foo is that execution behavior must match its declared contract, hidden review/model work adds failure modes, and a language rewrite cannot fix scope or authority confusion by itself. Do not reintroduce copied workspaces, per-action reviewer models or a shell-intent classification engine.

### Retain from QQ

- A small provider seam: `stream(ModelRequest)` in [provider/lib.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-provider/src/lib.rs:49).
- Bounded provider wire/output sizes and fragmentation tests in [limits.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-provider/src/limits.rs:5) and [sse.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-provider/src/sse.rs:350).
- Commit-before-publication semantics in [streaming.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-core/src/sessions/streaming.rs:15).
- Truthful file-edit outcomes, including explicit `partial_apply` rather than pretending multi-file atomicity, in [edit.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-core/src/tools/edit.rs:387).
- Long commands with owned handles and cancellation in [commands.rs](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/crates/qq-core/src/tools/commands.rs:12).
- Acceptance tasks based on observed failures, independently verified outside the agent, in [README.md](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/docs/plans/README.md:148).

## FX: direct Zig feasibility and the cost of owning infrastructure

FX uses Zig and declares an empty package dependency table, but it is a broad agent application rather than a tiny harness. Its API-family configuration maps Responses, Chat Completions and Anthropic Messages explicitly in [configured_provider.zig](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/fx/src/core/config/configured_provider.zig:50). It separates codec-owned request fields from configurable fields and represents credentials as references. This is a useful example for foo's provider configuration.

FX uses `std.http.Client` in [client.zig](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/fx/src/gateway/client.zig:1511). That demonstrates an implementation path, but the surrounding code illustrates the engineering burden: a separate ownership state machine lets a request abandon a DNS/connect operation while the worker remains responsible for its resources in [open_job.zig](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/fx/src/gateway/open_job.zig:1); connection/TLS cancellation has additional task handling in [client.zig](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/fx/src/gateway/client.zig:1347). These source facts motivate foo's early transport qualification gate. They do not prove that the pinned standard library is unusable or that libcurl is necessarily faster.

FX's recovery module has an especially clear seam: it takes state, an event and time, then returns a plan without I/O, allocation or global state in [recovery.zig](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/fx/src/core/recovery/recovery.zig:1). Borrow deterministic decisions and explicit effects. Do not copy its policy that only success or user cancellation finishes a request; the same file describes indefinite waiting/retry behavior. foo returns typed failures under finite configured retry limits.

Runtime configuration contains review controls, subagent authority evidence and persistent child capabilities in [config.zig](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/fx/src/core/agent/runtime/config.zig:59). The point is not that FX is badly designed; its product scope differs. Implementing similar scope in Zig would still create substantial product state and maintenance obligations.

Retain the explicit codec families, environment credential references, deterministic recovery decisions, careful resource ownership and tested Zig integration patterns. Avoid copying the application shell, delegation/review policies, broad session machinery or performance machinery before foo has measurements.

## PI: a small agent loop separated from a much larger coding application

PI's agent package is a useful conceptual reference because it accepts an injected model stream, messages and tool controls in [agent.ts](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/pi/packages/agent/src/agent.ts:115). The neutral agent state can start with no tools. The coding application composes substantially more behavior around it; the small core and large application should not be conflated.

The loop naturally stops after a response without tools or queued inputs. It also offers explicit continuation and follow-up hooks in [agent-loop.ts](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/pi/packages/agent/src/agent-loop.ts:250). Borrow the natural stop rule and injection seams; omit queues and continuation hooks that would recreate orchestration. The same code refuses every tool call from an output-limit response, even if partial JSON could be parsed. This is a direct regression fixture for foo.

The coding application's prompt composition and extension platform are larger than the neutral core. Its true prompt-replacement escape hatch bypasses composition in [system-prompt.ts](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/pi/packages/coding-agent/src/core/system-prompt.ts:194). foo should make exact replacement, including empty content, an ordinary explicit contract rather than an obscure advanced option.

PI has an inspectable JSONL session format, but its current loader skips malformed lines in [session-manager.ts](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/pi/packages/coding-agent/src/core/session-manager.ts:617). Its coding session emits to extensions/public listeners before appending completed messages in [agent-session.ts](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/pi/packages/coding-agent/src/core/agent-session.ts:1209). For foo, distinguish provisional display from committed state and report middle-of-file corruption rather than silently skipping records.

The generic event stream queues producer events without a visible bound in [event-stream.ts](/home/zmeyer/Development/repos/github.com/retsu-AI/qq/.source/pi/packages/ai/src/utils/event-stream.ts:3). This is an observed mechanism, not a measured production leak. It motivates explicit byte/count limits and slow-consumer tests. Similarly, neither shallow message copies nor TypeScript alone establish an allocation problem; benchmark actual serialization and rendering workloads before claiming a speed improvement.

Retain one state owner, injected provider/tool seams, exact stop reasons, tool-call ordering, simple optional persistence and render coalescing. Avoid embedded extension runtimes, package installation, arbitrary UI hooks, automatic prompt composition, implicit queues and silent recovery from corrupt evidence.

## Decisions derived from the comparison

| Evidence | foo decision | Acceptance implication |
| --- | --- | --- |
| QQ's local TUI communicates through its server | Direct local library calls | Same fake conversation produces equivalent CLI/TUI outcomes |
| QQ and FX contain internal child/review state | No orchestration concepts in core contracts | No child, goal, worktree or audit fields in F00 |
| PI separates a small loop from its coding application | Neutral core with optional preset | Empty tools/system prompt remain empty on the wire |
| FX has explicit API-family codecs | Three codecs and data-driven endpoints | Family conformance plus named endpoint qualification |
| FX owns complex cancellable connection state | Early std.http qualification; focused fallback if required | DNS/connect/TLS/body cancellation and teardown on all OSes |
| QQ commits before publishing durable events | Journal effect-boundary commits | Tool success followed by commit failure becomes uncertain |
| PI skips malformed journal lines | Distinguish torn tail from middle corruption | Corruption fixture cannot silently lose a record |
| PI exposes unbounded producer buffering | Bounded events and independent cancellation | Slow stdout/display consumer cannot cause unbounded memory |
| QQ historical failures involve tool/process behavior | Small schemas, accurate edits and owned commands | Invalid args, stale edits, long output and cancellation fixtures |
| All three have useful but broader product behavior | Finite first-release scope | MCP/ACP are adapters; additional orchestration stays external |

MCP and ACP support is an explicit user requirement, not a conclusion inferred from source-line counts. Current protocol research, chosen versions and compatibility claims are recorded in [Protocols](protocols.md). The design decision is to implement each as an adapter over the same contracts, preserving a small core.

The central conclusion is scope-related: a Zig rewrite can reduce deployment/runtime requirements, but it will not automatically remove product policy, protocol edge cases or process lifecycle work. foo's plan earns simplicity by excluding entire responsibilities while retaining the small set of correctness guarantees that every useful harness needs.
