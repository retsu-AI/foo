# Nix development environment

The flake supplies development shells and environment checks for foo. It uses only the existing locked nixpkgs input. It does not package a foo executable before the harness exists.

| File | Concern |
| --- | --- |
| `default.nix` | Supported Nix systems and composition |
| `toolchain.nix` | Exact Zig and compatible ZLS versions, with assertions on upgrades |
| `tools.nix` | Workflow, Nix, documentation, and interactive tool groups |
| `shells.nix` | Development/CI shells and worktree-friendly cache defaults |
| `transport.nix` | Curl with OpenSSL and c-ares. foo supplies the trust roots |
| `transport-sources.json` | Source versions and checksums shared by Nix and native CI |
| `formatter.nix` | Formatting only root and `nix/**` Nix sources |
| `checks.nix` | Formatting, lint, compiler smoke, and Markdown tooling checks |
| `tests/toolchain.zig` | Small environment smoke fixture, independent of future harness tests |

## Commands

```sh
nix develop
nix develop .#ci -c zig version
nix fmt
nix flake check -L
nix flake check --no-build --all-systems
nix develop .#ci -c zig build check
nix develop .#ci -c zig build test -Dmodule=transport
nix develop .#ci -c python docs/plan/build.py --check
```

The default shell includes Zig 0.17.1, ZLS 0.17.0, Git, ripgrep, jq, Nix formatting/lint tools, Python with Markdown, Node.js, Bun, GitHub CLI, uv, and hyperfine. Node.js and Bun support the bundled [pstack scripts](../docs/pstack.md). The CI shell omits editor and interactive tools. Both shells set `FOO_TRANSPORT_PREFIX` to the focused curl profile. Zig uses that prefix to translate the headers and link the library when the transport profile is present.

Zig's global cache is shared across worktrees and defaults to `$XDG_CACHE_HOME/zig` or `$HOME/.cache/zig`. The local cache defaults to `.zig-cache` under the directory where the shell is entered. Explicit cache settings are preserved. Build products remain workspace-local.

The existing `.envrc` watches the Nix definitions and uses the default flake shell. Approve it with the normal `direnv allow` workflow when using direnv.

## Platforms and scope

Shells, formatter, and checks are declared for x86_64/aarch64 Linux and aarch64 macOS. The locked nixpkgs has dropped x86_64 macOS support; it is not advertised as a working Nix environment. Intel macOS would need a separately qualified package source/toolchain. Nix evaluation on another system is not native build/runtime qualification. Windows harness development and tests use the native Zig toolchain; a WSL Nix shell is a Linux environment and cannot qualify Windows console or process behavior.

`nix flake check` validates the environment. `zig build check` compiles the executable and runs the contract tests and transport loopback fixtures. `zig build check-bootstrap` runs the bootstrap checks without needing a transport prefix. The engine, providers, MCP, ACP, and TUI remain planned in [the implementation plan](../docs/plan/README.md).

On a native host outside Nix, build the focused profile with `python .github/scripts/build-transport.py <prefix>`. Use Python 3.12 or newer, Git, CMake, Ninja, Perl, and native C build tools. On Windows, run the command in an x64 Visual Studio developer shell with NASM on the path. Set `FOO_TRANSPORT_PREFIX` to the resulting path or pass `-Dtransport-prefix=<prefix>` to Zig. To run an installed Windows executable linked to this profile directly, add the prefix's `bin` directory to `PATH`.

The flake and `nix/` files are tracked, so the commands above work from a clean checkout. Git-backed flakes omit newly added untracked files. To check such files before staging them, use `nix develop path:.`, `nix run path:.#formatter.x86_64-linux`, or `nix flake check path:. -L`. Substitute the formatter's system on other hosts. `nix fmt` forwards positional arguments to the formatter; a positional `path:.` does not select a flake.

To upgrade the compiler, update the nixpkgs lock and explicit versions in `toolchain.nix` together, then rerun the checks on the declared native systems. Do not silently filter unavailable tools out of a shell: an unsupported package or compiler version must fail visibly.
