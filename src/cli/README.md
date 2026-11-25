# CLI and JSONL process interface

The CLI runs commands through the shared conversation engine. See the [candidate guide](../../tests/integration/README.md) for building foo and explicitly retrieving MCP context.

## Commands

```sh
foo --help
foo --version
foo --approve
foo tui --config profile.json
foo run --config profile.json --prompt 'Summarize the input'
printf 'Summarize the input\n' | foo run --config profile.json --stdin
foo run --config profile.json --resume --prompt 'Continue'
foo config check --config profile.json
foo config show --config profile.json --model example
foo rpc --config profile.json
```

`foo` and `zig build run` open the TUI with the user config when run without arguments. Use `foo --approve` or `zig build run -- --approve` to include the project's `.foo/config.json`. [Configuration paths and precedence](../config/README.md#configuration-files)

`run` requires exactly one prompt source. `--stdin` reads UTF-8 until EOF and retains the bytes, including trailing newlines. Plain stdout contains committed assistant text. A successful nonempty output ends with a newline. Diagnostics go to stderr. The same output rules apply to terminals and pipes.

Repeat `--config` to apply explicit files in command order. Set `--preset coding` to select the coding preset. Use `--provider`, `--model`, `--endpoint`, `--credential-env`, or `--cwd` to override values. See `foo --help` and the [configuration reference](../config/README.md).

Use `foo auth login PROVIDER --api-key` to save a key from an interactive terminal. Use `foo auth list` to see saved provider IDs and `foo auth logout PROVIDER` to remove one. [Credential commands](../auth/README.md)

`config check` validates the resolved configuration and exits silently on success. `config show` writes redacted effective JSON with provenance. Both commands can run before credentials are available. `run` and `rpc` check declared model credentials and header environment references before opening runtime adapters.

`--resume` selects an existing journal in the configured session directory. The CLI passes the recovered context to the runner and returns an interrupted outcome when the store reports unresolved effects. A fresh launch requests a new session. RPC with a bound store loads committed history before each subsequent prompt. Without a store, each RPC prompt supplies a fresh context.

## JSONL protocol v1

Send one UTF-8 JSON object per line to `foo rpc`. Keep stdin open to receive the result and to send further commands. The decoder accepts LF and CRLF and skips blank lines. Use a distinct string `id` for each command in flight. IDs contain 1 to 128 bytes and exclude control characters. The server assigns a positive integer `run` to each admitted prompt. Send a separate command ID when cancelling a run.

```jsonl
{"version":1,"id":"p1","command":"prompt","prompt":"Summarize the input"}
{"version":1,"id":"c1","command":"cancel","run":1}
```

Every response on stdout includes `version` and `type`. Responses include the request `id` when the decoder can recover it. Run responses include `run`. Optional fields are omitted when absent.

| Type | Meaning |
| --- | --- |
| `accepted` | The prompt was admitted. Wait for its `result`. |
| `event` | The run emitted a delta, committed message, or committed tool result. Committed records include their sequence. The projection omits provider replay payloads and reasoning signatures. |
| `cancel_ack` | A cancel command matched the active run. The prompt's `result` carries its outcome. |
| `result` | The terminal outcome of an admitted prompt. This is the only terminal record for that prompt while output remains deliverable. |
| `error` | The command was rejected. Read the typed `code`. |

A second prompt while a run is active receives `busy`. A cancel for an inactive run receives `no_active_run`. Other command errors use `invalid_command`, `unknown_command`, `unsupported_version`, or `limit_exceeded`. A rejected command has no terminal result.

The prompt limit is the smaller of 1 MiB and the configured transcript byte limit. The input frame and encoded event cap is the smaller of 8 MiB and the configured wire-message limit. The configured JSON depth also applies. The output queue limits event count to the smaller of 64 and the configured pending-event limit. Queued event bytes have the same cap as an encoded event, with one additional frame in flight. Control replies have a separate allowance of 16 queued records and one reserved terminal record. Exhausting control capacity ends the connection.

While output is blocked, the command reader can still process cancel. The runner observes cooperative cancellation, and the writer keeps its partially written record on an ordinary prompt cancel. The client must resume reading to receive the acknowledgment and result. EOF or a handled process signal closes admission, cancels the prompt, joins the runner, and gives stdout up to 500 ms to drain. A broken pipe or drain timeout closes output and joins the workers. If transport ends during a write, the last physical line can be incomplete.

## Exit status and signals

| Exit | Meaning |
| --- | --- |
| 0 | Success. RPC also returns 0 after a clean stdin close and output drain. |
| 2 | Invalid arguments or configuration, malformed RPC framing, or unavailable configured credentials |
| 3 | Input or run limit |
| 4 | Provider failure |
| 5 | Session or journal failure |
| 6 | Other host failure, unavailable runtime, or failed output |
| 7 | Interrupted run. Review any unresolved tool effects before continuing. |
| 130 | Cancellation or a handled process signal |

In RPC mode, individual run outcomes are in `result.outcome`. The exit code describes the process transport. The process entrypoint handles SIGINT and SIGTERM on Linux and macOS and console Ctrl+C and Ctrl+Break on Windows. It joins active work before returning. Signal cancellation can interrupt a blocked stream while the runner completes cooperative cleanup.

## Integration and verification

Import `src/cli/root.zig` with `foo` and `configuration` module imports. Pass args after the program name, an absolute invocation directory, a monotonic operation clock, and the caller's explicit environment. `execute` uses caller-provided cancellation. Call `executeProcess` from an entrypoint that owns process signal handlers.

The runtime binding supplies the runner, services, tools, and session identity. It stays alive through the final worker join. If the binding has an explicit release callback, the CLI calls it before freeing the binding arena. Runner and adapter implementations must observe the supplied cooperative cancellation request and release their active I/O before returning.

Run the black-box CLI suite from the repository root.

```sh
nix develop .#ci -c python tests/cli/check.py
nix develop .#ci -c python tests/cli/check.py --optimize ReleaseSafe
```

The suite drives real subprocess pipes, including a Linux check that observes the stdout writer blocked in the kernel before it sends cancel. It also drives the real journal through resume and cancellation. F12 wires production adapters and registers package tests. F13 repeats the CLI scenarios with the integrated executable and qualifies native macOS and Windows process behavior.
