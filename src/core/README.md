# Single-conversation core

`Engine` runs one admitted prompt at a time. CLI, TUI, and ACP can use `engine.runner()` as a `foo.host.Runner`. Embedders can call `engine.run` for the same outcome plus usage, request and tool counts, the exhausted limit, and any output delivery error.

```zig
var engine: core.Engine = .{};
const runner = engine.runner();
const outcome = try runner.run_fn(runner.context, allocator, operation, input, output);
```

Keep the engine, input, and injected adapters alive until the synchronous call returns. Use the same engine for all prompt submissions to one frontend. A competing submission receives `error.Unavailable` before it starts a run. The caller correlates that error with its prompt request. Cancellation uses the caller's `io.Cancellation` handle and remains available during adapter and event callbacks. Adapters own their waits, wake callbacks, and process or transport teardown.

## Input and history

Pass the explicit context in `RunInput.messages`. The last message is the new user prompt. Older messages supply context for the model. The core commits the new prompt once. When you enable a store, initialize its header and pass the recovered or reconciled context as the older messages. The core reads the store's sequence and uncertainty before starting effects. An unresolved effect returns `interrupted` with `uncertain_effects`. Only fresh tool calls from the current provider stream can enter a batch.

The run retains completed message blocks, including compatible provider replay data and reasoning signatures. Callbacks borrow their values until return. Copy the committed records you need for a later prompt. Without a store, committed events carry run-local sequence numbers. With a store, event sequence numbers identify committed records and may skip dispatch intents.

Request preparation can replace the messages for one provider request. The model, declared tools, and limits come from the admitted input. Prepared context must fit the transcript budget and preserve any replay data it carries under the selected provider identity.

## Transitions

| Case | Order |
| --- | --- |
| Text reply | Commit prompt → stream provisional deltas → commit complete assistant message → finish |
| Tool batch | Commit assistant request → commit intent → invoke once → commit correlated result → publish result → repeat for remaining calls → request the next reply |
| Invalid arguments or unknown tool | Commit assistant request → commit and publish a correlated `failure/not_started` result |
| Truncated response | Stream provisional deltas → return `limit_reached` with provider stop `output_limit` |
| Cancellation during dispatch | Stop new effects → record the active call's known or uncertain result → record skipped calls where storage permits → finish |
| Effect followed by failed result commit | Stop new effects → return `storage_error` with uncertainty → report pending intent on recovery |

The registry validates schema, catalog generation, and permissions before effects. A store must accept a correlated `tool_result` with `not_started` for an assistant call that required no dispatch intent. The provider transcript represents each result as a tool-role message. Recover that same message from the journal's result record. Include both unmatched dispatch intents and unreconciled results with `effect = .uncertain` in `Recovery.uncertain_call_ids`. Recording an uncertain result does not resolve the effect.

The report counts provider invocations and tool calls in accepted batches. Unknown provider usage stays null for an aggregate field if a possibly charged request leaves that field unknown. Tool output excerpts have a byte cap. The run also bounds transcript bytes, provider response data, model turns, and tool calls. `Report.limit` identifies exhausted run budgets. The concrete provider owns wire framing and enforcement of its output token setting.

Cancellation or a deadline stops admission. Final bookkeeping uses an uncancelled context with a one-second deadline to keep the original cancellation from discarding a known effect. An admitted run returns one outcome and attempts one final event. A sink can reject that event. `Report.output_error` captures delivery failure, and the returned outcome agrees with the committed terminal outcome when that commit succeeds.

## Verification

Run the core suite with Zig 0.17.1.

```sh
nix develop .#ci -c zig test \
  --dep foo --dep core --dep support -Mroot=tests/core/root.zig \
  -Mfoo=src/lib.zig --dep foo -Mcore=src/core/root.zig \
  --dep foo -Msupport=tests/support/root.zig
```

For ReleaseSafe, add `-O ReleaseSafe` before each `-M` option. The integrator owns the public facade and root test registry. Register `src/core/root.zig` as `core` with import `foo`. Register the test root with imports `core`, `foo`, and `support` for `zig build test -Dmodule=core`.

The suite drives the real runner with scripted provider, registry, journal, clock, and sink adapters. It records the transitions above, including cancellation wakeups and journal failure. Live provider replay and native process or journal recovery require the later adapter and integration packages.
