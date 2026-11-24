"""Acceptance tests driven through real PTYs and redirected stdio."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "platform-terminal"))
from pty_driver import TerminalPeer, TIMEOUT

IS_WINDOWS = os.name == "nt"


class NativeScenarios(unittest.TestCase):
    native_binary = None
    tui_binary = None
    artifacts = None

    def peer(self, binary, *args, columns=80, rows=18, environment=None, stderr_pipe=False):
        peer = TerminalPeer([binary, *args], columns, rows, environment, stderr_pipe)

        def close():
            peer.close()
            if self.artifacts:
                self.artifacts.mkdir(parents=True, exist_ok=True)
                (self.artifacts / f"{self._testMethodName}.vt").write_bytes(peer.capture())

        self.addCleanup(close)
        return peer

    def restored(self, peer, code=0):
        self.assertEqual(peer.wait(), code, peer.capture()[-1000:])
        if not IS_WINDOWS:
            self.assertEqual(peer.device.current_mode(), peer.device.original, "terminal attributes changed after exit")

    def tui(self, *arguments, columns=80, rows=18):
        peer = self.peer(self.tui_binary, *arguments, columns=columns, rows=rows)
        peer.expect("Ready")
        if not IS_WINDOWS:
            self.assertFalse(peer.device.mode_restored(), "TUI did not enter raw mode")
        return peer

    def quit(self, peer, key=b"\x04"):
        peer.send(key)
        self.restored(peer)
        if not IS_WINDOWS:
            peer.expect(b"\x1b[?2004l")
            peer.expect(b"\x1b[?1049l")

    def submit(self, peer, prompt):
        start = peer.mark()
        peer.send(prompt + "\r")
        return start

    def test_native_unicode_input_and_resize(self):
        peer = self.peer(self.native_binary, "read", columns=70, rows=13)
        peer.expect("ready 70 13")
        peer.resize(44, 8)
        peer.expect("size 44 8")
        data = "e\u0301界"
        peer.send(data)
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            writes = re.findall(rb"input ([0-9a-f]+)", peer.capture())
            received = bytes.fromhex(b"".join(writes).decode("ascii"))
            if data.encode() in received:
                break
            time.sleep(0.025)
        else:
            self.fail(f"the native reader lost UTF-8 input: {peer.capture()[-600:]!r}")
        peer.send(b"\x04")
        self.restored(peer)
        peer.expect("exit")

    def test_native_restore_after_controlled_error(self):
        peer = self.peer(self.native_binary, "error")
        peer.expect("ready")
        peer.send("!")
        peer.expect("error")
        self.restored(peer)

    def test_native_restore_after_signal(self):
        peer = self.peer(self.native_binary, "signal" if IS_WINDOWS else "read")
        peer.expect("ready")
        if IS_WINDOWS:
            peer.send("!")
        else:
            peer.device.terminate()
        peer.expect("terminated")
        self.restored(peer)

    @unittest.skipIf(IS_WINDOWS, "Unix PTY hangup closes the master")
    def test_native_disconnect(self):
        peer = self.peer(self.native_binary, "eof", stderr_pipe=True)
        peer.expect("ready")
        self.assertEqual(peer.disconnect(), 0)
        self.assertEqual(peer.device.process.stderr.read(), b"eof\n")

    def test_native_non_tty_does_not_write_escapes(self):
        result = subprocess.run(
            [self.native_binary], input=b"", capture_output=True, timeout=TIMEOUT, check=True,
        )
        self.assertEqual(result.stdout.strip(), b"fallback")
        self.assertEqual(result.stderr, b"")

    def test_tui_unicode_editing_and_history(self):
        peer = self.tui()
        start = peer.mark()
        peer.send("wide界 e\u0301👩‍💻")
        peer.expect("wide界", start=start)
        peer.send(b"\x7f\x7f")
        peer.send("x\r")
        peer.expect("answer: wide界 x", start=start)
        peer.expect("Completed", start=start)
        start = self.submit(peer, "history")
        peer.expect("history: 1 previous prompts", start=start)
        self.quit(peer)

    def test_tui_bracketed_multiline_paste(self):
        peer = self.tui()
        start = peer.mark()
        for block in [b"\x1b[2", b"00~alpha\r\n", "βeta".encode(), b"\x1b[20", b"1~"]:
            peer.send(block)
        peer.expect("alpha", start=start)
        peer.expect("βeta", start=start)
        self.assertNotIn(b"answer: alpha", peer.capture()[start:])
        peer.send("\r")
        peer.expect("answer: alpha", start=start)
        peer.expect("Completed", start=start)
        self.quit(peer)

    def test_tui_late_cancel_repeats_and_recovers(self):
        peer = self.tui()
        start = self.submit(peer, "slow")
        peer.expect("slow chunk 1", start=start)
        peer.send(b"\x03\x03\x03")
        peer.expect("Cancelled", start=start)
        peer.send(b"\x03")
        start = self.submit(peer, "again")
        peer.expect("answer: again", start=start)
        peer.expect("Completed", start=start)
        self.quit(peer)

    @unittest.skipIf(IS_WINDOWS, "this fixture spells Ctrl+Enter as xterm enhanced input")
    def test_tui_remapped_binding_and_multiline_edit(self):
        peer = self.tui("--keys")
        start = peer.mark()
        peer.send("alpha\rbeta")
        peer.expect("beta", start=start)
        self.assertNotIn(b"answer: alpha", peer.capture()[start:])
        peer.send(b"\x1b[13;5u")
        peer.expect("answer: alpha", start=start)
        peer.expect("Completed", start=start)
        self.quit(peer, b"\x03")

    @unittest.skipIf(IS_WINDOWS, "uses a Unix PTY output-pressure fixture")
    def test_tui_cancel_while_output_is_backed_up(self):
        with tempfile.TemporaryDirectory(prefix="foo-tui-pressure-") as directory:
            marker = Path(directory) / "worker"
            peer = self.peer(self.tui_binary, environment={"FOO_TUI_TEST_MARKER": str(marker)})
            peer.expect("Ready")
            peer.read_enabled.clear()
            try:
                self.assertGreater(peer.device.fill_output(), 0)
                self.submit(peer, "pressure")
                self.wait_for_marker(marker, "started")
                peer.send(b"\x03\x03")
            finally:
                peer.read_enabled.set()
            self.wait_for_marker(marker, "stopped")
            peer.expect("Cancelled")
            self.quit(peer)

    def wait_for_marker(self, marker, text):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            if marker.exists() and text in marker.read_text(encoding="utf-8"):
                return
            time.sleep(0.02)
        self.fail(f"runner did not report {text!r}")

    def test_tui_projected_tool_and_failure(self):
        peer = self.tui()
        start = self.submit(peer, "tools")
        peer.expect("Tool", start=start)
        peer.expect("fixture", start=start)
        peer.expect("tool complete", start=start)
        peer.expect("Completed", start=start)
        start = self.submit(peer, "failure")
        peer.expect("Provider error", start=start)
        self.quit(peer)

    def test_tui_controls_stay_in_transcript(self):
        peer = self.tui()
        start = self.submit(peer, "controls")
        peer.expect("safe-start", start=start)
        peer.expect("safe-end", start=start)
        peer.expect("Completed", start=start)
        rendered = peer.capture()[start:]
        self.assertNotIn(b"\x1b]2;", rendered)
        self.assertNotIn(b"\x1b[6n", rendered)
        self.quit(peer)

    def test_tui_long_transcript_and_rapid_resize(self):
        peer = self.tui()
        start = self.submit(peer, "long")
        peer.expect("line 199", start=start)
        peer.expect("Completed", start=start)
        before = peer.mark()
        peer.send(b"\x1b[5~")
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            visible = re.findall(rb"line ([0-9]{3})(?![0-9])", peer.capture()[before:])
            if any(int(row) < 184 for row in visible):
                break
            time.sleep(0.02)
        else:
            self.fail("Page Up did not reveal an older transcript row")
        before = peer.mark()
        peer.resize(8, 3)
        if not IS_WINDOWS:
            peer.expect(b"\x1b[3;1H", start=before)
        peer.resize(36, 7)
        start = self.submit(peer, "after")
        peer.expect("answer: after", start=start)
        peer.expect("Completed", start=start)
        self.quit(peer)

    def test_tui_colour_disabled(self):
        peer = self.tui("--no-color")
        start = self.submit(peer, "tools")
        peer.expect("tool complete", start=start)
        self.quit(peer)
        if not IS_WINDOWS:
            self.assertIsNone(re.search(rb"\x1b\[(?:[3-9][0-9]|1[0-9]{2})(?:;[0-9]+)*m", peer.capture()))

    def test_tui_plain_fallback(self):
        env = {**os.environ, "NO_COLOR": "1"}
        result = subprocess.run(
            [self.tui_binary], input="plain 界\n".encode(), env=env,
            capture_output=True, timeout=TIMEOUT, check=True,
        )
        self.assertIn("answer: plain 界".encode(), result.stdout)
        self.assertNotIn(b"\x1b", result.stdout)
        self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path)
    parser.add_argument("tui", type=Path)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    NativeScenarios.native_binary = args.native.resolve()
    NativeScenarios.tui_binary = args.tui.resolve()
    NativeScenarios.artifacts = args.artifacts
    unittest.main(argv=[sys.argv[0], "-v"])
