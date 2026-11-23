"""Build the fake-runtime ACP agent and drive it over native subprocess pipes."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--optimize", choices=("Debug", "ReleaseSafe"), action="append")
    parser.add_argument("--trace", type=Path, help="write client and agent frames to this file")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="foo-acp-") as directory:
        suffix = ".exe" if os.name == "nt" else ""
        for mode in args.optimize or ("Debug", "ReleaseSafe"):
            binary = Path(directory) / f"acp-probe-{mode}{suffix}"
            print(f"ACP {mode} on {sys.platform}", flush=True)
            subprocess.run(
                [
                    "zig", "build-exe", f"-femit-bin={binary}",
                    "-O", mode, "--dep", "foo", "--dep", "acp",
                    "-Mroot=tests/acp/probe.zig",
                    "-O", mode, "-Mfoo=src/lib.zig",
                    "-O", mode, "--dep", "foo", "-Macp=src/acp/root.zig",
                ],
                check=True,
                cwd=ROOT,
            )
            test = [sys.executable, str(ROOT / "tests/acp/test_stdio.py"), str(binary)]
            if args.trace:
                test += ["--trace", str(args.trace.with_suffix(f".{mode}.jsonl"))]
            subprocess.run(test, check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
