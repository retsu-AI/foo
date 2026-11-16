# Continuous integration

Pull requests and pushes to `main` run one Linux job named `Fast checks` in the `Check` workflow. It checks Zig formatting, executable compilation, contract tests, bootstrap command behavior, toolchain cache behavior, and the generated documentation and its local links. Every pull request runs the same check, including documentation-only changes. Superseded runs are cancelled. The five-minute timeout is a budget, not a measured completion time.

The `Nightly` workflow runs daily at 09:23 UTC and supports manual dispatch. Its native jobs run the implemented checks and bootstrap behavior in Debug and ReleaseSafe on Linux x86_64, macOS arm64, and Windows x86_64. A separate Linux job checks the Nix flake and documentation through the development shell. All jobs use public GitHub-hosted runners.

Branch protection can require `Fast checks`. Nightly checks stay outside the pull-request merge gate. Workflow configuration alone does not establish a successful hosted run or native qualification.

Zig downloads use the checksums in [the toolchain manifest](../.github/zig.json). The cache key includes the manifest, installer, runner OS, and architecture. The installer checks the cached manifest metadata and executable version before adding Zig to the path. Documentation checks pin Markdown in [their requirements file](../.github/docs-requirements.txt).

Jobs restore compiled Zig artifacts from a separate global cache keyed by OS, architecture, toolchain manifest, and commit. A matching toolchain prefix permits reuse across commits. Only successful pushes to `main` save this cache. Pull requests and nightly jobs only restore it. The project-local `.zig-cache` is not cached.

The workflows run implemented suites only. Missing modules, acceptance, live acceptance, benchmarks, and release remain explicitly unavailable. The checks need no provider credentials and do not qualify planned runtime behavior. See [the testing specification](testing.md) for first-release requirements.
