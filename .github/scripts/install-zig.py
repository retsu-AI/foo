import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

root = Path(__file__).resolve().parents[2]
manifest = json.loads((root / ".github/zig.json").read_text())
if manifest["version"] != (root / ".zig-version").read_text().strip():
    raise SystemExit("Zig version files disagree")
target = {
    ("Linux", "x86_64"): "x86_64-linux",
    ("Darwin", "arm64"): "aarch64-macos",
    ("Windows", "AMD64"): "x86_64-windows",
}[(platform.system(), platform.machine())]
entry = manifest["targets"][target]
with tempfile.TemporaryDirectory() as tmp:
    archive = Path(tmp) / entry["url"].rsplit("/", 1)[1]
    urllib.request.urlretrieve(entry["url"], archive)
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != entry["sha256"]:
        raise SystemExit("Zig archive checksum mismatch")
    destination = Path(os.environ["RUNNER_TEMP"]) / "foo-zig"
    destination.mkdir(exist_ok=True)
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as source:
            source.extractall(destination)
    else:
        with tarfile.open(archive) as source:
            source.extractall(destination, filter="data")
binary_name = "zig.exe" if target.endswith("windows") else "zig"
binary = next(destination.glob(f"*/{binary_name}"))
version = subprocess.check_output([str(binary), "version"], text=True).strip()
if version != manifest["version"]:
    raise SystemExit(f"Unexpected Zig version: {version}")
with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as output:
    output.write(str(binary.parent) + "\n")
print(f"Installed Zig {version} for native {target}")
