# F13 candidate qualification

**Release recommendation.** Hold publication until the approved live provider and MCP checks, manual ACP editor and terminal checks, and remaining performance evidence are available.

## Candidate identity

The candidate is `0f4534afa753193cf55a275d45d2855bb0e3186f`, built with Zig `0.17.1` in ReleaseSafe. Each archive declares the baseline CPU model for its target. The archive checks compare the pinned SHA-256, detached checksum, embedded and detached manifests, and hashes for every listed file before the candidate is executed. [Candidate archive run](https://github.com/retsu-AI/foo/actions/runs/45531957745) · [Machine-readable pin](candidate.json).

| Archive | Baseline CPU | Zig target | Archive SHA-256 |
| --- | --- | --- | --- |
| `foo-0f4534afa753-x86_64-linux.tar.gz` | `x86_64` | `x86_64-linux.7.0...7.0-gnu.2.39` | `29a47dd5c6fd91e55c712c0f94fd52909b187a40c27bca1d380cafa4e8245388` |
| `foo-0f4534afa753-aarch64-macos.tar.gz` | `apple_m1` | `aarch64-macos.15.8.2...15.8.2-none` | `22d7071eda14ab58d1d2619d94a0d80b8ef3069181df0de1af32b3aba05f74cc` |
| `foo-0f4534afa753-x86_64-windows.zip` | `x86_64` | `x86_64-windows.win10_cu...win10_cu-gnu` | `17b89f8d35ce53e20d42ed3990129e7b819de6ba156f4a319de384ea769c9833` |

The earlier F12 Linux archive required AVX512-FP16 and exited with SIGILL on a Ryzen 9 9950X. The exact replacement archive printed `foo 0.0.0-rc` on that host under the same `steam-run` FHS launcher. These binaries still have the OS and library requirements in their build manifests. [CPU baseline fix and reproduction](https://github.com/retsu-AI/foo/pull/17).

The earlier baseline archives passed a separate F13 run. U03 changed configuration to a provider catalog, so the fixtures were updated and all lanes against the new candidate were rerun where evidence was available. [Earlier baseline qualification](https://github.com/retsu-AI/foo/actions/runs/45531638723).

## Native results

The candidate build exercised Debug and ReleaseSafe checks and 18 extracted-archive integration cases per native target. The F13 matrix then ran the extracted archives against clean fixture commit `79fffc04fe241a9cb0f246ec4baaf8179518cd9a`. The report was added after the run. The archive and raw qualification artifacts expire on December 25, 2026 UTC. [Native qualification and raw artifacts](https://github.com/retsu-AI/foo/actions/runs/45533230917).

| Native runner | Offline acceptance | Benchmark workloads | Live and manual |
| --- | --- | --- | --- |
| Ubuntu 24.04 x86_64 | 15/15 pass | 7/7 pass, 20 samples each | Unavailable |
| macOS 15 arm64 | 15/15 pass | 7/7 pass, 20 samples each | Unavailable |
| Windows Server 2022 x86_64 | 15/15 pass | 7/7 pass, 20 samples each | Unavailable |

The offline cases exercise one-shot output from three provider codecs, exact repository changes and Git staging, failure and output bounds, interruption and resumption, MCP resources over both transports and revisions, ACP delegation and cancellation, native terminal startup, and redirected fallback. Provider and peer fixtures run on the loopback interface or a local subprocess.

## Measurements

Each cell gives the median and nearest-rank p95 over 20 valid trials. Time is in milliseconds unless labeled otherwise. Each runner used the same loopback fixture, limits, and workload. The raw reports include minimum, maximum, individual trials, fixture hashes, and available host CPU and OS metadata. Runner timing includes OS scheduling. The stream figure summarizes each trial's p95 over 32 incremental frames. Journal delta compares one persistent turn with the mean of two volatile turns. The volatile pair gives a measure of timing noise.

| Metric | Linux | macOS | Windows | Reference |
| --- | ---: | ---: | ---: | --- |
| Warm help startup | 1.44 / 1.50 | 7.75 / 16.97 | 7.05 / 7.29 | <20 ms |
| Warm version startup | 1.15 / 1.27 | 6.72 / 11.23 | 6.15 / 6.33 | <20 ms |
| Stream-to-JSONL per-trial p95 | 0.07 / 0.10 | 0.35 / 1.23 | 0.12 / 0.14 |  |
| Local 4 KiB read commit | 0.74 / 0.87 | 0.68 / 1.53 | 1.05 / 1.08 |  |
| Journal delta | 0.60 / 0.88 | 0.38 / 3.94 | 10.98 / 15.49 |  |
| Volatile A/A difference | 0.21 / 0.60 | 0.31 / 2.17 | 0.06 / 0.13 |  |
| Idle process memory (MiB) | 26.33 / 26.34 | 22.81 / 23.00 | 25.06 / 25.07 | <30 MiB |
| Process memory growth through turn 32 (MiB) | 0.78 / 0.78 | 1.48 / 1.72 | 0.73 / 0.75 |  |
| Journal size at turn 32 (KiB) | 108.25 / 108.25 | 108.25 / 108.25 | 108.25 / 108.25 |  |
| TUI first ready frame | 3.54 / 3.65 | 9.09 / 13.79 | 29.12 / 29.52 | <100 ms |
| TUI input echo | 24.66 / 24.88 | 27.61 / 30.39 | 15.59 / 16.06 |  |
| TUI frame delivered | 18.72 / 19.28 | 24.15 / 27.45 | 25.97 / 26.61 | <33 ms |
| TUI cancellation with output draining | 24.55 / 24.80 | 27.05 / 42.90 | 46.98 / 62.55 |  |
| TUI quit to process exit | 1.11 / 1.13 | 6.61 / 7.40 | 3.46 / 3.50 |  |

The measured warm startup, idle process memory, and terminal-frame results meet their initial targets on these runners. The macOS runner reported a one-minute load average of 47.51 at the start with three logical CPUs. Its journal delta median was 0.38 ms against 0.31 ms median A/A noise. The timings are observations from this run. A regression comparison requires matching hosts, workloads, and load.

The terminal driver measures output at a PTY or ConPTY. Cancellation holds the provider stream open while terminal output drains. Blocked-output cancellation latency and termination against a configured grace period are open benchmarks. Cold-cache startup, CPU time, allocations, idle wakeups, remote latency, and billed provider cost are unavailable. macOS reports current RSS and Windows reports working-set bytes. macOS peak RSS and Windows load average are unavailable. The session workload exercised 32 verified turns and measured journal growth within that fixture.

## Remaining evidence

- All four hosted provider routes are unavailable without an approved live profile and credentials from a capped project. The live runner made no service requests and recorded no service versions.
- Live MCP stdio and HTTP peers for both revisions are unavailable without the approved peer profiles and expected resource hashes.
- A real ACP editor transcript and operator-observed terminal checks across the target OSs remain open. The native subprocess and terminal evidence above covers the offline fixture behavior.

Follow the [candidate commands](README.md) to rerun the offline and benchmark lanes. The [live guide](live.md) describes the authorized profiles and editor evidence. If a pinned archive expires or candidate inputs change, verify the replacement archives and rerun the affected lanes before considering publication.
