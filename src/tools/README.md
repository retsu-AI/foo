# Custom executable tools

The `tools` module exposes a run-scoped registry of executable tools. The host supplies descriptors and a `foo.io.Spawner`. Only descriptors named in `foo.config.Resolved.enabled_tools` enter the catalog. The default catalog is empty. Unknown enabled names and duplicate names among enabled tools make initialization fail.

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
