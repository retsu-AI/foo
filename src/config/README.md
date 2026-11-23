# Configuration reference

F09 resolves explicit JSON layers into shared runtime settings and typed launch settings. F10 turns CLI arguments into configuration layers. F11 consumes the launch settings, and F12 wires the result into providers, tools, and sessions.

## Library API

`root.zig` imports the `foo` module. It exports two public entrypoints.

```zig
pub fn resolve(
    allocator: std.mem.Allocator,
    operation: foo.io.Context,
    input: Input,
    diagnostic: *?Diagnostic,
) Error!Effective;

pub fn effectiveJson(allocator: std.mem.Allocator, settings: Effective) Error![]const u8;
```

`Input.cwd` is an absolute invocation directory. `Input.preset` is `none` by default or explicitly `coding`. `Input.layers` contains `Layer` records with a `foo.config.Source`, optional `location`, and either `.data.json` bytes or `.data.file` filename.

Only `file`, `environment`, and `command_line` are accepted layer sources. Only a `file` layer can use `.data.file`. An environment layer is a JSON patch supplied by the caller after its own declared environment handling. Only caller-supplied environment patches take part in precedence.

`Effective.runtime` is `foo.config.Resolved`. `Effective.launch` contains `process`, `session`, `tui`, and `custom_tools`. `Effective.prompt_files` lists normalized surviving prompt filenames. Strings and arrays in the result remain valid until the caller frees its arena. Use one caller-owned arena for each resolution and discard it after the final consumer finishes. A failed resolution can leave allocations in that arena.

`resolve` clears the diagnostic before work. Schema, file, and limit failures include a setting `path`, `source`, `location`, and a typed `reason`. Diagnostics never include setting values. Syntax and duplicate-key errors use `$` because the JSON parser does not expose a reliable field path. Unsupported versions use `version`. Cancellation, deadline, and allocation errors return directly.

## Precedence and merging

The resolver applies these layers in order, regardless of the order in `Input.layers`:

1. Mechanical defaults.
2. The explicitly selected preset.
3. File layers, preserving their relative input order.
4. Environment layers, preserving their relative input order.
5. Command-line layers, preserving their relative input order.

Each supplied layer must be valid, including layers later overridden. Unknown and duplicate keys are rejected throughout the JSON tree. The exceptions to unknown-key validation are `model.options` and each custom tool's `schema`, whose semantics belong to their consumers.

Object fields merge individually for `model`, `limits`, `process`, `session`, `session.limits`, `tui`, `tui.keys`, and `tui.colors`. All arrays replace. `model.options` and `system_prompt` replace as whole objects. Each MCP server and custom tool is part of its containing replacement list.

Omitting a setting retains its earlier value. `[]` clears a list, `false` disables a boolean, and an empty prompt stays empty. Null is accepted only for `model.credential`, `session.directory`, and an MCP `revision`. Null clears the credential or session directory, or leaves MCP revision negotiation to F06.

`runtime.provenance` records the winning source and location for every configurable scalar or atomic replacement value, including defaults. Changing a model family or endpoint origin clears inherited credentials and headers before applying explicit credentials and headers from that same layer. Origin compares scheme and host without case and treats omitted HTTP/HTTPS ports as 80/443. Changing only the path or query on the same origin retains authentication.

The neutral defaults contain an empty prompt, no selected tools, no custom tools, no MCP servers, no session directory, no inherited process environment, local backends, and denied tool permissions. The coding preset supplies `coding_prompt` from `root.zig` and selects `read`, `edit`, `write`, and `exec`. The caller supplies the model and any credentials or permission overrides. The preset uses the built-in prompt text.

## Profile schema

The root is a JSON object. All settings are optional in an individual patch. The final configuration requires `model.family`, `model.endpoint`, and `model.id`. File-backed layers accept static JSON from paths supplied by the caller.

| Root key | Value | Default or behavior |
| --- | --- | --- |
| `version` | Integer `1` | Omitted means version 1 |
| `model` | Object described below | Family, endpoint, and ID required after merging |
| `cwd` | Nonempty path string | Invocation directory |
| `system_prompt` | Atomic object with `text` and `append_files` | Empty text and list |
| `enabled_tools` | Unique nonempty string array | `[]`; names remain data for tool owners |
| `custom_tools` | Executable-tool declaration array | `[]`; declaration does not select a tool |
| `mcp_servers` | MCP declaration array | `[]` |
| `limits` | Positive integer settings below | Shared contract defaults |
| `retry_attempts` | Unsigned 32-bit integer | `0` |
| `files_backend` | `local` or `client` | `local` |
| `process_backend` | `local` or `client` | `local` |
| `permissions` | `allow`, `ask`, or `deny` | `deny` |
| `process` | Process controls below | F05-compatible defaults |
| `session` | Session directory and limits below | Persistence disabled |
| `tui` | Keys and colors below | Basic terminal bindings and colors |

NUL is rejected in strings used by the schema. JSON text must be UTF-8. Integer settings reject fractional or exponent notation and values outside their target integer type. Configuration parsing bounds cannot be raised by `limits`.

### Model

| Key | Value | Default |
| --- | --- | --- |
| `family` | `openai_responses`, `openai_chat`, or `anthropic_messages` | Required |
| `endpoint` | Complete HTTP or HTTPS POST URL | Required |
| `id` | Nonempty string | Required |
| `credential` | Null or `{"environment":"VARIABLE_NAME"}` | Null |
| `headers` | Header array described below | `[]` |
| `options` | JSON object, retained as `runtime.model.options_json` | `{}` |
| `max_output_tokens` | Positive unsigned 32-bit integer | `4096` |

Endpoints reject missing hosts, user information, fragments, whitespace, control bytes, backslashes, and port zero. The resolver lowercases the URL scheme and preserves the remaining URL bytes. Effective output hides query values. Choose the protocol family explicitly and supply the complete POST URL. F04 owns the option allowlist and protocol-specific option validation. See [provider routes](../providers/routes.md) for endpoint and model selection.

Header entries have exactly `name` and `value`. Header names use HTTP token characters and must be unique without regard to case. Values are literal strings or `{"environment":"VARIABLE_NAME"}` references. Literal header values reject line breaks and control characters other than tab.

Environment entries have the same `name` and `value` shape. Names and referenced variable names match `[A-Za-z_][A-Za-z0-9_]*`. Duplicate environment names are rejected without regard to case for portable Windows behavior. Empty literal values are valid. References stay references until a host deliberately resolves them.

### System prompt and paths

`system_prompt` accepts only `text` and `append_files`. Omitted members of this atomic object become `""` and `[]`. `append_files` is an ordered list of nonempty path strings. Replacing the object discards the earlier text and file list. Files are read only after all layers and other semantic validation succeed.

The final prompt starts with `text`. Each file contributes its exact UTF-8 bytes. A newline separates two nonempty contributions. File contents become literal prompt text. Empty files add no separator. NUL and invalid UTF-8 are rejected.

`cwd`, prompt filenames, and `session.directory` resolve lexically against the directory containing their explicit configuration file. For inline `.data.json` with source `file`, `location`, when supplied, is that configuration filename. Other layers resolve paths against `Input.cwd`. The invocation or declaring file directory anchors each path. The resolver takes `~`, environment variables, and glob syntax literally. The frontend opens working and session directories during setup.

On Linux, an invocation directory of `/work` and an explicit file `/settings/profile.json` resolve `"cwd":"../project"` to `/project` and `"append_files":["rules.txt"]` to `/settings/rules.txt`. On Windows, `Input.cwd` can be `C:\\work`; a profile at `C:\\settings\\profile.json` resolves `"cwd":"..\\project"` to `C:\\project`. JSON requires escaped backslashes. Path syntax follows the compilation target. Use Windows path syntax on Windows and POSIX path syntax on Linux and macOS.

File reads use ordinary local regular files. The resolver checks file type and size before opening and again after opening, then checks cancellation and byte limits between bounded reads. It follows explicit symlinks. Lexical resolution does not resolve symlink targets. Callers choose which files they trust. Paths can change between filesystem calls, and cancellation checks run between calls.

### MCP servers

Each entry requires unique nonempty `id` and one `transport` object. `revision` is optional, null, `2026-07-28`, or `2025-11-25`.

`transport` contains exactly one of these members:

- `stdio` requires `argv` and accepts `environment`, defaulting to `[]`.
- `http` requires `url` and accepts `headers`, defaulting to `[]`.

`argv` must have a nonempty executable at index zero. Later arguments can be empty. No argument may contain NUL. Arguments are kept as supplied and never interpreted by a shell. MCP URLs follow the same validation as model endpoints. F06 owns discovery, connections, and revision-specific protocol behavior.

### Custom tools

Each entry requires `name`, `description`, `schema`, and `argv`. Optional fields are `environment`, `inherit_environment`, and `timeout_ms`.

Names match `[A-Za-z0-9_-]{1,64}`, must be unique, and cannot collide with the built-in names `read`, `edit`, `write`, or `exec`. Descriptions may be empty. `schema` must be a JSON object and becomes `CustomTool.schema_json`; F05 validates the supported schema semantics. `argv` follows the MCP rules. Environment defaults to `[]`, inheritance to `false`, and timeout to `30000` positive unsigned 64-bit milliseconds.

The list becomes `launch.custom_tools`. F12 maps these values into F05 descriptors and resolves explicit environment references. Selecting a tool is a separate decision in `enabled_tools`. The resolver preserves explicit arguments and environment references for the host. For shell execution, declare an executable such as `sh` in `argv`.

### Runtime limits

Every member of `limits` must be positive. The first eleven use `usize`; `model_turns` and `tool_calls` use unsigned 32-bit integers.

| Key | Default |
| --- | ---: |
| `wire_message_bytes` | 8388608 |
| `json_depth` | 64 |
| `pending_requests` | 64 |
| `pending_events` | 64 |
| `active_commands` | 16 |
| `server_stderr_bytes` | 262144 |
| `catalog_pages` | 128 |
| `catalog_bytes` | 16777216 |
| `tool_argument_bytes` | 1048576 |
| `tool_output_bytes` | 65536 |
| `transcript_bytes` | 33554432 |
| `model_turns` | 100 |
| `tool_calls` | 1000 |

### Process controls

| Key | Value | Default |
| --- | --- | --- |
| `file_bytes` | Positive `usize` | 8388608 |
| `environment` | Environment array | `[]` |
| `inherit_environment` | Boolean | `false` |
| `timeout_ms` | Positive unsigned 64-bit integer | 30000 |
| `cleanup_ms` | Positive unsigned 64-bit integer | 2000 |

F12 maps these controls into F05's built-in and registry options. Custom-tool and MCP environments are separate declarations and do not inherit `process.environment`.

### Session storage

`session.directory` is null or a nonempty path. Null disables persistence. `session.limits` merges the following positive integer fields and matches F07's `Limits` names:

| Key | Type | Default |
| --- | --- | ---: |
| `max_record_bytes` | `usize` | 8388608 |
| `max_journal_bytes` | Unsigned 64-bit | 268435456 |
| `max_context_bytes` | `usize` | 33554432 |
| `max_artifact_bytes` | Unsigned 64-bit | 67108864 |
| `max_artifacts` | `usize` | 1024 |

The host creates or opens the directory explicitly and passes it to F07. Journal access and resume happen in the host.

### TUI settings

`tui.keys` merges `submit`, `newline`, `cancel`, and `quit`. Defaults are `enter`, `alt+enter`, `ctrl+c`, and `ctrl+d`, respectively. Accepted values are `enter`, `alt+enter`, `ctrl+enter`, `ctrl+c`, `ctrl+d`, `ctrl+j`, `ctrl+q`, and `escape`. The final bindings must be distinct.

`tui.colors` merges `assistant`, `tool`, `error`, and `status`. Defaults are `default`, `cyan`, `red`, and `bright_black`. Accepted values are `default`, `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, and `bright_` prefixed variants of the eight named colors. F11 owns interpretation of these settings and terminal capability fallback.

## Resource bounds and effective output

Configuration limits are fixed at 64 layers, 1 MiB per JSON layer, 8 MiB total JSON, 64 open JSON containers, 1 MiB final prompt, and 16 MiB serialized effective output. Limits apply before parsing or retaining oversized file contents. Configuration allocation is proportional to bounded JSON trees and surviving prompt data. `operation.check()` runs before work, between layers, between file reads, and before return.

`effectiveJson` emits a diagnostic JSON object with `runtime`, `launch`, and `prompt_files`. It retains `runtime.provenance` and uses the shared contract's union representation. Use the result for inspection. Load settings with the profile schema above. It replaces all literal header and environment values with `<redacted>`, keeps environment reference names, hides endpoint and MCP URL queries, and replaces every nonempty model-options object with a redaction marker. Other values, including prompts, command arguments, descriptions, paths, and schemas, remain visible; credential values belong in declared credential or environment fields.

Output size is counted before allocating the exact result buffer. The serializer uses only the supplied settings. A failed output bound returns `LimitExceeded`.

## Examples and verification

[Minimal profile](examples/minimal.json) contains only the explicit provider selection. [Customized profile](examples/customized.json) includes prompt, tool, MCP, process, session, and TUI settings. The examples use fixture hosts and no real credentials. [The acceptance suite](../../tests/config/README.md) documents its direct Zig command and includes a redacted effective fixture.

Root test registration and frontend wiring remain F12 work. Provider adapters validate model options before sending a request. The tool registry validates executable tool schemas before admitting a tool.
