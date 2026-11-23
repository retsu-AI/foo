# Provider routes

Set `Model.endpoint` to the complete POST URL. Set `Model.id` to a model ID, a deployment ID, or a gateway alias. Set `Model.credential` to an environment variable reference. Keep the key in that variable. Use HTTPS for remote endpoints.

| Provider | Family | Endpoint | Model and credential |
| --- | --- | --- | --- |
| OpenAI | `openai_responses` | `https://api.openai.com/v1/responses` | Responses model ID and `OPENAI_API_KEY`. [API reference](https://developers.openai.com/api/reference/resources/responses/methods/create) |
| OpenAI | `openai_chat` | `https://api.openai.com/v1/chat/completions` | Chat Completions model ID and `OPENAI_API_KEY`. [API reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) |
| Anthropic | `anthropic_messages` | `https://api.anthropic.com/v1/messages` | Claude model ID and `ANTHROPIC_API_KEY`. [Messages API](https://platform.claude.com/docs/en/api/messages/create) |
| xAI | `openai_responses` | `https://api.x.ai/v1/responses` | For example, `grok-4.7` and `XAI_API_KEY`. Responses carries encrypted reasoning across tool turns. [Reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning) |
| DeepSeek | `openai_chat` | `https://api.deepseek.com/chat/completions` | `deepseek-flash` or `deepseek-v4-pro` and `DEEPSEEK_API_KEY`. Set the options below for thinking mode. [Chat API](https://api-docs.deepseek.com/api/create-chat-completion/) · [Thinking mode](https://api-docs.deepseek.com/guides/thinking_mode/) |
| LiteLLM | `openai_chat` | For example, `http://127.0.0.1:4000/v1/chat/completions` | The gateway's model alias and virtual key. Set `chat_litellm` to `true`. For upstreams that return `reasoning_content`, also set `chat_reasoning_content` to `true`. [LiteLLM gateway](https://docs.litellm.ai/docs/simple_proxy) |
| Amazon Bedrock Runtime | `openai_chat` or `openai_responses` | `https://bedrock-runtime.<region>.amazonaws.com/openai/v1/chat/completions` or `/openai/v1/responses` | Use a model or inference profile supported by the regional endpoint and protocol, such as `openai.gpt-oss-20b-1:0` for Chat. Set `AWS_BEARER_TOKEN_BEDROCK` to a Bedrock API key. [Chat routes](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html) · [Responses routes](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html) |
| Amazon Bedrock Mantle | `openai_chat` or `openai_responses` | `https://bedrock-mantle.<region>.api.aws/v1/chat/completions` or `/v1/responses` | Use the Bedrock API key and the model ID and path prefix from the model card. Some models use `/openai/v1`. [Bedrock endpoints](https://docs.aws.amazon.com/bedrock/latest/userguide/endpoints.html) |
| Claude on Amazon Bedrock | `anthropic_messages` | `https://bedrock-runtime.<region>.amazonaws.com/anthropic/v1/messages` or `https://bedrock-mantle.<region>.api.aws/anthropic/v1/messages` | Use the regional Claude model or inference profile and a Bedrock API key. The adapter sends this key in `x-api-key`. [Bedrock Messages](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-messages-api.html) |
| Google Gemini | `openai_chat` via LiteLLM | The LiteLLM Chat Completions URL | Use a gateway alias for the Gemini model. The local gateway test verifies signed function-call history. Google's direct Chat-compatible route is a candidate for text, and direct signed tool continuations need separate qualification. [Google OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai) · [Thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures) |
| Mistral, Azure, Vertex AI, Groq, and local models | `openai_chat` via LiteLLM | The LiteLLM Chat Completions URL | Use a configured gateway alias with the capabilities your model requires. [LiteLLM provider directory](https://docs.litellm.ai/docs/providers) |

## DeepSeek thinking options

Set `Model.options_json` to the following object. The Chat codec sends the value of `Model.max_output_tokens` as `max_tokens`. It copies the model's `reasoning_content` into subsequent assistant history for the same endpoint and model.

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
