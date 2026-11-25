const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const auth = @import("auth");
const support = @import("support");
const testing = std.testing;
const io = testing.io;
const allocator = testing.allocator;
const expect = testing.expect;
const equal = testing.expectEqual;
const same = testing.expectEqualStrings;

const oauth: auth.OAuth = .{ .access = "old-access", .refresh = "old-refresh", .expires_ms = 1, .account = "fixture-account" };
const updated: auth.OAuth = .{ .access = "new-access", .refresh = "new-refresh", .expires_ms = 2, .account = "fixture-account" };

fn operation() foo.io.Context {
    const State = struct {
        var clock: support.Clock = .{};
        const cancellation: foo.io.Cancellation = .{};
    };
    return .{ .io = io, .clock = State.clock.interface(), .cancellation = &State.cancellation };
}

fn awake() foo.io.Context {
    const State = struct {
        const cancellation: foo.io.Cancellation = .{};
        var std_io = io;

        fn now(_: *anyopaque) u64 {
            return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
        }
    };
    return .{ .io = io, .clock = .{ .context = &State.std_io, .now_fn = State.now }, .cancellation = &State.cancellation };
}

fn in(dir: std.Io.Dir) !auth.Store {
    const path = try dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    return .{ .directory = try allocator.dupe(u8, path) };
}

test "new store is private and each write replaces the previous file atomically" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);

    try store.put(allocator, operation(), "gateway", .{ .api_key = "first-key" });
    const original = try tmp.dir.openFile(io, "auth.json", .{});
    defer original.close(io);
    const before = try original.stat(io);
    if (builtin.os.tag != .windows) try equal(0o600, before.permissions.toMode() & 0o777);
    try store.put(allocator, operation(), "service", .{ .oauth = oauth });
    const after = try tmp.dir.statFile(io, "auth.json", .{});
    try expect(before.inode != after.inode);
    if (builtin.os.tag != .windows) try equal(0o600, after.permissions.toMode() & 0o777);

    var text: [1024]u8 = undefined;
    const count = try original.readPositionalAll(io, &text, 0);
    try expect(std.mem.indexOf(u8, text[0..count], "first-key") != null);
    try expect(std.mem.indexOf(u8, text[0..count], "old-access") == null);

    var snapshot = try store.read(allocator, operation());
    defer snapshot.deinit();
    try equal(2, snapshot.entries.count());
    try same("first-key", snapshot.entries.get("gateway").?.api_key);
    try same("old-access", snapshot.entries.get("service").?.oauth.access);
    try same("old-refresh", snapshot.entries.get("service").?.oauth.refresh.?);
    try same("fixture-account", snapshot.entries.get("service").?.oauth.account.?);
    try equal(1, snapshot.entries.get("service").?.oauth.expires_ms);

    try store.remove(allocator, operation(), "gateway");
    var latest = try store.read(allocator, operation());
    defer latest.deinit();
    try equal(1, latest.entries.count());
    try expect(latest.entries.get("gateway") == null);
}

test "store rejects exposed permissions, links, malformed input and oversized files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);

    try store.put(allocator, operation(), "gateway", .{ .api_key = "secret" });
    const file = try tmp.dir.openFile(io, "auth.json", .{ .mode = .read_write });
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o644));
    try testing.expectError(error.InsecurePermissions, store.read(allocator, operation()));
    try testing.expectError(error.InsecurePermissions, store.put(allocator, operation(), "other", .{ .api_key = "key" }));
    try file.setPermissions(io, .fromMode(0o600));
    try tmp.dir.hardLink("auth.json", tmp.dir, "hard-link", io, .{});
    try testing.expectError(error.UnsafeStore, store.read(allocator, operation()));
    try tmp.dir.deleteFile(io, "hard-link");

    try file.setLength(io, 0);
    try file.writePositionalAll(io, "{\"gateway\":{\"type\":\"api_key\",\"key\":\"one\"},\"gateway\":{\"type\":\"api_key\",\"key\":\"two\"}}", 0);
    try testing.expectError(error.InvalidStore, store.read(allocator, operation()));
    try file.setLength(io, 1_048_577);
    try testing.expectError(error.LimitExceeded, store.read(allocator, operation()));

    try tmp.dir.rename("auth.json", tmp.dir, "target", io);
    try tmp.dir.symLink(io, "target", "auth.json", .{});
    try testing.expectError(error.UnsafeStore, store.read(allocator, operation()));
}

test "Windows rejects a store file with inherited permissions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "{\"gateway\":{\"type\":\"api_key\",\"key\":\"fixture\"}}" });
    try testing.expectError(error.InsecurePermissions, store.read(allocator, operation()));
}

test "environment and store resolve only the requested credentials" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);
    var variables = std.process.Environ.Map.init(allocator);
    defer variables.deinit();
    try variables.put("FOO_KEY", "environment-key");
    try variables.put("EMPTY", "");
    const resolver = auth.Resolver{ .environment = &variables, .store = store };
    const source = resolver.interface();
    try same("environment-key", (try source.resolve(allocator, operation(), .{ .environment = "FOO_KEY" })).api_key);
    try same("literal-key", (try source.resolve(allocator, operation(), .{ .literal = "literal-key" })).api_key);
    try testing.expectError(error.Authentication, source.resolve(allocator, operation(), .{ .environment = "EMPTY" }));
    try testing.expectError(error.Authentication, source.resolve(allocator, operation(), .{ .auth = "missing" }));
    try testing.expectError(error.Unavailable, auth.resolveValue(&variables, .{ .environment = "MISSING" }));
    try same("", try auth.resolveValue(&variables, .{ .environment = "EMPTY" }));

    try store.put(allocator, operation(), "gateway", .{ .api_key = "stored-key" });
    try store.put(allocator, operation(), "service", .{ .oauth = oauth });
    const stored = try source.resolve(allocator, operation(), .{ .auth = "gateway" });
    defer allocator.free(stored.api_key);
    try same("stored-key", stored.api_key);
    const bearer = (try source.resolve(allocator, operation(), .{ .auth = "service" })).bearer;
    defer allocator.free(bearer.token);
    try same("old-access", bearer.token);
    try equal(null, bearer.account);
}

test "a refresh cannot overwrite a newer entry or reinstate a logged out provider" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);
    try store.put(allocator, operation(), "service", .{ .oauth = oauth });
    try expect(try store.replaceOAuth(allocator, operation(), "service", oauth, updated));
    try expect(!try store.replaceOAuth(allocator, operation(), "service", oauth, updated));
    try store.remove(allocator, operation(), "service");
    try expect(!try store.replaceOAuth(allocator, operation(), "service", updated, oauth));
    var snapshot = try store.read(allocator, operation());
    defer snapshot.deinit();
    try equal(0, snapshot.entries.count());
}

const oauth_wire = auth.oauth;

fn jwt(a: std.mem.Allocator, claims: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const payload = try a.alloc(u8, encoder.calcSize(claims.len));
    return std.mem.concat(a, u8, &.{ "eyJhbGciOiJub25lIn0.", encoder.encode(payload, claims), ".signature" });
}

const account_claims = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-fixture\"}}";

const Fixture = struct {
    const Reply = struct { url: []const u8, status: u16 = 200, body: []const u8 };

    a: std.mem.Allocator,
    replies: []const Reply,
    calls: usize = 0,
    bodies: std.ArrayList([]const u8) = .empty,

    fn transport(self: *Fixture) foo.io.HttpTransport {
        return .{ .context = self, .exchange_fn = exchange };
    }

    fn exchange(context: *anyopaque, operation_: foo.io.Context, request: foo.io.HttpRequest, sink: foo.io.HttpSink, delivery: *foo.io.Delivery) foo.io.Error!void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.calls == self.replies.len) return error.Unavailable;
        const reply = self.replies[self.calls];
        self.calls += 1;
        delivery.* = .possibly_sent;
        if (!std.mem.eql(u8, reply.url, request.url)) return error.InvalidInput;
        try self.bodies.append(self.a, try self.a.dupe(u8, request.body.bytes));
        try sink.head_fn(sink.context, operation_, .{ .status = reply.status, .headers = &.{} });
        try sink.body.write(operation_, reply.body);
    }
};

const Shown = struct {
    notices: std.ArrayList(auth.Notice) = .empty,

    fn prompt(self: *Shown) auth.Prompt {
        return .{ .context = self, .show_fn = show };
    }

    fn show(context: *anyopaque, _: foo.io.Context, notice: auth.Notice) auth.Error!void {
        const self: *Shown = @ptrCast(@alignCast(context));
        try self.notices.append(allocator, notice);
    }
};

test "PKCE challenge matches the RFC 7636 appendix B vector" {
    try same("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &oauth_wire.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
    const pkce = try oauth_wire.Pkce.generate(io);
    try same(&oauth_wire.challenge(&pkce.verifier), &pkce.challenge);
    try equal(null, std.mem.indexOfAny(u8, &pkce.verifier, "+/="));
}

test "authorize URLs and token forms percent-encode every reserved byte" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const url = try oauth_wire.authorizeUrl(arena.allocator(), "https://issuer.invalid/authorize", &.{
        .{ .name = "redirect_uri", .value = "http://localhost:1455/auth/callback" },
        .{ .name = "scope", .value = "openid profile" },
    });
    try same("https://issuer.invalid/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid%20profile", url);
}

test "callback accepts only the expected path and state" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try same("abc/def", (try oauth_wire.parseCallback(a, "/auth/callback?code=abc%2Fdef&state=s1", "/auth/callback", "s1")).code);
    try equal(.rejected, try oauth_wire.parseCallback(a, "/auth/callback?code=abc&state=tampered", "/auth/callback", "s1"));
    try equal(.rejected, try oauth_wire.parseCallback(a, "/auth/callback?code=abc", "/auth/callback", "s1"));
    try equal(.rejected, try oauth_wire.parseCallback(a, "/auth/callback?state=s1", "/auth/callback", "s1"));
    try equal(.rejected, try oauth_wire.parseCallback(a, "/auth/callback?code=abc&state=s1&state=s2", "/auth/callback", "s1"));
    try equal(.unrelated, try oauth_wire.parseCallback(a, "/favicon.ico", "/auth/callback", "s1"));
}

test "loopback callback rejects a tampered state and returns the code for the expected one" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Client = struct {
        fn send(port: u16, target: []const u8) !void {
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
            const stream = try address.connect(io, .{ .mode = .stream });
            defer stream.close(io);
            var buffer: [256]u8 = undefined;
            var writer = stream.writer(io, &buffer);
            try writer.interface.print("GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{target});
            try writer.interface.flush();
            var reply: [512]u8 = undefined;
            var slices = [_][]u8{&reply};
            _ = try stream.read(io, &slices);
        }
    };
    {
        var idle = try oauth_wire.Callback.listen(io, 0);
        defer idle.close(io);
        try equal(null, try idle.wait(a, awake(), "/auth/callback", "expected", 50));
    }
    for ([_]struct { target: []const u8, code: ?[]const u8 }{
        .{ .target = "/auth/callback?code=fixture-code&state=tampered", .code = null },
        .{ .target = "/auth/callback?code=fixture-code&state=expected", .code = "fixture-code" },
    }) |case| {
        var callback = try oauth_wire.Callback.listen(io, 0);
        defer callback.close(io);
        const idle_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(callback.boundPort()) };
        const idle = try idle_address.connect(io, .{ .mode = .stream });
        defer idle.close(io);
        var client = try io.concurrent(Client.send, .{ callback.boundPort(), case.target });
        defer client.cancel(io) catch {};
        if (case.code) |code| {
            try same(code, (try callback.wait(a, operation(), "/auth/callback", "expected", 10_000)).?);
        } else {
            try testing.expectError(error.Authentication, callback.wait(a, operation(), "/auth/callback", "expected", 10_000));
        }
    }
}

test "token responses need an access token and a positive lifetime" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try oauth_wire.parseTokens(a, 1_000, "{\"access_token\":\"a1\",\"refresh_token\":\"r1\",\"expires_in\":3600,\"id_token\":\"i1\",\"scope\":\"x\"}");
    try same("a1", parsed.oauth.access);
    try same("r1", parsed.oauth.refresh.?);
    try same("i1", parsed.id_token.?);
    try equal(3_601_000, parsed.oauth.expires_ms);
    for ([_][]const u8{
        "{\"refresh_token\":\"r1\",\"expires_in\":3600}",
        "{\"access_token\":\"a1\",\"refresh_token\":\"r1\"}",
        "{\"access_token\":\"\",\"expires_in\":3600}",
        "{\"access_token\":\"a1\",\"expires_in\":0}",
        "not json",
    }) |body| try testing.expectError(error.Authentication, oauth_wire.parseTokens(a, 0, body));
}

test "JWT claims decode from the payload without trusting malformed tokens" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path: []const []const u8 = &.{ "https://api.openai.com/auth", "chatgpt_account_id" };
    try same("acct-fixture", oauth_wire.jwtClaim(a, try jwt(a, account_claims), path).?);
    try equal(null, oauth_wire.jwtClaim(a, try jwt(a, "{\"sub\":\"user\"}"), path));
    try equal(null, oauth_wire.jwtClaim(a, "only.two", path));
    try equal(null, oauth_wire.jwtClaim(a, "a.!!!.c", path));
}

test "device polling waits while pending and slows down when asked" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{ .a = a, .replies = &.{
        .{ .url = "https://issuer.invalid/token", .status = 400, .body = "{\"error\":\"authorization_pending\"}" },
        .{ .url = "https://issuer.invalid/token", .status = 400, .body = "{\"error\":{\"code\":\"slow_down\"}}" },
        .{ .url = "https://issuer.invalid/token", .body = "{\"access_token\":\"device-access\",\"expires_in\":60}" },
    } };
    const State = struct {
        var clock: support.Clock = .{};
        var waits: [4]u64 = undefined;
        var count: usize = 0;
        const cancellation: foo.io.Cancellation = .{};

        fn sleep(_: foo.io.Context, ms: u64) auth.Error!void {
            waits[count] = ms;
            count += 1;
            clock.time_ms += ms;
        }
    };
    const context: foo.io.Context = .{ .io = io, .clock = State.clock.interface(), .cancellation = &State.cancellation };
    const Poller = struct {
        http: oauth_wire.Client,

        pub fn poll(self: @This()) auth.Error!oauth_wire.Poll([]const u8) {
            const response = try self.http.post("https://issuer.invalid/token", .{ .form = &.{.{ .name = "device_code", .value = "d1" }} });
            if (response.status == 200) return .{ .done = (try oauth_wire.parseTokens(self.http.a, 0, response.body)).oauth.access };
            const code = oauth_wire.errorCode(self.http.a, response.body) orelse return error.Authentication;
            if (std.mem.eql(u8, code, "authorization_pending")) return .pending;
            if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
            return error.Authentication;
        }
    };
    const http: oauth_wire.Client = .{ .a = a, .operation = context, .http = fixture.transport() };
    const schedule: oauth_wire.Schedule = .{ .interval_ms = 2_000, .expires_ms = 60_000, .sleep = State.sleep };
    try same("device-access", try oauth_wire.pollDevice([]const u8, context, schedule, Poller{ .http = http }));
    try testing.expectEqualSlices(u64, &.{ 2_000, 7_000 }, State.waits[0..State.count]);
    try same("device_code=d1", fixture.bodies.items[0]);

    State.count = 0;
    fixture.calls = 0;
    fixture.replies = &.{
        .{ .url = "https://issuer.invalid/token", .status = 400, .body = "{\"error\":\"authorization_pending\"}" },
        .{ .url = "https://issuer.invalid/token", .status = 400, .body = "{\"error\":\"authorization_pending\"}" },
    };
    const short: oauth_wire.Schedule = .{ .interval_ms = 2_000, .expires_ms = 3_000, .sleep = State.sleep };
    try testing.expectError(error.DeadlineExceeded, oauth_wire.pollDevice([]const u8, context, short, Poller{ .http = http }));
    try testing.expectEqualSlices(u64, &.{ 2_000, 1_000 }, State.waits[0..State.count]);
}

test "Codex device login exchanges the returned code with the device redirect" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const access = try jwt(a, account_claims);
    const tokens = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"refresh_token\":\"r1\",\"expires_in\":36000}}", .{access});
    var fixture: Fixture = .{ .a = a, .replies = &.{
        .{ .url = "https://auth.openai.com/api/accounts/deviceauth/usercode", .body = "{\"device_auth_id\":\"dev-1\",\"user_code\":\"ABCD-1234\",\"interval\":\"5\"}" },
        .{ .url = "https://auth.openai.com/api/accounts/deviceauth/token", .body = "{\"authorization_code\":\"code-1\",\"code_verifier\":\"verifier-1\"}" },
        .{ .url = "https://auth.openai.com/oauth/token", .body = tokens },
    } };
    var shown: Shown = .{};
    defer shown.notices.deinit(allocator);
    const flow = auth.findFlow(auth.flows, "openai-codex").?;
    const before = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const result = try flow.device.?(.{ .a = a, .operation = operation(), .http = fixture.transport(), .prompt = shown.prompt() });
    try same(access, result.access);
    try same("r1", result.refresh.?);
    try same("acct-fixture", result.account.?);
    try expect(result.expires_ms >= before + 36_000_000);
    try same("https://auth.openai.com/codex/device", shown.notices.items[0].device_code.uri);
    try same("ABCD-1234", shown.notices.items[0].device_code.code);
    try same("{\"client_id\":\"app_EMoamEEZ73f0CkXaXp7hrann\"}", fixture.bodies.items[0]);
    try same("{\"device_auth_id\":\"dev-1\",\"user_code\":\"ABCD-1234\"}", fixture.bodies.items[1]);
    try same("grant_type=authorization_code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code=code-1&code_verifier=verifier-1&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback", fixture.bodies.items[2]);
}

test "Codex refresh keeps the refresh token and reads the account from the new access token" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const access = try jwt(a, account_claims);
    const tokens = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"expires_in\":36000}}", .{access});
    var fixture: Fixture = .{ .a = a, .replies = &.{
        .{ .url = "https://auth.openai.com/oauth/token", .body = tokens },
        .{ .url = "https://auth.openai.com/oauth/token", .status = 400, .body = "{\"error\":\"invalid_grant\"}" },
    } };
    const flow = auth.findFlow(auth.flows, "openai-codex").?;
    try same("chatgpt-account-id", flow.account_header.?);
    const request: auth.Refresh = .{ .a = a, .operation = operation(), .http = fixture.transport(), .current = oauth };
    const result = try flow.refresh.?(request);
    try same(access, result.access);
    try same("old-refresh", result.refresh.?);
    try same("acct-fixture", result.account.?);
    try same("grant_type=refresh_token&client_id=app_EMoamEEZ73f0CkXaXp7hrann&refresh_token=old-refresh", fixture.bodies.items[0]);
    try testing.expectError(error.Authentication, flow.refresh.?(request));

    var bare: Fixture = .{ .a = a, .replies = &.{.{ .url = "https://auth.openai.com/oauth/token", .body = "{\"access_token\":\"opaque-access\",\"expires_in\":36000}" }} };
    const without_claim = try flow.refresh.?(.{ .a = a, .operation = operation(), .http = bare.transport(), .current = oauth });
    try same("opaque-access", without_claim.access);
    try equal(null, without_claim.account);
}

test "resolver refreshes an expiring token before use and fills the flow's account header" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Service = struct {
        fn refresh(request: auth.Refresh) auth.Error!auth.OAuth {
            const http: oauth_wire.Client = .{ .a = request.a, .operation = request.operation, .http = request.http };
            var tokens = try http.refresh("https://issuer.invalid/token", "fixture-client", request.current);
            tokens.oauth.account = oauth_wire.jwtClaim(request.a, tokens.oauth.access, &.{ "https://api.openai.com/auth", "chatgpt_account_id" });
            return tokens.oauth;
        }
        const flow: auth.Flow = .{ .provider = "service", .refresh = refresh, .account_header = "x-account" };
    };
    const access = try jwt(a, account_claims);
    const tokens = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"expires_in\":36000}}", .{access});
    var fixture: Fixture = .{ .a = a, .replies = &.{.{ .url = "https://issuer.invalid/token", .body = tokens }} };
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const resolver = auth.Resolver{ .store = store, .registry = &.{Service.flow}, .http = fixture.transport() };
    const source = resolver.interface();

    try store.put(allocator, operation(), "service", .{ .oauth = .{ .access = "fresh-access", .refresh = "r0", .expires_ms = now + 3_600_000, .account = "acct-stored" } });
    const fresh = (try source.resolve(a, operation(), .{ .auth = "service" })).bearer;
    try same("fresh-access", fresh.token);
    try same("x-account", fresh.account.?.header);
    try same("acct-stored", fresh.account.?.value);
    try equal(0, fixture.calls);

    try store.put(allocator, operation(), "service", .{ .oauth = .{ .access = "stale-access", .refresh = "r0", .expires_ms = now + 30_000, .account = "acct-stored" } });
    const renewed = (try source.resolve(a, operation(), .{ .auth = "service" })).bearer;
    try same(access, renewed.token);
    try same("acct-fixture", renewed.account.?.value);
    try equal(1, fixture.calls);
    try same("grant_type=refresh_token&client_id=fixture-client&refresh_token=r0", fixture.bodies.items[0]);
    var snapshot = try store.read(allocator, operation());
    defer snapshot.deinit();
    const saved = snapshot.entries.get("service").?.oauth;
    try same(access, saved.access);
    try same("r0", saved.refresh.?);
    try expect(saved.expires_ms >= now + 36_000_000);

    var failing: Fixture = .{ .a = a, .replies = &.{
        .{ .url = "https://issuer.invalid/token", .status = 503, .body = "" },
        .{ .url = "https://issuer.invalid/token", .status = 503, .body = "" },
    } };
    const offline = auth.Resolver{ .store = store, .registry = &.{Service.flow}, .http = failing.transport() };
    try store.put(allocator, operation(), "service", .{ .oauth = .{ .access = "closing-access", .refresh = "r1", .expires_ms = now + 30_000, .account = "acct-stored" } });
    try same("closing-access", (try offline.interface().resolve(a, operation(), .{ .auth = "service" })).bearer.token);
    try store.put(allocator, operation(), "service", .{ .oauth = .{ .access = "expired-access", .refresh = "r1", .expires_ms = now - 1_000, .account = "acct-stored" } });
    try expect(std.meta.isError(offline.interface().resolve(a, operation(), .{ .auth = "service" })));
    try equal(2, failing.calls);

    try store.put(allocator, operation(), "gateway", .{ .oauth = oauth });
    const unregistered = (try source.resolve(a, operation(), .{ .auth = "gateway" })).bearer;
    try equal(null, unregistered.account);
}

test "OAuth requests carry a bounded deadline that keeps an earlier caller deadline" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Recorder = struct {
        deadline: ?u64 = null,

        fn transport(self: *@This()) foo.io.HttpTransport {
            return .{ .context = self, .exchange_fn = exchange };
        }

        fn exchange(context: *anyopaque, operation_: foo.io.Context, _: foo.io.HttpRequest, sink: foo.io.HttpSink, delivery: *foo.io.Delivery) foo.io.Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.deadline = operation_.deadline_ms;
            delivery.* = .possibly_sent;
            try sink.head_fn(sink.context, operation_, .{ .status = 200, .headers = &.{} });
        }
    };
    var clock: support.Clock = .{ .time_ms = 1_000 };
    const cancellation: foo.io.Cancellation = .{};
    var recorder: Recorder = .{};
    var context: foo.io.Context = .{ .io = io, .clock = clock.interface(), .cancellation = &cancellation };
    const client: oauth_wire.Client = .{ .a = arena.allocator(), .operation = context, .http = recorder.transport() };
    _ = try client.post("https://issuer.invalid/token", .{ .json = "{}" });
    try equal(1_000 + oauth_wire.Client.request_timeout_ms, recorder.deadline.?);

    context.deadline_ms = 1_500;
    const bounded: oauth_wire.Client = .{ .a = arena.allocator(), .operation = context, .http = recorder.transport() };
    _ = try bounded.post("https://issuer.invalid/token", .{ .json = "{}" });
    try equal(1_500, recorder.deadline.?);
}

test "a refresh that loses a rotation race uses the credential another process saved" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Race = struct {
        var winner: ?auth.Store = null;
        var calls: usize = 0;

        fn refresh(request: auth.Refresh) auth.Error!auth.OAuth {
            calls += 1;
            try winner.?.put(request.a, request.operation, "service", .{ .oauth = .{ .access = "winner-access", .refresh = "r1", .expires_ms = std.math.maxInt(i32) * 1000, .account = "acct" } });
            return error.Authentication;
        }
        const flow: auth.Flow = .{ .provider = "service", .refresh = refresh, .account_header = "x-account" };
    };
    Race.winner = store;
    Race.calls = 0;
    var unused: Fixture = .{ .a = a, .replies = &.{} };
    const resolver = auth.Resolver{ .store = store, .registry = &.{Race.flow}, .http = unused.transport() };
    try store.put(allocator, operation(), "service", .{ .oauth = .{ .access = "loser-access", .refresh = "r0", .expires_ms = 1, .account = "acct" } });
    const resolved = (try resolver.interface().resolve(a, operation(), .{ .auth = "service" })).bearer;
    try same("winner-access", resolved.token);
    try equal(1, Race.calls);

    try store.put(allocator, operation(), "service", .{ .oauth = .{ .access = "loser-access", .refresh = "r0", .expires_ms = 1, .account = "acct" } });
    const Revoked = struct {
        fn refresh(_: auth.Refresh) auth.Error!auth.OAuth {
            return error.Authentication;
        }
        const flow: auth.Flow = .{ .provider = "service", .refresh = refresh };
    };
    const revoked = auth.Resolver{ .store = store, .registry = &.{Revoked.flow}, .http = unused.transport() };
    try testing.expectError(error.Authentication, revoked.interface().resolve(a, operation(), .{ .auth = "service" }));
}
