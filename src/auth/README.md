# Provider authentication

Run `foo auth login PROVIDER --api-key` and enter the key at the hidden terminal
prompt. Set the provider's `credential` to `{"auth":"PROVIDER"}`. Use the same ID
in both places. `foo auth list` shows saved provider IDs, credential types, and
expiry. `foo auth logout PROVIDER` removes the saved entry. These commands work
before you configure a model.

The store is `auth.json` in the same user directory as `config.json`. Set
`FOO_CONFIG_DIR` to an absolute path to override that directory. On Linux and
macOS, the store is created with mode `0600` and rejects group or world
permissions on read. On Windows, the store uses a protected ACL for the
current account.

## Store format

The file is a JSON object keyed by provider ID. API key entries contain
`"type":"api_key"` and `key`. OAuth entries contain `"type":"oauth"`, `access`,
and `expires_ms`. OAuth entries can also include `refresh` and `account`.
Expiry is measured in Unix milliseconds. Foo keeps a writer lock at `auth.lock`
and replaces the store atomically.

`CredentialSource` resolves the provider reference when the adapter builds an
attempt. The caller supplies the allocator for stored values. Literal and
environment values borrow their original storage. MCP headers and process
environment values resolve literals and environment names.

## Subscription login

`foo auth login openai-codex` logs in with a ChatGPT subscription. Foo prints an
`https://auth.openai.com/oauth/authorize` URL on stderr and waits on
`http://localhost:1455/auth/callback`. If no callback arrives within 120
seconds, or port 1455 is busy, foo switches to the device flow. A callback with
the wrong `state` ends the login and stores nothing. `--device` starts the
device flow directly. It prints `https://auth.openai.com/codex/device` and a
user code to enter there. The built-in `openai-codex` provider then sends the
token to `https://chatgpt.com/backend-api/codex` with the `chatgpt-account-id`
header.

Foo refreshes a registered OAuth token when it expires within 60 seconds, and
once more after an HTTP 401. Foo saves the refresh only if the previous OAuth
entry is still current.

## Adding a subscription login

`flows` in `root.zig` lists one `Flow` per provider. A `Flow` names the provider
ID and the capabilities it supports. `browser` and `device` log in, `refresh`
renews a token, and `account_header` names the header that carries the stored
`account`. Each provider file builds its capabilities from `oauth.zig`. That file
holds PKCE, form encoding, token exchange and refresh, the loopback callback, the
device polling loop, and JWT claim decoding. All HTTP goes through the injected
`HttpTransport`. To add a provider, write `src/auth/<provider>.zig` that exports
`flow`. Then append it to `flows` and add its entry to `src/config/defaults.zig`.

```sh
nix develop .#ci -c zig build test -Dmodule=auth
```
