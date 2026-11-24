"""Independent ACP client. It knows the pinned wire format and the probe's prompt vocabulary."""

import argparse
import contextlib
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import unittest

TIMEOUT = 8
EOF = object()


class Peer:
    def __init__(self, binary, test, trace, args, read_limit):
        self.test = test
        self.trace = trace
        self.process = subprocess.Popen(
            [binary, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.messages = queue.Queue()
        self.responses = set()
        self.next_id = 0
        self.input_closed = False
        threading.Thread(target=self.read_stdout, args=(read_limit,), daemon=True).start()

    def read_stdout(self, limit):
        try:
            for index, line in enumerate(self.process.stdout, 1):
                if not line.endswith(b"\n"):
                    raise AssertionError(f"partial ACP frame: {line!r}")
                self.messages.put(json.loads(line.decode("utf-8")))
                if index == limit:
                    return
        except (UnicodeError, ValueError, AssertionError) as exc:
            self.messages.put(exc)
        finally:
            self.messages.put(EOF)

    def record(self, direction, message):
        if self.trace:
            self.trace.write(json.dumps(
                {"case": self.test.id(), "direction": direction, "message": message},
                ensure_ascii=False,
            ) + "\n")

    def send(self, **fields):
        message = {"jsonrpc": "2.0", **fields}
        self.record("client", message)
        self.process.stdin.write(json.dumps(message, ensure_ascii=False).encode("utf-8") + b"\n")
        self.process.stdin.flush()

    def request(self, method, params, request_id=None):
        if request_id is None:
            self.next_id += 1
            request_id = f"editor-{self.next_id}"
        self.send(id=request_id, method=method, params=params)
        return request_id

    def notify(self, method, **params):
        self.send(method=method, params=params)

    def next(self):
        try:
            message = self.messages.get(timeout=TIMEOUT)
        except queue.Empty:
            self.test.fail("no ACP frame arrived before the test deadline")
        if isinstance(message, Exception):
            raise message
        if message is EOF:
            self.test.fail(f"agent closed stdout before the expected frame (exit={self.process.poll()})")
        self.record("agent", message)
        self.test.assertIsInstance(message, dict)
        self.test.assertEqual(message.get("jsonrpc"), "2.0", message)
        if "method" not in message and message.get("id") is not None:
            identity = (type(message["id"]), message["id"])
            self.test.assertNotIn(identity, self.responses, f"duplicate reply: {message}")
            self.responses.add(identity)
        return message

    def reply(self, request, result):
        self.send(id=request["id"], result=result)

    def error(self, request, code=-32602):
        self.send(id=request["id"], error={"code": code, "message": "client refused"})

    def result(self, request_id, *, error=False):
        message = self.next()
        self.test.assertNotIn("method", message, message)
        self.test.assertIs(type(message.get("id")), type(request_id), message)
        self.test.assertEqual(message.get("id"), request_id, message)
        if error:
            self.test.assertIn("error", message, message)
            self.test.assertNotIn("result", message, message)
            self.test.assertIsInstance(message["error"]["code"], int)
            return message["error"]
        self.test.assertIn("result", message, message)
        self.test.assertNotIn("error", message, message)
        return message["result"]

    def expect_request(self, method, session):
        while True:
            message = self.next()
            actual = message.get("method")
            if actual == "session/update":
                self.test.assertEqual(message["params"]["sessionId"], session)
                continue
            if actual == "$/cancel_request":
                self.test.assertNotIn("id", message)
                continue
            self.test.assertEqual(actual, method, message)
            self.test.assertIsInstance(message.get("id"), (int, str), message)
            self.test.assertEqual(message["params"]["sessionId"], session, message)
            return message

    def initialize(self, capabilities=None, version=1, *, mcp_http=False):
        params = {"protocolVersion": version, "clientInfo": {"name": "pipe-peer", "version": "1"}}
        if capabilities is not None:
            params["clientCapabilities"] = capabilities
        result = self.result(self.request("initialize", params))
        self.test.assertEqual(result.get("protocolVersion"), 1)
        advertised = result.get("agentCapabilities", {})
        self.test.assertFalse(advertised.get("loadSession", False))
        prompt = advertised.get("promptCapabilities", {})
        for kind in ("image", "audio", "embeddedContext"):
            self.test.assertFalse(prompt.get(kind, False), advertised)
        mcp = advertised.get("mcpCapabilities", {})
        self.test.assertIs(mcp.get("http", False), mcp_http, mcp)
        self.test.assertFalse(mcp.get("sse", False), mcp)
        self.test.assertFalse(result.get("authMethods", []))
        return result

    def session(self, cwd=None, servers=()):
        result = self.result(self.request("session/new", {
            "cwd": str(cwd or Path.cwd()), "mcpServers": list(servers),
        }))
        session = result["sessionId"]
        self.test.assertIsInstance(session, str)
        self.test.assertTrue(session)
        return session

    def prompt(self, session, text, request_id=None):
        return self.request("session/prompt", {
            "sessionId": session, "prompt": [{"type": "text", "text": text}],
        }, request_id)

    def wait_for_turn(self, request_id, session, *, stop="end_turn", error=False):
        updates = []
        while True:
            message = self.next()
            if "method" not in message:
                self.test.assertIs(type(message.get("id")), type(request_id), message)
                self.test.assertEqual(message.get("id"), request_id, message)
                if error:
                    self.test.assertIn("error", message, message)
                else:
                    self.test.assertEqual(message.get("result", {}).get("stopReason"), stop, message)
                return updates
            self.test.assertNotIn("id", message, message)
            if message["method"] == "$/cancel_request":
                self.test.assertIn("requestId", message["params"])
                continue
            self.test.assertEqual(message["method"], "session/update", message)
            self.test.assertEqual(message["params"]["sessionId"], session)
            updates.append(message["params"]["update"])

    def close_input(self):
        self.process.stdin.close()
        self.input_closed = True

    def join(self):
        code = self.process.wait(timeout=TIMEOUT)
        stderr = self.process.stderr.read()
        self.test.assertEqual(code, 0, stderr.decode("utf-8", "replace"))
        return stderr

    def cleanup(self):
        try:
            if not self.input_closed:
                with contextlib.suppress(BrokenPipeError):
                    self.close_input()
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=TIMEOUT)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=TIMEOUT)
        finally:
            self.process.stdout.close()
            self.process.stderr.close()


def agent_text(updates):
    return "".join(
        update["content"]["text"] for update in updates
        if update.get("sessionUpdate") == "agent_message_chunk"
    )


class AcpStdio(unittest.TestCase):
    binary = None
    trace = None

    def peer(self, *args, read_limit=None):
        peer = Peer(self.binary, self, self.trace, args, read_limit)
        self.addCleanup(peer.cleanup)
        return peer

    def initialized(self, capabilities=None, args=()):
        peer = self.peer(*args)
        peer.initialize(capabilities)
        return peer, peer.session()

    def test_lifecycle_and_tool_updates(self):
        peer = self.peer()
        before = peer.request("session/new", {"cwd": str(Path.cwd()), "mcpServers": []})
        peer.result(before, error=True)
        peer.initialize(version=65535)
        peer.result(peer.request("initialize", {"protocolVersion": 1}), error=True)
        malformed = peer.request("session/new", {"cwd": "relative", "mcpServers": []})
        peer.result(malformed, error=True)
        session = peer.session()
        second = peer.session()
        self.assertNotEqual(second, session)
        peer.result(peer.prompt("absent-session", "hello"), error=True)
        peer.result(peer.request("session/load", {"sessionId": session}), error=True)
        peer.result(peer.request("session/prompt", {
            "sessionId": session, "prompt": [{"type": "image", "mimeType": "image/png", "data": "AA=="}],
        }), error=True)

        first = peer.prompt(session, "hello", 7)
        self.assertEqual(agent_text(peer.wait_for_turn(first, session)), "hello 世界")
        tools = peer.prompt(session, "tools", "7")
        updates = peer.wait_for_turn(tools, session)
        announced = [update for update in updates if update["sessionUpdate"] == "tool_call"]
        self.assertEqual(len(announced), 1, updates)
        self.assertEqual(announced[0]["status"], "pending")
        transitions = [update for update in updates if update["sessionUpdate"] == "tool_call_update"]
        self.assertTrue(transitions, updates)
        self.assertEqual(transitions[-1]["status"], "completed")
        for update in transitions:
            self.assertEqual(update["toolCallId"], announced[0]["toolCallId"])
        repeated = peer.wait_for_turn(peer.prompt(session, "tools"), session)
        self.assertNotEqual(repeated[0]["toolCallId"], announced[0]["toolCallId"])
        peer.close_input()
        peer.join()
        self.assertIs(peer.messages.get(timeout=TIMEOUT), EOF)

    def test_overlapping_and_cancel_by_session_or_request(self):
        for method in ("session/cancel", "$/cancel_request"):
            with self.subTest(method=method):
                peer, session = self.initialized()
                other = peer.session()
                prompt = peer.prompt(session, "wait", 41)
                chunk = peer.next()
                self.assertEqual(chunk.get("method"), "session/update", chunk)
                self.assertEqual(chunk["params"]["sessionId"], session)

                peer.result(peer.prompt(other, "hello"), error=True)
                peer.notify("session/cancel", sessionId=other)
                if method == "session/cancel":
                    peer.result(peer.prompt(other, "hello"), error=True)
                    peer.notify(method, sessionId=session)
                else:
                    peer.notify(method, requestId=str(prompt))
                    peer.result(peer.prompt(other, "hello"), error=True)
                    peer.notify(method, requestId=prompt)
                peer.wait_for_turn(prompt, session, stop="cancelled")
                self.assertEqual(
                    agent_text(peer.wait_for_turn(peer.prompt(other, "hello"), other)), "hello 世界",
                )
                peer.close_input()
                peer.join()
                self.assertIs(peer.messages.get(timeout=TIMEOUT), EOF)

    def test_history_and_stop_reasons(self):
        peer, session = self.initialized()
        other = peer.session()
        peer.wait_for_turn(peer.prompt(session, "hello"), session)
        peer.wait_for_turn(peer.prompt(session, "refusal"), session, stop="refusal")
        updates = peer.wait_for_turn(peer.prompt(session, "history"), session)
        self.assertEqual(agent_text(updates), "history 1")
        updates = peer.wait_for_turn(peer.prompt(other, "history"), other)
        self.assertEqual(agent_text(updates), "history 0")
        peer.wait_for_turn(peer.prompt(session, "limit"), session, stop="max_tokens")
        peer.wait_for_turn(peer.prompt(session, "other-limit"), session, error=True)

    def test_editor_mcp_declaration_and_session_admission(self):
        peer = self.peer()
        peer.initialize()
        mcp = {"name": "fixture", "command": "mock-mcp", "args": ["--mock"], "env": []}
        session = peer.session(servers=[mcp])
        updates = peer.wait_for_turn(peer.prompt(session, "mcp"), session)
        self.assertEqual(agent_text(updates), "editor MCP delegated")
        for servers in ([mcp, mcp], [{"type": "http", "name": "remote", "url": "https://mcp.invalid", "headers": []}]):
            request = peer.request("session/new", {"cwd": str(Path.cwd()), "mcpServers": servers})
            peer.result(request, error=True)

    def test_advertised_editor_http_mcp_passes_validated_descriptor_to_factory(self):
        peer = self.peer("--mcp-http")
        peer.initialize(mcp_http=True)
        mcp = {
            "type": "http", "name": "remote", "url": "HTTPS://mcp.invalid/rpc",
            "headers": [{"name": "X-MCP-Test", "value": "fixture"}],
        }
        session = peer.session(servers=[mcp])
        updates = peer.wait_for_turn(peer.prompt(session, "mcp"), session)
        self.assertEqual(agent_text(updates), "editor HTTP MCP URL and header delegated")
        for invalid in (
            {**mcp, "type": "sse"},
            {**mcp, "type": 1},
            {**mcp, "url": "ftp://mcp.invalid"},
            {**mcp, "url": "https://name@host.invalid"},
            {**mcp, "url": "https://host.invalid/path#fragment"},
            {**mcp, "headers": [{"name": "bad header", "value": "value"}]},
            {**mcp, "headers": [{"name": "Header", "value": "value\r\nInjected: value"}]},
            {**mcp, "headers": [*mcp["headers"], {"name": "x-mcp-test", "value": "duplicate"}]},
            {**mcp, "command": "unexpected-command"},
        ):
            with self.subTest(descriptor=invalid):
                request = peer.request("session/new", {"cwd": str(Path.cwd()), "mcpServers": [invalid]})
                self.assertEqual(peer.result(request, error=True)["code"], -32602)

    def test_resource_link_reaches_runner(self):
        peer, session = self.initialized()
        uri = "file:///editor/manual.md"
        turn = peer.request("session/prompt", {
            "sessionId": session, "prompt": [
                {"type": "text", "text": "resource-link"},
                {"type": "resource_link", "name": "Manual", "uri": uri},
            ],
        })
        content = agent_text(peer.wait_for_turn(turn, session))
        self.assertIn("Manual", content)
        self.assertIn(uri, content)

    def test_session_open_cancellation_and_missing_credentials(self):
        params = {"cwd": str(Path.cwd()), "mcpServers": []}
        peer = self.peer("--slow-open")
        peer.initialize()
        opening = peer.request("session/new", params, 27)
        peer.notify("$/cancel_request", requestId=opening)
        self.assertEqual(peer.result(opening, error=True)["code"], -32800)

        auth = self.peer("--auth")
        auth.initialize()
        self.assertEqual(auth.result(auth.request("session/new", params), error=True)["code"], -32000)

    def test_permission_outcomes_and_late_approval(self):
        peer, session = self.initialized()
        for decision, expected in (
            ("allow_once", "approved"), ("reject_once", "denied"),
            ("unknown", "denied"), ("cancelled", "cancelled"),
        ):
            with self.subTest(decision=decision):
                prompt = peer.prompt(session, "permission")
                permission = peer.expect_request("session/request_permission", session)
                params = permission["params"]
                options = {item["kind"]: item["optionId"] for item in params["options"]}
                self.assertEqual(set(options), {"allow_once", "reject_once"})
                self.assertTrue(params["toolCall"]["toolCallId"])
                summary = json.dumps(params["toolCall"])
                self.assertIn("note.txt", summary)
                self.assertIn("fake-command", summary)
                self.assertIn("--check", summary)
                if decision == "cancelled":
                    outcome = {"outcome": "cancelled"}
                else:
                    outcome = {"outcome": "selected", "optionId": options.get(decision, "unknown")}
                peer.reply(permission, {"outcome": outcome})
                updates = peer.wait_for_turn(prompt, session)
                self.assertIn(expected, json.dumps(updates))

        cancelled = peer.prompt(session, "permission")
        stale = peer.expect_request("session/request_permission", session)
        peer.notify("session/cancel", sessionId=session)
        peer.wait_for_turn(cancelled, session, stop="cancelled")
        next_turn = peer.prompt(session, "permission")
        current = peer.expect_request("session/request_permission", session)
        self.assertNotEqual(stale["id"], current["id"])
        old_approval = next(o["optionId"] for o in stale["params"]["options"] if o["kind"] == "allow_once")
        peer.reply(stale, {"outcome": {"outcome": "selected", "optionId": old_approval}})
        rejected = next(o["optionId"] for o in current["params"]["options"] if o["kind"] == "reject_once")
        peer.reply(current, {"outcome": {"outcome": "selected", "optionId": rejected}})
        self.assertIn("denied", json.dumps(peer.wait_for_turn(next_turn, session)))

    def test_unsaved_read_and_negotiated_write(self):
        peer, session = self.initialized({"fs": {"readTextFile": True}})
        next_turn = peer.prompt(session, "read")
        read = peer.expect_request("fs/read_text_file", session)
        self.assertEqual(Path(read["params"]["path"]), Path.cwd() / "note.txt")
        peer.reply(read, {"content": "unsaved editor draft\n世界"})
        self.assertIn("unsaved editor draft\n世界", agent_text(peer.wait_for_turn(next_turn, session)))

        failed_read = peer.prompt(session, "read")
        read = peer.expect_request("fs/read_text_file", session)
        peer.error(read)
        peer.wait_for_turn(failed_read, session, error=True)
        peer.wait_for_turn(peer.prompt(session, "write"), session, error=True)
        peer.wait_for_turn(peer.prompt(session, "terminal"), session, error=True)
        self.assertFalse((Path.cwd() / "note.txt").exists())

        writer, write_session = self.initialized({"fs": {"writeTextFile": True}})
        turn = writer.prompt(write_session, "write")
        write = writer.expect_request("fs/write_text_file", write_session)
        self.assertEqual(Path(write["params"]["path"]), Path.cwd() / "note.txt")
        self.assertIsInstance(write["params"].get("content"), str)
        writer.reply(write, {})
        writer.wait_for_turn(turn, write_session)
        writer.wait_for_turn(writer.prompt(write_session, "read"), write_session, error=True)
        self.assertFalse((Path.cwd() / "note.txt").exists())

    def test_terminal_lifecycle(self):
        peer, session = self.initialized({"terminal": True})
        turn = peer.prompt(session, "terminal")
        create = peer.expect_request("terminal/create", session)
        self.assertTrue(create["params"]["command"])
        self.assertEqual(Path(create["params"]["cwd"]), Path.cwd())
        self.assertGreater(create["params"]["outputByteLimit"], 0)
        terminal = "editor-owned"
        peer.reply(create, {"terminalId": terminal})
        output = peer.expect_request("terminal/output", session)
        self.assertEqual(output["params"]["terminalId"], terminal)
        peer.reply(output, {"output": "editor terminal output", "truncated": False})
        wait = peer.expect_request("terminal/wait_for_exit", session)
        self.assertEqual(wait["params"]["terminalId"], terminal)
        peer.reply(wait, {"exitCode": 0})
        release = peer.expect_request("terminal/release", session)
        self.assertEqual(release["params"]["terminalId"], terminal)
        peer.reply(release, {})
        peer.wait_for_turn(turn, session)

    def test_terminal_snapshot_offset(self):
        peer, session = self.initialized({"terminal": True})
        turn = peer.prompt(session, "terminal-offset")
        create = peer.expect_request("terminal/create", session)
        peer.reply(create, {"terminalId": "offset-test"})
        output = peer.expect_request("terminal/output", session)
        peer.reply(output, {"output": "first ", "truncated": False})
        chunk = peer.next()
        self.assertEqual(agent_text([chunk["params"]["update"]]), "first ")
        output = peer.expect_request("terminal/output", session)
        peer.reply(output, {"output": "first second", "truncated": False})
        wait = peer.expect_request("terminal/wait_for_exit", session)
        peer.reply(wait, {"exitCode": 0})
        release = peer.expect_request("terminal/release", session)
        peer.reply(release, {})
        self.assertEqual(agent_text(peer.wait_for_turn(turn, session)), "second")

    def test_terminal_exit_supports_unsigned_status(self):
        peer, session = self.initialized({"terminal": True})
        turn = peer.prompt(session, "terminal")
        create = peer.expect_request("terminal/create", session)
        peer.reply(create, {"terminalId": "failed-command"})
        output = peer.expect_request("terminal/output", session)
        peer.reply(output, {"output": "", "truncated": False})
        wait = peer.expect_request("terminal/wait_for_exit", session)
        peer.reply(wait, {"exitCode": 0xC0000005})
        release = peer.expect_request("terminal/release", session)
        peer.reply(release, {})
        peer.wait_for_turn(turn, session, error=True)

    def test_terminal_cancel_uses_separate_cleanup_lifetime(self):
        peer, session = self.initialized({"terminal": True})
        turn = peer.prompt(session, "terminal")
        create = peer.expect_request("terminal/create", session)
        peer.reply(create, {"terminalId": "running-child"})
        output = peer.expect_request("terminal/output", session)
        peer.reply(output, {"output": "", "truncated": False})
        wait = peer.expect_request("terminal/wait_for_exit", session)
        peer.notify("session/cancel", sessionId=session)
        kill = peer.expect_request("terminal/kill", session)
        self.assertEqual(kill["params"]["terminalId"], "running-child")
        peer.reply(wait, {"exitCode": 0})
        peer.reply(kill, {})
        release = peer.expect_request("terminal/release", session)
        self.assertEqual(release["params"]["terminalId"], "running-child")
        peer.reply(release, {})
        peer.wait_for_turn(turn, session, stop="cancelled")

    def test_eof_with_active_terminal_records_uncertain_cleanup(self):
        peer, session = self.initialized({"terminal": True})
        peer.prompt(session, "terminal")
        create = peer.expect_request("terminal/create", session)
        peer.reply(create, {"terminalId": "editor-owned"})
        peer.expect_request("terminal/output", session)
        peer.close_input()
        self.assertIn(b"unconfirmed remote terminal cleanup", peer.join())
        self.assertIs(peer.messages.get(timeout=TIMEOUT), EOF)

    def test_cancelled_server_joins_turn_and_closes_session(self):
        peer, session = self.initialized(args=("--cancel-serve",))
        peer.prompt(session, "cancel-serve")
        self.assertIn(b"cancelled and closed session", peer.join())
        self.assertIs(peer.messages.get(timeout=TIMEOUT), EOF)

    def test_eof_during_permission(self):
        peer, session = self.initialized()
        peer.prompt(session, "permission")
        peer.expect_request("session/request_permission", session)
        peer.close_input()
        peer.join()
        self.assertIs(peer.messages.get(timeout=TIMEOUT), EOF)

    def test_permission_timeout_retires_request(self):
        peer, session = self.initialized(args=("--short",))
        turn = peer.prompt(session, "permission")
        expired = peer.expect_request("session/request_permission", session)
        self.assertIn("denied", json.dumps(peer.wait_for_turn(turn, session)))
        allow = next(o["optionId"] for o in expired["params"]["options"] if o["kind"] == "allow_once")
        peer.reply(expired, {"outcome": {"outcome": "selected", "optionId": allow}})
        self.assertEqual(agent_text(peer.wait_for_turn(peer.prompt(session, "hello"), session)), "hello 世界")

    def test_broken_stdout_cancels_idle_stdin_read(self):
        with subprocess.Popen(
            [self.binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as process:
            process.stdout.close()
            process.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}\n')
            process.stdin.flush()
            try:
                code = process.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                process.kill()
                self.fail("agent kept waiting for stdin after stdout broke")
            self.assertEqual(code, 0, process.stderr.read().decode("utf-8", "replace"))

    def test_stdout_pressure_ends_connection_with_stdin_open(self):
        peer = self.peer(read_limit=2)
        peer.initialize()
        session = peer.session()
        self.assertIs(peer.messages.get(timeout=TIMEOUT), EOF)
        peer.prompt(session, "spam")
        peer.join()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--trace", type=Path)
    args = parser.parse_args()
    AcpStdio.binary = args.binary.resolve()
    with contextlib.ExitStack() as stack:
        if args.trace:
            AcpStdio.trace = stack.enter_context(args.trace.open("w", encoding="utf-8"))
        unittest.main(argv=[sys.argv[0], "-v"])
