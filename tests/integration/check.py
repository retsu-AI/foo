"""Drive the production executable with local provider and MCP peers."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

TESTS = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(TESTS / "acp"), str(TESTS / "cli"), str(TESTS / "platform-terminal")]
from test_stdio import Peer, agent_text
from check import Reader
from pty_driver import TerminalPeer

TIMEOUT = 12
LEGACY = "2025-11-25"
MODERN = "2026-07-28"


def mcp_result(request):
    match request["method"]:
        case "initialize":
            return {
                "protocolVersion": LEGACY,
                "serverInfo": {"name": "loopback", "version": "1"},
                "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
            }
        case "server/discover":
            return {
                "supportedVersions": [MODERN],
                "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
                "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "loopback", "version": "1"}},
            }
        case "resources/list":
            return {"resources": [{"uri": "fixture://sample", "name": "sample"}]}
        case "resources/templates/list":
            return {"resourceTemplates": [{"uriTemplate": "fixture://{name}", "name": "sample template"}]}
        case "prompts/list":
            return {"prompts": [{"name": "explain"}]}
        case "resources/read":
            uri = request["params"]["uri"]
            payload = {"blob": "/wA="} if uri == "fixture://binary" else {"text": "resource text"}
            return {"contents": [{"uri": uri, **payload}]}
        case "prompts/get":
            assert request["params"]["name"] == "explain", request
            subject = request["params"]["arguments"]["subject"]
            return {"messages": [{"role": "user", "content": {"type": "text", "text": f"Explain {subject}"}}]}
        case "tools/list":
            return {"tools": [{
                "name": "lookup",
                "description": "Return fixture text",
                "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
            }]}
        case "tools/call":
            assert request["params"]["name"] == "lookup", request
            assert request["params"]["arguments"] == {}, request
            return {"content": [{"type": "text", "text": "loopback tool result"}]}
        case _:
            raise AssertionError(request)


def mcp_reply(request, modern=False):
    result = mcp_result(request)
    if modern:
        result["resultType"] = "complete"
    return {"jsonrpc": "2.0", "id": request["id"], "result": result}


def stdio_peer(marker):
    for line in sys.stdin.buffer:
        request = json.loads(line)
        if request["method"] == "initialize":
            marker.write_text("started", encoding="utf-8")
        if "id" in request:
            print(json.dumps(mcp_reply(request)), flush=True)
        else:
            assert request["method"] == "notifications/initialized", request


def chat_reply(request):
    messages = request["messages"]
    prompt = next(message["content"] for message in reversed(messages) if message["role"] == "user")
    content = messages[-1]
    tools = [item["function"]["name"] for item in request.get("tools", [])]
    if content["role"] == "tool":
        result = content["content"]
        if prompt in ("call read", "call exec"):
            key = "content" if prompt == "call read" else "output"
            result = json.loads(result)[key]
        delta = {"role": "assistant", "content": "Observed " + result}
        finish = "stop"
    elif prompt.startswith("call "):
        name = prompt.split()[1]
        assert name in tools, (name, tools)
        arguments = {
            "read": {"path": "sample.txt"},
            "exec": {"argv": ["fixture", "--flag"]},
        }.get(name, {})
        delta = {"role": "assistant", "tool_calls": [{
            "index": 0, "id": "call-fixture", "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments)},
        }]}
        finish = "tool_calls"
    else:
        delta = {"role": "assistant", "content": f"Reply to {prompt.strip()}"}
        finish = "stop"
    packets = [
        {"id": "chat-fixture", "choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
        {"id": "chat-fixture", "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]},
    ]
    return ("".join(f"data: {json.dumps(packet)}\n\n" for packet in packets) + "data: [DONE]\n\n").encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.respond(405)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append((self.path, request))
        if self.path == "/chat":
            self.respond(200, chat_reply(request), "text/event-stream")
        elif self.path in ("/mcp", "/modern") and "id" in request:
            modern = self.path == "/modern"
            if modern:
                assert self.headers["Mcp-Method"] == request["method"]
                assert self.headers["MCP-Protocol-Version"] == MODERN
            self.respond(200, json.dumps(mcp_reply(request, modern)).encode())
        elif self.path == "/mcp" and request["method"] == "notifications/initialized":
            self.respond(202)
        else:
            self.respond(404)


class Production(unittest.TestCase):
    binary = None

    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix="foo-runtime-")
        self.addCleanup(work.cleanup)
        self.directory = Path(work.name).resolve()
        self.profile = self.directory / "profile.json"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.requests = []
        worker = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05})
        worker.start()

        def close():
            self.server.shutdown()
            worker.join()
            self.server.server_close()

        self.addCleanup(close)
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.env = {**os.environ, "NO_COLOR": "1", "TERM": "xterm-256color"}
        for name in ("FOO_CA_FILE", "FOO_CONFIG_JSON", "FOO_SMOKE_MISSING"):
            self.env.pop(name, None)
        self.config()

    def config(self, **options):
        self.profile.write_text(json.dumps({
            "model": {"family": "openai_chat", "endpoint": self.origin + "/chat", "id": "fixture"},
            "cwd": str(self.directory),
            **options,
        }), encoding="utf-8")

    def argv(self, *command):
        return [self.binary, *command, "--config", self.profile]

    def execute(self, *command, data=None):
        return subprocess.run(
            self.argv(*command), input=data, env=self.env, cwd=self.directory,
            capture_output=True, timeout=TIMEOUT,
        )

    def success(self, command, text, data=None):
        result = self.execute(*command, data=data)
        self.assertEqual(result.returncode, 0, (result.stderr, result.stdout, self.server.requests))
        self.assertEqual(result.stdout.decode().replace("\r\n", "\n"), text)
        self.assertEqual(result.stderr, b"")

    def provider_requests(self):
        return [request for path, request in self.server.requests if path == "/chat"]

    def test_help_and_version(self):
        for flag, expected in (("--help", b"foo tui"), ("--version", b"foo 0.0.0-rc")):
            result = subprocess.run([self.binary, flag], env=self.env, cwd=self.directory,
                                    capture_output=True, timeout=TIMEOUT)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)
            self.assertEqual(result.stderr, b"")

    def test_one_shot_config_and_disabled_tools(self):
        marker = self.directory / "stdio-started"
        server, _ = self.stdio_config(marker)
        self.config(
            mcp_servers=[server],
            custom_tools=[{
                "name": "disabled_exec", "description": "Fixture", "schema": {},
                "argv": ["missing-program"],
                "environment": [{"name": "INPUT", "value": {"environment": "FOO_SMOKE_MISSING"}}],
            }],
        )
        result = self.execute("config", "show")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["runtime"]["model"]["id"], "fixture")
        self.assertEqual(self.server.requests, [])
        self.success(("run", "--stdin"), "Reply to hello\n", b"hello\n")
        self.assertEqual([call.get("tools", []) for call in self.provider_requests()], [[]])
        self.assertFalse(marker.exists())

    def test_journal_and_builtin_read(self):
        (self.directory / "sample.txt").write_text("local text", encoding="utf-8")
        journal = self.directory / "journal"
        journal.mkdir(mode=0o700)
        self.config(enabled_tools=["read"], permissions="allow", session={"directory": str(journal)})
        self.success(("run", "--prompt", "call read"), "Observed local text\n")
        self.success(("run", "--resume", "--prompt", "again"), "Reply to again\n")
        messages = self.provider_requests()[-1]["messages"]
        self.assertEqual([entry["role"] for entry in messages], ["user", "assistant", "tool", "assistant", "user"])
        self.assertEqual(messages[2]["tool_call_id"], "call-fixture")
        self.assertTrue((journal / "journal.jsonl").is_file())

    def stdio_config(self, marker):
        argv = [sys.executable, str(Path(__file__).resolve()), "--stdio-peer", str(marker)]
        return {
            "id": "pipe", "revision": LEGACY, "transport": {"stdio": {"argv": argv}},
        }, {
            "name": "pipe", "type": "stdio", "command": argv[0], "args": argv[1:], "env": [],
        }

    def test_stdio_mcp_is_discovered_and_called(self):
        marker = self.directory / "stdio-started"
        server, _ = self.stdio_config(marker)
        dormant = self.directory / "dormant-started"
        unused, _ = self.stdio_config(dormant)
        self.config(mcp_servers=[server, {**unused, "id": "unused"}],
                    enabled_tools=["mcp_pipe_lookup"], permissions="allow")
        result = self.execute("run", "--prompt", "call mcp_pipe_lookup")
        self.assertEqual(result.returncode, 0, (result.stderr, result.stdout, self.server.requests))
        self.assertIn(b"loopback tool result", result.stdout)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(marker.read_text(encoding="utf-8"), "started")
        self.assertFalse(dormant.exists())

    def test_mcp_context_is_retrieved_only_on_explicit_selection(self):
        server = {"id": "web", "revision": LEGACY, "transport": {"http": {"url": self.origin + "/mcp"}}}
        self.config(mcp_servers=[server])

        def context(*command):
            result = self.execute("mcp", *command)
            self.assertEqual(result.returncode, 0, (result.stderr, self.server.requests))
            self.assertEqual(result.stderr, b"")
            return json.loads(result.stdout)

        for kind, identity in (("resource", "fixture://sample"), ("resource_template", "fixture://{name}"),
                               ("prompt", "explain")):
            page = context("list", kind, "web")
            self.assertEqual(page["items"][0]["reference"], {"server": "web", "kind": kind, "id": identity})

        resource = context("get", "resource_template", "web", "fixture://{name}",
                           "--arguments", '{"name":"sample"}')
        self.assertEqual(resource["reference"], {"server": "web", "kind": "resource", "id": "fixture://sample"})
        self.assertEqual((resource["mime"], resource["encoding"], resource["bytes"]),
                         ("text/plain", "utf8", "resource text"))
        binary = context("get", "resource", "web", "fixture://binary")
        self.assertEqual((binary["mime"], binary["encoding"], binary["bytes"]),
                         ("application/octet-stream", "base64", "/wA="))
        prompt = context("get", "prompt", "web", "explain", "--arguments", '{"subject":"the fixture"}')
        self.assertEqual(prompt["reference"], {"server": "web", "kind": "prompt", "id": "explain"})
        self.assertEqual(json.loads(prompt["bytes"])["messages"][0]["content"]["text"], "Explain the fixture")
        self.assertEqual(self.provider_requests(), [])

    def test_modern_http_mcp(self):
        server = {"id": "web", "revision": MODERN, "transport": {"http": {"url": self.origin + "/modern"}}}
        self.config(mcp_servers=[server], enabled_tools=["mcp_web_lookup"], permissions="allow")
        result = self.execute("run", "--prompt", "call mcp_web_lookup")
        self.assertEqual(result.returncode, 0, (result.stderr, result.stdout, self.server.requests))
        self.assertIn(b"loopback tool result", result.stdout)
        self.assertEqual(result.stderr, b"")

    def test_configured_executable_reads_arguments_and_environment(self):
        script = self.directory / "tool.py"
        script.write_text(
            "import json, os, sys\n"
            "assert json.load(sys.stdin) == {}\n"
            "print(json.dumps({'content': os.environ['FOO_TOOL_VALUE']}))\n",
            encoding="utf-8",
        )
        self.config(enabled_tools=["fixture_exec"], permissions="allow", custom_tools=[{
            "name": "fixture_exec", "description": "Result from explicit environment",
            "schema": {"type": "object"},
            "argv": [sys.executable, str(script)],
            "environment": [{"name": "FOO_TOOL_VALUE", "value": "custom result"}],
        }])
        self.success(("run", "--prompt", "call fixture_exec"), "Observed custom result\n")

    def test_rpc_can_run_multiple_correlated_prompts(self):
        with subprocess.Popen(
            self.argv("rpc"), cwd=self.directory, env=self.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as child:
            reader = Reader(child.stdout)
            try:
                for index in range(1, 3):
                    request = {"version": 1, "id": str(index), "command": "prompt", "prompt": str(index)}
                    child.stdin.write((json.dumps(request) + "\n").encode())
                    child.stdin.flush()
                    result = reader.until(lambda row: row["type"] == "result")
                    self.assertEqual((result["id"], result["run"], result["outcome"]["reason"]),
                                     (str(index), index, "completed"))
                child.stdin.close()
                reader.collect()
                self.assertEqual(child.wait(timeout=TIMEOUT), 0)
                self.assertEqual(child.stderr.read(), b"")
                self.assertEqual([row["id"] for row in reader.rows if row["type"] == "result"], ["1", "2"])
            finally:
                if child.poll() is None:
                    child.kill()

    def acp(self, capabilities=None):
        peer = Peer(self.binary, self, None, self.argv("acp")[1:], None)
        self.addCleanup(peer.cleanup)
        result = peer.result(peer.request("initialize", {
            "protocolVersion": 1, "clientCapabilities": capabilities or {},
        }))
        self.assertEqual(result["protocolVersion"], 1)
        self.assertTrue(result["agentCapabilities"]["mcpCapabilities"]["http"])
        self.assertFalse(result["agentCapabilities"]["mcpCapabilities"].get("sse", False))
        return peer

    def test_acp_http_mcp_and_editor_server_policy(self):
        url = self.origin + "/mcp"
        self.config(mcp_servers=[{"id": "web", "revision": LEGACY, "transport": {"http": {"url": url}}}],
                    enabled_tools=["mcp_web_lookup"], permissions="allow")
        peer = self.acp()
        descriptor = {"type": "http", "name": "web", "url": url, "headers": []}
        peer.result(peer.request("session/new", {
            "cwd": str(self.directory), "mcpServers": [{**descriptor, "url": url + "/unknown"}],
        }), error=True)
        self.assertEqual(self.server.requests, [])
        session = peer.session(self.directory, [descriptor])
        updates = peer.wait_for_turn(peer.prompt(session, "call mcp_web_lookup"), session)
        self.assertIn("loopback tool result", agent_text(updates))
        self.assertEqual([req["method"] for path, req in self.server.requests if path == "/mcp"],
                         ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        peer.close_input()
        self.assertEqual(peer.join(), b"")

    def test_acp_permission_and_editor_read(self):
        (self.directory / "sample.txt").write_text("disk content", encoding="utf-8")
        self.config(enabled_tools=["read"], files_backend="client", permissions="ask")
        peer = self.acp({"fs": {"readTextFile": True}})
        session = peer.session(self.directory)
        request = peer.prompt(session, "call read")
        approval = peer.expect_request("session/request_permission", session)
        option = next(item["optionId"] for item in approval["params"]["options"] if item["kind"] == "allow_once")
        peer.reply(approval, {"outcome": {"outcome": "selected", "optionId": option}})
        reading = peer.expect_request("fs/read_text_file", session)
        self.assertEqual(Path(reading["params"]["path"]), self.directory / "sample.txt")
        peer.reply(reading, {"content": "unsaved editor text"})
        self.assertEqual(agent_text(peer.wait_for_turn(request, session)), "Observed unsaved editor text")
        peer.close_input()
        self.assertEqual(peer.join(), b"")

    def test_acp_terminal_receives_explicit_process_environment(self):
        environment = [{"name": "FIXTURE_ONLY", "value": "fixture-value"}]
        self.config(enabled_tools=["exec"], process_backend="client", permissions="allow",
                    process={"environment": environment})
        peer = self.acp({"terminal": True})
        session = peer.session(self.directory)
        turn = peer.prompt(session, "call exec")
        create = peer.expect_request("terminal/create", session)
        self.assertEqual(create["params"]["command"], "fixture")
        self.assertEqual(create["params"]["args"], ["--flag"])
        self.assertEqual(create["params"]["env"], environment)
        terminal = "editor-terminal"
        peer.reply(create, {"terminalId": terminal})
        for method, response in [
            ("terminal/wait_for_exit", {"exitCode": 0}),
            ("terminal/output", {"output": "editor output", "truncated": False}),
            ("terminal/release", {}),
        ]:
            request = peer.expect_request(method, session)
            self.assertEqual(request["params"]["terminalId"], terminal)
            peer.reply(request, response)
        self.assertEqual(agent_text(peer.wait_for_turn(turn, session)), "Observed editor output")
        peer.close_input()
        self.assertEqual(peer.join(), b"")

    def test_tui_terminal_and_plain_fallback(self):
        self.success(("tui",), "Reply to redirected\n", b"redirected\n")
        peer = TerminalPeer(self.argv("tui"), 64, 12, self.env)
        self.addCleanup(peer.close)
        peer.expect("Ready")
        peer.resize(43, 8)
        start = peer.mark()
        peer.send("term 雪\r")
        peer.expect("Reply to term", start=start)
        peer.send(b"\x04")
        self.assertEqual(peer.wait(), 0, peer.capture()[-800:])
        if os.name != "nt":
            self.assertTrue(peer.device.mode_restored())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", type=Path)
    parser.add_argument("--stdio-peer", type=Path)
    args = parser.parse_args()
    if args.stdio_peer:
        stdio_peer(args.stdio_peer)
    elif args.binary:
        Production.binary = args.binary.resolve()
        unittest.main(argv=[sys.argv[0], "-v"])
    else:
        parser.error("Pass the production binary to test")
