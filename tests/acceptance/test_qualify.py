import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

from qualify import digest, unpack


class CandidateGate(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.directory = self.root / "payload"
        self.directory.mkdir()

    def archive(self, suffix, target, binary, extra=None):
        payload = b"test binary bytes"
        program = self.root / binary
        program.write_bytes(payload)
        manifest = {
            "commit": "a" * 40, "zig_version": "0.17.1", "optimize": "ReleaseSafe",
            "target": target, "cpu": "x86_64", "files": {binary: digest(program)},
        }
        detached = json.dumps(manifest).encode()
        archive = self.root / f"candidate{suffix}"
        files = {binary: payload, "manifest.json": detached}
        if extra:
            files[extra] = b"unlisted"
        if suffix == ".zip":
            with zipfile.ZipFile(archive, "w") as bundle:
                for name, content in files.items():
                    bundle.writestr(name, content)
        else:
            with tarfile.open(archive, "w:gz") as bundle:
                for name, content in files.items():
                    entry = tarfile.TarInfo(name)
                    entry.size = len(content)
                    entry.mode = 0o755
                    bundle.addfile(entry, io.BytesIO(content))
        archive.with_name(archive.name + ".manifest.json").write_bytes(detached)
        archive.with_name(archive.name + ".sha256").write_text(f"{digest(archive)}  {archive.name}\n")
        self.pin = {
            **manifest, "targets": {target: {"archive": archive.name, "sha256": digest(archive), "cpu": "x86_64"}},
        }
        return archive

    def test_accepts_zip_and_tar_with_matching_payload(self):
        for suffix, target, binary in (
            (".tar.gz", "x86_64-linux", "foo"),
            (".zip", "x86_64-windows", "foo.exe"),
        ):
            with self.subTest(target=target):
                archive = self.archive(suffix, target, binary)
                destination = self.directory / target
                path, result = unpack(self.root, destination, self.pin, target)
                self.assertEqual(path.read_bytes(), b"test binary bytes")
                self.assertEqual(result["sha256"], digest(archive))

    def test_rejects_untrusted_archive_before_extraction(self):
        target = "x86_64-linux"
        archive = self.archive(".tar.gz", target, "foo")
        with archive.open("ab") as stream:
            stream.write(b"unexpected data")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            unpack(self.root, self.directory, self.pin, target)
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_rejects_mismatched_detached_manifest(self):
        target = "x86_64-windows"
        archive = self.archive(".zip", target, "foo.exe")
        archive.with_name(archive.name + ".manifest.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "Embedded manifest"):
            unpack(self.root, self.directory, self.pin, target)

    def test_rejects_unlisted_payload(self):
        target = "x86_64-linux"
        self.archive(".tar.gz", target, "foo", extra="extraneous")
        with self.assertRaisesRegex(ValueError, "Extracted file list differs"):
            unpack(self.root, self.directory, self.pin, target)


if __name__ == "__main__":
    unittest.main()
