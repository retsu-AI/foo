const std = @import("std");
const root = @import("root.zig");
const oauth = @import("oauth.zig");
const Error = root.Error;
const OAuth = root.OAuth;

const client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const device_code_url = "https://auth.x.ai/oauth2/device/code";
const token_url = "https://auth.x.ai/oauth2/token";
const scope = "openid profile email offline_access grok-cli:access api:access";
const device_grant = "urn:ietf:params:oauth:grant-type:device_code";
const max_device_ms = 15 * 60 * 1000;

pub const flow: root.Flow = .{
    .provider = "xai",
    .device = device,
    .refresh = refresh,
};

fn device(login: root.Login) Error!OAuth {
    const http = client(login);
    const started = try http.post(device_code_url, .{ .form = &.{
        .{ .name = "client_id", .value = client_id },
        .{ .name = "scope", .value = scope },
        .{ .name = "referrer", .value = "foo" },
    } });
    if (started.status != 200) return oauth.statusError(started.status);
    const Started = struct {
        device_code: []const u8,
        user_code: []const u8,
        verification_uri: []const u8,
        verification_uri_complete: ?[]const u8 = null,
        interval: ?u64 = null,
        expires_in: u64,
    };
    const info = std.json.parseFromSliceLeaky(Started, login.a, started.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.Authentication;
    if (info.device_code.len == 0 or info.user_code.len == 0 or info.expires_in == 0) return error.Authentication;
    if (!https(info.verification_uri)) return error.Authentication;
    const page = info.verification_uri_complete orelse info.verification_uri;
    if (!https(page)) return error.Authentication;
    try login.prompt.show(login.operation, .{ .device_code = .{ .uri = page, .code = info.user_code } });

    const Poller = struct {
        http: oauth.Client,
        device_code: []const u8,

        pub fn poll(self: @This()) Error!oauth.Poll(oauth.Tokens) {
            const response = try self.http.post(token_url, .{ .form = &.{
                .{ .name = "grant_type", .value = device_grant },
                .{ .name = "client_id", .value = client_id },
                .{ .name = "device_code", .value = self.device_code },
            } });
            if (response.status == 200) return .{ .done = try oauth.parseTokens(self.http.a, std.Io.Timestamp.now(self.http.operation.io, .real).toMilliseconds(), response.body) };
            const code = oauth.errorCode(self.http.a, response.body) orelse return oauth.statusError(response.status);
            if (std.mem.eql(u8, code, "authorization_pending")) return .pending;
            if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
            return oauth.statusError(response.status);
        }
    };
    const interval_s = if (info.interval) |seconds| if (seconds == 0) 5 else seconds else 5;
    const tokens = try oauth.pollDevice(oauth.Tokens, login.operation, .{
        .interval_ms = interval_s *| 1000,
        .expires_ms = @min(info.expires_in *| 1000, max_device_ms),
        .wait_first = true,
    }, Poller{ .http = http, .device_code = info.device_code });
    if (tokens.oauth.refresh == null) return error.Authentication;
    return tokens.oauth;
}

fn refresh(request: root.Refresh) Error!OAuth {
    const http: oauth.Client = .{ .a = request.a, .operation = request.operation, .http = request.http };
    return (try http.refresh(token_url, client_id, request.current)).oauth;
}

fn client(login: root.Login) oauth.Client {
    return .{ .a = login.a, .operation = login.operation, .http = login.http };
}

/// The user opens this page in a browser, so an issuer response cannot point it at another scheme.
fn https(uri: []const u8) bool {
    const parsed = std.Uri.parse(uri) catch return false;
    const host = parsed.host orelse return false;
    return std.ascii.eqlIgnoreCase(parsed.scheme, "https") and !host.isEmpty();
}
