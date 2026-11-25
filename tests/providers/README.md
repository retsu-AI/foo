# Run the provider tests

Run the deterministic fixtures with Zig 0.17.1.

```sh
nix develop .#ci -c zig build test -Dmodule=providers
```

For ReleaseSafe, add `-Doptimize=ReleaseSafe`. The fixtures call the production provider interface and record request bytes, headers, fragmented SSE, deltas, terminal responses, and delivery states.

## Test a LiteLLM tool continuation

On Linux, build the probe with the pinned HTTP transport.

```sh
nix develop .#ci -c sh tests/providers/build-probe.sh /tmp/foo-provider-probe
```

Use an installed LiteLLM Proxy executable. The fixture was exercised with `litellm[proxy]==1.110.2`. The test starts a local instance and a local Gemini fixture. The fixture requires the original thought signature and a correlated tool result on the second request. No upstream key or account is required.

```sh
python3 tests/providers/gateway.py /tmp/foo-provider-probe "$(command -v litellm)"
```

## Probe an authenticated endpoint

The probe makes one text request and prints a JSON report with the terminal reason and usage. Pass the name of the environment variable that holds the key. For an unauthenticated local endpoint, pass `-`.

```sh
/tmp/foo-provider-probe openai_chat \
  https://api.deepseek.com/chat/completions deepseek-v4-pro DEEPSEEK_API_KEY \
  '{"chat_token_limit":"max_tokens","chat_reasoning_content":true}'

/tmp/foo-provider-probe openai_chat \
  https://bedrock-runtime.us-west-2.amazonaws.com/openai/v1/chat/completions \
  openai.gpt-oss-20b-1:0 AWS_BEARER_TOKEN_BEDROCK

/tmp/foo-provider-probe openai_chat \
  http://127.0.0.1:4000/v1/chat/completions my-model LITELLM_API_KEY
```

For a LiteLLM route, use the model alias configured on your gateway. For Bedrock, use the model or inference profile ID and endpoint for your region. Bedrock compatibility routes accept a Bedrock API key. LiteLLM can also manage credentials and call native Bedrock APIs on the gateway side. [Bedrock Chat Completions](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html) · [LiteLLM provider directory](https://docs.litellm.ai/docs/providers)
