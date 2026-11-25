"""Build a fixture executable and exercise the CLI over real stdio pipes."""

import argparse
import contextlib
import json
import os
from pathlib import Path
from queue import Empty, Queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[2]
TIMEOUT = 8
EXE = None
CREDENTIAL = "FOO_CLI_FIXTURE_CREDENTIAL"
MARKER = "FOO_CLI_TEST_MARKER"


def build(exe, optimize):
    command = ["zig", "build-exe", f"-femit-bin={exe}"]
    for module, source, dependencies in (
        ("root", "tests/cli/probe.zig", ("foo", "cli", "configuration", "core", "journal")),
        ("foo", "src/lib.zig", ()),
        ("cli", "src/cli/root.zig", ("foo", "configuration")),
        ("configuration", "src/config/root.zig", ("foo",)),
        ("core", "src/core/root.zig", ("foo",)),
        ("journal", "src/session/root.zig", ("foo",)),
    ):
        for dependency in dependencies:
            command.extend(["--dep", dependency])
        command.extend(["-O", optimize, f"-M{module}={source}"])
    subprocess.run(command, cwd=ROOT, check=True, timeout=150)


class Cli(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="foo-cli-")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.profile = self.directory / "profile.json"
        self.marker = self.directory / "state"
        self.environment = {**os.environ, MARKER: str(self.marker)}
        self.environment.pop(CREDENTIAL, None)
        self.write_config()

    def write_config(self, **options):
        self.profile.write_text(
            json.dumps({
                "providers": {"local": {
                    "family": "openai_responses",
                    "base_url": "https://example.invalid",
                    "models": {"fixture": {}, "later-layer": {}},
                    **options.pop("provider", {}),
                }},
                "model": "local/fixture",
                **options,
            }),
            encoding="utf-8",
        )

    def run_cli(self, *args, data=None, env=None):
        return subprocess.run(
            [EXE, *args],
            input=data,
            capture_output=True,
            cwd=self.directory,
            env=self.environment if env is None else env,
            timeout=TIMEOUT,
        )

    @contextlib.contextmanager
    def start(self, *args):
        process = subprocess.Popen(
            [EXE, *args],
            cwd=self.directory,
            env=self.environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            yield process
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=TIMEOUT)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def options(self):
        return ["--config", str(self.profile)]

    def send(self, child, request_id, command, **data):
        self.send_raw(child, json.dumps({
            "version": 1, "id": request_id, "command": command, **data,
        }).encode() + b"\n")

    @staticmethod
    def send_raw(child, data):
        child.stdin.write(data)
        child.stdin.flush()

    def wait_for(self, predicate, reason, child):
        end = time.monotonic() + TIMEOUT
        while not predicate():
            self.assertIsNone(child.poll(), f"{reason}: process exited early")
            self.assertLess(time.monotonic(), end, reason)
            time.sleep(0.01)

    def wait_marker(self, value, child):
        def marked():
            try:
                return self.marker.read_text() == value
            except FileNotFoundError:
                return False

        self.wait_for(marked, f"provider did not reach {value!r}", child)

    @staticmethod
    def wait_channel(child, name):
        for channel in Path(f"/proc/{child.pid}/task").glob("*/wchan"):
            try:
                if name in channel.read_text():
                    return True
            except (FileNotFoundError, ProcessLookupError):
                pass
        return False

    def test_help_version_and_usage(self):
        help_output = self.run_cli("--help")
        self.assertEqual(help_output.returncode, 0)
        for option in (b"--stdin", b"--resume", b"rpc", b"config"):
            self.assertIn(option, help_output.stdout)
        self.assertEqual(help_output.stderr, b"")
        version = self.run_cli("--version")
        self.assertEqual(version.returncode, 0)
        self.assertTrue(version.stdout.startswith(b"foo "))
        conflicting = self.run_cli("run", "--prompt", "hi", "--stdin", *self.options())
        self.assertEqual(conflicting.returncode, 2)
        self.assertEqual(conflicting.stdout, b"")
        self.assertTrue(conflicting.stderr)

    def test_one_shot_and_piped_input(self):
        plain = self.run_cli("run", "--prompt", "hello", *self.options())
        self.assertEqual((plain.returncode, plain.stdout, plain.stderr), (0, b"answer: hello\n", b""))
        piped = self.run_cli("run", "--stdin", *self.options(), data=b"from pipe\n")
        self.assertEqual((piped.returncode, piped.stdout, piped.stderr), (0, b"answer: from pipe\n", b""))

    def test_plain_broken_stdout_reports_a_host_failure(self):
        read_end, write_end = os.pipe()
        os.close(read_end)
        try:
            result = subprocess.run(
                [EXE, "run", "--prompt", "hello", *self.options()],
                stdout=write_end,
                stderr=subprocess.PIPE,
                cwd=self.directory,
                env=self.environment,
                timeout=TIMEOUT,
            )
        finally:
            os.close(write_end)
        self.assertEqual(result.returncode, 6)
        self.assertTrue(result.stderr)

    def test_usage_config_credentials_and_redaction(self):
        self.write_config(provider={
            "credential": {"environment": CREDENTIAL},
            "base_url": "https://example.invalid?token=fixture-query-secret",
            "headers": [{"name": "X-Private", "value": "fixture-header-secret"}],
        })
        valid = self.run_cli("config", "check", *self.options())
        self.assertEqual(valid.returncode, 0, valid.stderr)
        second = self.directory / "second.json"
        second.write_text('{"model":"local/later-layer"}', encoding="utf-8")
        show = self.run_cli("config", "show", *self.options(), "--config", str(second), "--model", "local/override")
        self.assertEqual(show.returncode, 0, show.stderr)
        effective = json.loads(show.stdout)
        self.assertEqual(effective["runtime"]["model"]["id"], "override")
        self.assertNotIn(b"fixture-query-secret", show.stdout + show.stderr)
        self.assertNotIn(b"fixture-header-secret", show.stdout + show.stderr)
        denied = self.run_cli("run", "--prompt", "hold", *self.options())
        self.assertEqual((denied.returncode, denied.stdout), (2, b""))
        self.assertTrue(denied.stderr)
        self.assertFalse(self.marker.exists())
        allowed = self.run_cli("run", "--prompt", "hello", *self.options(), env={
            **self.environment, CREDENTIAL: "present-but-private",
        })
        self.assertEqual((allowed.returncode, allowed.stdout), (0, b"answer: hello\n"))
        self.assertNotIn(b"present-but-private", allowed.stdout + allowed.stderr)
        self.profile.write_text('{"unknown":true}', encoding="utf-8")
        invalid = self.run_cli("config", "check", *self.options())
        self.assertEqual((invalid.returncode, invalid.stdout), (2, b""))
        self.assertTrue(invalid.stderr)

    def test_model_selection_and_provider_overrides(self):
        self.profile.write_text(json.dumps({
            "providers": {
                "openai": {
                    "family": "openai_responses",
                    "base_url": "https://openai.invalid/v1",
                    "models": {"large": {}, "mini": {"max_output_tokens": 2048}},
                },
                "gateway": {
                    "family": "openai_chat",
                    "base_url": "https://gateway.invalid/v1/",
                    "models": {"z-first": {}, "a-second": {}},
                },
            },
            "model": "openai/large",
        }), encoding="utf-8")

        def show(*flags):
            result = self.run_cli("config", "show", *self.options(), *flags)
            self.assertEqual((result.returncode, result.stderr), (0, b""))
            return json.loads(result.stdout)["runtime"]

        settings = show("--model", "openai/mini", "--provider", "gateway")
        self.assertEqual(settings["model"]["id"], "mini")
        self.assertEqual(settings["model"]["max_output_tokens"], 2048)
        provenance = {entry["key"]: entry for entry in settings["provenance"]}
        self.assertEqual(provenance["model.id"]["source"], "command_line")
        self.assertEqual(provenance["model.max_output_tokens"]["input_key"],
                         "providers.openai.models.mini.max_output_tokens")
        self.assertEqual(show("--provider", "gateway")["model"]["id"], "z-first")
        self.assertEqual(show("--provider", "gateway", "--model", "a-second")["model"]["id"], "a-second")
        model = show("--provider", "gateway", "--family", "anthropic_messages")["model"]
        self.assertEqual(model["endpoint"], "https://gateway.invalid/v1/messages")
        self.assertEqual(model["family"], "anthropic_messages")
        model = show("--provider", "gateway", "--endpoint", "https://override.invalid/custom",
                     "--credential-env", CREDENTIAL)["model"]
        self.assertEqual(model["endpoint"], "https://override.invalid/custom")
        self.assertEqual(model["credential"], {"environment": CREDENTIAL})

    def test_legacy_model_object_has_migration_message(self):
        self.profile.write_text('{"model":{"id":"fixture"}}', encoding="utf-8")
        check = self.run_cli("config", "check", *self.options())
        self.assertEqual((check.returncode, check.stdout), (2, b""))
        self.assertIn(b'config invalid_value from file at model:', check.stderr)
        self.assertIn(b'model is a string "provider/id"; define providers under "providers"', check.stderr)

    def test_provider_and_resource_outcomes(self):
        for prompt, code in (("provider-error", 4), ("output-limit", 3)):
            result = self.run_cli("run", "--prompt", prompt, *self.options())
            self.assertEqual((result.returncode, result.stdout), (code, b""))
            self.assertTrue(result.stderr)
        self.write_config(limits={"transcript_bytes": 512})
        limited = self.run_cli("run", "--stdin", *self.options(), data=b"a" * 1024)
        self.assertEqual((limited.returncode, limited.stdout), (3, b""))

    def test_resume_loads_committed_context_explicitly(self):
        missing_directory = self.run_cli("run", "--resume", "--prompt", "second", *self.options())
        self.assertEqual(missing_directory.returncode, 2)
        directory = self.directory / "journal"
        directory.mkdir()
        self.write_config(session={"directory": str(directory)})
        first = self.run_cli("run", "--prompt", "first", *self.options())
        self.assertEqual((first.returncode, first.stdout), (0, b"answer: first\n"))
        ordinary = self.run_cli("run", "--prompt", "second", *self.options())
        self.assertEqual((ordinary.returncode, ordinary.stdout), (5, b""))
        resumed = self.run_cli("run", "--resume", "--prompt", "second", *self.options())
        self.assertEqual((resumed.returncode, resumed.stdout), (0, b"resumed: second\n"))

    def test_resume_reports_unresolved_intent_before_provider_starts(self):
        directory = self.directory / "journal"
        directory.mkdir()
        self.write_config(session={"directory": str(directory)})
        call = {"id": "pending", "name": "mark", "arguments_json": "{}"}
        records = [
            {"header": {"version": 1, "config_identity": "fixture"}},
            {"message": {"role": "user", "blocks": [{"text": "first"}]}},
            {"message": {"role": "assistant", "blocks": [{"tool_call": call}]}},
            {"dispatch_intent": {"call": call, "declaration": {
                "identity": {"backend": "fixture", "name": "mark"},
                "spec": {"name": "mark", "description": "Write marker", "schema_json": "{}"},
                "generation": 1,
            }}},
        ]
        journal = directory / "journal.jsonl"
        with journal.open("wb") as file:
            for sequence, record in enumerate(records, 1):
                payload = json.dumps({"sequence": sequence, "record": record}, separators=(",", ":")).encode()
                prefix = f'{{"crc32":"{zlib.crc32(payload):08x}","payload":'.encode()
                file.write(prefix + payload + b"}\n")
        before = journal.read_bytes()
        result = self.run_cli("run", "--resume", "--prompt", "hold", *self.options())
        self.assertEqual((result.returncode, result.stdout), (7, b""))
        self.assertIn(b"unresolved tool effects", result.stderr)
        self.assertFalse(self.marker.exists())
        self.assertEqual(journal.read_bytes(), before)

    def test_rpc_correlation_busy_cancel_and_reuse(self):
        with self.start("rpc", *self.options()) as child:
            reader = Reader(child.stdout)
            self.send_raw(child, b"{not json}\n")
            self.assertEqual(reader.take()["code"], "invalid_command")
            self.send(child, "wrong-version", "prompt", version=2, prompt="unused")
            self.assertEqual(reader.until(lambda row: row.get("id") == "wrong-version")["code"], "unsupported_version")
            self.send(child, "bad-shape", "prompt", prompt=[120])
            self.assertEqual(reader.until(lambda row: row.get("id") == "bad-shape")["code"], "invalid_command")
            self.send(child, "bad", "unknown")
            self.assertEqual(reader.until(lambda row: row.get("id") == "bad")["code"], "unknown_command")
            self.send(child, "one", "prompt", prompt="hold")
            first = reader.until(lambda row: row["type"] == "accepted")
            self.assertEqual((first["version"], first["id"]), (1, "one"))
            run = first["run"]
            self.wait_marker("started", child)
            self.send(child, "busy", "prompt", prompt="unused")
            self.assertEqual(reader.until(lambda row: row.get("id") == "busy")["code"], "busy")
            self.send(child, "wrong", "cancel", run=run + 1)
            self.assertEqual(reader.until(lambda row: row.get("id") == "wrong")["code"], "no_active_run")
            self.send(child, "cancel", "cancel", run=run)
            reader.until(lambda row: row["type"] == "result")
            self.wait_marker("stopped", child)
            self.send(child, "second", "prompt", prompt="replay")
            reader.until(lambda row: row.get("id") == "second" and row["type"] == "result")
            child.stdin.close()
            reader.collect()
            self.assertEqual(child.wait(timeout=TIMEOUT), 0)
            self.assertEqual(child.stderr.read(), b"")
            self.assertTrue(all(row["version"] == 1 for row in reader.rows))
            self.assertEqual([row["outcome"]["reason"] for row in reader.results("one")], ["cancelled"])
            self.assertEqual([row["outcome"]["reason"] for row in reader.results("second")], ["completed"])
            self.assertEqual([(row["id"], row["run"]) for row in reader.rows if row["type"] == "cancel_ack"], [("cancel", run)])
            self.assertEqual({row.get("run") for row in reader.rows if row.get("id") == "one"}, {run})
            self.assertNotIn("fixture-private-replay", json.dumps(reader.rows))

    def test_rpc_eof_cancels_and_joins_active_prompt(self):
        with self.start("rpc", *self.options()) as child:
            reader = Reader(child.stdout)
            self.send(child, "one", "prompt", prompt="hold")
            self.wait_marker("started", child)
            child.stdin.close()
            reader.collect()
            self.assertEqual(child.wait(timeout=TIMEOUT), 0)
            self.assertEqual(self.marker.read_text(), "stopped")
            self.assertEqual([row["outcome"]["reason"] for row in reader.results("one")], ["cancelled"])

    @unittest.skipUnless(sys.platform.startswith("linux"), "observe the blocked Linux pipe writer")
    def test_rpc_cancel_with_full_stdout_pipe(self):
        import fcntl

        with self.start("rpc", *self.options()) as child:
            output = child.stdout.fileno()
            fcntl.fcntl(output, fcntl.F_SETPIPE_SZ, 4096)
            self.send(child, "one", "prompt", prompt="pressure")
            self.wait_marker("started", child)

            self.wait_for(
                lambda: self.wait_channel(child, "pipe_write"),
                "stdout writer did not block",
                child,
            )
            self.send(child, "cancel", "cancel", run=1)
            self.wait_marker("stopped", child)
            reader = Reader(child.stdout)
            reader.until(lambda row: row["type"] == "result")
            child.stdin.close()
            reader.collect()
            self.assertEqual(child.wait(timeout=TIMEOUT), 0)
            self.assertEqual([row["outcome"]["reason"] for row in reader.results("one")], ["cancelled"])
            self.assertEqual([row["id"] for row in reader.rows if row["type"] == "cancel_ack"], ["cancel"])

    def test_rpc_broken_output_cancels_with_stdin_still_open(self):
        with self.start("rpc", *self.options()) as child:
            self.send(child, "one", "prompt", prompt="pressure")
            self.wait_marker("started", child)
            child.stdout.close()
            self.assertEqual(child.wait(timeout=TIMEOUT), 6)
            self.assertEqual(self.marker.read_text(), "stopped")

    @unittest.skipUnless(sys.platform.startswith("linux"), "observe the blocked Linux pipe writer")
    def test_rpc_eof_with_blocked_stdout_joins_without_waiting_for_consumer(self):
        with self.start("rpc", *self.options()) as child:
            self.send(child, "one", "prompt", prompt="pressure")
            self.wait_marker("started", child)
            self.wait_for(lambda: self.wait_channel(child, "pipe_write"), "stdout writer did not block", child)
            child.stdin.close()
            self.assertEqual(child.wait(timeout=TIMEOUT), 6)
            self.assertEqual(self.marker.read_text(), "stopped")

    def test_rpc_rejects_oversize_record_without_starting_run(self):
        self.write_config(limits={"wire_message_bytes": 256})
        request = json.dumps({"version": 1, "id": "large", "command": "prompt", "prompt": "x" * 512})
        result = self.run_cli("rpc", *self.options(), data=request.encode() + b"\n")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(self.marker.exists())

    @unittest.skipUnless(sys.platform.startswith("linux"), "observe the blocked Linux pipe reader")
    def test_signal_interrupts_plain_stdin_without_launching_provider(self):
        with self.start("run", "--stdin", *self.options()) as child:
            self.wait_for(lambda: self.wait_channel(child, "pipe_read"), "stdin reader did not block", child)
            child.send_signal(signal.SIGINT)
            self.assertEqual(child.wait(timeout=TIMEOUT), 130)
            self.assertFalse(self.marker.exists())

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal delivery")
    def test_signals_cancel_and_join_plain_run(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(sig=sig), self.start("run", "--prompt", "hold", *self.options()) as child:
                self.wait_marker("started", child)
                child.send_signal(sig)
                self.assertEqual(child.wait(timeout=TIMEOUT), 130)
                self.assertEqual(self.marker.read_text(), "stopped")
                self.assertEqual(child.stdout.read(), b"")

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal delivery")
    def test_signal_drains_active_rpc_result(self):
        with self.start("rpc", *self.options()) as child:
            reader = Reader(child.stdout)
            self.send(child, "active", "prompt", prompt="hold")
            reader.until(lambda row: row["type"] == "accepted")
            self.wait_marker("started", child)
            child.send_signal(signal.SIGTERM)
            reader.collect()
            self.assertEqual(child.wait(timeout=TIMEOUT), 130)
            self.assertEqual(self.marker.read_text(), "stopped")
            self.assertEqual([row["outcome"]["reason"] for row in reader.results("active")], ["cancelled"])

    @unittest.skipUnless(sys.platform.startswith("linux"), "observe the blocked Linux pipe writer")
    def test_signal_joins_active_rpc_when_stdout_stays_blocked(self):
        with self.start("rpc", *self.options()) as child:
            self.send(child, "active", "prompt", prompt="pressure")
            self.wait_marker("started", child)
            self.wait_for(lambda: self.wait_channel(child, "pipe_write"), "stdout writer did not block", child)
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=TIMEOUT), 130)
            self.assertEqual(self.marker.read_text(), "stopped")

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal delivery")
    def test_signal_allows_session_to_commit_cancelled_outcome(self):
        directory = self.directory / "journal"
        directory.mkdir()
        self.write_config(session={"directory": str(directory)})
        with self.start("run", "--prompt", "hold", *self.options()) as child:
            self.wait_marker("started", child)
            child.send_signal(signal.SIGINT)
            self.assertEqual(child.wait(timeout=TIMEOUT), 130)
        records = [
            json.loads(row)["payload"]["record"]
            for row in (directory / "journal.jsonl").read_text().splitlines()
        ]
        self.assertEqual(records[-1]["finished"]["reason"], "cancelled")
        resumed = self.run_cli("run", "--resume", "--prompt", "second", *self.options())
        self.assertEqual((resumed.returncode, resumed.stdout), (0, b"resumed: second\n"))


class Reader:
    def __init__(self, file):
        self.lines = Queue()
        self.rows = []
        self.ended = False

        def read():
            for line in file:
                self.lines.put(line)
            self.lines.put(None)

        self.worker = threading.Thread(target=read, daemon=True)
        self.worker.start()

    def take(self):
        try:
            line = self.lines.get(timeout=TIMEOUT)
        except Empty as error:
            raise AssertionError("timed out waiting for JSONL output") from error
        if line is None:
            self.ended = True
            return None
        try:
            row = json.loads(line)
        except ValueError as error:
            raise AssertionError(f"non-JSONL stdout: {line[:120]!r}") from error
        self.rows.append(row)
        return row

    def until(self, predicate):
        while (row := self.take()) is not None:
            if predicate(row):
                return row
        raise AssertionError(f"stdout ended before expected record: {self.rows!r}")

    def collect(self):
        while not self.ended:
            self.take()
        self.worker.join(timeout=TIMEOUT)
        return self.rows

    def results(self, request_id):
        return [row for row in self.rows if row.get("id") == request_id and row["type"] == "result"]


def main():
    global EXE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--optimize", default="Debug", choices=["Debug", "ReleaseSafe"])
    parser.add_argument("--executable", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="foo-cli-build-") as directory:
        EXE = args.executable.resolve() if args.executable else Path(directory) / "foo-fixture.exe"
        if not args.executable:
            build(EXE, args.optimize)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(Cli)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
