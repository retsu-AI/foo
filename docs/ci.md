# Continuous integration

The `Check` workflow runs on pull requests and pushes to `main`. Its Linux job checks Zig formatting, contracts, wire, core, providers, configuration, the toolchain installer, and generated documentation. These checks can run without the native transport libraries.

The `Nightly` workflow runs on pull requests that touch runtime, test, or build inputs. It also runs daily and accepts manual dispatch. Its native jobs build or restore hash-pinned curl, c-ares, and OpenSSL, then run the full deterministic suite in Debug and ReleaseSafe on Linux x86_64, macOS arm64, and Windows x86_64. Pull requests also package and test an extracted candidate on each host. The scheduled and manual workflows run Nix checks in a separate Linux job. [Native workflow](../.github/workflows/nightly.yml).

A manual run with the `candidate` input retains the candidate archives and manifests as GitHub Actions artifacts for 30 days. Use the workflow run's commit and manifest checksums to identify the inputs for acceptance. [Candidate guide](../tests/integration/README.md).

The focused native tools, ACP, and TUI workflows remain available for changes to those packages.

Zig downloads use the checksums in [the toolchain manifest](../.github/zig.json). The cache key includes the manifest, installer, runner OS, and architecture. The installer checks the cached manifest metadata and executable version before adding Zig to the path. Documentation checks pin Markdown in [their requirements file](../.github/docs-requirements.txt).

Jobs restore compiled Zig artifacts from a separate global cache keyed by OS, architecture, toolchain manifest, and commit. A matching toolchain prefix permits reuse across commits. Only successful pushes to `main` save this cache. Pull requests and nightly jobs only restore it. The project-local `.zig-cache` is not cached.

Deterministic checks need no hosted provider credentials. The [testing specification](testing.md) defines the remaining first-release acceptance, live interoperability, and performance checks.
