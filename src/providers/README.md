# Provider adapter reference

F04 implements streaming Responses, Chat Completions, and Anthropic Messages through the F01 HTTP transport and F02 SSE and JSON decoders. The adapter accepts text and function tools. It preserves provider replay data required for continuation. It does not run tools or choose models.

## Interface and ownership

`root.zig` exports `Adapter`, with the following fields.

| Field | Meaning |
| --- | --- |
| `transport` | Required `foo.io.HttpTransport`. |
| `credentials` | Optional `auth.CredentialSource` for provider credential references. The default resolves literals and the supplied environment. |
| `environment` | Optional borrowed `std.process.Environ.Map` for explicit header references and the default credential source. |
| `retry_attempts` | Additional attempts after eligible failures. Defaults to zero. |
| `scratch_allocator` | Internal allocation backing, defaults to `std.heap.page_allocator`. Separate from the result allocator. |

`Adapter.interface()` returns `foo.provider.Provider`. Requests, the environment map, and sink callbacks remain borrowed until `stream_fn` returns. Returned message slices belong to the caller's result allocator. Request, attempt, and per-event arenas reclaim intermediate allocations before return. No callback outlives the call.

The model endpoint is the complete request URL, including its path. The adapter uses the configured URL and the selected protocol family. The model ID goes to the wire unchanged. F12 owns application composition and the public library facade. [Provider routes and model settings](routes.md)

## Credentials and headers

`credential.environment`, `credential.literal`, and `credential.auth` resolve through the credential source. Responses and Chat send API keys in `Authorization: Bearer`. Messages sends API keys in `x-api-key` and includes `anthropic-version: 2023-06-01`. OAuth access tokens use `Authorization: Bearer` in every family. A missing, empty, or invalid key returns `Authentication` before transmission. `credential.none` permits local and explicitly unauthenticated endpoints.

All families send `Content-Type: application/json` and `Accept: text/event-stream`. Custom headers support literal values and explicit environment references. Header names are case-insensitive. Duplicate headers, invalid names or values, and overrides of managed headers return `InvalidInput`. Managed headers include authorization, API keys, content type, accept, Anthropic version, host, content length, transfer encoding, connection, expect, upgrade, TE, trailer, and keep-alive. At most 128 custom headers are accepted.

The built-in OAuth registry is empty. Configure a compatible API-key endpoint and its credential explicitly. [Credential commands](../auth/README.md)

## Request options

`Model.max_output_tokens` supplies `max_output_tokens` for Responses, `max_completion_tokens` for Chat, or `max_tokens` for Messages. `options_json` must be a bounded JSON object with unique keys. Unknown top-level options and attempts to override model, input, tools, streaming, credentials, or token-limit fields return `InvalidInput`. Unsupported enumerated values return `Rejected`.

The supported options are listed below. Protocol support does not promise that every model accepts every value. A remote rejection is returned to the caller.

| Option | Families | Accepted values |
| --- | --- | --- |
| `temperature` | All | Finite number from 0 through 2 for OpenAI shapes, or 0 through 1 for Messages. |
| `top_p` | All | Finite number from 0 through 1. |
| `parallel_tool_calls` | Responses, Chat | Boolean. |
| `reasoning` | Responses | Object containing only `effort` and `summary`. Effort accepts `none`, `minimal`, `low`, `medium`, `high`, `max`, or `xhigh`. Summary accepts `auto`, `concise`, or `detailed`. |
| `reasoning_effort` | Chat | `none`, `minimal`, `low`, `medium`, `high`, `max`, or `xhigh`. |
| `thinking` | Chat | Object containing only `type`, with `enabled` or `disabled`. Requires an endpoint that documents this extension. |
| `thinking` | Messages | `type: enabled` with `budget_tokens` of at least 1024 and below the configured output limit. `disabled` and `adaptive` accept no other fields. |
| `output_config` | Messages | Object containing only `effort`, with `low`, `medium`, `high`, or `max`. |

The following Chat options are consumed locally and are absent from the outgoing request.

| Option | Default | Effect |
| --- | --- | --- |
| `chat_token_limit` | `"max_completion_tokens"` | `"max_tokens"` selects the older token-limit field for endpoints such as DeepSeek. |
| `chat_include_usage` | `true` | Adds `stream_options: {include_usage: true}`. False omits that request field. |
| `chat_reasoning_content` | `false` | Accepts `delta.reasoning_content`, emits provisional reasoning, and retains its exact concatenated value for replay. |
| `chat_litellm` | `false` | Preserves message and tool `provider_specific_fields` objects in opaque replay. Exact tool IDs, including embedded thought signatures, survive normalization. |

LiteLLM metadata may appear once or repeat identically. Conflicting metadata replacements return `Rejected`. The adapter does not guess how to merge provider-native metadata.

Responses always sends `stream: true`, `store: false`, and `include: ["reasoning.encrypted_content"]`. Function schemas remain non-strict through `strict: false`. Chat requests one streamed completion and uses plain text content. Messages combines adjacent messages with the same native role, including consecutive tool results in one user turn, and puts system text in the top-level system array.

## Completion and replay

| Family | Accepted completion | Replay representation |
| --- | --- | --- |
| Responses | `response.completed` or supported `response.incomplete`, with the authoritative `response.output` array. | One opaque snapshot of the complete native output array, alongside normalized text and tools. The next request validates normalized content against this snapshot and sends each native item once, in its original order. |
| Chat | One explicit finish reason followed by `[DONE]`. A trailing usage-only chunk is accepted. | Optional opaque object containing reasoning content or LiteLLM metadata. Normalized text and tools remain the source of ordinary Chat messages. |
| Messages | Closed content blocks, an explicit stop reason, and `message_stop`. | Each signed thinking or redacted-thinking block remains opaque JSON in its original content position. |

Replay identity includes family, exact endpoint, and model. A mismatch returns `IncompatibleReplay`. Responses replay also checks assistant roles and exact normalized text and tool order, IDs, names, and argument strings. A changed transcript cannot silently retain a contradictory snapshot. Provider-native reasoning is never converted into generic prompt text. Generic `Block.reasoning` input is unsupported because it lacks the full replay identity and native structure.

Responses function argument deltas use the call ID from the corresponding indexed output item. Chat assembles indexed calls and returns them in index order. Messages requires sequential content blocks and reconstructs thinking and signature fragments without changing their bytes. Text, reasoning, and argument deltas are provisional. No response returns successfully after a missing terminal event.

Normal stops map to `end_turn`, function calls to `tool_use`, token exhaustion to `output_limit`, and refusal or filtering to `refusal`. Responses accepts incomplete reasons `max_output_tokens` and `content_filter`. Messages also maps `stop_sequence` to `end_turn` and `model_context_window_exceeded` to `output_limit`. Unknown stop reasons return `Rejected`. Missing usage stays unknown. Messages input usage includes fresh input, cache writes, and cache reads. Cache-read accounting uses native cached-token fields, including DeepSeek's `prompt_cache_hit_tokens` fallback.

Malformed OpenAI argument strings remain available to the core's correlated tool-error handling. Byte and depth limits still apply. Completed Messages tool input must be a JSON object. Partial arguments in a response marked `output_limit` never authorize tool execution.

Images, audio, video, hosted tools, deprecated Chat function calls, arbitrary structured-output options, and automatic conversion between providers are unsupported. Unknown output content returns a typed error instead of disappearing from the transcript.

## Bounds, failures, and retry

`wire_message_bytes` bounds the encoded request, each SSE event, and each parsed JSON value. SSE names are capped at 128 bytes and IDs at 1024 bytes. JSON depth uses F02's configured limit and its maximum supported depth. Each JSON decode has fixed scratch of `16 * input_bytes + 4096` bytes. Scratch exhaustion is `LimitExceeded`.

`transcript_bytes` separately bounds input context, received HTTP body bytes, and accumulated response state. State accounting includes metadata, copied strings, replay identity, provisional output, and normalized output. These charges are conservative because several representations can coexist. Function argument bytes and tool counts use their configured limits before callback emission. Input tool results use `tool_output_bytes`. Integer overflow, bounded-buffer exhaustion, and allocation failures return typed errors.

HTTP 401 and 403 return `Authentication`, 429 returns `RateLimited`, and 5xx returns `Unavailable`. Other unsuccessful statuses return `Rejected`. Successful responses require `text/event-stream`. Malformed JSON, duplicate JSON keys, inconsistent event names, and invalid stream state return `Protocol`. Truncated framing or a missing completion marker returns `Disconnected`. Provider error events preserve their typed error through the HTTP callback interface.

Transport retries apply to `Unavailable` or `Disconnected` while delivery is `unsent`, before any response head or bytes. An HTTP 401 on a bearer request can trigger one refresh and one retry when the credential source provides a refresh flow. Every attempt shares the original cancellation token and deadline.

## Verification and remaining qualification

[Provider fixtures and probe commands](../../tests/providers/README.md) cover deterministic codec behavior and local gateway integration. F13 still owns real-provider qualification, current model option compatibility, provider throttling, and native platform coverage. Synthetic fixtures and loopback responses do not establish live model behavior.

The protocol rules follow the official [OpenAI reasoning guide](https://developers.openai.com/api/docs/guides/reasoning), [OpenAI Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses), [Anthropic streaming guide](https://platform.claude.com/docs/en/build-with-claude/streaming), and [xAI reasoning guide](https://docs.x.ai/developers/model-capabilities/text/reasoning).
