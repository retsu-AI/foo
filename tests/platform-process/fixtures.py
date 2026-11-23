import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

PROBE = str(Path(sys.argv.pop(1)).resolve())
GUARDIAN = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else ""


class NativeProcesses(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory(prefix="foo process ")
        self.addCleanup(fixture.cleanup)
        self.cwd = Path(fixture.name)
        (self.cwd / "working-directory").touch()

    def command(self, mode):
        return [PROBE, f"check-{mode}", PROBE, GUARDIAN]

    def run_probe(self, mode):
        result = subprocess.run(
            self.command(mode),
            cwd=self.cwd,
            env={**os.environ, "F05_PARENT_ONLY": "set"},
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))

    def assert_descendant_stopped(self):
        heartbeat = self.cwd / "heartbeat"
        self.assertGreater(heartbeat.stat().st_size, 1)
        time.sleep(0.15)
        before = heartbeat.stat().st_size
        time.sleep(0.25)
        self.assertEqual(heartbeat.stat().st_size, before)

    def test_cwd_environment_argv_exit_and_pipes(self):
        self.run_probe("args")

    @unittest.skipIf(os.name == "nt", "POSIX signal semantics")
    def test_signal(self):
        self.run_probe("signal")

    def test_large_stdio_and_json_protocol(self):
        self.run_probe("exec")

    def test_tree_cleanup_after_deadline(self):
        self.run_probe("tree-deadline")
        self.assert_descendant_stopped()

    def test_tree_cleanup_after_cancellation(self):
        self.run_probe("tree-cancel")
        self.assert_descendant_stopped()

    def test_tree_cleanup_after_leader_exit(self):
        self.run_probe("leader-exit")
        self.assert_descendant_stopped()

    def test_tree_cleanup_after_forced_owner_exit(self):
        with subprocess.Popen(
            self.command("owner-death"),
            cwd=self.cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ) as owner:
            try:
                heartbeat = self.cwd / "heartbeat"
                deadline = time.monotonic() + 5
                while not heartbeat.is_file() or heartbeat.stat().st_size < 3:
                    if owner.poll() is not None:
                        self.fail(owner.communicate()[1].decode(errors="replace"))
                    if time.monotonic() >= deadline:
                        self.fail("descendant heartbeat never started")
                    time.sleep(0.025)
                owner.kill()
                owner.communicate(timeout=5)
                self.assert_descendant_stopped()
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
