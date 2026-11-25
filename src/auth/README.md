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

The production OAuth registry is empty. A registered OAuth flow with a stored
refresh token can refresh once after an HTTP 401. Foo saves the refresh only if
the previous OAuth entry is still current.

```sh
nix develop .#ci -c zig build test -Dmodule=auth
```
