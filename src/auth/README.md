# Provider authentication

Run `foo auth login` to list the built-in providers with their login methods and
environment variables. `foo auth login PROVIDER` logs in: a provider with a
subscription flow opens the browser or shows a device code, and any other
provider prompts for an API key at a hidden terminal prompt. `--browser`,
`--device`, and `--api-key` pick one method; a method the provider lacks is
refused with the command to run instead. An unknown provider is refused with a
spelling suggestion unless `--api-key` is given, which stores a key under any
name for a user-configured provider.

A built-in provider's credential is `{"auth":"PROVIDER"}`. The stored entry
owns that slot. When nothing is stored, foo reads the provider's environment
variables in the order `foo auth login` lists them. A variable that is empty,
padded with spaces, or holds control bytes counts as unset, the same rule
`foo auth login` applies to a typed key. An expired stored token that cannot be
refreshed does not fall back to
the environment; log in again or log out. A damaged `auth.json` stops every
command that reads it, including the zero-config pick, with `cannot use
authentication store in DIR` and exit 5. `foo auth list` shows stored entries
with their type and expiry, then built-ins whose variable is set as
`PROVIDER  env  VARIABLE`. `foo auth logout PROVIDER` removes the saved entry.
These commands work before you configure a model.

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

`foo auth login xai` signs in with a SuperGrok or X Premium subscription
through the xAI device flow. Foo prints the `https://` verification page that
xAI returns and a user code, then polls until the login is approved or the code
expires, at most 15 minutes. The built-in `xai` provider sends the token to
`https://api.x.ai/v1`.

`foo auth login meta` signs in with a Muse subscription through the Meta device
flow at `https://auth.meta.com`. The identity token that flow returns is not
accepted for inference, so foo exchanges it at
`https://api.meta.ai/muse-code/key` for a Model API key that lives about a day.
The key is stored as the OAuth `access` and the identity token as `refresh`, so
the ordinary refresh re-mints the key. The identity token itself cannot be
renewed; a 401 or 403 from the mint means `foo auth login meta` again.

OpenCode Zen, OpenCode Go, and the other API-key providers have no login flow.
`foo auth login opencode` prompts for the key, and `OPENCODE_API_KEY` works
without a login.

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
`flow`. Then append it to `flows`. The provider must have a record in
`src/builtins/records.zig`; the build fails otherwise.

```sh
nix develop .#ci -c zig build test -Dmodule=auth
```
