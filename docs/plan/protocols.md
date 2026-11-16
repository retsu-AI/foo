# MCP and ACP

foo v1 includes an MCP client and an ACP agent. They adapt external protocols to the same execution core used by the CLI and TUI. They do not introduce an orchestrator, a daemon, a second agent loop, or a second permission system.

This is an implementation plan, not a claim that these features exist. Protocol sources were checked on **2026-11-16**. Pin the selected upstream schemas and their checksums when F00 establishes the contracts; do not build against a moving `latest` document.

## 1. Supported roles and revisions

| Surface | foo's role | Required for foo v1 | Explicit exclusions |
| --- | --- | --- | --- |
| MCP stdio | Client launching a configured server | Discovery, tools, resource reads, prompt retrieval, cancellation, bounded process lifecycle | Becoming an MCP server; automatic server installation |
| MCP Streamable HTTP | Client connecting to a configured endpoint | JSON and SSE responses, revision-correct metadata, errors, cancellation, catalog updates | Deprecated standalone HTTP+SSE transport; an HTTP listener in foo |
| ACP stdio | Agent launched by an editor/client as `foo acp` | Initialization, new sessions, prompt turns, updates, cancellation, permission requests, supported client filesystem/terminal methods | Editor UI, remote ACP transport, agent delegation, planning modes |

The MCP preferred revision is **2026-07-28**, the revision reached by the official `latest` URL at the research date. It uses self-contained requests and per-request capabilities. Support **2025-11-25** as one explicit compatibility profile because its initialization and transport semantics differ. These are two tested profiles, not a promise of every previous revision. [MCP specification](https://modelcontextprotocol.io/specification/2026-07-28), [versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).

Use **ACP `protocolVersion: 1`** for foo v1. The official documentation labels v1 “Latest” and v2 “Draft.” v2 changes the prompt lifecycle and removes the v1 client filesystem and terminal interfaces; it must be a separately qualified adapter if added later. Do not mix v2 payloads into a v1 connection. [ACP initialization](https://agentclientprotocol.com/protocol/v1/initialization), [v2 migration status](https://agentclientprotocol.com/protocol/v2/migration).

This version matrix is a deliberate scope limit. Adding a revision requires schema fixtures, compatibility tests, and a concrete interoperability need.

## 2. Ownership and interfaces

| Work package | Owned paths | Responsibility |
| --- | --- | --- |
| F00 | `src/contracts/**` | Domain messages, tool descriptions/results, execution events, cancellation, permission decisions, host filesystem/process interfaces, limits |
| F01 | `src/transport/**` | HTTP/TLS requests, bounded response bodies, SSE byte delivery, deadlines, connection cancellation, credential-safe redirects |
| F02 | `src/wire/**` | JSON-RPC envelope validation, request correlation, bounded newline framing, one serialized writer, generic wire errors |
| F06 | `src/mcp/**` | MCP revision adapters, discovery/catalogs, stdio server ownership, HTTP protocol rules, tool/context adaptation |
| F08 | `src/acp/**` | ACP negotiation/session methods, update projection, client permission/filesystem/terminal adapters |

MCP and ACP import shared contracts and wire helpers. The execution core never imports either protocol. The CLI composition root provides the actual adapters. ACP can obtain MCP sessions through the same F06 interface as the CLI; it must not implement its own MCP client.

F00 should establish these small interfaces before parallel implementation:

- `ToolRegistry`: enumerate a stable generation of descriptions, resolve an identity, invoke with a deadline and cancellation handle. The identity includes the backend and server, not only a model-visible name.
- `ContextSource`: list and explicitly retrieve a resource or prompt, returning content with source identity and size/truncation information.
- `SessionRunner`: create/load supported sessions, submit one prompt, cancel active work, and consume execution events. It owns conversation semantics; ACP translates them.
- `PermissionHandler`: decide or obtain a decision for the exact prepared operation. An answer is bound to a session, operation identity, arguments, and targets.
- `HostFiles` and `HostProcess`: local implementations for normal CLI/TUI use; ACP client implementations when explicitly selected and supported.
- `HttpTransport`: one bounded exchange/stream abstraction; F06 supplies MCP headers and parses MCP events without owning TLS or connection policy.

Names are proposed contracts, not an instruction to create a generic plugin framework. Add no extension registry, service locator, or adapter factory hierarchy.

## 3. Shared wire implementation

Both stdio protocols use UTF-8 JSON messages separated by newlines. A framing helper can therefore serve both, while their message direction, lifecycle, capabilities, and cancellation remain protocol-specific. MCP HTTP needs HTTP bodies and SSE event parsing; it is not newline JSON over a socket. Neither stdio transport uses LSP `Content-Length` framing. [MCP stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio), [ACP transport](https://agentclientprotocol.com/protocol/v1/transports).

F02 must handle partial reads, several messages in one read, escaped newlines inside JSON strings, UTF-8 split across reads, and orderly EOF. Validate envelope shape before dispatch. Preserve request ID type and value; a string ID must not collide with a numeric ID. Reject unsupported JSON-RPC batches explicitly. Unknown requests receive an appropriate error; notifications receive no response. Unknown optional fields are handled according to the pinned protocol schema rather than one global “reject every unknown key” policy.

Use a bounded pending-request table and separate ownership for inbound and outbound requests. Do not block the input reader while waiting for a permission answer, client filesystem operation, or model response: the peer may send cancellation or the awaited response on the same stream. A single writer preserves complete message boundaries. Retire pending requests on deadline, EOF, protocol failure, and cancellation; late responses cannot resurrect work.

Suggested initial limits, finalized once in F00:

| Resource | Initial default | On exhaustion |
| --- | --- | --- |
| One JSON-RPC message or assembled SSE event | 8 MiB | Typed limit failure; close an unrecoverably malformed stream |
| JSON nesting | 64 levels | Reject before recursive work or large allocation |
| Outstanding requests per peer | 64 | Explicit busy/limit error; no hidden queue growth |
| Server stderr retained in memory | 256 KiB ring | Mark truncation; keep draining to avoid deadlock |
| One catalog refresh | 128 pages and 16 MiB accumulated metadata | Fail refresh and identify the limiting setting |
| Opaque continuation/state bytes | Bounded by the message limit and a dedicated config limit | Reject oversized continuation |

These limits are configurable local resource controls, not protocol promises. User-visible tools need output limits distinct from wire limits. Progress cannot extend a request's hard deadline forever. Long-lived catalog subscriptions have their own cancellable lifetime and acknowledgment deadline, rather than the ordinary tool timeout.

`foo acp` stdout contains only ACP messages. CLI JSON stdout contains only its declared output format. Logs, startup diagnostics, and subprocess stderr go to stderr or configured files. No TUI, banners, provider-debug dumps, or child output may leak onto either machine stream.

## 4. MCP client behavior

### Revision selection and connection lifecycle

Configuration accepts `protocol = "2026-07-28"`, `"2025-11-25"`, or `"auto"`. Auto mode performs bounded discovery, never a tool call, to select a profile. Recognized modern version errors are handled as version negotiation; authentication failures and arbitrary transport failures are not permission to downgrade. Cache the chosen profile for that configured connection, expose it in diagnostics, and allow an explicit pin for servers with unusual discovery behavior.

For **2026-07-28**, use `server/discover` to obtain identity, capabilities, and supported revisions. Attach required protocol/client metadata to each request, with the corresponding HTTP headers where specified. There is no `initialize`/`initialized` handshake or protocol session ID. [Discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover).

For **2025-11-25**, send `initialize`, validate the returned supported revision and capabilities, then send `notifications/initialized` before normal operations. Bound handshake time and report mismatch clearly. Earlier revisions are unsupported rather than partially emulated. [Legacy lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle).

For stdio, launch an explicit executable and argument vector; do not interpolate a shell command. Retain ownership of child pipes and process lifetime. On shutdown close input, wait a bounded grace period, then terminate/reap the owned process as needed. Restarting a failed server does not replay an uncertain tool call. Preserve an “outcome unknown” result when a server disappears after receiving an effectful call.

### Streamable HTTP

The modern profile uses POST for each request, accepts either JSON or SSE, and mirrors required request metadata consistently between headers and body. It does not send legacy session headers, GET subscriptions, or DELETE session teardown. Closing a modern HTTP response stream is the cancellation mechanism; stdio cancellation uses `notifications/cancelled`. Keep these decisions in F06. [Modern Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http).

The legacy profile handles returned `MCP-Session-Id`, subsequent protocol/session headers, optional GET streams, and DELETE teardown. When SSE event IDs allow resumption, reconnect with the correct cursor under a finite retry budget; do not re-POST an uncertain tool call. A lost legacy stream alone does not signal cancellation. An expired session requires a fresh handshake but does not justify replaying effects. A server that rejects optional GET/DELETE with the specified status remains usable. [Legacy transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

For either profile, reject mismatched response IDs, invalid content types, malformed SSE/JSON, oversized data, and impossible state transitions. Honor server retry timing within the caller's remaining deadline. Record connection failures separately from tool failures. Cancellation is a request to stop remote work, not proof that a remote effect was undone.

### Tools, resources, and prompts

All three are in F06's v1 scope. They have separate interfaces because discovering a tool, reading data, and invoking a user-selected prompt are different operations.

| Feature | Required behavior | foo policy |
| --- | --- | --- |
| Tools | `tools/list`, `tools/call`; input schema, structured/text results, `isError`, capability changes | Advertise only configured tools; dispatch rechecks membership and permission |
| Resources | `resources/list`, `resources/templates/list`, `resources/read` | Read on explicit selection or enabled tool request; do not preload every resource into context |
| Prompts | `prompts/list`, `prompts/get`, declared arguments | User-selected retrieval; no automatic execution or new authority |

Tool identities are `(server_id, remote_tool_name)`. Derive provider-compatible aliases deterministically and retain a reverse mapping; reject alias collisions instead of shadowing a local tool. Pin advertised tool declarations for the run and bind each prepared invocation to that catalog generation. A detected removal, schema change, or revocation blocks affected invocations with `catalog_changed`; additions and replacement schemas enter the next run. Never dispatch against a new schema using arguments generated for the old one. Keep transport errors distinct from a successful RPC carrying a tool execution error. Preserve structured results and content types; a text-only model receives an explicit representation or unsupported-content result, never silent data loss. [MCP tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools).

Resources retain their URI, MIME type, source server, and size metadata. Treat embedded data as data and links as references; retrieval uses the configured server and normal limits. Do not fetch arbitrary resource-link URLs through a second HTTP path. [MCP resources](https://modelcontextprotocol.io/specification/2026-07-28/server/resources).

Prompt templates remain server-authored text even when a user selects them. Preserve that provenance in the internal message representation. A template or `instructions` string cannot grant permissions, change the system prompt, modify configured tools, or set the working directory. [MCP prompts](https://modelcontextprotocol.io/specification/2026-07-28/server/prompts.md).

Follow opaque `nextCursor` values until absent, within page/byte/deadline limits. An empty cursor is valid and is not end-of-list. Detect repeated-page/no-progress loops without interpreting cursor contents. Publish a complete new catalog generation atomically; do not leave a half-refreshed catalog active. [Pagination](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/pagination).

For modern list-change notifications, use `subscriptions/listen`, validate its acknowledgment and subscription identity, and request only the supported filters foo consumes. A notification marks the relevant catalog stale. Coalesce bounded refreshes, use confirmed removals/changes to invalidate affected calls, and retain the completed replacement generation for the next run. Do not mutate the active run's advertised schemas. Legacy notifications arrive through its stdio/HTTP paths. Subscription loss marks freshness uncertain and triggers bounded recovery or explicit refresh, never an invisible retry loop. [Subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions).

### Requests from servers

Modern MCP encodes server input requests as MRTR `input_required` results rather than reverse JSON-RPC requests. Parse that result separately from completion; preserve opaque state exactly; require measurable progress and a finite continuation count. Legacy MCP can issue reverse requests and receives a revision-correct response or method/capability error. Never answer a modern input request using the legacy reverse-RPC channel. [Multi Round-Trip Requests](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr).

The minimal v1 capability policy is:

- Do not advertise sampling, elicitation, Tasks, MCP Apps, or a skill-execution extension. They are not necessary for ordinary tool/resource/prompt use.
- Recognize unsupported input requests and return a typed unsupported-capability outcome to the caller. Do not wait indefinitely, manufacture user answers, or launch a nested model call.
- Implement legacy `ping` and basic protocol housekeeping. Unknown reverse requests get an error, not a dropped message. Notifications never get responses.
- Keep server log/progress content bounded and non-authoritative. Tool annotations are hints, not permission grants or proof of idempotency.

An MRTR continuation is part of the requested remote operation, not an orchestration layer. If a future capability enables elicitation, it must use the shared interaction interface with a deadline and cancellation; no protocol-specific approval engine is permitted.

### Authentication and credential handling

For v1, support unauthenticated endpoints and caller-configured credentials scoped to one endpoint origin. OAuth discovery/login/refresh is **explicitly unsupported** in the initial delivery. A protected endpoint requiring that flow returns a clear unsupported-authentication result and configuration guidance; foo does not repeatedly retry 401, invent a partial OAuth flow, or advertise OAuth interoperability. MCP authorization is optional, and its HTTP flow differs from stdio environment credentials. [MCP authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization).

Resolve configured secret references at the effectful edge. Do not place secret values in persisted configuration snapshots, model context, MCP catalogs, ACP updates, logs, or errors. Do not forward endpoint credentials across origins on redirect. Reject attempts to overwrite protocol-owned headers with contradictory values. Stdio servers receive only the explicitly configured credentials and documented environment inheritance.

If OAuth becomes required for an actual v1 target, expand F06 deliberately to implement the selected specification's discovery, issuer/resource validation, PKCE, callback/state checks, scoped token storage, and bounded refresh as a complete feature. Until then, the support matrix must say which protected endpoints are unsupported.

## 5. ACP agent behavior

### Connection and session lifecycle

`foo acp` reads protocol input immediately and initializes no terminal UI. Implement `initialize`, `session/new`, `session/prompt`, `session/cancel`, and outgoing `session/update`; expose authentication methods only when implemented. A provider credential missing from the configured environment is reported clearly; it must not start an interactive login on protocol stdout. [ACP overview](https://agentclientprotocol.com/protocol/v1/overview), [authentication](https://agentclientprotocol.com/protocol/v1/authentication).

Return protocol version 1 and only verified capabilities. Omitted client capabilities are unsupported. Unsupported version negotiation returns the supported version according to ACP's rule, without processing later requests under a guessed revision. Use a pinned schema snapshot because additive v1 capabilities also evolve.

`session/new` validates its absolute working directory and configured MCP servers before admitting the session. Bind every subsequent request to its session ID and host scope. Sessions are ordinary conversations; no parent/child agent relationships, task queues, worktree ownership system, or hidden goals. Initially allow one active prompt per process with bounded idle-session metadata. Reject overlapping work explicitly rather than introducing a scheduler.

Use F06 for editor-supplied MCP servers. Advertise `mcpCapabilities.http: true` only when both required HTTP profiles pass; advertise no deprecated `sse` transport. Stdio MCP is required by ACP. Client-supplied server configuration must pass the same process/endpoint policy as local configuration; credential values remain ephemeral. [ACP session setup](https://agentclientprotocol.com/protocol/v1/session-setup).

Implement optional `session/load` only after the shared session store can replay an accurate history and restore its configuration requirements. Until then omit `loadSession`. Do not treat an unfamiliar session ID as a new conversation, and do not claim resumption while starting empty. Session list/fork/resume extensions, modes, plans, and custom editor features are outside the baseline.

### Prompt turns and updates

Translate supported prompt content into F00 messages and reject unsupported media clearly. Feed the same runner used by CLI/TUI. Stream text and tool lifecycle events as `session/update`; retain stable tool-call IDs. Finish the original `session/prompt` request once with the correct stop reason. In ACP v1, that response ends the turn; it is not an early acknowledgment as in v2. [Prompt lifecycle](https://agentclientprotocol.com/protocol/v1/prompt-turn).

A cancelled turn cancels provider I/O, pending permission requests, tool execution, and owned child work through the shared cancellation handle. Stop admitting new effects immediately. Drain required final updates before answering the prompt with `cancelled`. Handle a late approval/result as stale. Also implement request-level `$/cancel_request` for methods foo can cancel, returning the specified response/error rather than silently dropping the original request. [ACP cancellation](https://agentclientprotocol.com/protocol/v1/cancellation).

### Permission and host tools

Map the shared permission handler to `session/request_permission`. Include the real command/targets and operation identity; perform no effect before a required positive decision. Treat `cancelled`, unknown option IDs, unknown outcomes, timeout, and disconnect as non-approval. Start with allow-once/reject-once options; add remembered options only with a defined scope and persistence contract. An approval for one prepared operation cannot authorize changed arguments. [ACP tool calls and permissions](https://agentclientprotocol.com/protocol/v1/tool-calls).

When using client filesystem tools, check `fs.readTextFile` and `fs.writeTextFile` separately and issue `fs/read_text_file` or `fs/write_text_file` with the session ID and absolute path. This can expose unsaved editor content, so it is not equivalent to reading local disk. No silent local fallback after denial, unsupported capability, or client error. [ACP filesystem](https://agentclientprotocol.com/protocol/v1/file-system).

Select the filesystem backend explicitly for the session. ACP v1's plain read/write methods do not provide foo with a compare-and-swap transaction. Do not claim local atomic-edit guarantees for remote editor writes. A before-write reread can detect some changes but does not eliminate the race; disable operations requiring stronger guarantees unless a supported host interface provides them. This is a deliberate implementation limitation.

When the client advertises `terminal`, adapt `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, and `terminal/release`. Bound output and waits; request kill/release as appropriate while the connection is available. After disconnect, client-side cleanup cannot be confirmed: record unconfirmed remote cleanup, retire local handles, and rely on the client's ownership contract. Keep this distinct from confirmed cleanup of local child processes. Use client execution only when selected; failure must not rerun the command on foo's host. Local execution, where explicitly configured, remains visibly a different backend. [ACP terminals](https://agentclientprotocol.com/protocol/v1/terminals).

On stdin EOF or a broken stdout pipe, cancel the process's active turn, stop owned MCP children, clean up host resources, and exit within the configured shutdown bound. A disconnected editor is not permission to continue unattended.

## 6. Acceptance tests and interoperability

No real credentials or internet are required for deterministic protocol tests. Use scripted peers and local HTTP fixtures, plus optional manual interoperability checks against pinned official test tooling. Test through the public adapter interfaces and actual pipes; parser-only tests do not establish lifecycle correctness.

| Suite | Required acceptance cases |
| --- | --- |
| F02 framing | Every byte split for representative frames; combined frames; UTF-8 boundaries; invalid JSON; oversized/deep messages; duplicate/late IDs; writer serialization; EOF with partial input; bounded pending table |
| F06 modern MCP | Discover and per-request metadata; JSON/SSE; matching headers/body; request-scoped cancellation; subscription acknowledgment/correlation; unsupported MRTR; version rejection without accidental downgrade |
| F06 legacy MCP | Initialize/initialized ordering; unsupported revision; session headers and expiry; GET optionality; SSE cursor resumption without tool re-POST; reverse request rejection; notification cancellation |
| F06 catalogs/results | All pages including empty-string cursors; no-progress/page/byte limits; tool-name collision; schema replacement between preparation/dispatch; resource and prompt selection; structured result/error distinction |
| F06 processes/auth | Stderr flood; process exit mid-call; timeout/terminate/reap; no uncertain effect replay; 401 gives a finite unsupported-auth result; no credential leakage or redirect forwarding |
| F08 baseline | Initialize → new → prompt → streamed update → one terminal response; unsupported capabilities absent; overlapping prompt rejected; unknown session rejected; stdout contains only valid frames |
| F08 permissions | Approved/denied/cancelled/unknown decisions; cancellation while waiting; stale approval after cancellation; changed operation cannot use an old approval |
| F08 host tools | Unsaved client file content used; absent capability prevents calls; errors never switch backends; terminal output/kill/release; documented edit consistency limits |
| F08 end to end | Editor prompt invokes an MCP tool through F06, forwards result to the provider, streams response, then cancels cleanly on disconnect |

Measure cold `foo acp` startup, initialization latency, a no-network fake prompt, an MCP round trip, catalog refresh memory, and cancellation-to-resource-release time separately. The same workload should run through CLI and ACP with equivalent semantic results. Protocol support must not add MCP discovery, editor initialization, or background listeners to ordinary `foo --help` startup.

F06 and F08 are release requirements for foo v1. Their module gates use scripted peers and fake runner/tool interfaces; F06 also requires F05's real native process ownership before module completion. F12 owns real-runner integration, and F13 owns final native/live qualification on that candidate. This ordering permits parallel module completion without a circular dependency, while ensuring the released adapters do not conceal a second execution path.

## 7. Source and update policy

The links above are primary protocol sources inspected on 2026-11-16. The implementation must vendor or otherwise pin only the schema material it needs, preserving its license; document the upstream revision and checksum alongside fixture generation. A dependency on an official SDK is not required to consume a protocol schema.

At implementation kickoff, verify that the named revisions and ACP stability labels remain accurate. If they changed, update this support matrix and its tests together. Do not silently broaden capability claims, auto-negotiate an unimplemented revision, or rewrite the core around a protocol's experimental features.
