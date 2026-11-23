import json
import os
from pathlib import Path
import subprocess
import sys
import time


def read():
    line = sys.stdin.buffer.readline()
    assert line, "unexpected stdin EOF"
    return json.loads(line)


def encode(message):
    return (json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False) + "\n").encode()


def write(*messages):
    sys.stdout.buffer.write(b"".join(encode(message) for message in messages))
    sys.stdout.buffer.flush()


def fragmented(message):
    data = encode(message)
    byte = data.index("雪".encode())
    for segment in [data[:5], data[5 : byte + 1], data[byte + 1 : -1], data[-1:]]:
        sys.stdout.buffer.write(segment)
        sys.stdout.buffer.flush()
        time.sleep(0.015)


def response(request, result):
    return {"id": request["id"], "result": result}


def notify(method, **params):
    return {"method": method, "params": params}


def check_cancel(request):
    message = read()
    assert message == {
        "jsonrpc": "2.0",
        "method": "notifications/cancelled",
        "params": {"requestId": request["id"]},
    }, message


def eof():
    assert not sys.stdin.buffer.readline(), "unexpected extra wire message"
    Path("stdin-eof").touch()


def modern():
    discover = read()
    assert discover["method"] == "server/discover", discover
    assert discover["params"]["_meta"] == {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {},
    }, discover
    fragmented(response(discover, {"name": "雪\nstdio"}))

    subscription = read()
    assert subscription["method"] == "subscriptions/listen", subscription
    params = {"_meta": {"io.modelcontextprotocol/subscriptionId": subscription["id"]}}
    write(notify("notifications/subscriptions/acknowledged", **params,
                 notifications={"toolsListChanged": True}))
    regular = read()
    assert regular["method"] == "tools/list" and type(regular["id"]) is int, regular
    assert type(subscription["id"]) is str and subscription["id"] == str(regular["id"])
    write(
        notify("notifications/tools/list_changed", **params),
        response(regular, {"tools": []}),
    )
    failed = read()
    write({"id": failed["id"], "error": {"code": -32602, "message": "bad request\n雪",
                                         "data": {"fixture": True}}})
    check_cancel(subscription)
    write(response(subscription, {"resultType": "complete", **params}))
    follow_up = read()
    write(response(follow_up, {}))

    second = read()
    assert second["method"] == "subscriptions/listen"
    params = {"_meta": {"io.modelcontextprotocol/subscriptionId": second["id"]}}
    write(notify("notifications/subscriptions/acknowledged", **params),
          notify("notifications/cancelled", requestId=second["id"]),
          response(second, {"resultType": "complete", **params}))
    follow_up = read()
    write(response(follow_up, {}))
    eof()


def legacy():
    initialize = read()
    assert initialize["id"] == 1
    assert initialize["method"] == "initialize", initialize
    assert initialize["params"]["protocolVersion"] == "2025-11-25", initialize
    write(
        notify("notifications/message", data="early notification"),
        {"id": initialize["id"], "method": "ping"},
        {"id": "reverse", "method": "sampling/createMessage"},
    )
    assert read() == {"jsonrpc": "2.0", "id": 1, "result": {}}
    rejection = read()
    assert rejection["id"] == "reverse" and rejection["error"]["code"] == -32601, rejection
    write(response(initialize, {"protocolVersion": "2025-11-25", "capabilities": {}}))
    assert read() == {"jsonrpc": "2.0", "method": "notifications/initialized"}
    regular = read()
    assert regular["method"] == "tools/list"
    sys.stderr.buffer.write(b"x" * (512 * 1024) + b"fixture-stderr-tail\n")
    sys.stderr.buffer.flush()
    write(notify("notifications/tools/list_changed"), response(regular, {"tools": []}))
    for _ in range(10):
        time.sleep(0.02)
        write(notify("notifications/resources/list_changed"))
    eof()


def interrupted(slow):
    if slow:
        ready = read()
        assert ready["method"] == "ping"
        write(response(ready, {}))
    request = read()
    assert request["method"] == "tools/call" and request["id"] == "7"
    late = response(request, {"late": True})
    if slow:
        frame = encode(late)
        sys.stdout.buffer.write(frame[:9])
        sys.stdout.buffer.flush()
    else:
        write(notify("notifications/progress", progress=1, total=5, progressToken="fixture"))
    check_cancel(request)
    if slow:
        sys.stdout.buffer.write(frame[9:])
        sys.stdout.buffer.flush()
    else:
        write(late)
    follow_up = read()
    assert follow_up["method"] == "ping" and type(follow_up["id"]) is int
    write(response(follow_up, {"late": False}))
    eof()


def bad(mode):
    request = read()
    if mode == "malformed":
        sys.stdout.buffer.write(b'{"jsonrpc": \n')
    elif mode == "wrong-id":
        write({"id": str(request["id"]), "result": {}})
    elif mode == "truncated":
        sys.stdout.buffer.write(encode(response(request, {}))[:-1])
    elif mode == "oversized":
        write(response(request, {"oversized": "X" * 2048}))
    elif mode == "death":
        sys.exit(13)
    sys.stdout.buffer.flush()


def heartbeat():
    for _ in range(400):
        with Path("heartbeat").open("ab", buffering=0) as file:
            file.write(b".")
        time.sleep(0.025)


def tree():
    child = subprocess.Popen(
        [sys.executable, __file__, "heartbeat"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    Path("descendant-pid").write_text(str(child.pid), encoding="ascii")
    deadline = time.monotonic() + 4
    heartbeat_file = Path("heartbeat")
    while not heartbeat_file.is_file() or heartbeat_file.stat().st_size < 3:
        assert time.monotonic() < deadline, "heartbeat did not start"
        time.sleep(0.01)
    request = read()
    assert request["method"] == "tools/call"
    write(notify("notifications/progress", progress=1, progressToken="fixture"))
    check_cancel(request)
    follow_up = read()
    assert follow_up["method"] == "ping"
    write(response(follow_up, {}))
    eof()
    time.sleep(60)


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "heartbeat":
        heartbeat()
    else:
        assert sys.argv[2:] == ["one argument", "quote\"$ &"]
        assert os.environ["FOO_MCP_FIXTURE"] == "child"
        assert Path("expected-cwd").is_file()
        if mode == "modern":
            modern()
        elif mode == "legacy":
            legacy()
        elif mode in {"cancel", "slow"}:
            interrupted(mode == "slow")
        elif mode in {"malformed", "wrong-id", "truncated", "oversized", "death"}:
            bad(mode)
        elif mode == "tree":
            tree()
        elif mode == "blocked-stdin":
            time.sleep(60)
        else:
            raise RuntimeError(mode)
