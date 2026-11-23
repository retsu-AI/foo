import contextlib
import http.client
import json
from pathlib import Path
import socket
import subprocess
import sys
import unittest


WATCHDOG = 12


@contextlib.contextmanager
def accept(listener):
    peer, _ = listener.accept()
    with peer, peer.makefile("rb") as incoming:
        peer.settimeout(WATCHDOG)
        yield peer, incoming


def respond(peer, status, body=b"", headers=b""):
    peer.sendall(
        b"HTTP/1.1 " + status
        + b"\r\nConnection: close\r\nContent-Length: %d\r\n" % len(body)
        + headers + b"\r\n" + body
    )


def result(request_id, value):
    return json.dumps(
        {"jsonrpc": "2.0", "id": request_id, "result": value}, separators=(",", ":")
    ).encode()


def sse_chunk(peer, data):
    peer.sendall(b"%x\r\n" % len(data) + data + b"\r\n")


class HttpFixtures(unittest.TestCase):
    @contextlib.contextmanager
    def probe(self, mode):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(WATCHDOG)
            url = f"http://127.0.0.1:{listener.getsockname()[1]}/mcp"
            with subprocess.Popen(
                [PROBE, mode, url], stdout=subprocess.PIPE, stderr=subprocess.PIPE
            ) as process:
                try:
                    yield listener
                    stdout, stderr = process.communicate(timeout=WATCHDOG)
                except BaseException as err:
                    if process.poll() is None:
                        process.kill()
                    _, stderr = process.communicate(timeout=WATCHDOG)
                    if stderr:
                        err.add_note(stderr.decode(errors="replace"))
                    raise
                self.assertEqual(process.returncode, 0, stderr.decode(errors="replace"))
                self.assertEqual(stdout, b"")

            listener.setblocking(False)
            with self.assertRaises(BlockingIOError):
                unexpected, _ = listener.accept()
                unexpected.close()

    def request(self, incoming, verb):
        self.assertEqual(incoming.readline(), verb + b" /mcp HTTP/1.1\r\n")
        headers = http.client.parse_headers(incoming)
        size = int(headers.get("Content-Length", "0"))
        return headers, json.loads(incoming.read(size)) if size else None

    def post(self, incoming, method, expected_id=None):
        headers, body = self.request(incoming, b"POST")
        self.assertEqual(headers["Accept"], "application/json, text/event-stream")
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(body["jsonrpc"], "2.0")
        self.assertEqual(body["method"], method)
        if expected_id is None:
            self.assertNotIn("id", body)
        else:
            self.assertEqual(body["id"], expected_id)
        return headers, body.get("params")

    def modern_headers(self, headers, method, metadata):
        self.assertEqual(headers["Mcp-Method"], method)
        self.assertEqual(
            headers["MCP-Protocol-Version"],
            metadata["io.modelcontextprotocol/protocolVersion"],
        )
        self.assertEqual(headers["MCP-Protocol-Version"], "2026-07-28")
        self.assertEqual(metadata["io.modelcontextprotocol/clientCapabilities"], {})
        self.assertNotIn("MCP-Session-Id", headers)

    def legacy_headers(self, headers):
        self.assertEqual(headers["MCP-Protocol-Version"], "2025-11-25")
        self.assertEqual(headers["MCP-Session-Id"], "native-session")
        self.assertNotIn("Mcp-Method", headers)

    def test_modern_json_and_open_sse_finish_at_the_matching_reply(self):
        with self.probe("modern") as listener:
            with accept(listener) as (peer, incoming):
                headers, params = self.post(incoming, "server/discover", 1)
                self.modern_headers(headers, "server/discover", params["_meta"])
                self.assertNotIn("Mcp-Name", headers)
                respond(
                    peer,
                    b"200 OK",
                    result(1, {
                        "resultType": "complete",
                        "supportedVersions": ["2026-07-28"],
                        "capabilities": {"tools": {}},
                        "_meta": {"io.modelcontextprotocol/serverInfo": {
                            "name": "native-fixture",
                            "version": "1",
                        }},
                    }),
                    b"Content-Type: application/json\r\n"
                    b"MCP-Session-Id: ignored-modern-session\r\n",
                )

            with accept(listener) as (peer, incoming):
                headers, params = self.post(incoming, "tools/call", 2)
                self.modern_headers(headers, "tools/call", params["_meta"])
                self.assertEqual(params["name"], "héllo")
                self.assertEqual(headers["Mcp-Name"], "=?base64?aMOpbGxv?=")
                self.assertEqual(params["arguments"]["region"], " west ")
                self.assertEqual(headers["Mcp-Param-Region"], "=?base64?IHdlc3Qg?=")
                self.assertEqual(params["_meta"]["progressToken"], "http-fixture")
                peer.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                    b"Transfer-Encoding: chunked\r\n\r\n"
                )
                sse_chunk(
                    peer,
                    b'data: {"jsonrpc":"2.0","method":"notifications/progress",'
                    b'"params":{"progressToken":"http-fixture","progress":1}}\r\n\r',
                )
                sse_chunk(
                    peer,
                    b"\ndata: " + result(2, {
                        "resultType": "complete",
                        "content": [{"type": "text", "text": "stream"}],
                    }) + b"\n\n",
                )
                try:
                    self.assertEqual(incoming.read(1), b"")
                except ConnectionResetError:
                    pass

    def test_legacy_resumes_the_tool_by_get_and_tears_down_the_session(self):
        with self.probe("legacy") as listener:
            with accept(listener) as (peer, incoming):
                headers, params = self.post(incoming, "initialize", 1)
                self.assertNotIn("MCP-Protocol-Version", headers)
                self.assertNotIn("MCP-Session-Id", headers)
                self.assertEqual(params["protocolVersion"], "2025-11-25")
                respond(
                    peer,
                    b"200 OK",
                    result(1, {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "native-fixture", "version": "1"},
                    }),
                    b"Content-Type: application/json\r\nMCP-Session-Id: native-session\r\n",
                )

            with accept(listener) as (peer, incoming):
                headers, _ = self.post(incoming, "notifications/initialized")
                self.legacy_headers(headers)
                respond(peer, b"202 Accepted")

            with accept(listener) as (peer, incoming):
                headers, params = self.post(incoming, "tools/call", 2)
                self.legacy_headers(headers)
                self.assertEqual(params["name"], "fixture")
                peer.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                    b"Content-Length: 999\r\nConnection: close\r\n\r\n"
                    b"id: native-checkpoint\ndata:\n\nretry: 0\n\n"
                )

            with accept(listener) as (peer, incoming):
                headers, body = self.request(incoming, b"GET")
                self.legacy_headers(headers)
                self.assertEqual(headers["Accept"], "text/event-stream")
                self.assertEqual(headers["Last-Event-ID"], "native-checkpoint")
                self.assertIsNone(body)
                respond(
                    peer,
                    b"200 OK",
                    b"data: " + result(2, {"content": [{"type": "text", "text": "resumed"}]}) + b"\n\n",
                    b"Content-Type: text/event-stream\r\n",
                )

            with accept(listener) as (peer, incoming):
                headers, body = self.request(incoming, b"DELETE")
                self.legacy_headers(headers)
                self.assertNotIn("Last-Event-ID", headers)
                self.assertIsNone(body)
                respond(peer, b"204 No Content")


if __name__ == "__main__":
    PROBE = str(Path(sys.argv.pop(1)).resolve())
    unittest.main(verbosity=2)
