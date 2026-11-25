const std = @import("std");
const root = @import("root.zig");
const oauth = @import("oauth.zig");
const Error = root.Error;
const OAuth = root.OAuth;

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const issuer = "https://auth.openai.com";
const authorize_url = issuer ++ "/oauth/authorize";
const token_url = issuer ++ "/oauth/token";
const callback_port = 1455;
const callback_path = "/auth/callback";
const redirect_uri = std.fmt.comptimePrint("http://localhost:{d}{s}", .{ callback_port, callback_path });
const device_code_url = issuer ++ "/api/accounts/deviceauth/usercode";
const device_token_url = issuer ++ "/api/accounts/deviceauth/token";
const device_page = issuer ++ "/codex/device";
const device_redirect_uri = issuer ++ "/deviceauth/callback";
const device_timeout_ms = 15 * 60 * 1000;
const callback_timeout_ms = 120 * 1000;
const account_claim: []const []const u8 = &.{ "https://api.openai.com/auth", "chatgpt_account_id" };

pub const flow: root.Flow = .{
    .provider = "openai-codex",
    .browser = browser,
    .device = device,
    .refresh = refresh,
    .account_header = "chatgpt-account-id",
};

fn browser(login: root.Login) Error!OAuth {
    var callback = oauth.Callback.listen(login.operation.io, callback_port) catch |err| switch (err) {
        error.Unavailable => return device(login),
        else => |e| return e,
    };
    defer callback.close(login.operation.io);
    const pkce = try oauth.Pkce.generate(login.operation.io);
    const state = try oauth.state(login.operation.io);
    const url = try oauth.authorizeUrl(login.a, authorize_url, &.{
        .{ .name = "response_type", .value = "code" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "scope", .value = "openid profile email offline_access" },
        .{ .name = "code_challenge", .value = &pkce.challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "state", .value = &state },
        .{ .name = "id_token_add_organizations", .value = "true" },
        .{ .name = "codex_cli_simplified_flow", .value = "true" },
        .{ .name = "originator", .value = "foo" },
    });
    try login.prompt.show(login.operation, .{ .url = url });
    const code = try callback.wait(login.a, login.operation, callback_path, &state, callback_timeout_ms) orelse return device(login);
    return credential(login.a, try client(login).exchangeCode(token_url, client_id, code, &pkce.verifier, redirect_uri));
}

fn device(login: root.Login) Error!OAuth {
    const http = client(login);
    const started = try http.post(device_code_url, .{ .json = try std.json.Stringify.valueAlloc(login.a, .{ .client_id = client_id }, .{}) });
    if (started.status != 200) return oauth.statusError(started.status);
    const Started = struct { device_auth_id: []const u8, user_code: []const u8, interval: std.json.Value = .null };
    const info = std.json.parseFromSliceLeaky(Started, login.a, started.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.Authentication;
    const interval_s: u64 = switch (info.interval) {
        .integer => |n| std.math.cast(u64, n) orelse return error.Authentication,
        .string => |text| std.fmt.parseInt(u64, std.mem.trim(u8, text, " "), 10) catch return error.Authentication,
        .null => 5,
        else => return error.Authentication,
    };
    if (info.device_auth_id.len == 0 or info.user_code.len == 0) return error.Authentication;
    try login.prompt.show(login.operation, .{ .device_code = .{ .uri = device_page, .code = info.user_code } });

    const Grant = struct { authorization_code: []const u8, code_verifier: []const u8 };
    const Poller = struct {
        http: oauth.Client,
        body: []const u8,

        pub fn poll(self: @This()) Error!oauth.Poll(Grant) {
            const response = try self.http.post(device_token_url, .{ .json = self.body });
            if (response.status == 200) return .{ .done = std.json.parseFromSliceLeaky(Grant, self.http.a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.Authentication };
            if (response.status == 403 or response.status == 404) return .pending;
            const code = oauth.errorCode(self.http.a, response.body) orelse return oauth.statusError(response.status);
            if (std.mem.eql(u8, code, "deviceauth_authorization_pending")) return .pending;
            if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
            return oauth.statusError(response.status);
        }
    };
    const body = try std.json.Stringify.valueAlloc(login.a, .{ .device_auth_id = info.device_auth_id, .user_code = info.user_code }, .{});
    const grant = try oauth.pollDevice(Grant, login.operation, .{ .interval_ms = interval_s *| 1000, .expires_ms = device_timeout_ms }, Poller{ .http = http, .body = body });
    return credential(login.a, try http.exchangeCode(token_url, client_id, grant.authorization_code, grant.code_verifier, device_redirect_uri));
}

fn refresh(request: root.Refresh) Error!OAuth {
    const http: oauth.Client = .{ .a = request.a, .operation = request.operation, .http = request.http };
    return credential(request.a, try http.refresh(token_url, client_id, request.current));
}

fn client(login: root.Login) oauth.Client {
    return .{ .a = login.a, .operation = login.operation, .http = login.http };
}

fn credential(a: std.mem.Allocator, tokens: oauth.Tokens) Error!OAuth {
    var result = tokens.oauth;
    if (result.refresh == null) return error.Authentication;
    result.account = oauth.jwtClaim(a, result.access, account_claim) orelse
        oauth.jwtClaim(a, tokens.id_token orelse return error.Authentication, account_claim) orelse
        return error.Authentication;
    return result;
}
