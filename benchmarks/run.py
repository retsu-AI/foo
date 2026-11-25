"""Measure the production foo binary against fixed native workloads."""

import argparse
from contextlib import contextmanager, suppress
import hashlib
import json
import math
import os
from pathlib import Path
import platform
from queue import Empty, Queue
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import zlib

from loopback import (
    LOCAL_CONTENT, LOCAL_FILE, RENDER_TEXT, STREAM_PARTS, STREAM_PAUSE_S,
    TOOL_CALL_ID, TURN_PREFIX, TURN_REPLY_CHARS, model_peer,
)
from process_memory import process_memory

TERMINAL_FIXTURES = Path(__file__).resolve().parents[1] / "tests" / "platform-terminal"
sys.path.insert(0, str(TERMINAL_FIXTURES))
from pty_driver import TerminalPeer

TIMEOUT = 15
TURN_COUNT = 32
TURN_REQUEST_CHARS = 1024
IDLE_PAUSE_S = 0.05
TUI_COLUMNS = 80
TUI_ROWS = 18
LIMITS = {"model_turns": 4, "tool_calls": 4, "tool_output_bytes": 64 * 1024, "transcript_bytes": 2 * 1024 * 1024}
SESSION_LIMITS = {"max_record_bytes": 64 * 1024, "max_journal_bytes": 4 * 1024 * 1024, "max_context_bytes": 1024 * 1024}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def take(items):
    try:
        return items.get(timeout=TIMEOUT)
    except Empty as error:
        raise RuntimeError("benchmark peer did not respond") from error


def sha256(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def write_profile(directory, server, *, tool=False, journal=False):
    profile = directory / "profile.json"
    settings = {
        "providers": {"local": {
            "family": "openai_chat",
            "base_url": f"http://127.0.0.1:{server.server_port}",
            "models": {"benchmark": {}},
        }},
        "model": "local/benchmark",
        "cwd": str(directory),
        "limits": LIMITS,
    }
    if tool:
        (directory / LOCAL_FILE).write_bytes(LOCAL_CONTENT.encode())
        settings.update({"enabled_tools": ["read"], "permissions": "allow"})
    if journal:
        destination = directory / "session"
        destination.mkdir(mode=0o700)
        settings["session"] = {"directory": str(destination), "limits": SESSION_LIMITS}
    profile.write_text(json.dumps(settings), encoding="utf-8")
    return profile


def validate_journal(path, prompts):
    payload = path.read_bytes()
    require(payload.endswith(b"\n"), "journal ends with a complete record")
    records = []
    for sequence, line in enumerate(payload.splitlines(), 1):
        frame = json.loads(line)
        body = line.split(b'"payload":', 1)[1][:-1]
        require(frame["crc32"] == f"{zlib.crc32(body):08x}", "journal record checksum mismatch")
        require(frame["payload"]["sequence"] == sequence, "journal sequence mismatch")
        records.append(frame["payload"]["record"])

    committed_prompts, finished = [], 0
    for record in records:
        message = record.get("message")
        if message and message["role"] == "user":
            committed_prompts.append("".join(block["text"] for block in message["blocks"]))
        if record.get("finished", {}).get("reason") == "completed":
            finished += 1
    require(committed_prompts == prompts and finished == len(prompts), "journal must contain all prompts and successful outcomes")
    return len(payload)


class Rpc:
    def __init__(self, process):
        self.process = process
        self.lines = Queue()
        self.reader = threading.Thread(target=self.drain)
        self.reader.start()

    def drain(self):
        try:
            for line in self.process.stdout:
                self.lines.put((time.perf_counter_ns(), line))
        finally:
            self.lines.put(None)

    def prompt(self, request_id, prompt, expected):
        before = time.perf_counter_ns()
        self.process.stdin.write((json.dumps({
            "version": 1, "id": request_id, "command": "prompt", "prompt": prompt,
        }) + "\n").encode())
        self.process.stdin.flush()
        first = take(self.lines)
        require(first is not None, "stdout closed before prompt acceptance")
        accepted_at, line = first
        accepted = json.loads(line)
        require(accepted["type"] == "accepted" and accepted["id"] == request_id, f"prompt was not accepted: {accepted}")
        events = []
        while True:
            item = take(self.lines)
            require(item is not None, "stdout closed before terminal result")
            at, line = item
            row = json.loads(line)
            require(row["version"] == 1 and row["id"] == request_id and row["run"] == accepted["run"],
                    "RPC reply correlation mismatch")
            if row["type"] == "result":
                require(row["outcome"]["reason"] == "completed", f"run failed: {row['outcome']}")
                require(not row["outcome"]["uncertain_effects"], "run reported an uncertain effect")
                break
            require(row["type"] == "event", f"unexpected reply: {row}")
            events.append((at, row["event"]))
        messages = [event["message_committed"]["message"] for _, event in events if "message_committed" in event]
        assistant = "".join(block["text"] for message in messages if message["role"] == "assistant"
                            for block in message["blocks"] if "text" in block)
        require(assistant == expected, "committed assistant text differs from fixture answer")
        return {"submit_to_result_ns": at - before, "accepted_to_result_ns": at - accepted_at}, events


@contextmanager
def rpc(binary, profile):
    with tempfile.TemporaryFile() as diagnostics:
        with subprocess.Popen([binary, "rpc", "--config", profile], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=diagnostics, cwd=profile.parent) as process:
            peer = Rpc(process)
            try:
                yield peer
                process.stdin.close()
                code = process.wait(timeout=TIMEOUT)
                diagnostics.seek(0)
                stderr = diagnostics.read()
                require(code == 0 and not stderr, f"RPC shutdown failed: {code}, {stderr[-500:]!r}")
                require(take(peer.lines) is None, "extra RPC frames before shutdown")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=TIMEOUT)
                with suppress(BrokenPipeError):
                    process.stdin.close()
                peer.reader.join(timeout=TIMEOUT)


def startup(binary, flag):
    expected = {"--help": b"foo run", "--version": b"foo "}[flag]
    start = time.perf_counter_ns()
    result = subprocess.run([binary, flag], capture_output=True, timeout=TIMEOUT, check=False)
    elapsed = time.perf_counter_ns() - start
    require(result.returncode == 0 and expected in result.stdout and not result.stderr, f"{flag} failed with exit {result.returncode}: {result.stderr[-500:]!r}")
    return {"spawn_to_exit_ns": elapsed, "stdout_bytes": len(result.stdout)}


def stream(binary, directory, server, _):
    with rpc(binary, write_profile(directory, server)) as peer:
        timing, events = peer.prompt("stream", "stream", "".join(STREAM_PARTS))
    observed = take(server.observations)
    require(observed.prompt == "stream" and observed.messages == 1, "unexpected streaming workload")
    deltas = [(at, event["delta"]["text"]) for at, event in events if "text" in event.get("delta", {})]
    require([delta for _, delta in deltas] == list(STREAM_PARTS), "fixture deltas were dropped or reordered")
    delays = [at - sent for (at, _), sent in zip(deltas, observed.frame_ns)]
    require(len(delays) == len(STREAM_PARTS) and min(delays) >= 0, "invalid streaming timestamps")
    return timing | {
        "frame_to_rpc_ns": delays,
        "frame_p95_ns": sorted(delays)[math.ceil(0.95 * len(delays)) - 1],
        "request_bytes": observed.body_bytes,
        "server_work_ns": observed.server_work_ns,
        "answer_bytes": sum(map(len, STREAM_PARTS)),
    }


def tool(binary, directory, server, _):
    with rpc(binary, write_profile(directory, server, tool=True)) as peer:
        timing, events = peer.prompt("tool", "read", "read-complete")
    initial, continuation = sorted(
        (take(server.observations), take(server.observations)), key=lambda request: request.messages,
    )
    require((initial.messages, continuation.messages) == (1, 3), "tool continuation history is incomplete")
    require(initial.prompt == continuation.prompt == "read", "unexpected tool workload")
    commits = [(at, event["tool_committed"]["result"]) for at, event in events if "tool_committed" in event]
    require(len(commits) == 1, "tool must commit exactly once")
    committed, result = commits[0]
    content = json.loads(result["content"])
    require(result["status"] == "success" and result["effect"] == "observed" and not result["truncated"],
            "local read failed or was truncated")
    require(content["content"] == LOCAL_CONTENT, "read result is not the fixture file")
    reply = take(server.tool_results)
    require(reply["tool_call_id"] == result["call_id"] == TOOL_CALL_ID and reply["content"] == result["content"],
            "provider did not receive the committed tool result")
    return timing | {
        "offer_to_tool_commit_ns": committed - initial.frame_ns[0],
        "tool_bytes": len(LOCAL_CONTENT),
        "server_work_ns": initial.server_work_ns + continuation.server_work_ns,
    }


def journal(binary, directory, server, trial):
    sides = ("volatile_1", "journal", "volatile_2")
    offset = trial % len(sides)
    measurements = {}
    for side in sides[offset:] + sides[:offset]:
        workspace = directory / side
        workspace.mkdir()
        persistent = side == "journal"
        with rpc(binary, write_profile(workspace, server, journal=persistent)) as peer:
            timing, _ = peer.prompt("journal", "commit", "done:commit")
        observed = take(server.observations)
        require(observed.prompt == "commit" and observed.messages == 1, "journal comparison must use identical input")
        timing["server_work_ns"] = observed.server_work_ns
        timing["journal_bytes"] = validate_journal(workspace / "session" / "journal.jsonl", ["commit"]) if persistent else 0
        measurements[side] = timing
    first, second, persisted = (measurements[side]["accepted_to_result_ns"] for side in ("volatile_1", "volatile_2", "journal"))
    return {
        "run_order": list(measurements),
        "variants": measurements,
        "volatile_noise_ns": abs(first - second),
        "journal_delta_ns": persisted - (first + second) // 2,
    }


def long_session(binary, directory, server, _):
    prompts, turns, memory = [], [], []
    with rpc(binary, write_profile(directory, server, journal=True)) as peer:
        for index in range(TURN_COUNT):
            prompt = f"{TURN_PREFIX}{index:03d}:" + "p" * TURN_REQUEST_CHARS
            prompts.append(prompt)
            timing, _ = peer.prompt(str(index), prompt, f"done:{prompt[:8]}:" + "r" * TURN_REPLY_CHARS)
            request = take(server.observations)
            require(request.prompt == prompt and request.messages == index * 2 + 1, "retained provider context is incomplete")
            turns.append(timing | {"request_bytes": request.body_bytes, "server_work_ns": request.server_work_ns})
            if index + 1 in (1, 8, 16, TURN_COUNT):
                time.sleep(IDLE_PAUSE_S)
                require(peer.process.poll() is None, "runner exited before the memory snapshot")
                memory.append({"turn": index + 1} | process_memory(peer.process.pid))
    result = {
        "turns": turns,
        "memory": memory,
        "journal_bytes": validate_journal(directory / "session" / "journal.jsonl", prompts),
    }
    if "rss_bytes" in memory[0]:
        result["idle_rss_bytes"] = memory[0]["rss_bytes"]
        result["rss_growth_bytes"] = memory[-1]["rss_bytes"] - memory[0]["rss_bytes"]
    return result


def terminal(binary, directory, server, _):
    profile = write_profile(directory, server)
    start = time.perf_counter_ns()
    peer = TerminalPeer([binary, "tui", "--config", profile], columns=TUI_COLUMNS, rows=TUI_ROWS)
    try:
        peer.expect("Ready", timeout=TIMEOUT)
        ready_ns = time.perf_counter_ns() - start
        editor = "input-sample"
        mark = peer.mark()
        start = time.perf_counter_ns()
        peer.send(editor)
        peer.expect(editor, start=mark, timeout=TIMEOUT)
        input_ns = time.perf_counter_ns() - start
        peer.send(b"\x7f" * len(editor))
        render_start = peer.mark()
        peer.send("render\r")
        peer.expect("render-complete", start=render_start, timeout=TIMEOUT)
        displayed = time.perf_counter_ns()
        end = peer.expect("Completed", start=render_start, timeout=TIMEOUT) + len("Completed")
        rendered = take(server.observations)
        require(rendered.prompt == "render", "TUI submitted an unexpected prompt")

        mark = peer.mark()
        peer.send("stall\r")
        try:
            require(server.stalled.wait(timeout=TIMEOUT), "TUI did not start the stalled provider request")
            peer.expect("waiting-on-fixture", start=mark, timeout=TIMEOUT)
            mark = peer.mark()
            start = time.perf_counter_ns()
            peer.send(b"\x03")
            peer.expect("Cancelled", start=mark, timeout=TIMEOUT)
            cancel_ns = time.perf_counter_ns() - start
        finally:
            server.release_stall.set()
        stalled = take(server.observations)
        require(stalled.prompt == "stall", "TUI cancel workload did not reach the provider")

        start = time.perf_counter_ns()
        peer.send(b"\x04")
        require(peer.wait(timeout=TIMEOUT) == 130, "TUI did not exit with the cancelled outcome")
        exit_ns = time.perf_counter_ns() - start
        if os.name != "nt":
            require(peer.device.mode_restored(), "TUI did not restore the original terminal mode")
        return {
            "spawn_to_ready_ns": ready_ns, "input_to_visible_ns": input_ns,
            "frame_to_visible_ns": displayed - rendered.frame_ns[0], "render_bytes": end - render_start,
            "cancel_to_visible_ns": cancel_ns, "quit_to_exit_ns": exit_ns,
        }
    finally:
        peer.close()


def summary(samples):
    if not samples:
        return {}
    result = {}
    for key in samples[0]:
        values = [sample[key] for sample in samples]
        if all(isinstance(value, int) for value in values):
            values.sort()
            result[key] = {"median": statistics.median(values), "min": values[0], "max": values[-1],
                           "p95_nearest_rank": values[math.ceil(0.95 * len(values)) - 1]}
    return result


def report_identity(binary):
    digest = sha256(binary)
    identity = {"path": str(binary), "sha256": digest, "bytes": binary.stat().st_size}
    manifest = binary.with_name("manifest.json")
    if manifest.is_file():
        fields = json.loads(manifest.read_text(encoding="utf-8"))
        require(fields["files"].get(binary.name) == digest, "candidate binary differs from the adjacent manifest")
        identity.update({key: fields[key] for key in (
            "commit", "target", "zig_target", "zig_version", "optimize", "build_host",
        )})
        identity["libraries_bytes"] = sum(
            manifest.with_name(name).stat().st_size for name in fields["files"]
            if "/" not in name and (name.endswith((".dylib", ".dll")) or ".so" in name)
        )
    return identity


def load():
    return list(os.getloadavg()) if hasattr(os, "getloadavg") else None


def run(binary, count):
    cases = {name: {"samples": [], "failures": []} for name in
             ("startup_help", "startup_version", "stream", "tool", "journal", "long_session", "terminal")}
    report = {
        "schema": 1,
        "candidate": report_identity(binary),
        "measurement_host": {
            "platform": platform.platform(), "machine": platform.machine(), "processor": platform.processor(),
            "logical_cpu_count": os.cpu_count(), "python": platform.python_version(), "load_before": load(),
        },
        "fixture_sha256": {path.name: sha256(path) for path in (
            Path(__file__), Path(__file__).with_name("loopback.py"), Path(__file__).with_name("process_memory.py"),
            TERMINAL_FIXTURES / "pty_driver.py", TERMINAL_FIXTURES / "conpty.py",
        )},
        "reference_targets": {
            "startup_help_p95_ns": 20_000_000, "startup_version_p95_ns": 20_000_000,
            "tui_ready_p95_ns": 100_000_000, "idle_rss_bytes": 30 * 1024 * 1024,
            "tui_frame_to_visible_p95_ns": 33_000_000, "tui_cancel_p95_ns": 100_000_000,
        },
        "settings": {
            "clock": "perf_counter_ns", "stream_frames": len(STREAM_PARTS),
            "stream_pause_seconds": STREAM_PAUSE_S, "local_file_bytes": len(LOCAL_CONTENT),
            "long_session_turns": TURN_COUNT, "long_session_prompt_body_chars": TURN_REQUEST_CHARS,
            "long_session_reply_body_chars": TURN_REPLY_CHARS,
            "tui_terminal_columns_rows": [TUI_COLUMNS, TUI_ROWS], "tui_answer_bytes": len(RENDER_TEXT),
            "memory_snapshot_idle_wait_seconds": IDLE_PAUSE_S, "limits": LIMITS, "session_limits": SESSION_LIMITS,
        },
        "unavailable": {
            "cold_startup": "Operating system page cache was not cleared.",
            "allocations": "The candidate has no allocation counter.",
            "idle_wakeups": "The driver does not collect scheduler wakeups.",
            "cpu": "The driver records wall time and process memory.",
            "blocked_output_cancel": "TUI cancellation uses a stalled provider with the terminal output draining.",
        },
        "samples_per_case": count,
        "cases": cases,
    }
    if platform.system() == "Darwin":
        report["unavailable"]["peak_rss"] = "The macOS ps snapshot exposes current RSS."
    if platform.system() not in ("Linux", "Darwin", "Windows"):
        report["unavailable"]["rss"] = "No process memory reader for this OS."
    if report["measurement_host"]["load_before"] is None:
        report["unavailable"]["load_average"] = "The platform does not expose os.getloadavg()."

    for name, flag in (("startup_help", "--help"), ("startup_version", "--version")):
        try:
            startup(binary, flag)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            cases[name]["failures"].append({"stage": "warmup", "error": str(error)})

    measures = {
        "startup_help": lambda _: startup(binary, "--help"),
        "startup_version": lambda _: startup(binary, "--version"),
    }
    for measure in (stream, tool, journal, long_session, terminal):
        measures[measure.__name__] = lambda trial, measure=measure: run_workload(measure, binary, trial)
    for trial in range(count):
        for name, measure in measures.items():
            case = cases[name]
            try:
                case["samples"].append({"trial": trial} | measure(trial))
            except (AssertionError, KeyError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                case["failures"].append({"trial": trial, "error": str(error)})

    for case in cases.values():
        case["status"] = "fail" if case["failures"] else "pass"
        case["summary"] = summary([{key: value for key, value in row.items() if key != "trial"} for row in case["samples"]])
    report["measurement_host"]["load_after"] = load()
    report["status"] = "fail" if any(case["failures"] for case in cases.values()) else "pass"
    return report


def run_workload(measure, binary, trial):
    with tempfile.TemporaryDirectory(prefix="foo-bench-") as work, model_peer() as server:
        directory = Path(work).resolve()
        result = measure(binary, directory, server, trial)
        require(server.observations.empty() and server.tool_results.empty(), "workload made unexpected extra provider requests")
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--samples", type=int, choices=range(5, 51), default=5, metavar="5..50")
    args = parser.parse_args()

    for name in ("FOO_CONFIG_JSON", "FOO_CA_FILE"):
        os.environ.pop(name, None)
    os.environ["TERM"] = "xterm-256color"
    report = run(args.binary.resolve(), args.samples)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for name, case in report["cases"].items():
        print(f"{name}: {case['status']} ({len(case['samples'])} samples, {len(case['failures'])} errors)")
        for failure in case["failures"]:
            print(f"  {failure['error']}", file=sys.stderr)
    return int(report["status"] != "pass")


if __name__ == "__main__":
    sys.exit(main())
