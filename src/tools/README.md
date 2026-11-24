# Built-in and custom tools

The `foo-tools` build module exposes a run-scoped registry for opt-in built-ins and configured executables. The host supplies descriptors and a `foo.io.Spawner`. Only names selected in `foo.config.Resolved.enabled_tools` enter the catalog. The default catalog is empty. Unknown enabled names and duplicate names among enabled tools make initialization fail.

## Registry API

`tools.Descriptor` holds the provider-facing name, description, and JSON schema, along with the host-owned argv, resolved environment entries, environment inheritance flag, and timeout. Tool names use one to 64 ASCII letters, digits, underscores, or hyphens. The descriptor uses an explicit environment by default and a 30-second timeout. The registry gets the working directory and runtime limits from resolved settings.

```zig
const tools = @import("tools");

const descriptors: []const tools.Descriptor = &.{.{
    .name = "lookup",
    .description = "Look up an entry by key",
    .schema_json =
        \\{"type":"object","properties":{"key":{"type":"string"}},"required":["key"],"additionalProperties":false}
    ,
    .argv = &.{lookup_program},
}};
var registry = try tools.Registry.init(allocator, settings, descriptors, .{
    .spawner = spawner,
    .session = session_id,
    .run = run_id,
    .generation = catalog_generation,
    .permissions = host.permissions,
});
defer registry.deinit();
const run_tools = registry.interface();
```

Set `settings.enabled_tools` to include `"lookup"` to expose this descriptor. Pass `run_tools` as the `foo.host.RunInput.tools` value. Keep the registry at a stable address and keep the spawner, permission handler, and optional spool directory live through teardown. The registry copies the enabled descriptors, working directory, and limits.

The catalog pins each provider-facing specification and the identity `{ .backend = "executable", .server = null, .name = descriptor.name }`. Supply a fresh, nonzero generation when replacing a catalog. `Registry.revoke(name)` prevents later dispatch of an enabled name and leaves the run's declarations intact. A call that has passed the final revocation check is already admitted. Use the run cancellation token to interrupt an admitted call.

Dispatch checks the catalog and argument constraints before requesting permission. In `ask` mode, the handler receives the session, run, operation ID, pinned declaration, exact call, and executable target. Its decision applies only to that invocation. A missing handler denies the call. `deny` always denies dispatch, and `allow` skips the callback. The registry checks cancellation and revocation again before launch.

| Condition before launch | Result status | Effect |
| --- | --- | --- |
| Absent, replaced, or revoked declaration | `catalog_changed` | `not_started` |
| Invalid arguments or a validation limit | `failure` | `not_started` |
| Denied or unavailable approval | `denied` | `not_started` |
| Cancellation or deadline | `cancelled` | `not_started` |

The child receives the validated argument bytes unchanged on stdin, followed by EOF. The spawner receives only host-configured argv, working directory, and environment.

## Argument schema

The registry enforces this JSON Schema subset. Each schema node needs a single string `type`. The root type is `object`.

| Type | Supported keywords in addition to `type` |
| --- | --- |
| `object` | `properties` maps names to schemas. `required` lists distinct names from `properties`. Boolean `additionalProperties` permits unknown fields when true or omitted. |
| `array` | `items` optionally applies one schema to each element. |
| `string`, `boolean`, `null`, `number`, `integer` | Type check. An integer is a JSON number with an exact integral value. |
| All types | `description` is an optional string annotation. |

All other keywords and types cause registry initialization to fail. References cause initialization to fail and incur no network I/O. The wire validator checks UTF-8, complete JSON syntax, and depth on schemas and calls. Parsing rejects duplicate object keys. The catalog uses the `catalog_bytes` limit, calls use `tool_argument_bytes`, and both use `json_depth` up to the wire validator's maximum.

## Optional coding preset

Set `Options.builtins` explicitly and select the names in `settings.enabled_tools`. Use
`tools.coding_preset` to select all four. The preset needs an absolute working
directory. Configured custom tools can share the same catalog. A custom
descriptor with the same name explicitly replaces a preset tool. The same
schema, permission, cancellation, and revocation checks apply.

| Tool | Arguments | Result |
| --- | --- | --- |
| `read` | `path`, optional `encoding`, `offset`, and `max_bytes` | Bounded byte range, size, truncation, and source SHA-256 |
| `write` | `path`, `content`, and optional `encoding` | Create or replace one file |
| `edit` | `path`, `expected_sha256`, `replacements` of `{old,new}`, and optional `encoding` | Replace distinct, unique byte sequences in one file |
| `exec` | `argv` array | Exit or signal, stdout and stderr excerpts, and optional output artifact |

File encoding is UTF-8 by default. Select Base64 for binary bytes. Read the full
source digest before editing. An edit validates all old text against the same
snapshot and rejects stale, missing, ambiguous, or overlapping replacements before
publishing the replacement. New files publish without overwriting a concurrent
creator. Existing files use same-directory staging and replacement. The registry
serializes its own writes, and the adapter checks for external changes immediately
before replacement. A writer outside the registry can still race that last check.
The tools operate on one file per call and reject symbolic links, including in
ancestor directories. New files use mode 0600 on POSIX and replacements preserve
basic POSIX permission bits. These filesystem guarantees apply to the local backend.

`exec` passes literal argv elements with the configured cwd and environment. To
run shell syntax, call a shell explicitly in argv. This gives the command the
launching user's operating-system privileges. Configure an external isolation
boundary when running commands that require isolation.

## Editor backends

Supply the session's `foo.host.Host` in `Options.host` to use configured `client`
backends. For `permissions: "ask"`, the registry uses `Options.permissions` when
supplied and otherwise uses the host's permission handler.

`read` and `write` use the separately negotiated editor text-file capabilities.
A read can return unsaved editor text. A write sends UTF-8 text and reports the
size and digest of the submitted bytes. A write whose outcome cannot be
confirmed is uncertain. Select the local `files_backend` for `edit`, which
requires compare-and-swap semantics.

`exec` uses the negotiated editor terminal with literal argv, the configured
working directory, and explicitly configured environment entries. The editor
controls the terminal's launch environment and returns merged terminal output.
Client execution requires `process.inherit_environment: false`. Custom
executables require the local backend for their stdin/stdout protocol. Selecting
a tool whose configured backend lacks its required capability rejects the catalog.

## Executable protocol

A custom executable reads one admitted JSON object from stdin until EOF. It
writes one UTF-8 JSON object to stdout, then exits. The reply contains a required
string `content` and optional boolean `is_error`. Exit zero with a complete valid
reply reports the supplied content. A nonzero exit, signal, malformed reply, or
oversized reply produces a typed failure with process diagnostics. Cancellation
after possible launch and unconfirmed cleanup produce an uncertain effect.

The adapter drains stdout and stderr independently and caps retained bytes.
`exec` reports byte counts and excerpts as text or Base64 for binary bytes. If a host supplies a spool directory
and cap, the tool writes a single relative `exec-*.frames` artifact. Frames carry a
one-byte stream tag, a little-endian 32-bit payload length, and raw payload bytes.
Tags 1 and 2 identify stdout and stderr. The artifact stops at the cap and reports
truncation. On spool failure, the adapter discards the incomplete file where the
filesystem permits and reports the failure.

Run `zig build test -Dmodule=tools` for registry and built-in fixtures. Run
`zig build test -Dmodule=platform-process` for subprocess protocol and ownership
fixtures. The [process handoff](../platform/process/README.md) describes native
ownership and platform limits.
