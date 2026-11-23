"""Run the F07 suite and kill a real writer at each effect boundary."""

import argparse
import contextlib
import pathlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]


def run(arguments):
    subprocess.run(arguments, cwd=ROOT, check=True, timeout=120)


def modules(root, optimize):
    test_dependencies = ["--dep", "core"] if root == "root.zig" else []
    return [
        *test_dependencies,
        "--dep", "foo", "--dep", "journal", "-O", optimize, f"-Mroot=tests/session/{root}",
        "-O", optimize, "-Mfoo=src/lib.zig",
        "--dep", "foo", "-O", optimize, "-Mjournal=src/session/root.zig",
        *(["--dep", "foo", "-O", optimize, "-Mcore=src/core/root.zig"] if test_dependencies else []),
    ]


def crash_check(probe, phase, directory, scope):
    with subprocess.Popen(
        [probe, "hold", phase, directory, scope], stdin=subprocess.PIPE
    ) as writer:
        try:
            deadline = time.monotonic() + 10
            while not (directory / "ready").exists():
                if writer.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f"Writer failed to reach {phase}")
                time.sleep(0.01)
            subprocess.run([probe, "busy", phase, directory, scope], check=True, timeout=10)
        finally:
            if writer.poll() is None:
                writer.kill()
    if writer.returncode == 0:
        raise RuntimeError(f"Writer exited normally at {phase}")

    marker = directory / "effect"

    def effect():
        with contextlib.suppress(FileNotFoundError):
            return marker.read_bytes()
        return None

    expected = (
        b"executed once\n"
        if phase in {"after_effect", "after_result", "after_finish"}
        else None
    )
    if effect() != expected:
        raise RuntimeError(f"Wrong external effect before {phase} recovery")
    subprocess.run([probe, "recover", phase, directory, scope], check=True, timeout=10)
    if effect() != expected:
        raise RuntimeError(f"Recovery changed the external effect at {phase}")
    print(f"PASS {scope} crash recovery and writer exclusion at {phase}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--optimize", choices=["Debug", "ReleaseSafe"], default="Debug")
    args = parser.parse_args()
    run(["zig", "test", *modules("root.zig", args.optimize)])
    with tempfile.TemporaryDirectory(prefix="foo-session-") as temp:
        directory = pathlib.Path(temp)
        probe = directory / "session-crash.exe"
        run(["zig", "build-exe", f"-femit-bin={probe}", *modules("crash.zig", args.optimize)])
        for scope in ("top", "nested"):
            for phase in ("before_intent", "after_intent", "after_effect", "after_result", "after_finish"):
                target = directory / f"{scope}-{phase}"
                target.mkdir(mode=0o700)
                crash_check(probe, phase, target, scope)


if __name__ == "__main__":
    main()
