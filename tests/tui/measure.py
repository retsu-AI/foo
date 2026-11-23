"""Measure scripted editor feedback and transcript output on the native terminal."""

import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "platform-terminal"))
from pty_driver import TerminalPeer


def measure(binary):
    peer = TerminalPeer([binary, "--no-color"], columns=80, rows=18)
    try:
        peer.expect("Ready")
        samples_ms = []
        for index in range(20):
            token = f"k{index:02d}"
            start = peer.mark()
            before = time.perf_counter_ns()
            peer.send(token)
            peer.expect(token, start=start)
            samples_ms.append((time.perf_counter_ns() - before) / 1_000_000)
            peer.send(b"\x7f" * len(token))

        start = peer.mark()
        peer.send("long\r")
        peer.expect("line 199", start=start)
        end = peer.expect("Completed", start=start) + len("Completed")
        peer.send(b"\x04")
        if (code := peer.wait()) != 0:
            raise RuntimeError(f"probe exited with {code}")
    finally:
        peer.close()

    return {
        "system": platform.system(),
        "kernel": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "logical_cpus": os.cpu_count(),
        "pty_size_columns_rows": [80, 18],
        "sample_count": len(samples_ms),
        "samples_ms": [round(value, 3) for value in samples_ms],
        "median_ms": round(statistics.median(samples_ms), 3),
        "range_ms": [round(value, 3) for value in (min(samples_ms), max(samples_ms))],
        "long_transcript_render_bytes": end - start,
        "errors": 0,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = measure(args.binary.resolve())
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
