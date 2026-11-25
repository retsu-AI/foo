"""A deterministic SSE model peer for the benchmark workloads."""

from contextlib import contextmanager
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from queue import Queue
import threading
import time

# Leave room for the committed messages in the production RPC output queue.
STREAM_PARTS = tuple(f"stream-{index:02d} " for index in range(32))
STREAM_PAUSE_S = 0.001
TURN_PREFIX = "turn-"
TURN_REPLY_CHARS = 2048
LOCAL_FILE = "sample.txt"
LOCAL_CONTENT = "fixture-content\n" * 256
RENDER_TEXT = "".join(f"line {index:03d} of transcript\n" for index in range(128)) + "render-complete"
TOOL_CALL_ID = "read-fixture"


def chunk(delta, finish=None):
    message = {"id": "bench", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
    return f"data: {json.dumps(message)}\n\n".encode()


def answer(text):
    return chunk({"role": "assistant", "content": text}) + chunk({}, "stop") + b"data: [DONE]\n\n"


def request_read():
    return chunk({"role": "assistant", "tool_calls": [{
        "index": 0, "id": TOOL_CALL_ID, "type": "function",
        "function": {"name": "read", "arguments": json.dumps({"path": LOCAL_FILE})},
    }]}) + chunk({}, "tool_calls") + b"data: [DONE]\n\n"


@dataclass
class ObservedRequest:
    prompt: str
    messages: int
    body_bytes: int
    server_work_ns: int
    frame_ns: list[int] = field(default_factory=list)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        received = time.perf_counter_ns()
        if self.path != "/chat":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(body)
        messages = request["messages"]
        prompt = next(message["content"] for message in reversed(messages) if message["role"] == "user")
        tool_result = messages[-1] if messages[-1]["role"] == "tool" else None
        pause = False
        if tool_result is not None:
            self.server.tool_results.put(tool_result)
            frames = [answer("read-complete")]
        elif prompt == "read":
            frames = [request_read()]
        elif prompt == "stream":
            frames = [chunk({"content": part}) for part in STREAM_PARTS]
            frames.append(chunk({}, "stop") + b"data: [DONE]\n\n")
            pause = True
        elif prompt == "render":
            frames = [answer(RENDER_TEXT)]
        elif prompt == "stall":
            frames = [chunk({"content": "waiting-on-fixture"})]
        elif prompt.startswith(TURN_PREFIX):
            frames = [answer(f"done:{prompt[:8]}:" + "r" * TURN_REPLY_CHARS)]
        else:
            frames = [answer(f"done:{prompt}")]

        server_work_ns = time.perf_counter_ns() - received
        observation = ObservedRequest(prompt, len(messages), len(body), server_work_ns)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            length = sum(map(len, frames))
            self.send_header("Content-Length", str(length + 1 if prompt == "stall" else length))
            self.end_headers()
            for index, frame in enumerate(frames):
                if pause and index:
                    time.sleep(STREAM_PAUSE_S)
                observation.frame_ns.append(time.perf_counter_ns())
                self.wfile.write(frame)
                self.wfile.flush()
            if prompt == "stall":
                self.server.stalled.set()
                self.server.release_stall.wait(timeout=15)
        finally:
            self.server.observations.put(observation)


@contextmanager
def model_peer():
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        server.observations = Queue()
        server.tool_results = Queue()
        server.stalled = threading.Event()
        server.release_stall = threading.Event()
        worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
        worker.start()
        try:
            yield server
        finally:
            server.release_stall.set()
            server.shutdown()
            worker.join()
