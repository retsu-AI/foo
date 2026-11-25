"""Run acceptance and measurements against a verified native archive."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PIN = Path(__file__).with_name("candidate.json")
HOST_TARGETS = {
    ("Linux", "x86_64"): "x86_64-linux",
    ("Darwin", "arm64"): "aarch64-macos",
    ("Windows", "amd64"): "x86_64-windows",
}
DRIVERS = {
    "offline": "tests/acceptance/offline.py",
    "live": "tests/acceptance/live.py",
    "bench": "benchmarks/run.py",
}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def unpack(archives, destination, pin, target):
    expected = pin["targets"][target]
    archive = archives / expected["archive"]
    actual = digest(archive)
    if actual != expected["sha256"]:
        raise ValueError(f"{archive.name} SHA-256 mismatch")
    if archive.with_name(archive.name + ".sha256").read_text().split() != [actual, archive.name]:
        raise ValueError("Detached archive checksum disagrees with the candidate pin")
    detached = archive.with_name(archive.name + ".manifest.json").read_bytes()
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as payload:
            payload.extractall(destination)
    else:
        with tarfile.open(archive) as payload:
            payload.extractall(destination, filter="data")
    embedded = destination / "manifest.json"
    if embedded.read_bytes() != detached:
        raise ValueError("Embedded manifest differs from the detached manifest")
    manifest = json.loads(detached)
    for key in ("commit", "zig_version", "optimize"):
        if manifest[key] != pin[key]:
            raise ValueError(f"Candidate {key} differs from the pin")
    if manifest["target"] != target:
        raise ValueError("Candidate target differs from the native host")
    if manifest["cpu"] != expected["cpu"]:
        raise ValueError("Candidate CPU model differs from the pin")
    files = {p.relative_to(destination).as_posix(): p for p in destination.rglob("*") if p.is_file() and p != embedded}
    if files.keys() != manifest["files"].keys():
        raise ValueError("Extracted file list differs from the manifest")
    for name, path in files.items():
        if path.is_symlink() or digest(path) != manifest["files"][name]:
            raise ValueError(f"Candidate payload mismatch for {name}")
    binary = "foo.exe" if target == "x86_64-windows" else "foo"
    return files[binary], {"archive": archive.name, "sha256": actual, "manifest": manifest}


def candidate_env(lane, directory):
    environment = os.environ.copy()
    prefix = environment.pop("FOO_TRANSPORT_PREFIX", None)
    if prefix:
        root = Path(prefix).resolve()
        environment["PATH"] = os.pathsep.join(
            entry for entry in environment.get("PATH", "").split(os.pathsep)
            if entry and not Path(entry).resolve().is_relative_to(root)
        )
    for name in tuple(environment):
        if name.startswith("DYLD_") or name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "FOO_CONFIG_JSON"):
            environment.pop(name)
    if lane != "live":
        settings = directory / "empty-user-config"
        settings.mkdir()
        environment["FOO_CONFIG_DIR"] = str(settings)
        environment["XDG_CONFIG_HOME"] = str(settings)
        environment["APPDATA"] = str(settings)
        environment.pop("FOO_CA_FILE", None)
    return environment


def qualification_source():
    paths = ["tests/acceptance", "tests/integration", "tests/acp", "tests/cli", "tests/platform-terminal", "tests/tui", "benchmarks"]
    return {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "dirty_fixtures": bool(subprocess.check_output(["git", "status", "--porcelain", "--", *paths], cwd=ROOT)),
    }


def run(args, pin, target):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    results = output / f"{args.lane}.json"
    identity = output / f"{args.lane}-identity.json"
    results.unlink(missing_ok=True)
    identity.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="foo-qualify-") as directory:
        root = Path(directory)
        binary, candidate = unpack(args.archives.resolve(), root / "archive", pin, target)
        command = [sys.executable, ROOT / DRIVERS[args.lane], binary, "--output", results]
        if args.lane == "bench":
            command.extend(["--samples", str(args.samples)])
        if args.lane == "live" and args.profiles:
            command.extend(["--profiles", args.profiles.resolve()])
        metadata = {
            "lane": args.lane,
            "candidate": candidate,
            "fixtures": qualification_source(),
            "host": platform.platform(),
            "python": platform.python_version(),
        }
        returncode = subprocess.run(command, cwd=ROOT, env=candidate_env(args.lane, root)).returncode
    identity.write_text(json.dumps({**metadata, "returncode": returncode}, indent=2) + "\n", encoding="utf-8")
    if returncode:
        return returncode
    if not isinstance(json.loads(results.read_text(encoding="utf-8")), dict):
        raise ValueError(f"{results.name} must contain an object")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    lanes = parser.add_subparsers(dest="lane", required=True)
    for lane in DRIVERS:
        command = lanes.add_parser(lane)
        command.add_argument("archives", type=Path, help="directory with archive, checksum and manifest")
        command.add_argument("--output", type=Path, required=True)
        if lane == "bench":
            command.add_argument("--samples", type=int, default=5)
        if lane == "live":
            command.add_argument("--profiles", type=Path)
    download = lanes.add_parser("download")
    download.add_argument("archives", type=Path)
    args = parser.parse_args()

    try:
        key = (platform.system(), platform.machine().lower())
        if key not in HOST_TARGETS:
            raise ValueError(f"No pinned native candidate for {key[0]} {key[1]}")
        target = HOST_TARGETS[key]
        pin = json.loads(PIN.read_text(encoding="utf-8"))
        if args.lane == "download":
            runner = pin["targets"][target]["runner"]
            return subprocess.run([
                "gh", "run", "download", str(pin["run"]), "--repo", pin["repository"],
                "--name", f"candidate-{runner}-{pin['commit']}", "--dir", args.archives,
            ]).returncode
        return run(args, pin, target)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"qualification: {error}\n")


if __name__ == "__main__":
    sys.exit(main())
