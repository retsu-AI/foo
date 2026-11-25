# Run live interoperability checks

Use a verified F12 candidate executable from the unpacked release archive.
Run the live lane with an explicit profile and a new evidence path.

```sh
python tests/acceptance/live.py /path/to/unpacked/foo \
  --profiles /path/to/live.json --output live-results.json
```

Start with [the empty profile](live_profiles.example.json). It makes no
external requests. An omitted profile or incomplete coverage returns exit 2
and records unavailable evidence. A failed policy or probe returns exit 1.
Exit 0 requires every supported provider route, both MCP revisions on each
transport, and a complete editor evidence entry for every configured editor.

## Set the limits

Add the exact HTTPS URLs you intend to contact to
`policy.allowed_https_endpoints`. The runner validates all case approvals
and budget reservations before it starts any executable. Set
`ca_file` to the PEM trust bundle used for HTTPS. Resolve relative trust
bundle and trace paths against the profile's directory.

Set the aggregate `provider_request_limit`, `provider_output_token_limit`,
`mcp_operation_limit`, and `spend_cap_microusd` for this invocation.
A microdollar is one millionth of a US dollar. Longer service operations
remain bounded by `timeout_seconds` and the candidate's resource limits.
The MCP operation limit counts requested resource reads. Each read also
performs the handshake and cleanup its revision requires.

Use a dedicated service account with an independently enforced spending
ceiling. Set `project_cap_confirmed` to true when that ceiling is in place
for the authorized billable cases. Each billable case reserves its declared
worst-case charge before any requests leave the machine. The CLI exposes
the outcome of the request. Use the account's billing records to check
actual charges.

## Configure provider cases

Append one object to `providers` for each route you authorize. Provide
the public model and service version you intend to qualify. The credential
field holds the name of an environment variable.

```json
{
  "route": "openai-responses",
  "model": "<model-id>",
  "service_version": "<service-version>",
  "credential_env": "OPENAI_API_KEY",
  "max_output_tokens": 128,
  "max_charge_microusd": 500
}
```

The amounts in this example illustrate the input shape. Set your
reservations from your account's rate and ceiling. Each case makes one
request with a short random marker prompt, zero retries, and an explicit
output token limit. A successful response must echo the marker. The
report retains byte counts, hashes, the route, and the declared service
version. It omits response bodies, diagnostics, and credential values.

| Route | Endpoint to allow |
| --- | --- |
| `openai-responses` | `https://api.openai.com/v1/responses` |
| `openai-chat` | `https://api.openai.com/v1/chat/completions` |
| `anthropic-messages` | `https://api.anthropic.com/v1/messages` |
| `xai-responses` | `https://api.x.ai/v1/responses` |

## Configure MCP cases

Append an object to `mcp` for each authorized endpoint or process.
Set a public `name` and `service_version`. Select `2025-11-25` or
`2026-07-28` as its `revision`. Set `resource` to a read-only resource
URI and record the SHA-256 of the expected resource bytes as
`content_sha256`. Use the decoded bytes for a binary resource. Set
`max_charge_microusd` to the maximum charge for the whole check, or zero
for a free check.

For HTTP, set `transport.http.endpoint` to a URL in the allowlist.
If the server requires authorization, set `transport.http.authorization_env`
to the name of a variable containing the complete Authorization header
value.

For stdio, set `transport.stdio.argv` to an argument list with an
absolute executable path. Set `transport.stdio.program_sha256` to the
executable's digest. Optional `transport.stdio.credential_env` maps
each child variable name to the caller's environment variable name.
Use a trusted server executable and arguments. Approve its exact launch
digest in `policy.allowed_stdio_launches`. The runner checks the executable
digest again immediately before launch.

To print the launch digest for a configured stdio case, set `INDEX` to
that case's zero-based position in the `mcp` array.

```sh
PYTHONPATH=tests/acceptance python -c '
import json, sys
from pathlib import Path
from live import launch_sha256

profile = json.loads(Path(sys.argv[1]).read_bytes())
spec = profile["mcp"][int(sys.argv[2])]["transport"]["stdio"]
print(launch_sha256(spec["argv"], spec["program_sha256"], spec.get("credential_env", {})))
' /path/to/live.json INDEX
```

## Import native editor evidence

Connect a real editor to the verified `foo acp` executable. Capture
newline-delimited JSON records with the direction `client` or `agent`
and the ACP message under `message`. Include one full initialize,
session creation, streamed text turn, and terminal turn response. Use
an independently expected text response and record its SHA-256. Keep
the trace in an operator-controlled directory.

Append an object to `acp` with `editor`, `editor_version`,
`candidate_sha256`, `trace`, `trace_sha256`, `answer_sha256`,
`observed_exit`, and `observed_checks`. Use the SHA-256 of the exact
candidate binary. Set `observed_exit` to the agent process exit code
after disconnect. The runner checks the supplied trace and retains its
digest. Native editor operation remains operator-observed evidence.
The scripted ACP tests provide offline evidence.

Include an observed check only after exercising the corresponding
workflow in the editor. Use the editor steps in the
[ACP release qualification guide](../acp/README.md#release-qualification).

- `denied_and_approved_permission`
- `unsaved_read`
- `host_error`
- `terminal_cancel_and_release`
- `active_disconnect`
- `mcp_tool_continuation`

Run the offline policy controls with
`python tests/acceptance/live_test.py`.
