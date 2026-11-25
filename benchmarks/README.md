# Production benchmarks

Run on the candidate’s native OS with Python 3.12 or newer. Point the runner at the executable in the verified archive to include its compiler, target, build mode, and packaged library sizes in the report. Use a quiet host and retain the raw report alongside the archive manifest.

```sh
python benchmarks/run.py /path/to/extracted/foo --samples 20 --output benchmark.json
```

The runner warms `--help` and `--version` once each and takes five samples per case by default. It uses one production process at a time, loopback HTTP, a temporary workspace, and native terminal I/O. It exits nonzero if the binary fails a workload or produces an incorrect result. Each report retains verified samples and failures, nanosecond timings, byte counts, host identity and available load averages, fixture hashes, and resource limits. The candidate checksum is verified against its adjacent manifest when available.

| Case | Measurement and verification |
| --- | --- |
| Startup | Native subprocess launch through exit for each flag with expected stdout, empty stderr, and status zero. |
| Incremental stream | Loopback SSE frames sent at one-millisecond intervals through the observation of each JSONL delta. Verify all 32 deltas in order, final committed text, and the successful outcome. |
| Local tool | Loopback tool-call frame through observed commit of one built-in `read` against a 4 KiB file. Compare the committed and forwarded tool result byte for byte. |
| Journal | One journal-backed prompt and two volatile runs with identical input and a rotated run order. Report the signed difference from the mean of the two volatile runs and the absolute difference between those runs. Verify the complete journal with checksums, contiguous sequences, and successful outcomes. |
| Long session | One persistent RPC process answers 32 prompts with cumulative model context. After turns 1, 8, 16, and 32, wait 50 ms and sample process resident memory. Verify every reply, provider message count, and durable prompt. Report the first snapshot as idle RSS, final minus initial RSS, and journal size. |
| Terminal | Native Unix PTY or Windows pseudoconsole at 80 × 18. Observe the ready frame, editor input, a 128-line response, and visible cancellation of a stalled provider response. Verify prompt text, exit status, and Unix terminal restoration. |

The loopback measurements include kernel I/O and observer scheduling. The report gives the fixture’s request-read, parsing, and response-construction time separately. It contains no remote-provider latency or model-generation time. The terminal case observes bytes delivered by the PTY or pseudoconsole. Cancellation uses a stalled network response with terminal output draining. The journal comparison includes any extra journal-path work between RPC acceptance and result, including storage scheduling.

Linux memory comes from `/proc` RSS and high-water mark, macOS uses `ps` RSS, and Windows uses current and peak working set. These are process snapshots and exclude child processes. Windows has no load average in this driver. Cold-cache startup, macOS peak RSS, CPU time, allocations, idle wakeups, and cancellation latency with a blocked output consumer remain unmeasured.

The p95 values use the nearest-rank definition and equal the maximum when there are five samples. The [engineering targets](../docs/testing.md#performance-methodology) are recorded for reference. Before comparing builds, match OS, machine, toolchain, build mode, sample counts, fixtures, and load, then repeat runs against the same binary to estimate noise.
