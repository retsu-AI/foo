"""Build the terminal and TUI probes and drive the platform's native terminal."""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def build(binary, mode, source, dependencies, modules):
    arguments = ["zig", "build-exe", f"-femit-bin={binary}"]
    if os.name != "nt":
        arguments.append("-lc")
    arguments += ["-O", mode]
    for dependency in dependencies:
        arguments += ["--dep", dependency]
    arguments += [f"-Mroot={source}"]
    for name, path, deps in modules:
        arguments += ["-O", mode]
        for dependency in deps:
            arguments += ["--dep", dependency]
        arguments += [f"-M{name}={path}"]
    subprocess.run(arguments, cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--optimize", choices=("Debug", "ReleaseSafe"), action="append",
        help="build only the specified optimization mode",
    )
    parser.add_argument("--artifacts", type=Path, help="save captured terminal streams")
    parser.add_argument("--measure", action="store_true", help="measure scripted input and rendering")
    args = parser.parse_args()
    if args.measure and not args.artifacts:
        parser.error("--measure requires --artifacts")
    if args.artifacts:
        args.artifacts = args.artifacts.resolve()
        args.artifacts.mkdir(parents=True, exist_ok=True)

    terminal = ("terminal", "src/platform/terminal/root.zig", ())
    modules = [
        ("foo", "src/lib.zig", ()),
        ("builtins", "src/builtins/root.zig", ("foo",)),
        ("configuration", "src/config/root.zig", ("foo", "builtins")),
        terminal,
        ("core", "src/core/root.zig", ("foo",)),
        ("tui", "src/tui/root.zig", ("foo", "configuration", "terminal")),
    ]
    suffix = ".exe" if os.name == "nt" else ""
    with tempfile.TemporaryDirectory(prefix="foo-tui-") as directory:
        for mode in args.optimize or ("Debug", "ReleaseSafe"):
            print(f"{mode} on {platform.system()} {platform.release()} {platform.machine()}", flush=True)
            native = Path(directory) / f"terminal-probe-{mode}{suffix}"
            tui = Path(directory) / f"tui-probe-{mode}{suffix}"
            build(native, mode, "tests/platform-terminal/probe.zig", ("terminal",), [terminal])
            build(tui, mode, "tests/tui/probe.zig", ("foo", "tui", "core"), modules)
            command = [sys.executable, str(ROOT / "tests/tui/test_terminal.py"), str(native), str(tui)]
            if args.artifacts:
                command += ["--artifacts", str(args.artifacts / mode)]
            subprocess.run(command, cwd=ROOT, check=True)
            if args.measure:
                subprocess.run(
                    [sys.executable, str(ROOT / "tests/tui/measure.py"), str(tui),
                     str(args.artifacts / mode / "measurements.json")],
                    cwd=ROOT, check=True,
                )


if __name__ == "__main__":
    main()
