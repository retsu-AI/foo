# Provider routes

Place each entry under the root `providers` object. Replace placeholders such as `<model>` and `<region>`. Set the root `model` to `provider-id/model-id`.

The family determines the route appended to `base_url`. A model's `endpoint` can supply a complete POST URL for a custom path. Use HTTPS for remote endpoints.

| Provider | Entry under `providers` | API notes |
| --- | --- | --- |
| OpenAI Responses | `"openai": {"family":"openai_responses","base_url":"https://api.openai.com/v1","credential":{"environment":"OPENAI_API_KEY"},"models":{"<model>":{}}}` | [Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create) |
| OpenAI Chat Completions | `"openai-chat": {"family":"openai_chat","base_url":"https://api.openai.com/v1","credential":{"environment":"OPENAI_API_KEY"},"models":{"<model>":{}}}` | [Chat Completions API](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) |
| Anthropic | `"anthropic": {"family":"anthropic_messages","base_url":"https://api.anthropic.com/v1","credential":{"environment":"ANTHROPIC_API_KEY"},"models":{"<model>":{}}}` | [Messages API](https://platform.claude.com/docs/en/api/messages/create) |
| xAI | `"xai": {"family":"openai_responses","base_url":"https://api.x.ai/v1","credential":{"environment":"XAI_API_KEY"},"models":{"grok-4.7":{}}}` | Responses carries encrypted reasoning across tool turns. [Reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning) |
| DeepSeek | `"deepseek": {"family":"openai_chat","base_url":"https://api.deepseek.com","credential":{"environment":"DEEPSEEK_API_KEY"},"models":{"deepseek-flash":{},"deepseek-v4-pro":{}}}` | See the thinking options below. [Chat API](https://api-docs.deepseek.com/api/create-chat-completion/) |
| LiteLLM | `"litellm": {"family":"openai_chat","base_url":"http://127.0.0.1:4000/v1","credential":{"environment":"LITELLM_API_KEY"},"options":{"chat_litellm":true},"models":{"<alias>":{}}}` | Use the gateway's model alias and virtual key. Set `chat_reasoning_content` to `true` for upstreams that return it. [LiteLLM gateway](https://docs.litellm.ai/docs/simple_proxy) |
| Amazon Bedrock Runtime | `"bedrock": {"family":"openai_chat","base_url":"https://bedrock-runtime.<region>.amazonaws.com/openai/v1","credential":{"environment":"AWS_BEARER_TOKEN_BEDROCK"},"models":{"openai.gpt-oss-20b-1:0":{}}}` | Use `openai_responses` for a Responses model supported in the region. [Chat routes](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html) · [Responses routes](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html) |
| Amazon Bedrock Mantle | `"mantle": {"family":"openai_responses","base_url":"https://bedrock-mantle.<region>.api.aws/v1","credential":{"environment":"AWS_BEARER_TOKEN_BEDROCK"},"models":{"<model>":{}}}` | Use the protocol and path prefix from the model card. Some models use `/openai/v1`. [Bedrock endpoints](https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html) |
| Claude on Amazon Bedrock | `"bedrock-claude": {"family":"anthropic_messages","base_url":"https://bedrock-runtime.<region>.amazonaws.com/anthropic/v1","credential":{"environment":"AWS_BEARER_TOKEN_BEDROCK"},"models":{"<model>":{}}}` | The adapter sends the key in `x-api-key`. The base URL can also use the regional Mantle host. [Bedrock Messages](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html) |
| Google Gemini through LiteLLM | `"gemini-gateway": {"family":"openai_chat","base_url":"<gateway-base-url>","credential":{"environment":"LITELLM_API_KEY"},"options":{"chat_litellm":true},"models":{"<gemini-alias>":{}}}` | The local gateway test verifies signed function-call history. Direct signed tool continuations need separate qualification. [Google OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai) · [Thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures) |
| Mistral, Azure, Vertex AI, Groq, and local models through LiteLLM | `"upstream-gateway": {"family":"openai_chat","base_url":"<gateway-base-url>","credential":{"environment":"LITELLM_API_KEY"},"options":{"chat_litellm":true},"models":{"<alias>":{}}}` | [LiteLLM provider directory](https://docs.litellm.ai/docs/providers) |

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

The deterministic suite covers request encoding and streaming behavior for the three codecs, with route fixtures for the named xAI, DeepSeek, Bedrock, and LiteLLM settings. The local LiteLLM test runs the real HTTP transport and proxy with a simulated Gemini upstream. Hosted model access, Bedrock IAM and region support, and live tool behavior depend on the deployed key, model, and endpoint. Direct SigV4 and the native Converse and InvokeModel protocols require a gateway that implements them. [Provider test and probe commands](../../tests/providers/README.md)
