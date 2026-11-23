# Code Mode

Code Mode is an opt-in `foo.tool.Registry` decorator. Give it the registry the run already uses. The resulting catalog includes the direct tools and one extra tool named `codemode`.

```zig
const codemode = @import("foo-codemode");

var code = try codemode.Registry.init(allocator, enabled_tools, .{
    .generation = catalog_generation,
    .run_limits = settings.limits,
    .store = run_store,
});
defer code.deinit();

const tools = code.interface();
```

Pass `tools` to `foo.host.RunInput`. With durable sessions, pass the same store to the core and the decorator. Keep the decorator, the wrapped registry, and the store live through run teardown. The base registry owns its immutable declarations. Construct one decorator per run to start with a fresh call budget.

## Run a script

The model calls `codemode` with a JSON object containing one `code` string. The string is an async JavaScript body. Use `tools.name(args)` to call a tool and `tools["exact-name"](args)` for names that contain punctuation. `ALL_TOOLS` lists the enabled tools with their descriptions and JSON schemas. Tool names stay exact.

This example reads two files and edits the first using the digest returned by `read`.

```js
const left = JSON.parse((await tools.read({ path: "left.txt" })).content);
const right = JSON.parse((await tools.read({ path: "right.txt" })).content);
const current = left.content.trim();
const sum = Number(current) + Number(right.content);
const result = await tools.edit({
  path: "left.txt",
  expected_sha256: left.sha256,
  replacements: [{ old: current, new: String(sum) }],
});
if (result.status !== "success") throw Error(result.content);
return sum;
```

Tool calls run in order, and `await` works with their results. The reply includes `status`, `effect`, `content`, and any truncation or artifact metadata. Each effect uses the same schema, permission, and revocation checks as a direct call. `text(value)` and a defined return value contribute to the bounded result. The runtime discards queued jobs when the entry promise settles.

## Limits and recovery

Every script gets a fresh QuickJS-NG v0.18.0 runtime. It exposes JavaScript and the enabled tool calls. File, network, and process access come from those tools. Heap, stack, source, result, queued jobs, elapsed time, and call counts have finite limits. Direct calls, scripts, and nested calls share the configured run call budget. The 30-second script deadline also applies to tool callbacks and may be shortened by the enclosing run. The VM interrupt is cooperative and runs within the host process.

When a store is configured, Code Mode commits each nested intent before dispatch and its outcome before any dependent call. Recovery reports exact unresolved IDs. The model receives only the outer call result. A script exception preserves previously observed effects. An uncertain child stops further calls even when the script catches its exception.

## Verify

```sh
nix develop .#ci -c zig build test -Dmodule=codemode
nix develop .#ci -c zig build test -Dmodule=codemode -Doptimize=ReleaseSafe
nix develop .#ci -c python tests/session/check.py
```

The fixture runs a script through the actual conversation core, permission callback, local file tools, and reopened journal. Additional cases cover disabled tools, uncertain effects, cancellation, memory and output bounds, unresolved promises, and state isolation. The `foo-codemode` module is ready for host composition. The bootstrap executable still uses its original entry point.
