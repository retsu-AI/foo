//! Built-in providers, merged below every user layer. One provider per line.
pub const json =
    \\{"providers":{
    \\"anthropic":{"family":"anthropic_messages","base_url":"https://api.anthropic.com/v1","credential":{"environment":"ANTHROPIC_API_KEY"}},
    \\"openai":{"family":"openai_responses","base_url":"https://api.openai.com/v1","credential":{"environment":"OPENAI_API_KEY"}},
    \\"openai-codex":{"family":"openai_responses","base_url":"https://chatgpt.com/backend-api/codex","credential":{"auth":"openai-codex"},"headers":[{"name":"originator","value":"foo"}]},
    \\"opencode":{"family":"openai_responses","base_url":"https://opencode.ai/inference/openai/v1","credential":{"auth":"opencode"},"headers":[{"name":"user-agent","value":"foo"}]},
    \\"opencode-go":{"family":"openai_responses","base_url":"https://opencode.ai/inference/go/openai/v1","credential":{"auth":"opencode-go"},"headers":[{"name":"user-agent","value":"foo"}]},
    \\"xai":{"family":"openai_responses","base_url":"https://api.x.ai/v1","credential":{"auth":"xai"}}
    \\}}
;
