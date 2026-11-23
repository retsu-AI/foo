"""Exercise the provider probe against a local LiteLLM proxy and a Gemini fixture."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from urllib.error import URLError
from urllib.request import urlopen


SIGNATURE = "dGhvdWdodA=="
GATEWAY_KEY = "sk-foo-local-gateway"


class Gemini(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if ":streamGenerateContent" not in self.path:
            self.send_error(404)
            return
        contents = body["contents"]
        if len(contents) == 1:
            part = {
                "functionCall": {"name": "lookup", "args": {"key": "one"}},
                "thoughtSignature": SIGNATURE,
            }
        else:
            try:
                assistant, result = contents[-2:]
                assert assistant["role"] == "model"
                assert result["role"] == "user"
                call_part, = assistant["parts"]
                result_part, = result["parts"]
                call = call_part.get("functionCall") or call_part["function_call"]
                response = result_part.get("functionResponse") or result_part["function_response"]
                assert call_part.get("thoughtSignature") == SIGNATURE, "Gemini tool history lost its thought signature"
                assert call["name"] == response["name"] == "lookup"
                assert call["id"] == response["id"], "Gemini tool result has the wrong call ID"
                assert response["response"] == {"content": "Fixture value."}
            except AssertionError as exc:
                self.send_error(400, str(exc))
                return
            part = {"text": "Signed tool continuation passed."}
        frame = {
            "candidates": [{
                "index": 0,
                "content": {"role": "model", "parts": [part]},
                "finishReason": "STOP",
            }],
            "usageMetadata": {
                "promptTokenCount": 12,
                "candidatesTokenCount": 7,
                "totalTokenCount": 19,
            },
        }
        payload = ("data: " + json.dumps(frame) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


def wait_for_proxy(child, url):
    for _ in range(150):
        if child.poll() is not None:
            raise RuntimeError("LiteLLM proxy exited during startup")
        try:
            with urlopen(url + "/health/liveliness", timeout=1):
                return
        except URLError:
            time.sleep(0.1)
    raise RuntimeError("LiteLLM proxy did not become ready")


def verify(probe, litellm, upstream):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    environment = {
        **os.environ,
        "FOO_GATEWAY_FIXTURE_KEY": GATEWAY_KEY,
        "LITELLM_LOCAL_MODEL_COST_MAP": "True",
        "LITELLM_TELEMETRY": "False",
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
    }
    with tempfile.TemporaryDirectory() as temp:
        config = Path(temp) / "litellm.yaml"
        config.write_text(json.dumps({
            "model_list": [{
                "model_name": "gemini-fixture",
                "litellm_params": {
                    "model": "gemini/gemini-3.1-pro-preview",
                    "api_base": upstream,
                    "api_key": "fake",
                },
            }],
            "general_settings": {"master_key": GATEWAY_KEY},
            "router_settings": {"num_retries": 0},
        }))
        with (Path(temp) / "proxy.log").open("w+") as log:
            child = subprocess.Popen(
                [litellm, "--config", config, "--host", "127.0.0.1", "--port", str(port)],
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                wait_for_proxy(child, url)
                result = subprocess.run(
                    [probe, "openai_chat", url + "/v1/chat/completions", "gemini-fixture",
                     "FOO_GATEWAY_FIXTURE_KEY", '{"chat_litellm":true}', "fixture-tool"],
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                if result.returncode:
                    raise RuntimeError(result.stdout + result.stderr)
                text, report = result.stdout.splitlines()
                assert text == "Signed tool continuation passed.", result.stdout
                assert json.loads(report)["stop"] == "end_turn"
                print(result.stdout, end="")
            except Exception:
                log.seek(0)
                print(log.read())
                raise
            finally:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe")
    parser.add_argument("litellm")
    args = parser.parse_args()
    with ThreadingHTTPServer(("127.0.0.1", 0), Gemini) as server:
        worker = Thread(target=server.serve_forever)
        worker.start()
        try:
            verify(args.probe, args.litellm, f"http://127.0.0.1:{server.server_port}")
        finally:
            server.shutdown()
            worker.join()


if __name__ == "__main__":
    main()
