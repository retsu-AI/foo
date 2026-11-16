# Nix development environment

The flake supplies development shells and environment checks for foo. It uses only the existing locked nixpkgs input. It does not package a foo executable before the harness exists.

| File | Concern |
| --- | --- |
| `default.nix` | Supported Nix systems and composition |
| `toolchain.nix` | Exact Zig and compatible ZLS versions, with assertions on upgrades |
| `tools.nix` | Workflow, Nix, documentation, and interactive tool groups |
| `shells.nix` | Development/CI shells and worktree-friendly cache defaults |
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
nix develop .#ci -c python docs/plan/build.py --check
```

The default shell includes Zig 0.17.1, ZLS 0.17.0, Git, ripgrep, jq, Nix formatting/lint tools, Python with Markdown, GitHub CLI, uv, and hyperfine. The CI shell omits editor and interactive tools. No provider credentials, network policy, terminal settings, or library search paths are changed.

Zig's global cache is shared across worktrees and defaults to `$XDG_CACHE_HOME/zig` or `$HOME/.cache/zig`. The local cache defaults to `.zig-cache` under the directory where the shell is entered. Explicit cache settings are preserved. Build products remain workspace-local.

The existing `.envrc` watches `nix/*.nix` and uses the default flake shell. Approve it with the normal `direnv allow` workflow when using direnv.

## Platforms and scope

Shells, formatter, and checks are declared for x86_64/aarch64 Linux and aarch64 macOS. The locked nixpkgs has dropped x86_64 macOS support; it is not advertised as a working Nix environment. Intel macOS would need a separately qualified package source/toolchain. Nix evaluation on another system is not native build/runtime qualification. Windows harness development and tests use the native Zig toolchain; a WSL Nix shell is a Linux environment and cannot qualify Windows console or process behavior.

`nix flake check` validates the environment only. ENG-1473 will add the harness build and contract tests. Native harness, MCP/ACP, terminal, process, and live-provider acceptance remain the work packages described in `docs/plan`.

Until the initial repository commit exists, Git-backed flakes omit untracked `nix/` files. Use `nix develop path:.`, `nix run path:.#formatter.x86_64-linux`, and `nix flake check path:. -L` to validate the working directory without staging unrelated files. Substitute `aarch64-linux` or `aarch64-darwin` for the formatter system when appropriate. After adding these files to the intended initial commit, the ordinary commands above work. `nix fmt` forwards positional arguments to the formatter; a positional `path:.` does not select a flake.

To upgrade the compiler, update the nixpkgs lock and explicit versions in `toolchain.nix` together, then rerun the checks on the declared native systems. Do not silently filter unavailable tools out of a shell: an unsupported package or compiler version must fail visibly.
