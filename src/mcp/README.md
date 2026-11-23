# MCP client

Use `foo-mcp` to connect local stdio servers and Streamable HTTP endpoints. The
client supports MCP 2026-07-28 and 2025-11-25. The configured revision pins
negotiation. With auto selection, discovery can identify a legacy peer before a
tool call is sent.

## Connect a server

Resolve a `foo.config.McpServer` with `connection_config.resolve` at the launch
edge. It reads the configured environment references and borrows values from the
environment snapshot. Keep that snapshot private and live through the connection.

- For stdio, pass the resolved argv, cwd, and environment to `Stdio.init` with
  the native process spawner. The adapter owns the child, reads stdout, drains
  bounded stderr, and serializes writes. Use `Stdio.deinit` after stopping users
  of the connection.
- For HTTP, construct `Http` with the resolved URL and headers and the F01 HTTP
  transport. Give it an independent transport for a long-lived listener and
  another for legacy reverse replies when both primary lanes are occupied.
  Each F01 client supports one active exchange. Call `Client.shutdown` with a
  fresh cleanup context before deinitializing the HTTP adapter.

Create `Client` from the transport interface and server ID. Call `connect`
before requesting content. Call `listen` on an independent task for catalog
change notifications when a peer supports subscriptions. Stop and join that task
before reconnect or teardown. A dropped subscription invalidates freshness.
An expired legacy session requires a new explicit handshake.

## Use the same tool registry

Create a run-scoped `Registry` for each connected server. Pass the configured
enabled aliases, a nonzero generation, session and run IDs, and the permit
handler. `providerAlias` derives stable provider names from the configured
server ID and remote name. A name collision fails catalog creation or
composition. `RegistrySet` concatenates the selected MCP, built-in, and custom
tool declarations and dispatches by pinned identity. Pass its interface to
`foo.host.RunInput` or decorate it with Code Mode.

The run's declarations remain stable. A refresh rechecks the selected tools
against the peer. Removal or a changed declaration prevents affected dispatch
with `catalog_changed`. A new run adopts the new declarations. Permission
decisions apply to one exact invocation. Tool annotations do not grant
permission. Successful replies preserve typed content and structured results in
bounded JSON text. If delivery is possible but completion is unknown, the
registry reports an uncertain effect and leaves recovery to the caller.

`Registry.source()` lists resources, templates, and prompts through
`foo.tool.ContextSource`. Retrieval requires explicit selection and preserves
the source server and identifier. Embedded content stays data. Resource and
prompt requests go to the configured server.

## Schema and content limits

The schema validator supports object properties, required fields, arrays,
enumerated and constant values, composition, and exact numeric and size bounds.
It rejects unsupported validating keywords such as references and regular
expressions. Modern `x-mcp-header` annotations must select a valid primitive
property. An invalid header declaration excludes its tool. The client derives
each header from the same validated arguments sent in the body.

Resource templates expand locally with string variables and RFC 6570 operators.
The client supports scalar prefix modifiers. Composite variables and explode
modifiers require a separate extension. Multipart resources and prompt message
lists use JSON MIME types that preserve content types and roles.

## Protocol matrix

| Surface | 2026-07-28 | 2025-11-25 |
| --- | --- | --- |
| Lifecycle | `server/discover` and per-request client metadata | `initialize` followed by `notifications/initialized` |
| Stdio | NDJSON, typed correlation, subscriptions, cancellation | NDJSON, typed correlation, reverse ping and error replies, cancellation |
| HTTP | POST, JSON or SSE, request metadata headers, request-scoped cancellation | POST, JSON or SSE, optional session and notification GET, bounded cursor GET resumption, DELETE teardown |
| Catalog and context | Tools, resources, templates, prompts, explicit reads and retrieval | Same tool and context surface |

OAuth, sampling, elicitation, Tasks, Apps, and deprecated standalone HTTP+SSE
are outside the profile. Modern input-required results preserve opaque
continuation state in the client and return an unsupported outcome to callers.
HTTP redirects remain caller-visible failures, and the client sends each tool
request at most once. Legacy SSE resumption uses GET with the originating
cursor. Failed authentication returns a typed error.

## Verify

```sh
nix develop .#ci -c zig build test -Dmodule=mcp
nix develop .#ci -c zig build test -Dmodule=mcp -Doptimize=ReleaseSafe
```

Tests cover profile negotiation, scripted exchanges, actual native child
processes, and teardown. With the pinned F01 transport available, the same
command also drives real HTTP and SSE against loopback peers. The checkout uses
`FOO_TRANSPORT_PREFIX` from the Nix shell. Without that profile the scripted HTTP
tests and real stdio tests still run. F13 owns release-candidate interoperability
with external servers.
