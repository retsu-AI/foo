//! The only place a built-in provider is declared. Order is the zero-config priority.
const cfg = @import("foo").config;

pub const Record = struct {
    /// The auth store key and CLI id.
    id: []const u8,
    name: []const u8,
    family: cfg.Family,
    base_url: []const u8,
    /// API key variables in lookup order. Empty means a stored credential only.
    env: []const []const u8 = &.{},
    headers: []const cfg.Header = &.{},
    options_json: []const u8 = "{}",
    /// Must be in the merged catalog. The build fails otherwise.
    default_model: []const u8,
    /// Where `zig build catalog` reads the model list.
    models_dev: Source = .same_id,
    /// Models that models.dev lacks, sorted by id. The build fails once models.dev lists one,
    /// so a stale hand entry is deleted on the refresh that makes it redundant.
    extra_models: []const cfg.CatalogModel = &.{},

    pub const Source = union(enum) { none, same_id, id: []const u8 };

    pub fn modelsDevId(self: Record) ?[]const u8 {
        return switch (self.models_dev) {
            .none => null,
            .same_id => self.id,
            .id => |id| id,
        };
    }
};

const reasoning = "{\"chat_reasoning_content\":true}";
const user_agent: []const cfg.Header = &.{.{ .name = "user-agent", .value = .{ .literal = "foo" } }};

pub const list = [_]Record{
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .family = .anthropic_messages,
        .base_url = "https://api.anthropic.com/v1",
        .env = &.{"ANTHROPIC_API_KEY"},
        .default_model = "claude-sonnet-5-5",
    },
    .{
        .id = "openai-codex",
        .name = "ChatGPT (Codex)",
        .family = .openai_responses,
        .base_url = "https://chatgpt.com/backend-api/codex",
        .headers = &.{.{ .name = "originator", .value = .{ .literal = "foo" } }},
        .default_model = "gpt-6.2-sol",
        .models_dev = .none,
        // Context windows are what /backend-api/codex/models returned in November 2026.
        .extra_models = &.{
            .{ .id = "gpt-5.6-luna", .name = "GPT-5.6 Luna", .output_limit = 128000, .context_limit = 272000 },
            .{ .id = "gpt-5.6-sol", .name = "GPT-5.6 Sol", .output_limit = 128000, .context_limit = 272000 },
            .{ .id = "gpt-5.6-terra", .name = "GPT-5.6 Terra", .output_limit = 128000, .context_limit = 272000 },
            .{ .id = "gpt-6-astra", .name = "GPT-6 Astra", .output_limit = 128000, .context_limit = 272000 },
            .{ .id = "gpt-6-luna", .name = "GPT-6 Luna", .output_limit = 128000, .context_limit = 272000 },
            .{ .id = "gpt-6-sol", .name = "GPT-6 Sol", .output_limit = 128000, .context_limit = 272000 },
            .{ .id = "gpt-6.1-sol", .name = "GPT-6.1 Sol", .output_limit = 128000, .context_limit = 500000 },
            .{ .id = "gpt-6.1-terra", .name = "GPT-6.1 Terra", .output_limit = 128000, .context_limit = 500000 },
            .{ .id = "gpt-6.2-astra", .name = "GPT-6.2 Astra", .output_limit = 128000, .context_limit = 272000 },
            .{ .id = "gpt-6.2-sol", .name = "GPT-6.2 Sol", .output_limit = 128000, .context_limit = 500000 },
        },
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .family = .openai_responses,
        .base_url = "https://api.openai.com/v1",
        .env = &.{"OPENAI_API_KEY"},
        .default_model = "gpt-6.2-sol",
    },
    .{
        .id = "xai",
        .name = "xAI",
        .family = .openai_responses,
        .base_url = "https://api.x.ai/v1",
        .env = &.{"XAI_API_KEY"},
        .default_model = "grok-4.7",
    },
    .{
        .id = "meta",
        .name = "Meta",
        .family = .openai_responses,
        .base_url = "https://api.meta.ai/v1",
        .env = &.{ "META_API_KEY", "META_MODEL_API_KEY" },
        .default_model = "muse-spark-1.3",
    },
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .family = .openai_chat,
        .base_url = "https://api.deepseek.com",
        .env = &.{"DEEPSEEK_API_KEY"},
        .options_json = "{\"chat_reasoning_content\":true,\"chat_token_limit\":\"max_tokens\"}",
        .default_model = "deepseek-v4-pro",
    },
    .{
        .id = "zai",
        .name = "Z.ai",
        .family = .openai_chat,
        .base_url = "https://api.z.ai/api/paas/v4",
        .env = &.{ "ZAI_API_KEY", "ZHIPU_API_KEY" },
        .options_json = reasoning,
        .default_model = "glm-5.3",
    },
    .{
        .id = "zai-coding-plan",
        .name = "Z.ai Coding Plan",
        .family = .openai_chat,
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .env = &.{ "ZAI_API_KEY", "ZHIPU_API_KEY" },
        .options_json = reasoning,
        .default_model = "glm-5.4",
    },
    .{
        .id = "moonshotai",
        .name = "Moonshot AI",
        .family = .openai_chat,
        .base_url = "https://api.moonshot.ai/v1",
        .env = &.{"MOONSHOT_API_KEY"},
        .options_json = reasoning,
        .default_model = "kimi-k3.1-pro",
    },
    .{
        .id = "kimi-coding",
        .name = "Kimi Code",
        .family = .openai_chat,
        .base_url = "https://api.kimi.ai/coding/v1",
        .env = &.{"KIMI_API_KEY"},
        .options_json = reasoning,
        .default_model = "kimi-for-coding",
        .models_dev = .{ .id = "kimi-code-plan-global" },
    },
    .{
        .id = "minimax",
        .name = "MiniMax",
        .family = .anthropic_messages,
        .base_url = "https://api.minimax.io/anthropic/v1",
        .env = &.{"MINIMAX_API_KEY"},
        .default_model = "MiniMax-M3",
    },
    .{
        .id = "alibaba",
        .name = "Alibaba (Qwen)",
        .family = .openai_chat,
        .base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        .env = &.{"DASHSCOPE_API_KEY"},
        .options_json = reasoning,
        .default_model = "qwen4-max",
    },
    .{
        .id = "opencode",
        .name = "OpenCode Zen",
        .family = .openai_chat,
        .base_url = "https://opencode.ai/inference/openai/v1",
        .env = &.{"OPENCODE_API_KEY"},
        .headers = user_agent,
        .options_json = reasoning,
        .default_model = "claude-sonnet-5-5",
    },
    .{
        .id = "opencode-go",
        .name = "OpenCode Go",
        .family = .openai_chat,
        .base_url = "https://opencode.ai/inference/go/openai/v1",
        .env = &.{"OPENCODE_API_KEY"},
        .headers = user_agent,
        .options_json = reasoning,
        .default_model = "kimi-k3",
    },
};
