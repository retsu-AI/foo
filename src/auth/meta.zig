//! Meta splits identity from API access. The device grant at auth.meta.com yields an identity
//! token that inference rejects, so it is exchanged for a Model API key that lives about a day.
//! The key is stored as `access` and the identity token as `refresh`; a refresh re-mints the key.
//! The identity token itself cannot be renewed, so 401/403 from the mint means log in again.
const std = @import("std");
const root = @import("root.zig");
const oauth = @import("oauth.zig");
const Error = root.Error;
const OAuth = root.OAuth;

const client_id = "1031625952748946";
const device_code_url = "https://auth.meta.com/oidc/device/authorization/";
const token_url = "https://auth.meta.com/oidc/device/token/";
const mint_url = "https://api.meta.ai/muse-code/key";
const device_grant = "urn:ietf:params:oauth:grant-type:device_code";
const key_lifetime_ms = 24 * 60 * 60 * 1000;
const max_device_ms = 15 * 60 * 1000;

pub const flow: root.Flow = .{
    .provider = "meta",
    .device = device,
    .refresh = refresh,
};

fn device(login: root.Login) Error!OAuth {
    const http = client(login);
    const started = try http.post(device_code_url, .{ .form = &.{.{ .name = "client_id", .value = client_id }} });
    if (started.status != 200) return oauth.statusError(started.status);
    const Started = struct {
        device_code: []const u8,
        user_code: []const u8,
        verification_uri: []const u8,
        verification_uri_complete: ?[]const u8 = null,
        interval: ?u64 = null,
        expires_in: ?u64 = null,
    };
    const info = std.json.parseFromSliceLeaky(Started, login.a, started.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.Authentication;
    if (info.device_code.len == 0 or !oauth.printable(info.user_code)) return error.Authentication;
    if (!oauth.https(info.verification_uri)) return error.Authentication;
    const complete = info.verification_uri_complete orelse "";
    const page = if (complete.len == 0) info.verification_uri else complete;
    if (!oauth.https(page)) return error.Authentication;
    try login.prompt.show(login.operation, .{ .device_code = .{ .uri = page, .code = info.user_code } });

    const Poller = struct {
        http: oauth.Client,
        device_code: []const u8,

        pub fn poll(self: @This()) Error!oauth.Poll([]const u8) {
            const response = try self.http.post(token_url, .{ .form = &.{
                .{ .name = "grant_type", .value = device_grant },
                .{ .name = "device_code", .value = self.device_code },
                .{ .name = "client_id", .value = client_id },
            } });
            if (response.status == 200) {
                const Granted = struct { access_token: []const u8 };
                const granted = std.json.parseFromSliceLeaky(Granted, self.http.a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.Authentication;
                if (granted.access_token.len == 0) return error.Authentication;
                return .{ .done = granted.access_token };
            }
            const code = oauth.errorCode(self.http.a, response.body) orelse return oauth.statusError(response.status);
            if (std.mem.eql(u8, code, "authorization_pending")) return .pending;
            if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
            return oauth.statusError(response.status);
        }
    };
    const interval_s = if (info.interval) |seconds| if (seconds == 0) 5 else seconds else 5;
    const expires_s = if (info.expires_in) |seconds| if (seconds == 0) 900 else seconds else 900;
    const identity = try oauth.pollDevice([]const u8, login.operation, .{
        .interval_ms = interval_s *| 1000,
        .expires_ms = @min(expires_s *| 1000, max_device_ms),
        .wait_first = true,
    }, Poller{ .http = http, .device_code = info.device_code });
    return mint(http, identity);
}

fn refresh(request: root.Refresh) Error!OAuth {
    const http: oauth.Client = .{ .a = request.a, .operation = request.operation, .http = request.http };
    return mint(http, request.current.refresh orelse return error.Authentication);
}

fn mint(http: oauth.Client, identity: []const u8) Error!OAuth {
    const bearer = try std.mem.concat(http.a, u8, &.{ "Bearer ", identity });
    const response = try http.postWith(mint_url, .{ .json = "{}" }, &.{
        .{ .name = "authorization", .value = bearer },
        .{ .name = "x-api-version", .value = "1.0.0" },
    });
    if (response.status == 401 or response.status == 403) return error.Authentication;
    if (response.status < 200 or response.status > 299) return oauth.statusError(response.status);
    const Minted = struct { api_key: ?[]const u8 = null };
    const minted = std.json.parseFromSliceLeaky(Minted, http.a, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.Authentication;
    const key = minted.api_key orelse return error.Authentication;
    if (key.len == 0) return error.Authentication;
    return .{
        .access = key,
        .refresh = identity,
        .expires_ms = std.Io.Timestamp.now(http.operation.io, .real).toMilliseconds() +| key_lifetime_ms,
    };
}

fn client(login: root.Login) oauth.Client {
    return .{ .a = login.a, .operation = login.operation, .http = login.http };
}
