import base64
import contextlib
import http.client
import os
from pathlib import Path
import queue
import socket
import ssl
import subprocess
import sys
import threading
import unittest

TLS = Path(__file__).resolve().parent / "tls"
WATCHDOG = 10
AUTH = "Bearer origin-fixture"
COOKIE = "session=origin-fixture"
PROXY_AUTH = "Basic " + base64.b64encode(b"fixture-user:fixture-password").decode()


@contextlib.contextmanager
def listen():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.bind(("127.0.0.1", 0))
        server.listen()
        server.settimeout(WATCHDOG)
        yield server


def accept(server):
    peer, _ = server.accept()
    peer.settimeout(WATCHDOG)
    return peer


def url(server, scheme="http", host="127.0.0.1", path="/fixture"):
    return f"{scheme}://{host}:{server.getsockname()[1]}{path}"


def read_head(stream):
    line = stream.readline()
    return line, http.client.parse_headers(stream) if line else {}


def read_body(stream, headers):
    if "Content-Length" in headers:
        return stream.read(int(headers["Content-Length"]))
    if headers.get("Transfer-Encoding") != "chunked":
        return b""
    body = bytearray()
    while size := int(stream.readline(), 16):
        body.extend(stream.read(size))
        if stream.read(2) != b"\r\n":
            raise AssertionError("invalid upload chunk terminator")
    if stream.readline() != b"\r\n":
        raise AssertionError("invalid upload trailer terminator")
    return bytes(body)


def respond(peer, body, *, status=b"200 OK", headers=b"", close=False):
    head = b"HTTP/1.1 " + status + b"\r\n"
    head += b"Content-Length: %d\r\n" % len(body)
    if close:
        head += b"Connection: close\r\n"
    peer.sendall(head + headers + b"\r\n" + body)


def through_headers(peer):
    data = bytearray()
    while not data.endswith(b"\r\n\r\n"):
        byte = peer.recv(1)
        if not byte or len(data) == 8192:
            raise AssertionError("missing tunneled request headers")
        data.extend(byte)
    return data


class Transport(unittest.TestCase):
    @contextlib.contextmanager
    def probe(self, mode, target, extra="", *, ca=None, env=None):
        command = [PROBE, mode, target, extra]
        if ca:
            command.append(str(TLS / ca))
        with subprocess.Popen(
            command,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ) as process:
            try:
                yield process
            except BaseException as err:
                if process.poll() is None:
                    process.kill()
                _, stderr = process.communicate(timeout=WATCHDOG)
                if stderr:
                    err.add_note(stderr.decode(errors="replace"))
                raise
            else:
                try:
                    stdout, stderr = process.communicate(timeout=WATCHDOG)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=WATCHDOG)
                    raise
                self.assertEqual(process.returncode, 0, stderr.decode(errors="replace"))
                self.assertEqual(stdout, b"")
                self.assertNotIn(b"origin-fixture", stderr)
                self.assertNotIn(b"fixture-password", stderr)

    def body_arrived(self, process):
        lines = queue.SimpleQueue()
        thread = threading.Thread(
            target=lambda: lines.put(process.stdout.readline()), daemon=True
        )
        thread.start()
        try:
            self.assertEqual(lines.get(timeout=WATCHDOG), b"body\n")
        except queue.Empty:
            process.kill()
            self.fail("probe did not stream the first fragment")
        finally:
            thread.join(timeout=WATCHDOG)

    def signal(self, process):
        process.stdin.write(b"!")
        process.stdin.flush()

    def recover(self, server):
        with accept(server) as peer, peer.makefile("rb") as stream:
            self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
            respond(peer, b"recovered", close=True)

    def assert_disconnected(self, peer):
        try:
            self.assertEqual(peer.recv(1), b"")
        except ConnectionResetError:
            pass

    def test_streaming_and_reuse_with_ambient_proxy_ignored(self):
        with listen() as origin, listen() as unused_proxy:
            env = os.environ.copy()
            env.update({
                "http_proxy": url(unused_proxy, path=""),
                "HTTP_PROXY": url(unused_proxy, path=""),
                "all_proxy": url(unused_proxy, path=""),
                "ALL_PROXY": url(unused_proxy, path=""),
                "no_proxy": "",
                "NO_PROXY": "",
            })
            with self.probe("stream", url(origin), env=env) as process:
                with accept(origin) as peer, peer.makefile("rb") as stream:
                    line, headers = read_head(stream)
                    self.assertEqual(line, b"POST /fixture HTTP/1.1\r\n")
                    self.assertEqual(headers["Content-Length"], "12")
                    self.assertEqual(read_body(stream, headers), b"known upload")
                    peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nalpha")
                    self.body_arrived(process)
                    peer.sendall(b" beta")
                    self.signal(process)

                    line, headers = read_head(stream)
                    self.assertEqual(line, b"POST /fixture HTTP/1.1\r\n")
                    self.assertEqual(headers["Transfer-Encoding"], "chunked")
                    self.assertEqual(read_body(stream, headers), b"chunked upload")
                    peer.sendall(
                        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                        b"7\r\nchunked\r\n6\r\n reply\r\n0\r\n\r\n"
                    )
                self.assert_no_accept(unused_proxy)

    def test_reused_connection_closes_after_observed_post(self):
        with listen() as server, self.probe("replay", url(server)):
            with accept(server) as peer, peer.makefile("rb") as stream:
                self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
                respond(peer, b"seed")
                line, headers = read_head(stream)
                self.assertEqual(line, b"POST /fixture HTTP/1.1\r\n")
                self.assertEqual(read_body(stream, headers), b"")
            while True:
                with accept(server) as peer, peer.makefile("rb") as stream:
                    line, _ = read_head(stream)
                    if not line:
                        continue
                    self.assertEqual(line, b"GET /fixture HTTP/1.1\r\n")
                    respond(peer, b"recovered", close=True)
                    break
            self.assert_no_accept(server)

    def test_streams_large_body_with_fixed_client_allocator(self):
        with listen() as server, self.probe("large", url(server)) as process:
            with accept(server) as peer, peer.makefile("rb") as stream:
                self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
                peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2097152\r\n\r\n")
                block = b"z" * 16384
                peer.sendall(block)
                self.body_arrived(process)
                for _ in range(127):
                    peer.sendall(block)

    def test_redirect_and_http_error_are_caller_visible(self):
        with listen() as first, listen() as second:
            with self.probe("redirect", url(first), url(second)):
                with accept(first) as peer, peer.makefile("rb") as stream:
                    line, headers = read_head(stream)
                    self.assertEqual(line, b"GET /fixture HTTP/1.1\r\n")
                    self.assertEqual(headers["Authorization"], AUTH)
                    self.assertEqual(headers["Cookie"], COOKIE)
                    respond(
                        peer,
                        b"",
                        status=b"307 Temporary Redirect",
                        headers=b"Location: " + url(second).encode() + b"\r\n",
                        close=True,
                    )
                with accept(second) as peer, peer.makefile("rb") as stream:
                    line, headers = read_head(stream)
                    self.assertEqual(line, b"GET /fixture HTTP/1.1\r\n")
                    self.assertIsNone(headers["Authorization"])
                    self.assertIsNone(headers["Cookie"])
                    respond(
                        peer, b"later", status=b"429 Too Many Requests",
                        headers=b"Retry-After: 3\r\n", close=True,
                    )

    def check_connect(self, stream, origin):
        line, headers = read_head(stream)
        self.assertEqual(
            line, f"CONNECT 127.0.0.1:{origin.getsockname()[1]} HTTP/1.1\r\n".encode()
        )
        self.assertEqual(headers["Proxy-Authorization"], PROXY_AUTH)
        self.assertIsNone(headers["Authorization"])
        self.assertIsNone(headers["Cookie"])

    def test_explicit_proxy_scopes_connect_credentials(self):
        with listen() as proxy, listen() as origin:
            env = os.environ.copy()
            env.update({"NO_PROXY": "*", "no_proxy": "*"})
            with self.probe("proxy", url(origin), url(proxy, path=""), env=env):
                with accept(proxy) as tunnel, tunnel.makefile("rb") as control:
                    self.check_connect(control, origin)
                    upstream = socket.create_connection(origin.getsockname(), timeout=WATCHDOG)
                    with upstream, accept(origin) as peer, peer.makefile("rb") as stream:
                        tunnel.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                        upstream.sendall(through_headers(tunnel))
                        line, headers = read_head(stream)
                        self.assertEqual(line, b"GET /fixture HTTP/1.1\r\n")
                        self.assertEqual(headers["Authorization"], AUTH)
                        self.assertEqual(headers["Cookie"], COOKIE)
                        self.assertIsNone(headers["Proxy-Authorization"])
                        respond(peer, b"through tunnel", close=True)
                        peer.shutdown(socket.SHUT_WR)
                        while data := upstream.recv(4096):
                            tunnel.sendall(data)

    def test_rejected_proxy_auth_keeps_origin_unsent(self):
        with listen() as proxy, listen() as origin:
            with self.probe("proxy_rejected", url(origin), url(proxy, path="")):
                with accept(proxy) as peer, peer.makefile("rb") as stream:
                    self.check_connect(stream, origin)
                    respond(
                        peer, b"", status=b"407 Proxy Authentication Required",
                        headers=b'Proxy-Authenticate: Basic realm="fixture"\r\n', close=True,
                    )
            self.assert_no_accept(origin)

    def test_proxy_connect_headers_count_toward_budget(self):
        with listen() as proxy, listen() as origin:
            with self.probe("proxy_limited", url(origin), url(proxy, path="")):
                with accept(proxy) as peer, peer.makefile("rb") as stream:
                    self.check_connect(stream, origin)
                    peer.sendall(
                        b"HTTP/1.1 200 Connection Established\r\n"
                        b"X-Large: " + b"x" * 128 + b"\r\n\r\n"
                    )
                    self.assert_disconnected(peer)
            self.assert_no_accept(origin)

    def test_tls_chain_and_hostname_verification(self):
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        # The committed private key is for this localhost fixture only.
        tls.load_cert_chain(TLS / "loopback.pem", TLS / "loopback-key.pem")
        with listen() as server:
            loopback = url(server, "https", "localhost")
            with self.probe("trusted", loopback, ca="ca.pem"):
                with accept(server) as peer, tls.wrap_socket(peer, server_side=True) as secure:
                    with secure.makefile("rb") as stream:
                        self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
                        respond(secure, b"trusted", close=True)

            for target, ca in (
                (loopback, "unrelated-ca.pem"),
                (url(server, "https"), "ca.pem"),
            ):
                with self.subTest(ca=ca, url=target):
                    with self.probe("tls_failure", target, ca=ca):
                        with accept(server) as peer:
                            try:
                                with tls.wrap_socket(peer, server_side=True) as secure:
                                    self.assert_disconnected(secure)
                            except (ssl.SSLError, ConnectionResetError, BrokenPipeError):
                                pass
                    self.assert_no_accept(server)

    def test_refused_connection_is_unsent(self):
        with listen() as recovery:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as refused:
                refused.bind(("127.0.0.1", 0))
                target = url(refused)
            with self.probe("refused", target, url(recovery)):
                self.recover(recovery)

    def test_first_byte_deadline(self):
        with listen() as stalled, listen() as recovery:
            with self.probe("first_byte_deadline", url(stalled), url(recovery)):
                with accept(stalled) as peer, peer.makefile("rb") as stream:
                    self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
                    self.recover(recovery)
                    self.assert_disconnected(peer)

    def test_cancel_stalled_body(self):
        with listen() as stalled, listen() as recovery:
            with self.probe("body_cancel", url(stalled), url(recovery)) as process:
                with accept(stalled) as peer, peer.makefile("rb") as stream:
                    self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
                    peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\npart")
                    self.body_arrived(process)
                    self.signal(process)
                    self.recover(recovery)
                    self.assert_disconnected(peer)

    def test_cancel_and_deadline_during_stalled_tls_handshake(self):
        for mode in ("tls_cancel", "tls_deadline"):
            with self.subTest(mode=mode), listen() as stalled, listen() as recovery:
                with self.probe(
                    mode, url(stalled, "https"), url(recovery), ca="ca.pem"
                ) as process:
                    with accept(stalled) as peer, peer.makefile("rb") as stream:
                        record = stream.read(5)
                        self.assertEqual(len(record), 5)
                        self.assertEqual(record[0], 0x16)
                        size = int.from_bytes(record[3:], "big")
                        self.assertEqual(len(stream.read(size)), size)
                        if mode == "tls_cancel":
                            self.signal(process)
                        self.recover(recovery)
                        self.assert_disconnected(peer)

    def test_abrupt_disconnect_after_partial_body(self):
        with listen() as interrupted, listen() as recovery:
            with self.probe("truncated", url(interrupted), url(recovery)):
                with accept(interrupted) as peer, peer.makefile("rb") as stream:
                    self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
                    peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\npart")
                self.recover(recovery)

    def test_limits_and_recovery(self):
        with listen() as limited, listen() as recovery:
            with self.probe("limits", url(limited), url(recovery)) as process:
                aggregate_bytes = (b"X-Large: " + b"x" * 64 + b"\r\n") * 2
                for extra in (aggregate_bytes, b"X: a\r\n" * 5):
                    with accept(limited) as peer, peer.makefile("rb") as stream:
                        self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
                        respond(peer, b"", headers=extra, close=True)
                with accept(limited) as peer, peer.makefile("rb") as stream:
                    self.assertEqual(read_head(stream)[0], b"GET /fixture HTTP/1.1\r\n")
                    peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\npart")
                    self.body_arrived(process)
                    peer.sendall(b"more")
                with accept(limited) as peer, peer.makefile("rb") as stream:
                    line, headers = read_head(stream)
                    self.assertEqual(line, b"POST /fixture HTTP/1.1\r\n")
                    self.assertEqual(headers["Transfer-Encoding"], "chunked")
                    partial = stream.read()
                    self.assertNotIn(b"!", partial)
                    self.assertFalse(partial.endswith(b"0\r\n\r\n"))
                self.recover(recovery)
            self.assert_no_accept(limited)

    def assert_no_accept(self, server):
        server.setblocking(False)
        try:
            with self.assertRaises(BlockingIOError):
                accepted, _ = server.accept()
                accepted.close()
        finally:
            server.settimeout(WATCHDOG)


if __name__ == "__main__":
    PROBE = str(Path(sys.argv.pop(1)).resolve())
    unittest.main(verbosity=2)
