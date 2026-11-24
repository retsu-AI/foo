"""Build and smoke-test a relocatable, unpublished native candidate archive."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
TARGETS = {
    ("Linux", "x86_64"): ("x86_64-linux", (
        "libcurl.so.4", "libcares.so.2", "libssl.so.3", "libcrypto.so.3",
    )),
    ("Darwin", "arm64"): ("aarch64-macos", (
        "libcurl.4.dylib", "libcares.2.dylib", "libssl.3.dylib", "libcrypto.3.dylib",
    )),
    ("Windows", "AMD64"): ("x86_64-windows", (
        "libcurl.dll", "cares.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll",
    )),
}
LICENSES = {"curl": "curl", "c-ares": "MIT", "openssl": "Apache-2.0"}


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def run(*args):
    subprocess.run(args, check=True)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def mac_libraries(path):
    return [
        line.strip().split(" (compatibility version ", 1)[0]
        for line in output("otool", "-L", path).splitlines()[1:]
    ]


def relocate(files, libraries, system):
    installed = {path.name for path in libraries}
    if system == "Windows":
        return
    for path in files:
        if system == "Linux":
            run("patchelf", "--set-rpath", "$ORIGIN", path)
            for dependency in output("patchelf", "--print-needed", path).splitlines():
                name = Path(dependency).name
                if name in installed and name != dependency:
                    run("patchelf", "--replace-needed", dependency, name, path)
                elif "/" in dependency:
                    raise ValueError(f"Unexpected absolute ELF dependency {dependency}")
        else:
            if path.name in installed:
                run("install_name_tool", "-id", f"@loader_path/{path.name}", path)
            for dependency in mac_libraries(path):
                name = Path(dependency).name
                if name in installed and dependency != f"@loader_path/{name}":
                    run("install_name_tool", "-change", dependency, f"@loader_path/{name}", path)
                elif name not in installed and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                    raise ValueError(f"Unexpected Mach-O dependency {dependency}")

            for path_line in output("otool", "-l", path).splitlines():
                entry = path_line.strip()
                if entry.startswith("path /") and " (offset " in entry:
                    run("install_name_tool", "-delete_rpath", entry[5:].split(" (offset ")[0], path)
            run("codesign", "--force", "--sign", "-", path)


def write_archive(source, archive):
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
            for path in sorted(source.rglob("*")):
                if path.is_file():
                    bundle.write(path, path.relative_to(source))
    else:
        with tarfile.open(archive, "w:gz") as bundle:
            for path in sorted(source.rglob("*")):
                if path.is_file():
                    bundle.add(path, path.relative_to(source))


def verify_archive(archive, destination, binary_name, prefix):
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(destination)
    else:
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter="data")
    manifest = json.loads((destination / "manifest.json").read_text(encoding="utf-8"))
    for name, expected in manifest["files"].items():
        if sha256(destination / name) != expected:
            raise ValueError(f"Archive file hash mismatch for {name}")
    env = {
        name: value for name, value in os.environ.items()
        if name.upper() not in {"LD_LIBRARY_PATH", "LD_PRELOAD", "FOO_TRANSPORT_PREFIX"}
        and not name.upper().startswith("DYLD_")
    }
    env["PATH"] = os.pathsep.join(
        entry for entry in env.get("PATH", "").split(os.pathsep)
        if entry and not Path(entry).resolve().is_relative_to(prefix)
    )
    subprocess.run(
        [os.sys.executable, ROOT / "tests/integration/check.py", destination / binary_name],
        cwd=destination, env=env, check=True,
    )


def package(binary, install_prefix, prefix, triple):
    system = platform.system()
    target, names = TARGETS[(system, platform.machine())]
    if triple != target and not triple.startswith(f"{target}-"):
        raise ValueError(f"Candidate target {triple} must match native host {target}")

    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=ROOT, check=True)
    commit = output("git", "rev-parse", "HEAD")
    compiler = output("zig", "version")
    pins = json.loads((ROOT / "nix/transport-sources.json").read_text(encoding="utf-8"))
    notices = prefix / "share/foo-transport"
    if json.loads((notices / "transport-sources.json").read_text(encoding="utf-8")) != pins:
        raise ValueError("Transport prefix was built with different pins")

    destination = install_prefix / "candidate"
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="foo-candidate-", dir=destination) as temp:
        work = Path(temp)
        stage = work / "bundle"
        stage.mkdir()
        shutil.copy2(binary, stage)
        programs = [stage / binary.name]
        if system != "Windows":
            guardian = "foo-process-guardian"
            shutil.copy2(binary.with_name(guardian), stage)
            programs.append(stage / guardian)

        libraries = []
        library_dir = prefix / ("bin" if system == "Windows" else "lib")
        for name in names:
            shutil.copy2(library_dir / name, stage / name)
            libraries.append(stage / name)
        relocate(programs + libraries, libraries, system)

        licenses = stage / "licenses"
        licenses.mkdir()
        for name in pins:
            shutil.copyfile(notices / f"{name}.txt", licenses / f"{name}.txt")
        shutil.copyfile(ROOT / "src/tui/UNICODE-LICENSE.txt", licenses / "unicode.txt")
        shutil.copyfile(ROOT / "README.md", stage / "README.md")

        manifest = {
            "commit": commit,
            "target": target,
            "zig_target": triple,
            "zig_version": compiler,
            "optimize": "ReleaseSafe",
            "build_host": platform.platform(),
            "dependencies": {
                **{name: {**pin, "license": LICENSES[name], "notice": f"licenses/{name}.txt"}
                   for name, pin in pins.items()},
                "unicode-data": {"notice": "licenses/unicode.txt"},
            },
            "files": {
                path.relative_to(stage).as_posix(): sha256(path)
                for path in sorted(stage.rglob("*")) if path.is_file()
            },
        }
        manifest_path = stage / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        suffix = ".zip" if system == "Windows" else ".tar.gz"
        archive = work / f"foo-{commit[:12]}-{target}{suffix}"
        write_archive(stage, archive)
        verify_archive(archive, work / "extracted folder", binary.name, prefix)
        checksum = work / f"{archive.name}.sha256"
        checksum.write_text(f"{sha256(archive)}  {archive.name}\n", encoding="ascii")
        final_manifest = archive.with_name(f"{archive.name}.manifest.json")
        shutil.copyfile(manifest_path, final_manifest)
        for path in (archive, checksum, final_manifest):
            path.replace(destination / path.name)
        print(f"Candidate {commit} {target} Zig {compiler}")
        print(checksum.name + ": " + (destination / checksum.name).read_text().strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("install_prefix", type=Path)
    parser.add_argument("transport_prefix", type=Path)
    parser.add_argument("zig_target")
    args = parser.parse_args()
    package(args.binary.resolve(), args.install_prefix.resolve(), args.transport_prefix.resolve(), args.zig_target)


if __name__ == "__main__":
    main()
