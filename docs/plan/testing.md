# Testing and first-release acceptance

foo is ready for its first release when its CLI, TUI, MCP client, and ACP agent use the same engine and meet their contracts on Linux, macOS, and Windows. Compilation, a scripted provider, a live model response, and task success are different kinds of evidence. Record each separately.

F00 provides common fake implementations and test commands. Each module owner adds behavior tests under its assigned directory. F13 may write end-to-end scenarios against those fakes in parallel, but final qualification depends on the integrated F12 release candidate. All requirements below are planned.

## Build and test commands

| Planned command | Purpose and owner |
| --- | --- |
| `zig build test -Dmodule=core` | Narrow behavior tests; F00 adds module selection and every owner supplies its tests |
| `zig build check` | Formatting, compilation, and deterministic test suite; integrator owns aggregate registration |
| `zig build acceptance` | Native offline CLI, process, journal, MCP, ACP, and terminal scenarios against fakes |
| `zig build acceptance-live` | Explicit provider/server/editor interoperability checks using an allowlist, credentials, and a spend ceiling |
| `zig build bench` | Separate reproducible performance measurements, not wall-clock assertions in unit tests |

Module selector names are `contracts`, `transport`, `wire`, `core`, `providers`, `tools`, `platform-process`, `mcp`, `session`, `acp`, `config`, `cli`, `tui`, `platform-terminal`, and `integration`. A missing module implementation is reported as missing; a placeholder or empty test target must not count as acceptance. Build registration changes belong to the integrator so agents do not edit the same build files.

The regular pull-request path runs deterministic checks and focused native tests. Schedule longer fuzzing, soak, and benchmark runs separately. Live endpoints must not be required for ordinary CI. Do not weaken a failed assertion or add a retry merely to obtain a green result.

## Core behavior fixtures

| Scenario | Required observation |
| --- | --- |
| Text-only response | Deltas arrive in order; one final outcome; no tool is invoked |
| Tool call and follow-up | Complete arguments validate before execution; result uses the original call ID; next request contains the correct tool pair |
| Multiple tool calls | Stable transcript order; every accepted call obtains a result or explicit skipped/cancelled result |
| Truncated or failed response | Incomplete arguments never execute; partial text remains provisional; provider reason is retained |
| Unknown or disabled tool | Typed tool error; no execution through an alternate dispatch path |
| Invalid arguments | Actionable error for that call; no unchecked field reaches the executor |
| Limit reached | No extra model/tool action after admission fails; outcome names the limit |
| Normal model stop | Loop returns without hidden continuation or review calls; it makes no claim that the user's task was achieved |
| Cancellation | Independent cancellation wakeup works while provider, tool, permission request, or output is waiting |
| Busy input | Second prompt is rejected with a correlated busy response; cancel remains accepted |
| Context exhausted | Explicit outcome and recoverable transcript; no silent summary, truncation, or invented token count |

Inject time and scripted transport responses. Test transitions and results through public interfaces. Use allocation-failure injection and leak detection to check ownership paths, including cancellation before and after handoff. A tool's error is not automatically a fatal harness error; the contract distinguishes recoverable tool feedback from process, storage, or protocol failure.

## Provider and transport fixtures

For every provider codec, split representative stream fixtures at every byte boundary and verify the same completed semantic messages. Include CRLF, fragmented UTF-8, multiple data lines, comments, keepalives, unknown extension events, malformed frames, output limits, refusals, usage updates, and a stream ending before its declared completion.

Exercise interleaved tool-call fragments and provider-owned replay items. Verify that replay metadata remains with the matching provider family and that unsupported provider/model changes fail visibly. Compare emitted requests against literal fixtures; checking only that JSON parses is insufficient.

Test connection refusal, DNS delay, certificate failure, configured custom certificate authorities, proxy authentication, HTTP errors, retry hints, first-byte timeout, stalled bodies, cancellation, and resource cleanup. Failed TLS validation must not trigger an insecure fallback. Credential headers must not be forwarded across an unapproved redirect or logged in diagnostics.

Retry tests assert which layer owns the retry, attempts remaining, deadline consumption, and definitely-unsent versus possibly-sent classification. A restarted request must not rerun previously executed local tools. When an HTTP library has internal retries, configure and account for them explicitly.

Live qualification records exact build, endpoint, protocol family, model, request options, tool schema, observed usage, date, and outcome for OpenAI, Anthropic, and xAI. Add representative custom/local compatible endpoints when available. This qualifies those combinations; it does not establish universal vendor compatibility.

## Tool and process fixtures

Exercise paths containing spaces, non-ASCII characters, long names, and platform-specific separators. Preserve explicit working directory and environment behavior. Verify quoting with argument vectors; shell syntax is tested only for a configured shell.

File cases include missing files, invalid encodings, ambiguous matches, stale content, permissions, symbolic links, concurrent external edits, and replacement failure. Assert exact changed bytes and unchanged files after rejection. Single-file atomic replacement must not be described as multi-file transactional behavior.

Run a command that produces output far larger than the model excerpt limit. Verify bounded memory, complete spooling up to the configured disk limit, byte offsets, truncation metadata, and accessible output. Test a full disk, invalid spill destination, and a reader that stops consuming output. Reaching a disk cap is visible and must not silently erase diagnostics.

Start ordinary child/grandchild processes and cancel the run. Assert native process-tree ownership and cleanup using process groups on POSIX and job objects or an equivalently qualified mechanism on Windows. Document limitations for descendants that deliberately escape ordinary process ownership; this mechanism is not a hostile-process sandbox.

Executable tool fixtures cover malformed JSON, missing results, duplicate results, mixed stdout diagnostics, nonzero exit, timeout, cancellation, and oversized stderr/stdout. A long-command handle cannot outlive its owning run without an explicit external owner, which v1 does not provide.

## Persistence failure fixtures

Persisted sessions use one writer, ordered semantic records, and a defined commit operation. Live display deltas do not imply durable state.

- Kill the process before tool intent, after committed intent, after the external effect, and after committed outcome. A missing outcome after intent is uncertain; no automatic replay occurs.
- Make a tool succeed and then fail the journal commit. Stop subsequent effects and report the uncertain durable outcome.
- Recover a torn trailing append according to the format rule. Reject corruption in the middle, unknown incompatible versions, oversized records, duplicate sequence numbers, and a second writer.
- Resume without interpreting incomplete assistant text or argument fragments as a completed response.
- Test file and directory synchronization semantics on supported native platforms. State the resulting durability guarantee; a successful write call alone is not proof of power-loss durability.
- Replay a long session while loading only the context and UI history actually needed. Old spill files and history must not all be retained in memory.

## MCP and ACP interoperability

The revision and capability matrix in [the protocol plan](protocols.md) is authoritative. Fixtures must encode the pinned revision, not a blend of similarly named methods from different revisions.

MCP tests cover both required transports and each supported revision profile. Verify discovery or initialization as appropriate, capability declarations, listing/pagination, namespaced tool IDs, structured/error content, resources/templates, explicitly selected prompts, cancellation, and bounded shutdown. Pin advertised tool schemas per run; a detected removal or schema change yields `catalog_changed` for affected calls, and additions/replacements appear only on the next run. An MCP tool result and a JSON-RPC transport error remain distinguishable.

Test protected HTTP endpoints with configured credentials and explicit unsupported-auth outcomes. Test server-originated input requests and nested model requests without advertising unsupported capabilities or creating an implicit second agent loop. Server text and prompt templates do not gain the authority to modify local permissions. A disconnect during a side-effecting tool call must not cause automatic redispatch.

ACP tests use a scripted editor client as well as at least one real compatible editor. Verify initialization, capability negotiation, session setup, a prompt with streamed updates, tool call status, permission request/response, cancellation, and the terminal prompt response. ACP stdout contains only valid protocol messages; diagnostics use stderr.

Test editor-provided filesystem and terminal capabilities. An editor denial or missing capability must not silently fall back to unrestricted local execution. Test editor-supplied MCP servers, including the advertised HTTP support and explicit rejection of unsupported transport variants. Session IDs select independent state but do not imply concurrent active loops: the v1 one-active-run contract remains in force.

Advertise optional features only after their exact behavior passes. In particular, session loading, image/audio content, legacy SSE transport, automatic authentication flows, and draft protocol revisions cannot be inferred from text/tools working.

## Native platform and TUI matrix

| Area | Linux | macOS | Windows |
| --- | --- | --- | --- |
| CLI and machine modes | Native shell/pipes | Native shell/pipes | Native console and redirected pipes |
| Processes | Process groups, signals, cleanup | Process groups, signals, cleanup | Native argument handling, control events, job cleanup |
| Persistence | Filesystem sync and locks | Filesystem sync and locks | Replacement, sharing modes, locks, sync |
| Transport | TLS trust, configured proxies, cancellation | TLS trust, configured proxies, cancellation | TLS trust, configured proxies, cancellation |
| TUI | PTY, resize, Unicode, paste, restoration | PTY, resize, Unicode, paste, restoration | Windows Terminal/console, resize, Unicode, paste, restoration |
| MCP and ACP | Native subprocess and HTTP fixtures | Native subprocess and HTTP fixtures | Native subprocess and HTTP fixtures |

Choose release architectures explicitly during F00; initial native qualification targets are Linux x86_64, macOS arm64, and Windows x86_64. Extra architecture builds are labeled separately until exercised on native hardware. Cross-compilation and emulation do not substitute for these native runtime checks.

The TUI must survive tiny terminals, rapid resize, long unbroken strings, combining marks, emoji, wide characters, bracketed paste, invalid input bytes, and cancellation during a redraw. Confirm restoration after normal exit, errors, and handled termination. Check text-only operation with `NO_COLOR` and redirected streams. Full terminal restoration after an uncatchable process kill is not promised.

## Performance methodology

| Metric | Initial engineering target |
| --- | --- |
| Warm help/version startup | p95 below 20 ms |
| Offline TUI first usable frame | p95 below 100 ms |
| Idle harness resident memory | Below 30 MiB, excluding child processes; report native platform differences |
| Local stream-to-display delay | p95 below 33 ms under stated fixture load |
| Visible cancellation response | p95 below 100 ms, including a blocked output consumer |
| Process termination | Within the configured grace period |

These are initial targets, not measured results or guarantees across all hardware. Establish baselines on named native machines before treating regressions as meaningful. Keep the same build mode, inputs, host load, and capture method. Use repeated A/A runs to estimate noise; preserve raw data and rerunnable commands.

Measure real startup, not a benchmark-only early exit before initialization. Report cold and warm startup separately. Separate local overhead, network/provider latency, model generation, and tool execution. Record CPU, peak and idle memory, allocations, stripped binary size, packaged library size, disk growth, and idle wakeups. A smaller binary does not prove a faster task.

Use a bounded long-session fixture and a large-output fixture to detect growth. Record resources before/after repeated cancellation cycles. Optimize measured hotspots, preserving the behavioral fixtures. Benchmark optional parallel tools against the serial baseline before admitting concurrency into v1.

## Task-level acceptance and release

Use six small externally verified tasks: a bug fix, a refactor while an unrelated file changes, a long build/debug command, an interrupted run and explicit resume, a context-limit/reconstruction case, and a review/fix task with an explicitly requested repository action. Add MCP data/tool use and an ACP editor workflow as required first-release scenarios.

Keep model, prompt, options, tools, starting files, and configuration fixed when comparing harnesses. Record all attempts, failures, human interventions, and final artifact checks. A model saying it is done, a normal stop reason, or many tool calls is not task success. Live evaluation requires an explicit endpoint allowlist and spend cap; lack of live evidence is recorded rather than filled by synthetic results.

F12 produces an integrated candidate. F13 completes the native, protocol, resource, and task qualification evidence on that candidate. Any code change after qualification requires the affected checks on the new candidate. The release owner publishes only after reviewing those results. The plan itself does not authorize a release or claim any implementation check has passed.
