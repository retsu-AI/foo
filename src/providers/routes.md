# Provider routes

Fourteen providers are built in with their models. Run `foo auth login` to list them with their login methods and environment variables, and `foo models --all` to list every model. A built-in works with zero configuration once `foo auth login PROVIDER` has stored a credential or the provider's variable is set; the stored credential wins. `--model PROVIDER/ID` accepts any model id for a built-in, so a catalog refresh never breaks a working selection. The catalog comes from a checked-in [models.dev](https://models.dev) snapshot in `src/builtins/catalog.zig`; `src/builtins/records.zig` holds one record per provider.

| Built-in | Default model | Protocol and notes |
| --- | --- | --- |
| `anthropic` | `claude-sonnet-5-5` | Messages at `https://api.anthropic.com/v1`. `ANTHROPIC_API_KEY`. [Messages API](https://platform.claude.com/docs/en/api/messages/create) |
| `openai-codex` | `gpt-6.2-sol` | Responses at `https://chatgpt.com/backend-api/codex` with a ChatGPT subscription. `foo auth login openai-codex` opens the browser or falls back to the device flow. Header `originator: foo`. models.dev does not list these models; `records.zig` carries them. See the Codex note below. |
| `openai` | `gpt-6.2-sol` | Responses at `https://api.openai.com/v1`. `OPENAI_API_KEY`. [Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create) |
| `xai` | `grok-4.7` | Responses at `https://api.x.ai/v1`. `foo auth login xai` signs in with SuperGrok or X Premium; `XAI_API_KEY` or `--api-key` stores a key. Encrypted reasoning carries across tool turns. [Reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning) |
| `meta` | `muse-spark-1.3` | Responses at `https://api.meta.ai/v1`. `foo auth login meta` signs in with a Muse subscription through the device flow and mints a Model API key; `META_API_KEY` or `META_MODEL_API_KEY` supplies one directly. |
| `deepseek` | `deepseek-v4-pro` | Chat Completions at `https://api.deepseek.com` with `chat_reasoning_content` and `chat_token_limit: max_tokens`. `DEEPSEEK_API_KEY`. See the thinking options below. [Chat API](https://api-docs.deepseek.com/api/create-chat-completion/) |
| `zai` | `glm-5.3` | Chat Completions at `https://api.z.ai/api/paas/v4`. `ZAI_API_KEY` or `ZHIPU_API_KEY`. |
| `zai-coding-plan` | `glm-5.4` | Chat Completions at `https://api.z.ai/api/coding/paas/v4`. Same variables as `zai`. |
| `moonshotai` | `kimi-k3.1-pro` | Chat Completions at `https://api.moonshot.ai/v1`. `MOONSHOT_API_KEY`. |
| `kimi-coding` | `kimi-for-coding` | Chat Completions at `https://api.kimi.ai/coding/v1`. `KIMI_API_KEY`. models.dev lists it as `kimi-code-plan-global`. |
| `minimax` | `MiniMax-M3` | Messages at `https://api.minimax.io/anthropic/v1`. `MINIMAX_API_KEY`. The adapter sends the key in `x-api-key`. |
| `alibaba` | `qwen4-max` | Chat Completions at `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`. `DASHSCOPE_API_KEY`. |
| `opencode` | `claude-sonnet-5-5` | Chat Completions at `https://opencode.ai/inference/openai/v1`. `foo auth login opencode --api-key` or `OPENCODE_API_KEY`. Claude models route to `/inference/anthropic/v1` and GPT models to Responses at the same origin, so the stored key is inherited. The adapter sends a random `x-opencode-session` per foo session to `opencode.ai`. [Zen](https://opencode.ai/docs/zen/) |
| `opencode-go` | `kimi-k3` | Chat Completions at `https://opencode.ai/inference/go/openai/v1`, with the same routing and session header. [Go](https://opencode.ai/docs/console/go/) |

Google and Mistral are not built in. Gemini's OpenAI-compatible endpoint needs `extra_content.google.thought_signature` replayed on tool calls, which the Chat codec drops, and Magistral streams `content` as typed chunks. Both work through a LiteLLM gateway below.

## User-configured providers

Place each entry under the root `providers` object. Replace placeholders such as `<model>` and `<region>`. Set the root `model` to `provider-id/model-id`. A user entry can override any built-in field or set the provider to `null`. A `base_url` on another origin drops the built-in credential, headers, and catalog, because a secret belongs to the server it was issued for. A different `family` keeps them all and only drops the per-model routes, so a stored login survives a protocol change. Give a moved provider its own `credential` before selecting it.

The family determines the route appended to `base_url`. A model's `endpoint` can supply a complete POST URL for a custom path. Use HTTPS for remote endpoints.

| Provider | Entry under `providers` | API notes |
| --- | --- | --- |
| OpenAI Chat Completions | `"openai-chat": {"family":"openai_chat","base_url":"https://api.openai.com/v1","credential":{"environment":"OPENAI_API_KEY"},"models":{"<model>":{}}}` | [Chat Completions API](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) |
| LiteLLM | `"litellm": {"family":"openai_chat","base_url":"http://127.0.0.1:4000/v1","credential":{"environment":"LITELLM_API_KEY"},"options":{"chat_litellm":true},"models":{"<alias>":{}}}` | Use the gateway's model alias and virtual key. Set `chat_reasoning_content` to `true` for upstreams that return it. [LiteLLM gateway](https://docs.litellm.ai/docs/simple_proxy) |
| Amazon Bedrock Runtime | `"bedrock": {"family":"openai_chat","base_url":"https://bedrock-runtime.<region>.amazonaws.com/openai/v1","credential":{"environment":"AWS_BEARER_TOKEN_BEDROCK"},"models":{"openai.gpt-oss-20b-1:0":{}}}` | Use `openai_responses` for a Responses model supported in the region. [Chat routes](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html) · [Responses routes](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html) |
| Amazon Bedrock Mantle | `"mantle": {"family":"openai_responses","base_url":"https://bedrock-mantle.<region>.api.aws/v1","credential":{"environment":"AWS_BEARER_TOKEN_BEDROCK"},"models":{"<model>":{}}}` | Use the protocol and path prefix from the model card. Some models use `/openai/v1`. [Bedrock endpoints](https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html) |
| Claude on Amazon Bedrock | `"bedrock-claude": {"family":"anthropic_messages","base_url":"https://bedrock-runtime.<region>.amazonaws.com/anthropic/v1","credential":{"environment":"AWS_BEARER_TOKEN_BEDROCK"},"models":{"<model>":{}}}` | The adapter sends the key in `x-api-key`. The base URL can also use the regional Mantle host. [Bedrock Messages](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html) |
| Google Gemini through LiteLLM | `"gemini-gateway": {"family":"openai_chat","base_url":"<gateway-base-url>","credential":{"environment":"LITELLM_API_KEY"},"options":{"chat_litellm":true},"models":{"<gemini-alias>":{}}}` | The local gateway test verifies signed function-call history. Direct signed tool continuations need separate qualification. [Google OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai) · [Thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures) |
| Mistral, Azure, Vertex AI, Groq, and local models through LiteLLM | `"upstream-gateway": {"family":"openai_chat","base_url":"<gateway-base-url>","credential":{"environment":"LITELLM_API_KEY"},"options":{"chat_litellm":true},"models":{"<alias>":{}}}` | [LiteLLM provider directory](https://docs.litellm.ai/docs/providers) |

## Adding a built-in provider

Add one record to `src/builtins/records.zig`: id, name, family, base URL, environment variables in lookup order, headers, provider options, and a `default_model`. Set `models_dev` when the models.dev id differs, or to `.none` with `extra_models` for a provider models.dev does not list. Then run `zig build catalog -Dmodels-dev=api.json` with a downloaded `https://models.dev/api.json` and commit the regenerated `catalog.zig`. The build fails until the default model is in the catalog. A subscription login adds `src/auth/<provider>.zig` and one line in `auth.flows`. The generator keeps tool-capable, non-deprecated chat models with text output, maps per-model `provider.npm` to a route on the same origin, and skips protocols foo has no codec for; the skip list lands in `zig-out/catalog-gen.log`. `.github/workflows/catalog.yml` opens a refresh PR every Monday with the check result in its title.

The `chat_*` option keys tune only the Chat Completions codec. Every family accepts and strips them, so a provider options block applies cleanly to models routed to Responses or Messages.

## OpenAI Codex backend

Checked on 2026-11-25 with a ChatGPT account. `POST https://chatgpt.com/backend-api/codex/responses` returned a 200 event stream for the standard Responses body, including `store: false`, `include: ["reasoning.encrypted_content"]`, `max_output_tokens`, and `instructions`. No field needed removal. The request carried `authorization: Bearer`, `chatgpt-account-id`, and `originator: foo`. The backend accepted `gpt-6.1-terra` and rejected `gpt-5.5-codex` and `gpt-5.5` with HTTP 400 `model_not_found`. The 200 response has no `Content-Type` header and includes a `response.metadata` event. The adapter accepts a missing content type and ignores that event. A one-turn reply and a `read` tool continuation with encrypted reasoning both completed through `foo run`.

## DeepSeek thinking options

Set `options` on the DeepSeek provider or model entry. With these options, the Chat codec sends the model's `max_output_tokens` as `max_tokens`. It copies `reasoning_content` into later assistant history for the same endpoint and model.

```json
{
  "chat_token_limit": "max_tokens",
  "chat_reasoning_content": true,
  "reasoning_effort": "high",
  "thinking": {"type": "enabled"}
}
```

DeepSeek also publishes Responses and Anthropic Messages routes. The DeepSeek fixture in this package covers Chat Completions with thinking and tools. [DeepSeek Responses](https://api-docs.deepseek.com/guides/responses_api/) · [DeepSeek Messages](https://api-docs.deepseek.com/guides/anthropic_api/)

For endpoints that reject `stream_options`, set `chat_include_usage` to `false`. The adapter records usage when the endpoint sends it.

## Verified routes

The deterministic suite covers request encoding and streaming behavior for the three codecs, with route fixtures for the named xAI, OpenCode, OpenCode Go, DeepSeek, Bedrock, and LiteLLM settings. The local LiteLLM test runs the real HTTP transport and proxy with a simulated Gemini upstream. Hosted model access, Bedrock IAM and region support, and live tool behavior depend on the deployed key, model, and endpoint. Direct SigV4 and the native Converse and InvokeModel protocols require a gateway that implements them. [Provider test and probe commands](../../tests/providers/README.md)
