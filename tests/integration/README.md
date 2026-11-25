# Native integration and candidate archives

Build and run foo from a development shell with the pinned transport profile.

```sh
nix develop .#ci -c zig build
nix develop .#ci -c zig build run -- --help
nix develop .#ci -c zig build test -Dmodule=integration
nix develop .#ci -c zig build check -Doptimize=ReleaseSafe
```

The integration suite launches the installed executable. It uses real pipes,
a native PTY or ConPTY, the native process guardian on POSIX, and local
provider, MCP, and ACP fixtures. It checks the provider requests, tool results,
journal replay, command exit status, terminal restoration, and stdout framing.

Use `--config PATH` to load a profile. `FOO_CONFIG_JSON` adds an explicit
environment layer. HTTPS trusts the platform root store. To use other roots, set
`FOO_CA_FILE` or `SSL_CERT_FILE` to a PEM bundle under 2 MiB. `FOO_CA_FILE` wins.
Only configured tools are available to the model. ACP accepts editor MCP
descriptors that match a server explicitly configured on the agent. Client
file and terminal tools require the configured client backend and the
negotiated editor capability. ACP client writes use the editor's plain write
operation. Atomic edit and custom executable protocols require local backends.

## Retrieve MCP context

Choose one configured server and a resource, template, or prompt. The command
writes JSON with the server, item identity, MIME type, and payload encoding.
It performs the requested MCP operation without starting a model turn.

```sh
foo mcp list resource work --config profile.json
foo mcp get resource work fixture://sample --config profile.json
foo mcp get prompt work explain --arguments '{"subject":"a sample"}' --config profile.json
```

The `resource_template` kind accepts template arguments as a JSON object with
string values. Binary resource bytes use Base64. Prompt retrieval returns the
server-authored messages for inspection.

## Build a candidate

Use a clean checkout and the pinned Zig toolchain on Linux x86_64, macOS
arm64, or Windows x86_64. Build the shared libraries and notices with
`.github/scripts/build-transport.py`, then set `FOO_TRANSPORT_PREFIX` to
that prefix. Candidate builds use the architecture's baseline CPU features. Linux packaging requires `patchelf`. macOS packaging uses
`otool`, `install_name_tool`, and ad hoc `codesign` from Xcode.

```sh
zig build release -Doptimize=ReleaseSafe -Dcpu=baseline
```

Find the native archive, SHA-256 file, and manifest in `zig-out/candidate/`.
The archive includes foo, its POSIX guardian where needed, curl, c-ares,
OpenSSL, and dependency notices including the Unicode data notice. The
optional QuickJS-NG Code Mode module is outside the baseline candidate.
The manifest records the commit, compiler, target, CPU, build host, dependency
pins, and SHA-256 of each payload file. The packaging step extracts the
archive into a fresh directory and reruns the integrated checks there with
the build prefix removed from the loader environment.

The [native workflow](../../.github/workflows/nightly.yml) packages the
declared targets on GitHub-hosted runners. Dispatch it with `candidate=true`
to retain the archives for F13. Live interoperability, performance, manual
acceptance, and publication follow the [release qualification plan](../../docs/testing.md#task-level-acceptance-and-release).
