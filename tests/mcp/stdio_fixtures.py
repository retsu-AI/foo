import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

PROBE = str(Path(sys.argv.pop(1)).resolve())
GUARDIAN = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else ""
SERVER = str(Path(__file__).with_name("stdio_server.py").resolve())


class Stdio(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory(prefix="foo mcp stdio ")
        self.addCleanup(fixture.cleanup)
        self.cwd = Path(fixture.name)
        (self.cwd / "expected-cwd").touch()

    def probe(self, mode, eof=True):
        result = subprocess.run(
            [PROBE, mode, sys.executable, SERVER, GUARDIAN],
            cwd=self.cwd, capture_output=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")
        if eof:
            self.assertTrue((self.cwd / "stdin-eof").is_file(), "child did not observe stdin EOF")

    def test_modern(self):
        self.probe("modern")

    def test_legacy(self):
        self.probe("legacy")

    def test_cancel_and_late_reply(self):
        self.probe("cancel")

    def test_deadline_mid_frame_and_late_reply(self):
        self.probe("slow")

    def test_write_deadline_on_backpressured_stdin(self):
        self.probe("blocked-stdin", eof=False)

    def test_peer_failure(self):
        for case in ("malformed", "wrong-id", "truncated", "oversized", "death"):
            with self.subTest(case=case):
                self.probe(case, eof=False)

    def test_cancellation_and_tree_reaping(self):
        self.probe("tree")
        heartbeat = self.cwd / "heartbeat"
        before = heartbeat.stat().st_size
        self.assertGreaterEqual(before, 3)
        time.sleep(0.2)
        self.assertEqual(heartbeat.stat().st_size, before)
        if sys.platform.startswith("linux"):
            pid = int((self.cwd / "descendant-pid").read_text(encoding="ascii"))
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
