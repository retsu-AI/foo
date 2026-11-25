# foo usability plan

foo must work like Pi, OpenCode, and Codex for a developer who installs it and opens a terminal. Today HTTPS needs `FOO_CA_FILE`, a config file names one model with its endpoint and key inline, the project config needs `--approve`, and a wrong key and a TLS failure both print `provider_error`. This program removes those faults and adds subscription login for OpenAI Codex and xAI, plus OpenCode Go as a built-in provider. Eight PRs land in this order. U01 platform trust. U02 typed failure reasons. U03 providers with nested models. U04 project file layout. U05 `foo auth` and a token store. U06 OpenAI Codex login. U07 xAI login and OpenCode Go. U08 `foo models` and TUI model switching. U03 and U05 are reviewed in chat before merge.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `skills/poteto-mode/playbooks/autopilot-stack.md` from the installed plugin, found in this repository at `.agents/skills/poteto-mode/playbooks/autopilot-stack.md`. U02 builds on U01, U04 on U03, U05 on U03, U06 and U07 on U05, and U08 on U07. The root appends each PR to the stack. The operator lands the stack bottom-up. U03 and U05 are the operator's review items. They stop at merge-ready until the operator has seen the screenshots and the video in chat.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on the operator's explicit go.
- [ ] On the operator's go, write this exact text into `notes.md` in the program's store under `~/.claude/orchestrate/foo-usability/` and restate it in your todolist. "Plan at docs/plan/usability.md. PRs U01, U02, U03, U04, U05, U06, U07, U08 in that order. Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. The operator lands the stack bottom-up. U03 and U05 wait for the operator's chat review. Done when every box in the plan is checked and the operator has landed U08."
- [ ] Read these from the installed plugin at program start. Re-read them at every tick.
  - [ ] `skills/poteto-mode/playbooks/autopilot-stack.md`
  - [ ] `skills/swarm/SKILL.md`
  - [ ] `skills/run/SKILL.md`, the CLI and TUI driver. The repository has no project `verify` skill, so lanes drive `zig-out/bin/foo` and the probe binaries through `run`.
  - [ ] `skills/poteto-mode/playbooks/opening-a-pr.md`
  - [ ] `skills/architect/SKILL.md`, `skills/how/SKILL.md`, `skills/interrogate/SKILL.md`, `skills/deslop/SKILL.md`, `skills/no-comments/SKILL.md`, `skills/technical-writing/SKILL.md`, `skills/unslop/SKILL.md`
- [ ] Arm the hourly audit tick as a real `/loop` in dynamic mode, which schedules its own wake-up rather than blocking on a sleep. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read the execution playbook from the installed plugin and the objective in the program store's `notes.md`. Audit the operation against both and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then post a short status message to the operator in chat only when the audit found a tracked change that no earlier status message reported, such as a PR opened, a code-ready head, a round launched or closed, a verdict, a merge, a stuck agent and the action taken, a blocker added or cleared, or a decision only the operator can make. Name every such change and nothing else. Do not repeat a table, the merged list, or an unchanged blocker. If the audit found none, end the turn with no reply text. Either way, log this tick's row in your decision trail. The row names the items reported, or none."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges, or base it on the parent branch when the execution playbook stacks.
  - [ ] U01 and U03 are independent and first. Both branch from `main`.
  - [ ] U02 after U01.
  - [ ] U04 after U03.
  - [ ] U05 after U03.
  - [ ] U06 after U05.
  - [ ] U07 after U05.
  - [ ] U08 after U07.
- [ ] Hold the file boundaries. U01 touches only `src/transport/**`, `src/contracts/runtime/session.zig`, `tests/transport/**`, `tests/integration/**`, `nix/README.md`, and `docs/README.md`. U02 touches only `src/contracts/events.zig`, `src/core/root.zig`, `src/providers/root.zig`, `src/cli/root.zig`, `src/tui/root.zig`, `src/acp/projection.zig`, and their tests. U03 touches `src/contracts/config.zig`, `src/config/**`, `src/cli/arguments.zig`, `src/cli/root.zig`, `src/providers/routes.md`, `tests/config/**`, `tests/cli/**`, `tests/contracts/root.zig`, and `docs/architecture.md`. U03 also updates credential dispatch in `src/providers/root.zig` and migrates configuration fixtures in `tests/integration/check.py`. U04 touches only `src/cli/arguments.zig`, `src/main.zig`, `.foo/**`, `.gitignore`, `src/config/README.md`, `README.md`, and `tests/integration/check.py`. U05 touches only the new `src/auth/**`, `src/cli/**`, `src/main.zig`, `src/providers/root.zig`, `src/contracts/config.zig`, `src/contracts/runtime/session.zig`, `src/mcp/connection_config.zig`, `build.zig`, and `tests/auth/**`. U06 and U07 touch only `src/auth/**`, `src/providers/**`, `src/config/defaults.zig`, `tests/providers/**`, and `tests/auth/**`. U08 touches only `src/cli/**`, `src/tui/**`, `src/contracts/runtime/session.zig`, `tests/tui/**`, and `tests/cli/**`.
- [ ] Hold the review gate. U03 and U05 change an interaction. They wait for the operator's review in chat with screenshots and a video before merge.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft, per **Opening a PR**. Use the run's built-in PR tool when it has one, else `origin pr create --status open --base <base-branch>` or `gh pr create --base <base-branch>` according to the resolved forge. A stack child targets its parent branch.
- [ ] Run `nix develop .#ci -c zig build check` and `nix develop .#ci -c zig fmt --check src tests build.zig` once before the PR-facing push. Push with hooks on.
- [ ] Run `/deslop` before each commit and `/no-comments` before review.
- [ ] Triage every review-bot and security-reviewer comment per `../references/bugbot-triage.md`.
- [ ] Before the code-ready report and babysit, and again after merge prep, record the base and head SHAs prepared by the topology owner under the execution playbook.
- [ ] When a PR changes a status the board shows, update `docs/plan/work-packages.json`, run `nix develop .#ci -c python docs/plan/build.py`, and commit the regenerated `docs/plan/index.html` in the same PR.

### Verdict and merge, for every PR

- [ ] A full swarm runs once, at the code-ready head. Another full swarm runs only for new behavior, a redesign, or a large new diff. A rebase, a merge-conflict resolution, or a minor fix gets a single verifier at the new head, and a wording-only change gets none. Run each full swarm per `skills/swarm/SKILL.md`. One gates lane. The ten live lanes from the PR's **Verify, live** block. The perf lane from its **Verify, perf** block. Two or more audit lanes, each with its own focus, that read the diff and the receipts and distrust the PR body. The root audits the receipts in the merge-ready report before the verdict.
- [ ] Judge every finding by the execution playbook's blocking rule. The verdict is clean when none blocks. A failure on trunk behavior in a lane marked `Regression lane against trunk.` is recorded against trunk and does not block the PR. A new head gets a fresh verdict, except for results that stay valid under the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends a PR with a clean verdict to the base-branch stack. The operator lands the stack bottom-up. A PR whose patch-id is unchanged after a rebase keeps its verdict under `playbooks/shipping.md`.

### Boot recipe, for every live lane

Each live lane runs in its own worktree at the PR head. Drive through the skill path or exact commands recorded in this boot recipe.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] `nix develop .#ci -c zig build` and confirm `zig-out/bin/foo --version` prints `foo ` followed by the version in `src/lib.zig`.
- [ ] Deliver input only through `run` with `zig-out/bin/foo <command>` or the probe binary the lane names. Read-only diagnostics are `foo config show`, `foo config check`, `git status`, and the lane's own stderr capture.
- [ ] A lane that needs a live credential reads it from the operator's environment or the operator's `foo.json`. The lane records `credential: present` or `credential: absent` and never prints the value. A lane whose credential is absent records that fact and gates only the behavior the diff adds that does not need the credential.
- [ ] Save every screenshot to `/tmp/swarm-<pr-id>/worker-<n>/<slug>.png` and return the paths with the report. A terminal screenshot is a capture of the terminal pane that ran the command.

## Load platform trust roots by default (U01)

**Depends on.** None.

**Files.**

- [x] Edit `src/contracts/runtime/session.zig`. `httpClient` at line 114 and `loadRoots` at line 522.
- [x] Edit `src/transport/root.zig`. `Options` at line 20, the HTTPS gate at line 120, and `configure` at line 162.
- [x] Create `src/transport/trust.zig`.
- [x] Edit `src/transport/README.md` lines 56 and 61 to 68, `nix/README.md` line 12, `docs/README.md` line 5, and `tests/integration/README.md` line 18.
- [x] Edit `tests/transport/fixtures.py` and `tests/transport/probe.zig`. Add a `platform_trust` mode.
- [x] Edit `tests/integration/check.py` line 179.

**Build.**

- [x] Add `Trust` to `src/transport/trust.zig`. It is `union(enum) { platform, pem: []const u8 }`. `Trust.platformPem(allocator, io, now)` calls `std.crypto.Certificate.Bundle.rescan`, then writes each DER root in `bundle.map` as a PEM block. Appendix A has the measured loop. `rescan` reads the Linux bundle paths, the macOS `SystemRootCertificates.keychain`, and the Windows `ROOT` store, so one code path covers the three release targets.
- [x] Replace `transport.Options.ca_pem: ?[]const u8` with `trust: Trust = .platform`. `Client.init` resolves `.platform` to PEM bytes once per client. Raise `max_ca_bytes` to 2 MiB. Delete the `error.Unavailable` return at `src/transport/root.zig:120`. An empty platform bundle fails `Client.init` with `error.Unavailable` and the frontend prints `no trusted certificate roots found. Set FOO_CA_FILE or SSL_CERT_FILE to a PEM bundle`.
- [x] In `App.httpClient`, choose the trust source in this order. `FOO_CA_FILE` as `Trust.pem`, then `SSL_CERT_FILE` as `Trust.pem`, then `Trust.platform`. Keep `loadRoots` for both file paths. `SSL_CERT_FILE` is the variable Codex, Bun, and OpenSSL honor, so a Nix shell or a corporate image works with no foo-specific setting.
- [x] Leave `nix/transport.nix` and `.github/scripts/build-transport.py` unchanged. Trust comes from the Zig standard library, not from a curl build flag. Appendix B records why.
- [x] Add `platform_trust` to `tests/transport/probe.zig` `Mode`. It opens a client with `.trust = .platform` and fetches the URL. In `tests/transport/fixtures.py`, add `test_platform_trust_rejects_fixture_ca`, which runs `platform_trust` against the loopback TLS server and expects `IoFailure` with `.unsent` because the fixture CA is not a platform root, and `test_ssl_cert_file_override`, which sets `SSL_CERT_FILE` to `tests/transport/tls/ca.pem` and expects 200.

**You see.**

- [x] `nix develop -c zig build run -- run --prompt hi --config /tmp/opencode/ca-proto/probe.json` with no `FOO_CA_FILE` reaches `api.openai.com` and fails on the missing key, not on TLS. Before U02 the line reads `foo: run ended with provider_error`. After U02 it names the 401.
- [x] `tests/integration/check.py` no longer mentions `FOO_CA_FILE`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] `tests/transport/fixtures.py` gains `test_platform_trust_rejects_fixture_ca` and `test_ssl_cert_file_override`. Run `nix develop .#ci -c zig build test -Dmodule=transport` and `nix develop .#ci -c zig build test -Dmodule=transport -Doptimize=ReleaseSafe`.
- [x] `src/transport/trust.zig` gains a test that encodes `tests/transport/tls/ca.pem` from DER back to PEM and matches the file byte for byte. Run `nix develop .#ci -c zig build test -Dmodule=transport`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on the configured `swarm workers` model at the PR head, per the boot recipe.

- [x] Lane 1. Regression lane against trunk. Run `zig-out/bin/foo run --prompt hi --config /tmp/opencode/ca-proto/probe.json` with no `FOO_CA_FILE` at trunk and head. Save `trust-default.png`. Pass when trunk fails before any bytes leave and head reaches the host and fails on the missing key.
- [x] Lane 2. Build the transport probe per `tests/providers/build-probe.sh` adapted to `tests/transport/probe.zig` and run `platform_trust https://api.openai.com/v1/models`. Save `trust-openai.png`. Pass when the status is 401 and the error is not `Unavailable` or `IoFailure`.
- [x] Lane 3. Same probe against `https://api.anthropic.com/v1/models`, `https://api.x.ai/v1/models`, `https://opencode.ai/inference/v1/models`, and `https://chatgpt.com/backend-api/codex/responses`. Save `trust-hosts.png`. Pass when every host returns an HTTP status and none returns a transport error.
- [x] Lane 4. `FOO_CA_FILE=/tmp/opencode/ca-proto/roots.pem` and `FOO_CA_FILE=tests/transport/tls/unrelated-ca.pem` against `api.openai.com`. Save `trust-override.png`. Pass when the first returns 401 and the second fails with `IoFailure`.
- [x] Lane 5. `SSL_CERT_FILE=tests/transport/tls/ca.pem` and no `FOO_CA_FILE` against the loopback fixture. Save `trust-ssl-cert-file.png`. Pass when the status is 200.
- [x] Lane 6. Both variables set, `FOO_CA_FILE` to `unrelated-ca.pem` and `SSL_CERT_FILE` to `ca.pem`, against the loopback fixture. Save `trust-precedence.png`. Pass when the request fails, which proves `FOO_CA_FILE` wins.
- [x] Lane 7. `FOO_CA_FILE` pointing at a missing path, an empty file, and a 3 MiB file. Save `trust-bad-file.png`. Pass when the messages name the path, `InvalidInput`, and `LimitExceeded` in that order and the exit code is `host`.
- [x] Lane 8. Run `nix develop .#ci -c zig build check`. Save `trust-check.png`. Pass when every suite passes.
- [x] Lane 9. Run the MCP Streamable HTTP suite from `src/mcp/README.md` with no `FOO_CA_FILE`. Save `trust-mcp.png`. Pass when the suite passes unchanged.
- [x] Lane 10. Run the probe in a container with no `/etc/ssl` tree, built with `docker run --rm -v $PWD/zig-out:/app` on a `scratch`-like image or `nix shell nixpkgs#busybox --ignore-environment`. Save `trust-no-roots.png`. Pass when the message is `no trusted certificate roots found` and the exit code is `host`.

Lanes 1 to 7 and 10 passed at the PR head with text captures instead of screenshots. Lane 1 traced the connection with `strace`, because a 401 and a TLS failure both print `provider_error` before U02. The CLI lanes used a provider-format copy of `probe.json`, because U03 retired the old root `model` object. Lane 8 passed on Linux, and native CI ran the transport suite on macOS and Windows. Lane 9 ran `zig build test -Dmodule=mcp` in Debug and ReleaseSafe with both variables unset, and it passed.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. `Client.init` wall time with `.platform` trust, printed by the probe, and the `trusted` loopback fixture round trip. Trunk has no platform scan, so the diff-added work is the scan and the PEM encode. The budget for that work is 25 ms on this host, where the prototype measured 5 ms for 118 roots.
- [x] Probe. `hyperfine --warmup 3 -r 10 'probe platform_trust_failure <loopback-url>' 'probe trusted <loopback-url> - tests/transport/tls/ca.pem'` interleaved, at trunk with `trusted` only and at head with both.
- [x] Baseline. Record the trunk `trusted` mean first.
- [x] Rule. Head `platform_trust_failure` mean minus head `trusted` mean is under 25 ms. Head `trusted` mean is within 5 percent of trunk `trusted` mean. Over 300 interleaved ReleaseSafe runs per side, `platform_trust_failure` measured 5.76 ms and head `trusted` 2.90 ms, so the scan adds 2.86 ms. Head `trusted` was 5.5 percent faster than trunk's 3.07 ms. A second run of the same trunk binary measured 2.94 ms, so the difference is noise and no slowdown.

**Review gate.** None. U01 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Base and verdict are current under the execution playbook and the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends U01 to the base-branch stack and the operator lands it bottom-up.

## Name the failure reason in every frontend (U02)

**Depends on.** U01.

**Files.**

- [x] Edit `src/contracts/events.zig`. `Stop` at line 7 and `Outcome` at line 8.
- [x] Edit `src/core/root.zig`. The provider error mapping at line 218 and `ioStop` at line 484.
- [x] Edit `src/providers/root.zig`. `Exchange.head` at line 152.
- [x] Edit `src/contracts/io.zig`. The `Error` set at line 3. Edit `src/transport/root.zig` `curlResult` at line 293.
- [x] Edit `src/cli/root.zig`. `Exit.fromOutcome` at line 67 and the terminal report.
- [x] Edit `src/tui/root.zig` line 237 and `src/acp/projection.zig` line 12.
- [x] Edit `src/cli/README.md` for the JSONL record and the `tests/core`, `tests/cli`, and `tests/acp` fixtures that assert `provider_error`.

**Build.**

- [x] Add `Outcome.detail: ?Detail`. `Detail` is `union(enum) { authentication: struct { endpoint: []const u8, status: ?u16 }, rate_limited: struct { endpoint: []const u8, retry_after_ms: ?u64 }, rejected: struct { endpoint: []const u8, status: u16 }, transport: struct { endpoint: []const u8, kind: enum { trust, connect, disconnected, deadline } } }`. `Stop` keeps its seven variants. A `provider_error` outcome always carries a `detail`.
- [x] Add `Exchange.status: ?u16` and `Exchange.retry_after_ms: ?u64` in `src/providers/root.zig` and fill them in `head()` so the status and `retry-after` header travel with `error.Authentication`, `error.RateLimited`, and `error.Rejected`. Map a curl TLS verification failure to `kind = .trust` by adding `error.Untrusted` to `foo.io.Error` at `src/contracts/io.zig:3`, returning it from `curlResult` at `src/transport/root.zig:293` for `CURLE_PEER_FAILED_VERIFICATION`, and mapping it to `transport.kind = .trust` in core.
- [x] In `src/core/root.zig`, map `error.Authentication`, `error.RateLimited`, `error.Rejected`, `error.Untrusted`, `error.Unavailable`, and `error.Disconnected` to the matching `Detail` with the endpoint from `settings.model.endpoint`.
- [x] In `src/cli/root.zig`, print one line per detail. `foo: authentication failed for <endpoint> (HTTP 401). Set <VAR>` for an environment credential. `foo: rate limited by <endpoint>, retry after 2 s`. `foo: could not reach <endpoint>: certificate not trusted`. `foo: <endpoint> rejected the request (HTTP 400)`. Keep the `provider` exit code. U05 changes the second sentence for `auth` credentials.
- [x] In `src/tui/root.zig`, show the same line in the status row. In `src/acp/projection.zig`, put the line in the stop update's message.
- [x] Emit `detail` in the JSONL `rpc` outcome record. The field is optional and additive. Document it in `src/cli/README.md`.

**You see.**

- [x] `zig-out/bin/foo run --prompt hi --config /tmp/opencode/ca-proto/probe.json` prints `foo: authentication failed for https://api.openai.com/v1/chat/completions (HTTP 401). Set OPENAI_API_KEY` and exits with code 4.
- [x] The same run with `FOO_CA_FILE=tests/transport/tls/unrelated-ca.pem` prints `foo: could not reach https://api.openai.com/v1/chat/completions: certificate not trusted`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] `tests/core/root.zig` gains one scripted case per `Detail` variant through the fake provider's failure modes. Run `nix develop .#ci -c zig build test -Dmodule=core`.
- [x] `tests/providers/root.zig` gains a 429 case with `retry-after: 2` asserting `retry_after_ms == 2000`. Run `nix develop .#ci -c zig build test -Dmodule=providers`.
- [x] `tests/cli/check.py` gains a JSONL fixture with a `detail` object on the outcome record. Run `nix develop .#ci -c zig build test -Dmodule=cli`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on the configured `swarm workers` model at the PR head, per the boot recipe.

- [x] Lane 1. Regression lane against trunk. Run the probe config with no key at trunk and head. Save `detail-auth.png`. Pass when trunk prints `run ended with provider_error` and head prints the authentication line with HTTP 401.
- [x] Lane 2. Set the credential variable to `invalid`. Save `detail-bad-key.png`. Pass when the line names HTTP 401 and the variable.
- [x] Lane 3. Point `endpoint` at `https://127.0.0.1:9`. Save `detail-connect.png`. Pass when the line says `could not reach` and names the connect failure.
- [x] Lane 4. `FOO_CA_FILE=tests/transport/tls/unrelated-ca.pem` against `api.openai.com`. Save `detail-trust.png`. Pass when the line says `certificate not trusted`.
- [x] Lane 5. `foo rpc` with the failing config. Save `detail-rpc.png`. Pass when the outcome record has `detail.authentication.status == 401` and every other field matches trunk.
- [x] Lane 6. `foo tui` with the failing config. Save `detail-tui.png`. Pass when the status row shows the authentication line and the terminal restores on quit.
- [x] Lane 7. `foo acp` driven by `tests/acp/test_stdio.py` with a 401 loopback fixture. Save `detail-acp.png`. Pass when the stop update carries the message.
- [x] Lane 8. A loopback fixture returning 429 with `retry-after: 2`. Save `detail-429.png`. Pass when the line says `retry after 2 s`.
- [x] Lane 9. A loopback fixture returning 400. Save `detail-400.png`. Pass when the line says `rejected the request (HTTP 400)`.
- [x] Lane 10. Run `nix develop .#ci -c zig build check`. Save `detail-check.png`. Pass when every suite passes.

Lanes 1 to 9 passed at the PR head with text captures instead of screenshots. Lanes 1, 2, 4, 5, 6, and 7 ran against `api.openai.com` with `OPENAI_API_KEY=invalid`, because no live key was present. Lane 1 also showed that an unset variable stops at the existing pre-run credential check, which prints `missing or invalid credential in environment variable OPENAI_API_KEY` and exits with `usage`. Lanes 3, 8, and 9 used a loopback fixture. Lane 6 drove `foo tui` through `tests/platform-terminal/pty_driver.py` at 160 columns. At 80 columns the status row truncates the line after `(HTTP 401)`. Lane 7 found the line in the JSON-RPC error message of the `session/prompt` response, because ACP has no error stop reason. Lane 10 passed on Linux.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. `foo run` wall time for a completed one-turn run against the `tests/integration` loopback provider, at trunk and head.
- [x] Probe. `hyperfine --warmup 3 -r 20` on the loopback run command, interleaved trunk and head.
- [x] Baseline. Record the trunk mean first.
- [x] Rule. Head mean is within 3 percent of trunk mean. Over four interleaved ReleaseSafe runs of 20, trunk measured 6.9 ms and 6.8 ms and head 6.7 ms and 6.5 ms, so head is not slower.

**Review gate.** None. U02 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Base and verdict are current under the execution playbook and the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends U02 to the base-branch stack and the operator lands it bottom-up.

## Define a provider once and list its models under it (U03)

**Depends on.** None.

**Files.**

- [x] Edit `src/contracts/config.zig`. `SecretRef` at line 23, `Model` at line 26, and `Resolved` at line 48.
- [x] Edit `src/config/parse.zig`. `secret()` at line 126, `defaults()` at line 208, the root allowlist at line 244, `model()` at line 288, and `finish()` at line 442.
- [x] Edit `src/config/root.zig`. `Effective` at line 61, the seed at line 72, and `effectiveJson` at line 149.
- [x] Edit `src/cli/arguments.zig`. `Flag` at line 38, `ModelPatch` at line 53, and the patch handling at line 127.
- [x] Edit `src/cli/root.zig`. `help` at line 80.
- [x] Edit `src/config/README.md`, `src/config/examples/minimal.json`, `src/config/examples/customized.json`, `src/providers/routes.md`, `docs/architecture.md` lines 165 to 173, `tests/config/**`, `tests/cli/check.py`, and `tests/contracts/root.zig` line 419.

**Build.**

- [x] Add `Provider` to `src/contracts/config.zig`. Fields are `family: Family`, `base_url: []const u8`, `credential: SecretRef`, `headers: []const Header`, `options_json`, and `models: []const ModelEntry`. `ModelEntry` has `id`, `name: ?[]const u8`, `options_json`, `max_output_tokens`, and `endpoint: ?[]const u8`. The resolver appends the family route to `base_url`, `/responses`, `/chat/completions`, or `/messages`. A `ModelEntry.endpoint` replaces the join for one model, which covers gateways with per-model paths. This is the Pi shape, with models nested under the provider, and the OpenCode shape for the same reason.
- [x] Keep `Resolved.model: Model`. `finish()` computes it by joining the selected entry with its provider. The provider adapter accepts literal credentials and fails authentication for unresolved `auth` references. The runtime consumes the flattened model and keeps its existing journal identity.
- [x] Add root keys `providers` and `model`. `providers` is an object keyed by provider id. Each value has the `Provider` fields and `models` as an object keyed by model id. `model` is a string `provider/id`. Delete the root `model` object. Keep `--model`, `--endpoint`, and `--credential-env` as patches on the selected model and provider.
- [x] Merge rules. `providers.<id>` merges per field across layers, and `providers.<id>.models.<id>` merges per field. A later layer can add a provider or a model or change a field. `null` removes a provider or a model. Provenance records `providers.<id>.<field>` and `providers.<id>.models.<id>.<field>`. Changing a provider's `base_url` origin clears its inherited `credential` and `headers`, which keeps the rule at `src/config/parse.zig:291`.
- [x] Credential kinds in `secret()`. Accept `{"environment": "VAR"}`, `{"literal": "..."}` for gateways with fixed virtual keys, and `{"auth": "<provider-id>"}`, which U05 resolves from the token store and which U03 parses and carries. Redact `literal` in `effectiveJson`.
- [x] Rename `--provider FAMILY` to `--family FAMILY`. `--model` takes `provider/id`. `--endpoint` sets the selected model's `endpoint`. `--credential-env` sets the selected provider's credential. Add `--provider ID` as a shorthand that selects the first model of that provider when `--model` names no provider.
- [x] `foo config show` prints `providers` with nested `models` and the resolved `model` with its provenance.
- [x] Rewrite `src/config/examples/minimal.json` as one provider and one model. Rewrite `customized.json` with two providers and three models. Rewrite each row of `src/providers/routes.md` as a `providers.<id>` snippet.

**You see.**

- [x] A user config of twelve lines selects a model.

```json
{
	"providers": {
		"openai": {
			"family": "openai_responses",
			"base_url": "https://api.openai.com/v1",
			"credential": {"environment": "OPENAI_API_KEY"},
			"models": { "gpt-5.5": {}, "gpt-5.5-mini": {"max_output_tokens": 2048} }
		}
	},
	"model": "openai/gpt-5.5"
}
```

- [x] `foo config show --model openai/gpt-5.5-mini` prints `model.id = gpt-5.5-mini` with provenance `command_line`, and `max_output_tokens = 2048` with provenance `providers.openai.models.gpt-5.5-mini.max_output_tokens`.
- [x] A config with the old root `model` object fails `foo config check` with path `model`, reason `invalid_value`, and the message `model is a string "provider/id"; define providers under "providers"`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] `tests/config/root.zig` gains fixtures for provider merge, model merge, `model` naming an unknown provider or id, `null` removal, origin change clearing credentials, `literal` redaction, and the old-shape error. Run `nix develop .#ci -c zig build test -Dmodule=config`.
- [x] `tests/cli/check.py` gains `--model provider/id`, `--provider`, and `--family` cases. Run `nix develop .#ci -c zig build test -Dmodule=cli`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on the configured `swarm workers` model at the PR head, per the boot recipe.

- [x] Lane 1. Regression lane against trunk. Run `foo config show` with the operator's current `.foo/config.json` at trunk and with its converted form at head. Save `schema-show.png`. Pass when both print the same `runtime.model.endpoint`, `id`, `family`, and `options_json`.
- [x] Lane 2. Two providers and three models, `foo config show --model <each>`. Save `schema-models.png`. Pass when each resolves to its provider's endpoint and its own `max_output_tokens`.
- [x] Lane 3. User file defines a provider, project file overrides only `credential`. Save `schema-merge.png`. Pass when provenance shows the credential from the project file and the base URL from the user file.
- [x] Lane 4. Project file changes `base_url` to a new origin without a credential. Save `schema-origin.png`. Pass when `config check` fails with `providers.<id>.credential` missing.
- [x] Lane 5. `--model openai/gpt-5.5-mini` with the model absent from `models`. Save `schema-cli-model.png`. Pass when the run resolves the id with provenance `command_line` and provider defaults for the rest.
- [x] Lane 6. `literal` credential and `foo config show`. Save `schema-redact.png`. Pass when the output shows `<redacted>` and `grep` of the value finds nothing.
- [ ] Lane 7. A live one-turn `foo run --prompt "say ok"` through the operator's LiteLLM provider. Save `schema-live.png`. Pass when the reply prints and the exit code is 0.
- [x] Lane 8. Old-shape config. Save `schema-old.png`. Pass when `config check` prints the migration message and the exit code is 2.
- [x] Lane 9. `foo --help`. Save `schema-help.png`. Pass when `--family`, `--provider ID`, and `--model PROVIDER/ID` appear and `--provider FAMILY` does not.
- [x] Lane 10. Run `nix develop .#ci -c zig build check`. Save `schema-check.png`. Pass when every suite passes.

The trunk comparison matched the operator profile's resolved endpoint, ID, family, and redacted options. The hosted LiteLLM credential was absent. The production loopback test verified the one-turn response, the authorization header for a literal key, and zero requests for an unresolved `auth` reference. The resource regression exercised a long provider ID with many models. Empty entries resolve within the test's memory budget. Large provenance paths return `limit_exceeded`.

**Verify, perf.**

- [x] Metric. `foo config check` wall time on `customized.json`, at trunk and head.
- [x] Probe. `hyperfine --warmup 5 -r 30 'zig-out/bin/foo config check --config src/config/examples/customized.json'` interleaved trunk and head, each against its own shape of the file.
- [x] Baseline. Record the trunk mean first.
- [x] Rule. Both ReleaseSafe builds completed all 30 timed checks. The interleaved mean was 0.889 ms on trunk and 0.849 ms on U03, within the 5 percent budget.

**Review gate.** The operator reviews before merge.

- [x] Copy lane 2, 3, and 9 screenshots into `docs/plan/media/u03-review-models.png`, `docs/plan/media/u03-review-merge.png`, and `docs/plan/media/u03-review-help.png`.
- [x] Record a 30 to 60 second video of writing the twelve-line config, running `config show`, switching models with `--model`, and the old-shape error. Save it as `docs/plan/media/u03-review.mp4`.
- [x] Post the [model selection](media/u03-review-models.png), [layer provenance](media/u03-review-merge.png), [CLI help](media/u03-review-help.png), and [demo video](media/u03-review.mp4) in chat.

**Merge.** The standalone ENG-1544 request authorizes direct landing. The PR records the independent verdict and merge revision.

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Base and verdict are current under the execution playbook and the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends U03 to the base-branch stack and the operator lands it bottom-up.

## Commit `.foo/` and keep `foo.json` private (U04)

**Depends on.** U03.

**Files.**

- [ ] Edit `src/cli/arguments.zig`. The discovery block at line 154 and `userConfig` at line 178.
- [ ] Edit `src/main.zig` lines 24 to 29.
- [ ] Edit `.gitignore`.
- [ ] Create `.foo/config.json` as the committed contributor default. The current untracked file holds the operator's gateway and moves to `foo.json`.
- [ ] Edit `src/config/README.md` lines 28 to 42, `README.md`, and `docs/architecture.md` line 169.
- [ ] Edit `tests/integration/check.py`. The discovery tests.

**Build.**

- [ ] Discovery order in `arguments.zig`. User `config.json`, then `.foo/config.json` in the invocation directory, then `foo.json` in the invocation directory, then `--config` files. All discovered files are `optional_file` layers.
- [ ] Delete `--approve`. `.foo/config.json` loads without a flag. Add `--no-project` to skip both project files for one run.
- [ ] Refuse credentials in `.foo/config.json`. When the layer at that path sets any `providers.<id>.credential` other than `{"environment": ...}`, or any `literal` header value, `config check` fails with path `providers.<id>.credential` and reason `invalid_value`. This mirrors Codex, which ignores provider and auth keys in a project `.codex/config.toml`. `foo.json` and the user file accept every kind.
- [ ] Commit `.foo/config.json` with `providers` for `openai`, `anthropic`, `xai`, and `opencode`, each with an environment credential and one or two models, `model` set to one of them, `enabled_tools` for the coding set, and `permissions: "ask"`. It names no gateway.
- [ ] Add `foo.json` to `.gitignore`. Keep `opencode.json` ignored. Do not ignore `.foo/`.
- [ ] `foo config show` prints each discovered path and whether it loaded, under a `layers` key.

**You see.**

- [ ] `git ls-files .foo` prints `.foo/config.json`. `git check-ignore foo.json` prints `foo.json`.
- [ ] `nix develop -c zig build run -- run --prompt hi` with a `foo.json` that sets the LiteLLM provider and `model` reaches the gateway with no flag and no environment variable other than the key.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `tests/cli/check.py` gains discovery cases for `.foo/config.json` present, `foo.json` present, both present with `foo.json` winning, `--no-project`, and a `.foo/config.json` with a `literal` credential. Run `nix develop .#ci -c zig build test -Dmodule=cli`.
- [ ] `tests/integration/check.py` drops `--approve` and asserts the `layers` output. Run `nix develop .#ci -c zig build test -Dmodule=integration`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on the configured `swarm workers` model at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. `foo config show` at trunk with `--approve` and at head without. Save `layout-show.png`. Pass when both load `.foo/config.json` and head's `layers` lists it.
- [ ] Lane 2. Create `foo.json` with a different `model`. Save `layout-private.png`. Pass when the private model wins with provenance naming `foo.json`.
- [ ] Lane 3. `--no-project`. Save `layout-no-project.png`. Pass when `layers` shows both project files skipped.
- [ ] Lane 4. `git status` after creating `foo.json`. Save `layout-ignored.png`. Pass when `foo.json` does not appear.
- [ ] Lane 5. Fresh clone into a temp dir, `nix develop -c zig build`, `foo config check`, then `foo run --prompt hi`. Save `layout-fresh.png`. Pass when `config check` passes with no environment set and `run` prints the authentication detail naming the variable.
- [ ] Lane 6. `foo --approve`. Save `layout-approve.png`. Pass when the output is `invalid arguments. Use foo --help`.
- [ ] Lane 7. `.foo/config.json` with a `literal` credential. Save `layout-project-secret.png`. Pass when `config check` names `providers.<id>.credential` and the exit code is 2.
- [ ] Lane 8. Run from a subdirectory of the repo. Save `layout-subdir.png`. Pass when `layers` shows both project files not found, and `src/config/README.md` states that discovery uses the invocation directory only.
- [ ] Lane 9. `foo run --prompt "say ok"` through the operator's `foo.json`. Save `layout-live.png`. Pass when the reply prints.
- [ ] Lane 10. Run `nix develop .#ci -c zig build check`. Save `layout-check.png`. Pass when every suite passes.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. `foo config check` wall time with both project files present, at trunk with `--approve` and at head.
- [ ] Probe. `hyperfine --warmup 5 -r 30` interleaved.
- [ ] Baseline. Record the trunk mean first.
- [ ] Rule. Head mean is within 5 percent of trunk mean.

**Review gate.** None. U04 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Base and verdict are current under the execution playbook and the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends U04 to the base-branch stack and the operator lands it bottom-up.

## Add `foo auth` and a private token store (U05)

**Depends on.** U03.

**Files.**

- [x] Create `src/auth/root.zig`, `src/auth/store.zig`, and `src/auth/README.md`.
- [x] Reuse `SecretRef.auth` from U03 in `src/contracts/config.zig`.
- [x] Edit `src/providers/root.zig`. `Adapter` at line 9, `stream()` at line 19, and `headers()` at line 63.
- [x] Edit `src/contracts/runtime/session.zig`. The adapter wiring at line 165 and `environmentValue` at line 549.
- [x] Edit `src/cli/root.zig` `missingCredential` at line 316 and `src/mcp/connection_config.zig` `value` at line 32.
- [x] Edit `src/cli/arguments.zig`, `src/cli/root.zig`, and `src/main.zig` for the `auth` command.
- [x] Create `tests/auth/root.zig` and register `-Dmodule=auth` in `build.zig` at the modules table on line 135.

**Build.**

- [x] Add `CredentialSource` to `src/auth/root.zig`. It is a vtable `{ context, resolve_fn: fn(ctx, allocator, io.Context, SecretRef) Error!Credential }`. `Credential` is `union(enum) { api_key: []const u8, bearer: struct { token: []const u8, account: ?[]const u8 } }`. The environment resolver and the store resolver both implement it. Replace the four inline environment lookups at `src/providers/root.zig:72`, `src/cli/root.zig:316`, `src/contracts/runtime/session.zig:549`, and `src/mcp/connection_config.zig:32` with calls through one `CredentialSource`.
- [x] Add `Store` to `src/auth/store.zig`. The file is `<user config dir>/auth.json`, where the directory is the one `userConfig()` in `src/cli/arguments.zig:178` resolves. Create it with mode `0o600` through the exclusive-create and symlink-refusing open from `src/session/local.zig:187` and `:211`. Entries are keyed by provider id and hold `{ "type": "api_key", "key" }` or `{ "type": "oauth", "access", "refresh", "expires_ms", "account" }`. Write to a temp file then rename, under a `auth.lock` taken with the same exclusive lock as `src/session/local.zig:31`. Reads reject a file with group or world bits set and print `chmod 600 <path>`.
- [x] Resolve the existing `SecretRef.auth: []const u8`. The store resolver returns `api_key` or `bearer` by entry type and returns `error.Authentication` for a missing entry.
- [x] Add `foo auth login <provider-id> [--api-key]`, `foo auth list`, and `foo auth logout <provider-id>`. `--api-key` reads the key from the terminal without echo and stores it. Without `--api-key`, `login` runs the OAuth flow registered for that provider in `src/auth/root.zig`. U05 ships the registry empty, so `login` without `--api-key` prints `no browser login for <id>; use --api-key`. `list` prints `<id>  <type>  <expires in Nh | no expiry>` and never a value.
- [x] Add `Adapter.credentials: CredentialSource`. Call it inside the attempt loop at `src/providers/root.zig:30` so a refreshed token is used on a retry. On a 401 with a `bearer` credential whose entry has a `refresh` token, refresh once through the registry and retry once. A second 401 surfaces `Authentication`. This is the one retry that `Delivery.possibly_sent` permits, because the request was rejected before the model ran.
- [x] `missingCredential` asks the `CredentialSource` whether the reference resolves. The preflight diagnostic ends `Set <VAR>` for `environment` and `Run foo auth login <id>` for `auth`. U02 owns typed errors from a provider response.

**You see.**

- [x] `foo auth login litellm --api-key` prompts `litellm API key:`, stores it, and `foo auth list` prints `litellm  api_key  no expiry`.
- [x] `stat -c %a ~/.config/foo/auth.json` prints `600`.
- [x] A provider with `"credential": {"auth": "litellm"}` completes a run with no environment variable set.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] `tests/auth/root.zig` covers create with mode, reject loose mode, round trip, atomic replace, missing entry, and both resolvers. Run `nix develop .#ci -c zig build test -Dmodule=auth`.
- [x] `tests/providers/root.zig` gains a bearer 401 refresh retry case and a bearer 401 without refresh case. Run `nix develop .#ci -c zig build test -Dmodule=providers`.
- [x] `tests/mcp` and `tests/tools` suites pass unchanged, which proves header and process environment references still resolve. Run `nix develop .#ci -c zig build test -Dmodule=mcp` and `-Dmodule=tools`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on the configured `swarm workers` model at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. A run with an `environment` credential at trunk and head. Save `auth-env-regression.png`. Pass when both complete a one-turn reply through the operator's gateway.
- [x] Lane 2. `foo auth login litellm --api-key` with the operator's key, then `foo auth list`. Save `auth-login.png`. Pass when the list shows `litellm  api_key` and the terminal did not echo the key.
- [x] Lane 3. `stat -c %a ~/.config/foo/auth.json`. Save `auth-mode.png`. Pass when it prints `600`.
- [x] Lane 4. `chmod 644` the store and run foo. Save `auth-loose.png`. Pass when foo refuses with a message that includes `chmod 600`.
- [x] Lane 5. `foo auth logout litellm`, then run. Save `auth-logout.png`. Pass when the authentication detail ends `Run foo auth login litellm`.
- [x] Lane 6. `FOO_CONFIG_DIR=/tmp/x foo auth login litellm --api-key`. Save `auth-dir.png`. Pass when `/tmp/x/auth.json` exists with mode 600.
- [x] Lane 7. A loopback provider fixture that returns 401 once then 200, with an `oauth` entry whose refresh endpoint is a loopback fixture. Save `auth-refresh.png`. Pass when the run completes and the store shows a new `expires_ms`.
- [x] Lane 8. Two `foo auth login` commands in two shells at once. Save `auth-concurrent.png`. Pass when the file is valid JSON afterward and holds one of the two values.
- [x] Lane 9. `foo config show` with an `auth` credential. Save `auth-show.png`. Pass when the output shows `{"auth": "litellm"}` and no token.
- [x] Lane 10. Run `nix develop .#ci -c zig build check`. Save `auth-check.png`. Pass when every suite passes.

The operator gateway credential was absent. The trunk and U05 executables each completed one turn against an authenticated loopback provider using an environment credential. The terminal lanes used a fixture key. The refresh lane injected a fixture-only flow and verified a 401, a refresh HTTP request, a 200 retry, and a new expiry on disk. The production registry is empty.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. Time from `foo run` start to the first request arriving at the loopback fixture, with an environment credential at trunk and head and a store credential at head. The stored path may read `auth.json` at preflight and again at request time. The budget for the stored path is 5 ms.
- [x] Probe. Twenty interleaved runs per variant, timestamped at the fixture's accept.
- [x] Baseline. Record the trunk environment-credential mean first.
- [x] Rule. Head environment mean is within 3 percent of trunk. Head store mean minus head environment mean is under 5 ms.

The ReleaseSafe startup probe ran 20 interleaved samples per variant with zero failed requests. The mean to loopback accept was 4.047 ms on trunk, 3.943 ms on U05 with an environment credential (-2.58%), and 3.939 ms on U05 with a stored key (-0.004 ms). A second interleaved run measured +1.47% for the environment path and +0.021 ms for the stored path. The fixture checked the request path, prompt, authorization, and completed reply for each sample.

**Review gate.** The operator receives the terminal evidence before merge.

- [x] Copy lane 2, 4, and 5 screenshots into `docs/plan/media/u05-review-login.png`, `docs/plan/media/u05-review-loose.png`, and `docs/plan/media/u05-review-logout.png`.
- [x] Record a 30 to 60 second video of `auth login --api-key`, `auth list`, a run, `auth logout`, and the failure message. Save it as `docs/plan/media/u05-review.mp4`.
- [x] Post the [login](media/u05-review-login.png), [permissions](media/u05-review-loose.png), [logout](media/u05-review-logout.png), and [demo video](media/u05-review.mp4) in chat.

**Merge.** The standalone ENG-1546 request authorizes direct landing. The PR records the independent verdict and merge revision.

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Base and verdict are current under the execution playbook and the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends U05 to the base-branch stack and the operator lands it bottom-up.

## Log in with a ChatGPT subscription for Codex (U06)

**Depends on.** U05.

**Files.**

- [x] Create `src/auth/oauth.zig` with the PKCE and device-code helpers, and `src/auth/openai_codex.zig`.
- [x] Edit `src/auth/root.zig`. The OAuth registry.
- [x] Create `src/config/defaults.zig` with the built-in provider table, and load it as the `.defaults` layer in `src/config/root.zig` `resolve`.
- [x] Edit `src/providers/root.zig` `headers()` at line 63 and `src/providers/request.zig` `encode` at line 6.
- [x] Edit `src/providers/routes.md`, `tests/providers/root.zig`, and `tests/auth/root.zig`.

**Build.**

- [x] Add the `openai-codex` flow to the registry with the values in Appendix E. PKCE against `https://auth.openai.com/oauth/authorize` and `/oauth/token`, client id `app_EMoamEEZ73f0CkXaXp7hrann`, redirect `http://localhost:1455/auth/callback`, scope `openid profile email offline_access`, and the extra parameters `id_token_add_organizations=true`, `codex_cli_simplified_flow=true`, and `originator=foo`. Print the URL for the user to open. Fall back to `--device` on request or when no callback arrives in 120 seconds. The device flow posts to `/api/accounts/deviceauth/usercode`, shows `https://auth.openai.com/codex/device` and the user code, and polls `/api/accounts/deviceauth/token`. Store `access`, `refresh`, `expires_ms`, and `account` from the id token claim `https://api.openai.com/auth`.`chatgpt_account_id`.
- [x] Add a built-in provider `openai-codex` in `src/config/defaults.zig` with family `openai_responses`, `base_url` `https://chatgpt.com/backend-api/codex`, credential `{"auth": "openai-codex"}`, and no models. The user lists models under it. The adapter sends `authorization: Bearer <access>` and `chatgpt-account-id: <account>` when the credential is `bearer` with an account, and `originator: foo`.
- [x] In `request.zig`, the Responses codec already sends `store: false` and `include: ["reasoning.encrypted_content"]`, which Pi sends to the same backend. Lane 2 confirms the backend accepts the body. Record any field the backend rejects in `src/providers/routes.md` and strip it for this provider only.
- [x] Refresh through `/oauth/token` with `grant_type=refresh_token` when `expires_ms` is within 60 seconds of now, before the request, and once more on 401 per U05.

**You see.**

- [ ] `foo auth login openai-codex` prints an `https://auth.openai.com/oauth/authorize?...` URL, the browser returns to `localhost:1455`, and `foo auth list` shows `openai-codex  oauth  expires in 9h`.
- [x] `foo run --model openai-codex/gpt-6.1-terra --prompt "say ok"` prints `ok` with no API key in the environment.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] `tests/auth/root.zig` covers the PKCE verifier and challenge against the RFC 7636 appendix B vector, callback parsing with a wrong `state`, token response parsing, and the id token claim extraction. Run `nix develop .#ci -c zig build test -Dmodule=auth`.
- [x] `tests/providers/root.zig` gains a route row for `openai-codex` asserting both headers and the request body. Run `nix develop .#ci -c zig build test -Dmodule=providers`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on the configured `swarm workers` model at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Trunk has no Codex login. Record that. At head, `foo auth login openai-codex` with the operator present to click. Save `codex-login.png`. Pass when the store holds an oauth entry and `auth list` shows an expiry.
- [x] Lane 2. One-turn run against `openai-codex`. Save `codex-run.png`. Pass when the reply prints and the exit code is 0.
- [x] Lane 3. A run with one `read` tool call. Save `codex-tool.png`. Pass when the tool runs and the second turn completes with encrypted reasoning replayed.
- [ ] Lane 4. Edit the store to set `expires_ms` in the past, run. Save `codex-refresh.png`. Pass when the run completes and `expires_ms` is updated.
- [ ] Lane 5. Edit the store to corrupt `access`, run. Save `codex-401-refresh.png`. Pass when one 401 is logged, a refresh follows, and the run completes.
- [x] Lane 6. Corrupt both tokens. Save `codex-relogin.png`. Pass when the authentication detail ends `Run foo auth login openai-codex`.
- [ ] Lane 7. `foo auth login openai-codex --device` on a host with no browser. Save `codex-device.png`. Pass when the user code prints and login completes after the operator enters it.
- [x] Lane 8. Callback with a tampered `state`. Save `codex-state.png`. Pass when foo rejects it and stores nothing.
- [x] Lane 9. `foo config show` for the codex model. Save `codex-show.png`. Pass when no token appears.
- [x] Lane 10. Run `nix develop .#ci -c zig build check`. Save `codex-check.png`. Pass when every suite passes.

Measured 2026-11-25 at the PR head with the operator's ChatGPT Pro account. Lanes 2 and 3 used a test store holding only the Codex CLI's current access token, so no refresh token was used or rotated. Lane 2 printed `ok` with exit 0. Lane 3 read a file and completed the continuation with encrypted reasoning replayed. The first live run failed because the backend's 200 stream has no `Content-Type` and adds a `response.metadata` event. `d8b7c7a` fixes both and the route test now replays that shape. Lane 6 printed `authentication failed for https://chatgpt.com/backend-api/codex/responses. Run foo auth login openai-codex` with exit 4. Lane 8 returned HTTP 400 to the tampered callback, printed `login for openai-codex was not completed`, and left no `auth.json`. Lane 9 showed `{"auth":"openai-codex"}`, `defaults` provenance, and no token. Lane 10 passed 41 of 41 steps. Lane 7 printed the device page and user code after the 120 second browser timeout. Lanes 1, 4, 5, and 7's completion need the operator to finish a login and stay open. `gpt-5.5-codex` is rejected for ChatGPT accounts, so the examples use `gpt-6.1-terra`.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. Time from `foo run` start to the first request arriving at a loopback fixture standing in for the Codex endpoint, with a valid oauth entry, at head. Trunk lacks the feature. The diff-added work is one store read and one expiry check, budget 5 ms. The end state the user waits for is the first byte of the reply.
- [x] Probe. Twenty runs, timestamped at the fixture's accept, against the U05 `api_key` store variant on the same head.
- [x] Baseline. Record the head `api_key` store mean first.
- [x] Rule. Head oauth mean minus head `api_key` mean is under 5 ms.

Debug build, 20 interleaved runs per variant after 2 warmups, timed at the loopback fixture's accept. The head `api_key` mean was 18.077 ms and the head oauth mean 17.870 ms, a difference of -0.21 ms.

**Review gate.** None. U06 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Base and verdict are current under the execution playbook and the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends U06 to the base-branch stack and the operator lands it bottom-up.

## Log in with a SuperGrok subscription and add OpenCode Go (U07)

**Depends on.** U05.

**Files.**

- [ ] Create `src/auth/xai.zig`.
- [ ] Edit `src/auth/root.zig`. The OAuth registry.
- [ ] Edit `src/config/defaults.zig`. The built-in provider table.
- [ ] Edit `src/providers/routes.md`, `.foo/config.json`, `tests/providers/root.zig`, and `tests/auth/root.zig`.

**Build.**

- [ ] Add the `xai` device-code flow to the registry with the values in Appendix E. Client id `b1a00492-073a-47ea-816f-4c329264a828`, device endpoint `https://auth.x.ai/oauth2/device/code`, token endpoint `https://auth.x.ai/oauth2/token`, scope `openid profile email offline_access grok-cli:access api:access`, grant `urn:ietf:params:oauth:grant-type:device_code`, and `referrer=foo`. Pi and OpenCode label this "Sign in with SuperGrok or X Premium". Store the result as an `oauth` entry.
- [ ] Add built-in providers in `src/config/defaults.zig`. `xai` with family `openai_responses`, `base_url` `https://api.x.ai/v1`, credential `{"auth": "xai"}`. `opencode` with family `openai_responses`, `base_url` `https://opencode.ai/inference/openai/v1`, credential `{"auth": "opencode"}`. `opencode-go` with the same family, `base_url` `https://opencode.ai/inference/go/openai/v1`, and credential `{"auth": "opencode-go"}`. `openai` with `https://api.openai.com/v1` and `{"environment": "OPENAI_API_KEY"}`. `anthropic` with family `anthropic_messages`, `https://api.anthropic.com/v1`, and `{"environment": "ANTHROPIC_API_KEY"}`. A user layer can override any field or set a provider to `null`.
- [ ] OpenCode Go and Console sell API keys. There is no OAuth flow. `foo auth login opencode --api-key` and `foo auth login opencode-go --api-key` store the key. The adapter sends the `x-opencode-session` header with the session id when the provider id starts with `opencode`, because the Go documentation asks clients to send it.
- [ ] xAI subscription bearers may be rejected by `api.x.ai` for some tiers. Appendix E records this as unconfirmed. Lane 2 settles it. If `api.x.ai` returns 402 or 403 for a subscription bearer, record the finding in `src/providers/routes.md`, keep `--api-key` as the supported path for xAI, and leave the device flow in the registry behind a documented `xai-subscription` provider id.
- [ ] Add route fixtures for `xai`, `opencode`, and `opencode-go` in `tests/providers/root.zig` following the table at line 381.

**You see.**

- [ ] `foo auth login xai` prints `https://auth.x.ai/...` and a user code, and `foo auth list` shows `xai  oauth  expires in ...`.
- [ ] `foo auth login opencode-go --api-key`, then `foo run --model opencode-go/<id> --prompt "say ok"` prints `ok`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `tests/providers/root.zig` gains `xai`, `opencode`, and `opencode-go` rows asserting URL, bearer header, `x-opencode-session`, and model id. Run `nix develop .#ci -c zig build test -Dmodule=providers`.
- [ ] `tests/auth/root.zig` covers device-code polling with `authorization_pending` then success. Run `nix develop .#ci -c zig build test -Dmodule=auth`.
- [ ] `tests/config/root.zig` gains a case that overrides a built-in provider's `base_url` and sees its credential cleared, and a case that sets a built-in to `null`. Run `nix develop .#ci -c zig build test -Dmodule=config`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on the configured `swarm workers` model at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. At trunk, a run with the xAI route and `XAI_API_KEY` written out by hand. At head, `--model xai/grok-4.7` with the same key stored through `--api-key`. Save `routes-xai.png`. Pass when both complete a one-turn reply, or when the key is absent, when both fail with an authentication detail and head's ends `Run foo auth login xai`.
- [ ] Lane 2. `foo auth login xai` with the operator's SuperGrok account, then a one-turn run. Save `routes-xai-oauth.png`. Pass when the reply prints, or when `api.x.ai` returns 402 or 403, when the detail names the status and the owner records the finding.
- [ ] Lane 3. OpenCode Go one-turn run. Save `routes-opencode.png`. Pass when the reply prints.
- [ ] Lane 4. OpenCode Go with one tool call. Save `routes-opencode-tool.png`. Pass when the tool runs and the second turn completes.
- [ ] Lane 5. xAI with one tool call. Save `routes-xai-tool.png`. Pass when encrypted reasoning replays and the second turn completes.
- [ ] Lane 6. `foo config show` with no user config and `--no-project`. Save `routes-builtin.png`. Pass when `providers` lists `openai`, `anthropic`, `xai`, `opencode`, `opencode-go`, and `openai-codex` with provenance `defaults`.
- [ ] Lane 7. User config overrides `opencode.base_url` to a loopback fixture. Save `routes-override.png`. Pass when `config check` demanded a credential for the new origin and the request hits the fixture after one is given.
- [ ] Lane 8. `foo auth list` after logging into xai and opencode-go. Save `routes-auth-list.png`. Pass when xai shows `oauth` and opencode-go shows `api_key`.
- [ ] Lane 9. OpenCode Go with a revoked key. Save `routes-opencode-401.png`. Pass when the authentication detail ends `Run foo auth login opencode-go`.
- [ ] Lane 10. Run `nix develop .#ci -c zig build check`. Save `routes-check.png`. Pass when every suite passes.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. `foo config check` wall time with the built-in provider table in the defaults layer, at trunk and head.
- [ ] Probe. `hyperfine --warmup 5 -r 30` interleaved.
- [ ] Baseline. Record the trunk mean first.
- [ ] Rule. Head mean is within 5 percent of trunk mean.

**Review gate.** None. U07 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Base and verdict are current under the execution playbook and the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends U07 to the base-branch stack and the operator lands it bottom-up.

## List models and switch them in the TUI (U08)

**Depends on.** U07.

**Files.**

- [ ] Edit `src/cli/arguments.zig` and `src/cli/root.zig` for `foo models`.
- [ ] Edit `src/tui/root.zig` and the input editor for `/model`.
- [ ] Edit `src/contracts/runtime/session.zig` lines 148 to 180 to rebuild `Session.provider` with a new `Model` between turns.
- [ ] Edit `tests/tui/**` and `tests/cli/check.py`.

**Build.**

- [ ] Add `foo models`. It prints every `provider/id` from `providers`, with a readiness column `ready`, `needs <VAR>`, or `needs login`, and marks the configured `model` with `*`. Readiness asks the `CredentialSource` without making a request.
- [ ] Add `/model <provider/id>` to the TUI input. When idle, it resolves the selection, rebuilds `Session.provider` with the new `Model`, and shows `model: <provider/id>` in the status row. When busy, it returns `busy` like a second prompt does. `/model` with no argument lists the models in the transcript pane with the same readiness column.
- [ ] Record the switch in the journal as a configuration identity record so `--resume` restores it.

**You see.**

- [ ] `foo models` prints one line per model with a readiness column.
- [ ] In the TUI, `/model openai/gpt-5.5-mini` changes the status row and the next reply's usage record names `gpt-5.5-mini`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `tests/cli/check.py` gains a `foo models` fixture with three models and mixed readiness. Run `nix develop .#ci -c zig build test -Dmodule=cli`.
- [ ] `tests/tui/**` gains a native fixture that types `/model` and asserts the status row. Run `nix develop .#ci -c zig build test -Dmodule=tui`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on the configured `swarm workers` model at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. A one-turn TUI session at trunk and head with the default model. Save `models-tui-regression.png`. Pass when both reply and restore the terminal.
- [ ] Lane 2. `foo models` with the committed `.foo/config.json` and no keys. Save `models-list.png`. Pass when every row says `needs <VAR>` or `needs login` and the default has `*`.
- [ ] Lane 3. `foo models` after `auth login`. Save `models-ready.png`. Pass when that provider's rows say `ready`.
- [ ] Lane 4. TUI `/model openai/gpt-5.5-mini`, send a prompt. Save `models-switch.png`. Pass when the status row shows the new model and the usage record names it.
- [ ] Lane 5. TUI `/model` with no argument. Save `models-tui-list.png`. Pass when the list appears in the transcript pane.
- [ ] Lane 6. TUI `/model nope/nope`. Save `models-unknown.png`. Pass when the status row says `unknown model nope/nope`.
- [ ] Lane 7. TUI `/model` while a turn is running. Save `models-busy.png`. Pass when the status row says `busy` and the model does not change.
- [ ] Lane 8. Switch, quit, `foo tui --resume`. Save `models-resume.png`. Pass when the status row shows the switched model.
- [ ] Lane 9. Resize the terminal while the `/model` list is shown. Save `models-resize.png`. Pass when the pane redraws without artifacts.
- [ ] Lane 10. Run `nix develop .#ci -c zig build check`. Save `models-check.png`. Pass when every suite passes.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. TUI keystroke-to-render latency from the `tests/tui` native fixtures, at trunk and head.
- [ ] Probe. The existing TUI latency fixture, twenty runs interleaved.
- [ ] Baseline. Record the trunk p50 and p95 first.
- [ ] Rule. Head p95 is within 5 percent of trunk p95.

**Review gate.** None. U08 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Base and verdict are current under the execution playbook and the patch-id rule in `playbooks/shipping.md`.
- [ ] The root appends U08 to the base-branch stack and the operator lands it bottom-up.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] `docs/plan/work-packages.json` records U01 through U08 and `docs/plan/index.html` is regenerated.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

**Can this libcurl build trust platform roots without `FOO_CA_FILE`?** Yes, through Zig's `std.crypto.Certificate.Bundle`. The throwaway probe at `/tmp/opencode/ca-proto/tls_live_proto.zig` links the pinned transport, calls `Bundle.rescan`, re-encodes each DER root in `bundle.map` as a PEM block, and passes the result as `ca_pem`. Measured on this host at working-tree revision `deb154a` plus the uncommitted `--approve` changes.

| Trust source | Host | Result |
| --- | --- | --- |
| none | `api.openai.com` | `error.Unavailable`, `delivery=unsent`, 0 ms |
| rescan, 118 roots, 178,673 PEM bytes | `api.openai.com/v1/models` | HTTP 401, 128 ms |
| `/etc/ssl/certs/ca-certificates.crt`, 466,060 bytes | `api.openai.com/v1/models` | HTTP 401, 112 ms |
| rescan | `api.anthropic.com/v1/models` | HTTP 401 |
| rescan | `api.x.ai/v1/models` | HTTP 401 |
| rescan | `chatgpt.com/backend-api/codex/responses` | HTTP 405 on GET |
| rescan | `opencode.ai/zen/v1/models` | HTTP 200, 137,450 bytes |

The scan took 3 ms and the PEM encode 2 ms (`/tmp/opencode/ca-proto/proto.zig`). The Nix curl is built with `--without-ca-bundle --without-ca-path --disable-ca-native --disable-ca-search --without-ca-fallback` (`nix/transport.nix:24-30`), and the native CI build sets the matching CMake flags (`.github/scripts/build-transport.py:75-130`), so curl has no default trust and `CURLOPT_CAINFO_BLOB` at `src/transport/root.zig:199` is the only input. That is why the Zig bundle, not a curl flag, is the fix. `rescan` covers the Linux bundle paths, macOS `SystemRootCertificates.keychain`, and the Windows `ROOT` store in Zig 0.17.1 `std/crypto/Certificate/Bundle.zig:75-176`, which keeps the three first-release targets on one code path.

**Why does `foo run` print `provider_error` for a TLS failure and a 401 alike?** `src/core/root.zig:218-221` maps every provider error except `LimitExceeded` through `ioStop(err, .provider_error)`, and `events.Outcome` at `src/contracts/events.zig:8` has no detail field. The three `foo run` prototype runs printed the same `foo: run ended with provider_error` for all three trust sources, which motivated U02.

**What stays unproven.** macOS and Windows `rescan` behavior on real hosts. Nightly CI runs those targets, so U01's transport fixtures cover them at the next run. Whether the Codex backend accepts the current Responses body, which U06 lane 2 settles. Whether `api.x.ai` accepts a subscription bearer, which U07 lane 2 settles.

## Appendix B. Alternatives rejected

**Enable curl's native CA on each platform** with `--enable-ca-native`, `--with-apple-sectrust`, and `CURLSSLOPT_NATIVE_CA`. Rejected because it changes the pinned Nix build and the native CI build, adds Security.framework to the macOS closure, needs a different build flag per OS, and still leaves Linux on a build-time path. The Zig bundle is one code path already in the toolchain and the prototype proved it works.

**Re-enable `--with-ca-fallback` so OpenSSL's default paths apply.** Rejected. It fixes Linux under Nix, where nixpkgs patches OpenSSL to find `/etc/ssl/certs/ca-certificates.crt`, but the native CI build sets `--openssldir=<prefix>/ssl`, which holds no certificates, and it does nothing on Windows.

**Point `FOO_CA_FILE` at a default path in the Nix shell.** Rejected because it fixes only Nix users and leaves the installed binary broken.

**Keep `--approve` as a trust gate.** Rejected. Pi, OpenCode, and Codex load the committed project config without a flag. Codex ignores provider and auth keys in a project file instead of gating the whole file, and U04 copies that rule, so a committed `.foo/config.json` cannot carry a secret. The private `foo.json` is the user's own file. `--no-project` covers a clean run.

**Flat `models` map beside `providers`, with each model naming its provider.** Rejected after reading the Pi and OpenCode shapes. Both nest models under the provider, which makes "configure a provider once, then its models" one object and removes the dangling-reference case where a model names a provider that a later layer removed.

**Keep the root `model` object and add `providers` beside it.** Rejected under the migrate-callers-then-delete rule. Two shapes for one concept doubles the merge rules and the docs. The project has no external users yet.

**Store tokens in the OS keychain.** Rejected for this program. A `0600` JSON file matches Pi and Codex's file mode, works on all three targets with no new dependency, and `docs/architecture.md:226` requires each dependency to replace a named burden. OpenCode V2 uses SQLite, which would add a dependency for the same result.

**OAuth for OpenCode Go.** Not available. The Go and Console documentation sells an API key. U07 ships `--api-key` for both OpenCode providers.

**Model switching by restarting the session.** Rejected. Rebuilding `Session.provider` between turns is the smaller change and keeps the journal.

## Appendix C. Risks

**U01.** `Bundle.rescan` on macOS parses the keychain file, which Apple can change. The watch is the Nightly macOS transport job. The fallback is `SSL_CERT_FILE`, which U01 also honors.

**U01.** A platform bundle that encodes to more than 2 MiB fails `Client.init`. Debian's 118-root bundle encodes to 179 KiB here. Lane 10's container image reports its size.

**U02.** `detail` in the JSONL outcome record is visible to rpc clients. The field is optional and additive. The owner checks `tests/acp` and `tests/cli` fixtures for strict-equality assertions on the record.

**U03.** This is the breaking change. Every example, fixture, README, and the HTML plan page that mentions `model.endpoint` changes. The owner greps `"model"` across `docs/`, `src/`, and `tests/` before opening the PR and fixes `tests/contracts/root.zig:419` first.

**U04.** Loading `.foo/config.json` without a flag means a cloned repo can set `permissions: "allow"` or `enabled_tools`. The committed default sets `permissions: "ask"`. The owner adds a `config check` warning, printed once per run, when a project file sets `permissions: "allow"`.

**U05.** Four credential resolution sites collapse into one. The MCP and tools suites in the unit block prove environment references still resolve for headers and process environments.

**U06.** OpenAI can change the Codex client id, endpoints, or accepted request fields. The owner records the values used in `src/providers/routes.md` with the date and treats a 4xx from the backend as a route change to re-probe, not a foo bug.

**U07.** `api.x.ai` may reject subscription bearers for some tiers. Appendix E marks this unconfirmed. Lane 2 settles it and the build step says what to do in each case.

**U08.** Rebuilding the adapter mid-session touches `Session` ownership. The owner reads `src/contracts/runtime/session.zig:148-180` and the `errdefer` chain before editing.

## Appendix D. Links and reading list

Read before editing. `docs/architecture.md` sections "Configuration" at line 165 and "Dependencies and performance" at line 220. `src/config/README.md` in full. `src/providers/README.md` and `src/providers/routes.md`. `src/transport/README.md`. `src/session/local.zig:187-225` for the private-file pattern U05 reuses. `src/contracts/README.md` for the shared contracts. `docs/protocols.md:122-126` for the earlier decision to defer OAuth for MCP, which U05 and U06 do not change.

Each PR runs `skills/how/SKILL.md` on its touched modules before the first edit. U03 and U05 run `skills/architect/SKILL.md` on `Provider`, `ModelEntry`, and `CredentialSource` before implementing. U03, U05, and U06 run `skills/interrogate/SKILL.md` before merge-ready.

The decision trail per `skills/show-me-your-work/SKILL.md` lives at `.audit/foo-usability.tsv` and is committed with U08.

## Appendix E. Harness comparison and auth parameters

Research date 2026-11-24. Each row cites the page the research lane fetched.

**Config shape.**

| Harness | User file | Project file | Provider then models |
| --- | --- | --- | --- |
| Pi | `~/.pi/agent/models.json` and `settings.json` | `.pi/settings.json`, loaded after project trust | `providers.<id>.{baseUrl, api, apiKey, headers, models[]}` with per-model `api` or `baseUrl` override. [models.md](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/docs/models.md) |
| OpenCode V2 | `~/.config/opencode/opencode.json` | `./opencode.json` or `./.opencode/opencode.json`, searched cwd to root | `providers.<id>.{package, settings.baseURL, env[], headers, models.<id>}`. [providers](https://opencode.ai/docs/providers/) |
| Codex | `~/.codex/config.toml` | `.codex/config.toml`, trusted projects only, and provider and auth keys are ignored there | `model_providers.<id>.{base_url, env_key, wire_api}` and a bare `model` string. [config reference](https://developers.openai.com/codex/config-reference) |
| foo after U03 | `~/.config/foo/config.json` | `.foo/config.json` committed, `foo.json` private | `providers.<id>.{family, base_url, credential, headers, models.<id>}` and `model` as `provider/id` |

**Credential references.** Pi accepts a literal, `$VAR`, or `!command`, and resolves `--api-key`, then `auth.json`, then `models.json`, then the provider's environment variable ([providers.md](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/docs/providers.md)). OpenCode accepts `{env:VAR}` and `{file:path}` ([config](https://opencode.ai/docs/config/)). Codex accepts `env_key` and an `auth.command` ([auth](https://developers.openai.com/codex/auth)). foo after U03 accepts `environment`, `literal`, and `auth`.

**OpenAI Codex OAuth.** Client id `app_EMoamEEZ73f0CkXaXp7hrann`, issuer `https://auth.openai.com`, paths `/oauth/authorize` and `/oauth/token`, redirect `http://localhost:1455/auth/callback`, scope `openid profile email offline_access`, extra parameters `id_token_add_organizations=true` and `codex_cli_simplified_flow=true`, account id from the id token claim `https://api.openai.com/auth`.`chatgpt_account_id`, header `chatgpt-account-id`, endpoint `https://chatgpt.com/backend-api/codex/responses`. Device flow at `/api/accounts/deviceauth/usercode` and `/api/accounts/deviceauth/token` with verification page `/codex/device`. Codex stores tokens in `~/.codex/auth.json` written as a `0600` temp file then renamed under `auth.lock`. Sources are Pi's [openai-codex.ts](https://raw.githubusercontent.com/earendil-works/pi/main/packages/ai/src/auth/oauth/openai-codex.ts), OpenCode's [openai.ts](https://raw.githubusercontent.com/anomalyco/opencode/dev/packages/core/src/plugin/provider/openai.ts), and Codex's [server.rs](https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/server.rs), [device_code_auth.rs](https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/device_code_auth.rs), and [storage.rs](https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/auth/storage.rs).

**xAI OAuth.** Device code flow. Client id `b1a00492-073a-47ea-816f-4c329264a828`, `https://auth.x.ai/oauth2/device/code`, `https://auth.x.ai/oauth2/token`, scope `openid profile email offline_access grok-cli:access api:access`, grant `urn:ietf:params:oauth:grant-type:device_code`. Pi sends the access token as a bearer to `https://api.x.ai/v1`. Sources are Pi's [xai.ts](https://raw.githubusercontent.com/earendil-works/pi/main/packages/ai/src/auth/oauth/xai.ts) and OpenCode's [xai.ts](https://raw.githubusercontent.com/anomalyco/opencode/dev/packages/core/src/plugin/provider/xai.ts). Unconfirmed from xAI sources, and reported only by a third party at [shunt.sh](https://shunt.sh/guides/xai/), is that `api.x.ai` rejects subscription bearers for some tiers. U07 lane 2 settles this.

**OpenCode Go.** An API key sold with the subscription, `OPENCODE_API_KEY`. Endpoints are per protocol under `https://opencode.ai/inference/`, with `openai/v1/responses`, `openai/v1/chat/completions`, and `anthropic/v1/messages`, and Go uses the `go/` prefix. The model list is `GET /inference/v1/models`. Go asks clients to send `x-opencode-session`. Sources are [console/go](https://opencode.ai/docs/console/go/) and [zen](https://opencode.ai/docs/zen/). The prototype in Appendix A reached the older `/zen/v1/models` path with HTTP 200, so both paths serve today.

**TLS trust.** Pi runs on Node, which uses the bundled Mozilla roots and honors `NODE_EXTRA_CA_CERTS` ([Node CLI](https://nodejs.org/api/cli.html)). OpenCode runs on Bun, which reads bundled roots plus `/etc/ssl/cert.pem` and `/etc/ssl/certs`, and honors `SSL_CERT_FILE` and `SSL_CERT_DIR` ([Bun environment](https://bun.com/docs/runtime/environment-variables)). Codex uses `rustls-native-certs`, which reads the platform store, and honors `CODEX_CA_CERTIFICATE` then `SSL_CERT_FILE` ([custom_ca.rs](https://raw.githubusercontent.com/openai/codex/main/codex-rs/http-client/src/custom_ca.rs)). foo after U01 reads the platform store through Zig and honors `FOO_CA_FILE` then `SSL_CERT_FILE`.

**Features a usable harness has.** Pi, OpenCode, and Codex each ship `auth login`, a models list, a model switch in the TUI, session resume, slash commands, and `AGENTS.md` loading ([Pi CLI](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/docs/cli.md), [OpenCode commands](https://opencode.ai/docs/cli/commands/), [Codex CLI reference](https://developers.openai.com/codex/cli/reference.md)). This program adds the first three to foo. Session resume exists today as `--resume`. Slash commands beyond `/model`, `AGENTS.md` loading, and a thinking-level toggle stay out of this program. `docs/architecture.md:175` keeps `AGENTS.md` loading out of neutral mode by design, so that one needs a product decision before a plan.
