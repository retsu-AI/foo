"""Run the deterministic acceptance corpus against a native foo executable."""

import argparse
from collections import deque
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import subprocess
import sys
import threading
import traceback
from typing import Callable
import unittest

INTEGRATION = runpy.run_path(str(Path(__file__).resolve().parents[1] / "integration" / "check.py"))
Production = INTEGRATION["Production"]
Handler = INTEGRATION["Handler"]
Reader = INTEGRATION["Reader"]
agent_text = INTEGRATION["agent_text"]
mcp_reply = INTEGRATION["mcp_reply"]
LEGACY = INTEGRATION["LEGACY"]
MODERN = INTEGRATION["MODERN"]
TIMEOUT = INTEGRATION["TIMEOUT"]


def chat(delta, finish=None):
    message = {"id": "acceptance", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
    return f"data: {json.dumps(message)}\n\n".encode()


def answer(text):
    return chat({"role": "assistant", "content": text}) + chat({}, "stop") + b"data: [DONE]\n\n"


def call(name, arguments, call_id):
    delta = {"role": "assistant", "tool_calls": [{
        "index": 0, "id": call_id, "type": "function",
        "function": {"name": name, "arguments": json.dumps(arguments)},
    }]}
    return chat(delta) + chat({}, "tool_calls") + b"data: [DONE]\n\n"


def stream(*events):
    return "".join(f"event: {kind}\ndata: {json.dumps({'type': kind, **payload})}\n\n"
                   for kind, payload in events).encode()


def responses_answer(text):
    response = {"id": "response", "object": "response", "status": "in_progress", "output": []}
    message = {"id": "message", "type": "message", "role": "assistant", "status": "in_progress", "content": []}
    item = {"item_id": "message", "output_index": 0, "content_index": 0}
    empty = {"type": "output_text", "text": "", "annotations": []}
    part = {**empty, "text": text}
    completed = {**message, "status": "completed", "content": [part]}
    return stream(
        ("response.created", {"response": response}),
        ("response.output_item.added", {"output_index": 0, "item": message}),
        ("response.content_part.added", {**item, "part": empty}),
        ("response.output_text.delta", {**item, "delta": text}),
        ("response.output_text.done", {**item, "text": text}),
        ("response.content_part.done", {**item, "part": part}),
        ("response.output_item.done", {"output_index": 0, "item": completed}),
        ("response.completed", {"response": {**response, "status": "completed", "output": [completed]}}),
    )


def messages_answer(text):
    return stream(
        ("message_start", {"message": {
            "id": "message", "type": "message", "role": "assistant", "model": "fixture", "content": [],
            "stop_reason": None, "usage": {"input_tokens": 8, "output_tokens": 1},
        }}),
        ("content_block_start", {"index": 0, "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": text}}),
        ("content_block_stop", {"index": 0}),
        ("message_delta", {"delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 4}}),
        ("message_stop", {}),
    )


@dataclass(frozen=True)
class Reply:
    body: bytes
    check: Callable[[dict], None] | None = None
    disconnected: threading.Event | None = None


class ScriptedHandler(Handler):
    def do_POST(self):
        if self.path not in ("/chat/completions", "/responses", "/messages") or self.server.replies is None:
            return super().do_POST()

        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append((self.path, request))
        try:
            reply = self.server.replies.popleft()
            if reply.check:
                reply.check(request)
        except Exception:
            self.server.peer_errors.append(traceback.format_exc())
            self.respond(500)
            return

        if reply.disconnected is None:
            self.respond(200, reply.body, "text/event-stream")
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(reply.body) + 8192))
        self.end_headers()
        self.wfile.write(reply.body)
        self.wfile.flush()
        self.connection.settimeout(TIMEOUT)
        self.close_connection = True
        try:
            if not self.connection.recv(1):
                reply.disconnected.set()
        except ConnectionError:
            reply.disconnected.set()
        except socket.timeout:
            self.server.peer_errors.append("provider stream remained open past the cancellation deadline")


class Acceptance(Production):
    def setUp(self):
        super().setUp()
        self.server.RequestHandlerClass = ScriptedHandler
        self.server.replies = None
        self.server.peer_errors = []

    def script(self, *replies):
        self.server.replies = deque(replies)

        def check_exchanges():
            self.assertEqual(self.server.peer_errors, [])
            self.assertEqual(len(self.server.replies), 0, "provider replies left unconsumed")

        self.addCleanup(check_exchanges)

    def source(self, path, content):
        (self.directory / path).write_bytes(content.encode())

    def read_result(self, call_id, check):
        def inspect(request):
            result = request["messages"][-1]
            self.assertEqual(result["role"], "tool")
            self.assertEqual(result["tool_call_id"], call_id)
            check(result["content"])

        return inspect

    def run_fixture_program(self, *argv):
        return subprocess.run(argv, cwd=self.directory, env=self.env,
                              capture_output=True, timeout=TIMEOUT, check=True)

    @contextmanager
    def rpc(self, *options):
        with subprocess.Popen(
            self.argv("rpc", *options), env=self.env, cwd=self.directory,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as child:
            reader = Reader(child.stdout)
            try:
                yield child, reader
            finally:
                if child.poll() is None:
                    child.kill()

    @staticmethod
    def send(child, request_id, command, **params):
        frame = {"version": 1, "id": request_id, "command": command, **params}
        child.stdin.write((json.dumps(frame) + "\n").encode())
        child.stdin.flush()

    def expect_result(self, reader, request_id, reason):
        result = reader.until(lambda row: row["type"] == "result")
        self.assertEqual(result["id"], request_id)
        self.assertEqual(result["outcome"]["reason"], reason)
        return result

    def finish_rpc(self, child, reader):
        child.stdin.close()
        reader.collect()
        self.assertEqual(child.wait(timeout=TIMEOUT), 0)
        self.assertEqual(child.stderr.read(), b"")

    def journal_config(self, **settings):
        journal = self.directory / "journal"
        journal.mkdir(exist_ok=True)
        self.config(session={"directory": str(journal)}, **settings)
        return journal / "journal.jsonl"

    def test_one_shot_responses_and_messages(self):
        prompt = "Return the greeting."
        text = "Café ☕"
        self.script(Reply(responses_answer(text)), Reply(messages_answer(text)))
        for family, route, request_key in (
            ("openai_responses", "/responses", "input"),
            ("anthropic_messages", "/messages", "messages"),
        ):
            with self.subTest(family=family):
                self.config(provider={"family": family})
                self.success(("run", "--prompt", prompt), text + "\n")
                actual_route, request = self.server.requests[-1]
                self.assertEqual(actual_route, route)
                self.assertEqual(request["model"], "fixture")
                self.assertIs(request["stream"], True)
                self.assertIn(prompt, json.dumps(request[request_key]))

    def test_repository_bug_fix(self):
        original = "def price(subtotal, tax):\n    return subtotal - tax\n"
        fixed = "def price(subtotal, tax):\n    return subtotal + tax\n"
        self.source("store.py", original)
        self.source("check_price.py", "from store import price\nassert price(20, 2) == 22\n")
        self.config(enabled_tools=["read", "edit", "exec"], permissions="allow")

        def inspect_read(content):
            read = json.loads(content)
            self.assertEqual(read["content"], original)
            self.assertEqual(read["sha256"], hashlib.sha256(original.encode()).hexdigest())

        def inspect_build(content):
            build = json.loads(content)
            self.assertEqual(build["exit_code"], 0)

        self.script(
            Reply(call("read", {"path": "store.py"}, "read")),
            Reply(call("edit", {
                "path": "store.py", "expected_sha256": hashlib.sha256(original.encode()).hexdigest(),
                "replacements": [{"old": "subtotal - tax", "new": "subtotal + tax"}],
            }, "edit"), self.read_result("read", inspect_read)),
            Reply(call("exec", {"argv": [sys.executable, "check_price.py"]}, "check"),
                  self.read_result("edit", lambda content: self.assertEqual(
                      json.loads(content)["sha256"], hashlib.sha256(fixed.encode()).hexdigest()))),
            Reply(answer("Price verification passed."), self.read_result("check", inspect_build)),
        )

        self.success(("run", "--stdin"), "Price verification passed.\n", b"Fix the tax calculation.\n")
        self.assertEqual((self.directory / "store.py").read_bytes(), fixed.encode())
        self.run_fixture_program(sys.executable, "check_price.py")

    def test_refactor_preserves_concurrent_unrelated_edit(self):
        original = "price = 4 + 4\n"
        updated = "price = 2 * 4\n"
        self.source("price.py", original)
        self.source("notes.txt", "original notes\n")
        self.config(enabled_tools=["read", "edit"], permissions="allow")

        def next_edit(content):
            self.assertEqual(json.loads(content)["content"], original)
            self.source("notes.txt", "independent change\n")

        self.script(
            Reply(call("read", {"path": "price.py"}, "read")),
            Reply(call("edit", {
                "path": "price.py", "expected_sha256": hashlib.sha256(original.encode()).hexdigest(),
                "replacements": [{"old": "4 + 4", "new": "2 * 4"}],
            }, "edit"), self.read_result("read", next_edit)),
            Reply(answer("Refactored the price.")),
        )
        self.success(("run", "--prompt", "Refactor price.py only."), "Refactored the price.\n")
        self.assertEqual((self.directory / "price.py").read_bytes(), updated.encode())
        self.assertEqual((self.directory / "notes.txt").read_bytes(), b"independent change\n")
        self.run_fixture_program(sys.executable, "-c", "from price import price; assert price == 8")

    def test_build_failure_returns_bounded_diagnostics(self):
        self.source("build.py", """
from pathlib import Path
import sys
Path("build-receipt").write_bytes(b"compiler ran")
sys.stdout.buffer.write(b"build progress\\n" * 16384)
sys.stderr.buffer.write(b"fixture compiler failure\\n")
raise SystemExit(23)
""".lstrip())
        output_limit = 8192
        self.config(enabled_tools=["exec"], permissions="allow", limits={"tool_output_bytes": output_limit})

        def inspect_tool(content):
            build = json.loads(content)
            self.assertEqual(build["exit_code"], 23)
            self.assertEqual(build["stdout_bytes"], len(b"build progress\n") * 16384)
            self.assertGreater(build["stdout_bytes"], len(build["stdout"]))
            self.assertIn("fixture compiler failure", build["stderr"])
            self.assertTrue(build["cleanup_confirmed"])
            self.assertLessEqual(len(content.encode()), output_limit)

        self.script(
            Reply(call("exec", {"argv": [sys.executable, "build.py"]}, "build")),
            Reply(answer("Build failed with code 23."), self.read_result("build", inspect_tool)),
        )
        with self.rpc() as (child, reader):
            self.send(child, "build", "prompt", prompt="Run the fixture build and diagnose its failure.")
            self.expect_result(reader, "build", "completed")
            self.finish_rpc(child, reader)
        results = [event["tool_committed"]["result"] for row in reader.rows
                   if (event := row.get("event")) and "tool_committed" in event]
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["status"], "failure")
        self.assertTrue(results[0]["truncated"])
        self.assertEqual((self.directory / "build-receipt").read_bytes(), b"compiler ran")

    def test_interrupted_stream_does_not_commit_partial_answer(self):
        journal = self.journal_config()
        seed = "First complete answer."
        partial = "uncommitted partial"
        self.script(
            Reply(answer(seed)),
            Reply(chat({"role": "assistant", "content": partial})),
            Reply(answer("Resume after disruption.")),
        )

        self.success(("run", "--prompt", "First turn"), seed + "\n")
        broken = self.execute("run", "--resume", "--prompt", "Disrupt this turn")
        self.assertEqual(broken.returncode, 4)
        self.assertEqual(broken.stdout, b"")
        self.assertNotIn(partial.encode(), journal.read_bytes())
        self.success(("run", "--resume", "--prompt", "Continue"), "Resume after disruption.\n")
        transcript = self.provider_requests()[-1]["messages"]
        self.assertIn({"role": "assistant", "content": seed}, transcript)
        self.assertNotIn(partial, json.dumps(transcript))

    def test_rpc_cancellation_disconnects_and_resumes(self):
        journal = self.journal_config()
        disconnected = threading.Event()
        seed = "Before cancellation."
        partial = "provisional text"
        self.script(
            Reply(answer(seed)),
            Reply(chat({"role": "assistant", "content": partial}), disconnected=disconnected),
            Reply(answer("Resumed.")),
        )

        self.success(("run", "--prompt", "Seed the journal"), seed + "\n")
        with self.rpc("--resume") as (child, reader):
            self.send(child, "held", "prompt", prompt="Interrupt the active response")
            accepted = reader.until(lambda row: row["type"] == "accepted")
            reader.until(lambda row: partial in json.dumps(row.get("event")))
            self.send(child, "stop", "cancel", run=accepted["run"])
            self.expect_result(reader, "held", "cancelled")
            self.finish_rpc(child, reader)
        self.assertEqual(len(reader.results("held")), 1)
        self.assertTrue(any(row["type"] == "cancel_ack" and row["id"] == "stop" for row in reader.rows))
        self.assertTrue(disconnected.wait(TIMEOUT), "cancel did not close the active provider stream")
        self.assertNotIn(partial.encode(), journal.read_bytes())
        self.success(("run", "--resume", "--prompt", "Resume explicitly"), "Resumed.\n")
        transcript = self.provider_requests()[-1]["messages"]
        self.assertIn({"role": "assistant", "content": seed}, transcript)
        self.assertNotIn(partial, json.dumps(transcript))

    def test_reconstructed_context_respects_byte_limit(self):
        self.journal_config(limits={"transcript_bytes": 4096})
        seed = "history " + "x" * 600
        self.script(Reply(answer("Saved history.")), Reply(answer("Reconstructed.")))
        self.success(("run", "--prompt", seed), "Saved history.\n")

        self.journal_config(limits={"transcript_bytes": 512})
        result = self.execute("run", "--resume", "--prompt", "Too much retained history")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(len(self.provider_requests()), 1, "over-limit context reached the provider")

        self.journal_config(limits={"transcript_bytes": 4096})
        self.success(("run", "--resume", "--prompt", "Reconstruct history"), "Reconstructed.\n")
        self.assertEqual(self.provider_requests()[-1]["messages"], [
            {"role": "user", "content": seed},
            {"role": "assistant", "content": "Saved history."},
            {"role": "user", "content": "Reconstruct history"},
        ])

    def test_review_and_explicit_stage(self):
        git = shutil.which("git")
        self.assertIsNotNone(git, "git is required for the temporary repository fixture")
        self.run_fixture_program(git, "init", "--quiet")
        self.source("rules.txt", "mode=unsafe\n")
        self.source("notes.txt", "outside review scope\n")
        self.config(enabled_tools=["read", "edit", "exec"], permissions="allow")

        self.script(
            Reply(call("read", {"path": "rules.txt"}, "review")),
            Reply(call("edit", {
                "path": "rules.txt", "expected_sha256": hashlib.sha256(b"mode=unsafe\n").hexdigest(),
                "replacements": [{"old": "mode=unsafe", "new": "mode=safe"}],
            }, "fix"), self.read_result("review", lambda content: self.assertEqual(
                json.loads(content)["content"], "mode=unsafe\n"))),
            Reply(call("exec", {"argv": [git, "add", "--", "rules.txt"]}, "stage")),
            Reply(answer("Staged only rules.txt."), self.read_result("stage", lambda content:
                  self.assertEqual(json.loads(content)["exit_code"], 0))),
        )
        self.success(("run", "--prompt", "Review rules.txt, correct the mode, and stage only that file."),
                     "Staged only rules.txt.\n")
        self.assertEqual(self.run_fixture_program(git, "diff", "--cached", "--name-only").stdout.splitlines(),
                         [b"rules.txt"])
        self.assertEqual(self.run_fixture_program(git, "show", ":rules.txt").stdout, b"mode=safe\n")
        self.assertEqual((self.directory / "notes.txt").read_bytes(), b"outside review scope\n")

    def test_acp_cancel_and_reuse(self):
        disconnected = threading.Event()
        self.script(Reply(chat({"role": "assistant", "content": "partial ACP update"}),
                          disconnected=disconnected),
                    Reply(answer("Recovered editor session.")))
        peer = self.acp()
        session = peer.session(self.directory)
        turn = peer.prompt(session, "Cancel this turn")
        update = peer.next()
        self.assertEqual(update["method"], "session/update")
        self.assertEqual(update["params"]["sessionId"], session)
        self.assertEqual(agent_text([update["params"]["update"]]), "partial ACP update")
        peer.notify("session/cancel", sessionId=session)
        peer.wait_for_turn(turn, session, stop="cancelled")
        self.assertTrue(disconnected.wait(TIMEOUT), "ACP cancellation did not close the provider stream")
        update = peer.wait_for_turn(peer.prompt(session, "Continue in the editor"), session)
        self.assertEqual(agent_text(update), "Recovered editor session.")
        peer.close_input()
        self.assertEqual(peer.join(), b"")

    def test_mcp_profiles_and_transports(self):
        for revision in (LEGACY, MODERN):
            for transport in ("stdio", "http"):
                with self.subTest(revision=revision, transport=transport):
                    marker = self.directory / "stdio-transcript.jsonl"
                    marker.unlink(missing_ok=True)
                    if transport == "stdio":
                        argv = [sys.executable, str(Path(__file__).resolve()), "--stdio-peer", revision, str(marker)]
                        config = {"stdio": {"argv": argv}}
                    else:
                        route = "/modern" if revision == MODERN else "/mcp"
                        config = {"http": {"url": self.origin + route}}
                    self.config(
                        mcp_servers=[{"id": "subject", "revision": revision, "transport": config}],
                        enabled_tools=["mcp_subject_lookup"], permissions="allow",
                    )
                    result = self.execute("run", "--prompt", "call mcp_subject_lookup")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(b"loopback tool result", result.stdout)
                    self.assertEqual(result.stderr, b"")
                    if transport == "stdio":
                        methods = [json.loads(line) for line in marker.read_text().splitlines()]
                        self.assertEqual(methods[-1], "input-closed")
                    else:
                        methods = [request["method"] for path, request in self.server.requests if path == route]
                    self.assertEqual(methods[0], "server/discover" if revision == MODERN else "initialize")
                    self.assertIn("tools/list", methods)
                    self.assertIn("tools/call", methods)


CASES = {
    "one-shot-answers": "test_one_shot_config_and_disabled_tools",
    "one-shot-responses-and-messages": "test_one_shot_responses_and_messages",
    "repository-bug-fix": "test_repository_bug_fix",
    "concurrent-unrelated-edit": "test_refactor_preserves_concurrent_unrelated_edit",
    "build-failure-bounded-diagnostics": "test_build_failure_returns_bounded_diagnostics",
    "stream-disruption-and-resume": "test_interrupted_stream_does_not_commit_partial_answer",
    "cancel-and-resume": "test_rpc_cancellation_disconnects_and_resumes",
    "context-limit-and-reconstruction": "test_reconstructed_context_respects_byte_limit",
    "review-fix-and-stage": "test_review_and_explicit_stage",
    "mcp-revisions-and-transports": "test_mcp_profiles_and_transports",
    "mcp-context-selection": "test_mcp_context_is_retrieved_only_on_explicit_selection",
    "acp-editor-file-delegation": "test_acp_permission_and_editor_read",
    "acp-cancel-and-reuse": "test_acp_cancel_and_reuse",
    "tui-native": "test_bare_invocation_opens_tui",
    "tui-redirected": "test_explicit_tui_plain_fallback",
}


def stdio_peer(revision, marker):
    with marker.open("w", encoding="utf-8") as methods:
        for line in sys.stdin.buffer:
            request = json.loads(line)
            methods.write(json.dumps(request["method"]) + "\n")
            methods.flush()
            if "id" in request:
                print(json.dumps(mcp_reply(request, revision == MODERN)), flush=True)
            elif request["method"] != "notifications/initialized":
                raise ValueError(f"unexpected notification {request['method']}")
        methods.write(json.dumps("input-closed") + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()

    for name in ("FOO_CONFIG_JSON", "FOO_CA_FILE"):
        os.environ.pop(name, None)
    Acceptance.binary = options.binary.resolve(strict=True)
    cases = options.case or tuple(CASES)
    rows = []
    for case in cases:
        result = unittest.TextTestRunner(verbosity=2).run(Acceptance(CASES[case]))
        rows.append({
            "case": case,
            "status": "pass" if result.wasSuccessful() and not result.skipped else "fail",
            "failures": [details for _, details in result.failures + result.errors + result.skipped],
        })
    if options.output:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(json.dumps({"schema": 1, "cases": rows}, indent=2) + "\n", encoding="utf-8")
    return 0 if all(row["status"] == "pass" for row in rows) else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--stdio-peer"]:
        stdio_peer(sys.argv[2], Path(sys.argv[3]))
    else:
        raise SystemExit(main())
