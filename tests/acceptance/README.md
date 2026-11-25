# Qualify a native candidate

The [candidate pin](candidate.json) identifies one ReleaseSafe archive per native target. The runner matches the host to a target, verifies the downloaded archive and detached manifest, and checks every extracted file before starting foo. Each lane writes an identity file with the archive hash, manifest, fixture revision, and measurement host.

The [F13 qualification report](qualification.md) records the measured results and open release gates for this pin.

## Run the corpus and benchmarks

Use the pinned compiler and Python 3.12 or newer. Download the archive, checksum, and manifest for the current host.

```sh
nix develop .#ci -c python tests/acceptance/qualify.py download /tmp/foo-candidate
nix develop .#ci -c zig build acceptance -- /tmp/foo-candidate --output /tmp/foo-results
nix develop .#ci -c zig build bench -- /tmp/foo-candidate --output /tmp/foo-results --samples 20
```

On NixOS, the Ubuntu archive needs a glibc FHS loader. With `steam-run` installed, run the Zig targets inside it.

```sh
nix develop .#ci -c steam-run zig build acceptance -- /tmp/foo-candidate --output /tmp/foo-results
```

On GitHub, dispatch the [Nightly workflow](../../.github/workflows/nightly.yml) with `qualification=true` to run the native matrix against the pinned archives. The workflow retains the raw results and build identities.

The offline corpus uses a scripted loopback provider, real repository and journal artifacts, native subprocesses, and the production CLI, RPC, TUI, MCP, and ACP entrypoints. The provider script supplies actions so the tests can judge the exact repository effects independently. The [benchmark methods](../../benchmarks/README.md) identify what each case times and which counters the host supplies.

## Run approved live checks

Use the [live qualification guide](live.md) to prepare the endpoint allowlist, credential references, request limits, spend cap, and editor evidence.

```sh
nix develop .#ci -c zig build acceptance-live -- /tmp/foo-candidate --profiles /path/to/approved-profiles.json --output /tmp/foo-results
```

The live lane exits nonzero when required evidence is absent or fails. Keep the raw results and identity files with the candidate. Reissue the pin and renew affected evidence when the shipped code or build inputs change. Publication requires separate owner authorization.
