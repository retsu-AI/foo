# ACP v1 pipe tests and integration

The ACP adapter serves newline-delimited JSON-RPC over stdin and stdout. It runs one active prompt per connection through an injected `host.Runner`. Each session has its own bounded conversation history, working directory, host capability selection, and MCP settings.

## Run the native pipe suite

```sh
nix develop .#ci -c python tests/acp/run.py
```

The script builds `tests/acp/probe.zig` in Debug and ReleaseSafe with the pinned Zig toolchain. It launches the probe as a subprocess and drives it with an independent Python client. The Native ACP workflow runs the same script on Linux, macOS, and Windows. F12 owns registration under `zig build test -Dmodule=acp`.

To save the exchanged frames, add `--trace /tmp/acp.jsonl`. The script writes one JSONL transcript per build mode. The probe uses a scripted runner and fixture data. It requires no credentials, external servers, or editor installation.

## Protocol support

| Direction | Methods |
| --- | --- |
| Editor to agent | `initialize`, `session/new`, `session/prompt`, `session/cancel`, `$/cancel_request` |
| Agent to editor | `session/update`, `session/request_permission`, `$/cancel_request` |
| Agent to editor with matching capability | `fs/read_text_file`, `fs/write_text_file`, `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, `terminal/release` |

The adapter accepts text and resource links. Linked names and URIs reach the runner as text, and the adapter leaves resource access to the configured tools. [Pinned ACP schema](../contracts/protocol-pins.json). Session loading, media, interactive authentication, and MCP HTTP support require additional capabilities. For stdio MCP, the injected session factory receives the editor's server declarations and applies the executable and environment policy.

| Runner outcome | Prompt response |
| --- | --- |
| Completed | `end_turn` |
| Cancelled | `cancelled` |
| Provider output limit | `max_tokens` |
| Provider refusal | `refusal` |
| Other limits or infrastructure failures | Correlated JSON-RPC error |

The agent sends the active prompt's final response after its updates. Refused turns are excluded from subsequent prompts. Cancellation retires in-flight editor requests so a late response cannot approve a later tool operation. Approval applies to one prepared operation.

File read and write are independently negotiated. Reads can use unsaved editor content. Writes offer plain replacement semantics without a compare-and-swap guarantee. When a configured client operation fails, the adapter returns the failure to the runner. The adapter asks the editor to kill and release live terminals when the connection permits it. The shutdown report records terminals whose remote cleanup could not be confirmed.

## Release qualification

F12 supplies the production session factory, configured providers and tools, F06 MCP registrations, and `foo acp` dispatch. When testing the integrated binary for F13, connect each supported editor and confirm that it can:

1. Open a working directory, submit a text prompt, and display an agent chunk and final response.
2. Deny a tool operation, then approve a different prepared operation.
3. Read unsaved editor content and report an editor-host error.
4. Run a permitted terminal command, cancel it, and release the terminal. Disconnect during a separate active turn.
5. Start the configured stdio MCP server and complete a tool call followed by a provider continuation.
