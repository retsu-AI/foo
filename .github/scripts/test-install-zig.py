import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.request
import zipfile


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / ".github/scripts"
        scripts.mkdir(parents=True)
        self.script = scripts / "install-zig.py"
        shutil.copy(Path(__file__).with_name("install-zig.py"), self.script)
        (self.root / ".zig-version").write_text("0.17.1\n")
        self.runner = self.root / "runner"
        self.runner.mkdir()
        self.github_path = self.root / "path"
        self.env = {"RUNNER_TEMP": str(self.runner), "GITHUB_PATH": str(self.github_path)}

    def fixture(self, system, machine, target):
        binary = "zig.exe" if system == "Windows" else "zig"
        archive = self.root / ("zig.zip" if system == "Windows" else "zig.tar.xz")
        name = f"toolchain/{binary}"
        if system == "Windows":
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr(name, b"fixture")
        else:
            with tarfile.open(archive, "w:xz") as output:
                info = tarfile.TarInfo(name)
                info.size = len(b"fixture")
                info.mode = 0o755
                output.addfile(info, io.BytesIO(b"fixture"))
        entry = {"url": archive.as_uri(), "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
        manifest = {"version": "0.17.1", "targets": {target: entry}}
        (self.root / ".github/zig.json").write_text(json.dumps(manifest))
        self.system, self.machine = system, machine
        return self.runner / "foo-zig/toolchain" / binary

    def install(self, version="0.17.1"):
        with patch.dict(os.environ, self.env), \
             patch("platform.system", return_value=self.system), \
             patch("platform.machine", return_value=self.machine), \
             patch("subprocess.check_output", return_value=version + "\n") as check, \
             contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(self.script))
        return check

    def test_native_archives_and_warm_cache(self):
        for system, machine, target in [
            ("Linux", "x86_64", "x86_64-linux"),
            ("Darwin", "arm64", "aarch64-macos"),
            ("Windows", "AMD64", "x86_64-windows"),
        ]:
            with self.subTest(target=target):
                binary = self.fixture(system, machine, target)
                self.install().assert_called_once_with([str(binary), "version"], text=True)
                self.assertEqual(binary.read_bytes(), b"fixture")
                with patch("urllib.request.urlretrieve", side_effect=AssertionError("warm cache downloaded")):
                    self.install()
                self.assertEqual(self.github_path.read_text().splitlines()[-1], str(binary.parent))

    def test_stale_or_invalid_metadata_downloads_again(self):
        self.fixture("Linux", "x86_64", "x86_64-linux")
        self.install()
        metadata = self.runner / "foo-zig/install.json"
        for value in ['{"version": "stale"}', "invalid JSON"]:
            with self.subTest(metadata=value):
                metadata.write_text(value)
                with patch("urllib.request.urlretrieve", wraps=urllib.request.urlretrieve) as download:
                    self.install()
                self.assertEqual(download.call_count, 1)

    def test_archive_checksum_is_required(self):
        self.fixture("Linux", "x86_64", "x86_64-linux")
        (self.root / "zig.tar.xz").write_bytes(b"corrupt")
        with self.assertRaisesRegex(SystemExit, "checksum mismatch"):
            self.install()
        self.assertFalse(self.github_path.exists())

    def test_wrong_cached_version_is_rejected(self):
        self.fixture("Linux", "x86_64", "x86_64-linux")
        self.install()
        self.github_path.unlink()
        with self.assertRaisesRegex(SystemExit, "Unexpected Zig version"):
            self.install(version="0.0.0")
        self.assertFalse(self.github_path.exists())

    def test_cached_metadata_requires_an_executable(self):
        binary = self.fixture("Linux", "x86_64", "x86_64-linux")
        self.install()
        binary.unlink()
        self.github_path.unlink()
        with self.assertRaisesRegex(SystemExit, "Expected one installed Zig executable"):
            self.install()
        self.assertFalse(self.github_path.exists())


if __name__ == "__main__":
    unittest.main()
