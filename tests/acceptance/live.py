"""Check authorized provider and MCP routes and import native ACP editor evidence."""

import argparse
import base64
import binascii
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
from urllib.parse import urlsplit


ROUTES = {
    "openai-responses": ("openai_responses", "https://api.openai.com/v1/responses"),
    "openai-chat": ("openai_chat", "https://api.openai.com/v1/chat/completions"),
    "anthropic-messages": ("anthropic_messages", "https://api.anthropic.com/v1/messages"),
    "xai-responses": ("openai_responses", "https://api.x.ai/v1/responses"),
}
MCP_REVISIONS = ("2025-11-25", "2026-07-28")
EDITOR_CHECKS = (
    "denied_and_approved_permission", "unsaved_read", "host_error",
    "terminal_cancel_and_release", "active_disconnect", "mcp_tool_continuation",
)
PROMPT_PREFIX = "Reply with exactly this marker and nothing else: "
RESOURCE_LIMITS = {
    "model_turns": 1,
    "tool_calls": 1,
    "wire_message_bytes": 1 << 20,
    "transcript_bytes": 1 << 18,
    "tool_output_bytes": 1 << 16,
    "server_stderr_bytes": 1 << 16,
    "catalog_pages": 2,
    "catalog_bytes": 1 << 16,
}


class InvalidProfile(ValueError):
    pass


class FailedCheck(ValueError):
    pass


class UnavailableCheck(ValueError):
    pass


@dataclass(frozen=True)
class ProviderCase:
    route: str
    model: str
    version: str
    credential: str
    output_tokens: int
    max_charge: int


@dataclass(frozen=True)
class HttpPeer:
    endpoint: str
    authorization_env: str | None


@dataclass(frozen=True)
class StdioPeer:
    argv: tuple[str, ...]
    program_sha256: str
    launch_sha256: str
    credential_env: dict[str, str]


@dataclass(frozen=True)
class McpCase:
    name: str
    version: str
    revision: str
    resource: str
    expected_content: str
    max_charge: int
    peer: HttpPeer | StdioPeer


@dataclass(frozen=True)
class EditorCase:
    name: str
    version: str
    candidate_sha256: str
    trace: Path
    trace_sha256: str
    answer_sha256: str
    observed_checks: tuple[str, ...]
    observed_exit: int


@dataclass(frozen=True)
class Profile:
    timeout_seconds: int
    ca_file: Path | None
    budget: dict
    providers: tuple[ProviderCase, ...]
    mcp: tuple[McpCase, ...]
    acp: tuple[EditorCase, ...]


def require(condition, message):
    if not condition:
        raise InvalidProfile(message)


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON property")
        result[key] = value
    return result


def object_fields(value, required, optional=()):
    require(isinstance(value, dict), "expected a JSON object")
    require(set(required) <= value.keys() <= set(required) | set(optional), "unexpected or missing JSON property")
    return value


def items(value, limit=16):
    require(isinstance(value, list) and len(value) <= limit, "invalid or oversized case list")
    return value


def label(value):
    require(
        isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./@ +:-]{0,127}", value),
        "invalid service, model, or version label",
    )
    return value


def string(value, limit=4096):
    require(isinstance(value, str) and 0 < len(value) <= limit, "invalid string")
    require(all(char.isprintable() for char in value), "invalid character in string")
    return value


def number(value, minimum, maximum):
    require(type(value) is int and minimum <= value <= maximum, "invalid integer limit")
    return value


def digest(value):
    require(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value), "invalid SHA-256")
    return value


def endpoint(value):
    url = urlsplit(string(value))
    require(
        value.startswith("https://") and url.scheme == "https" and url.hostname and url.username is None
        and url.password is None and bool(url.path) and not re.search(r"[?\\#\s]", value)
        and (url.port is None or url.port > 0),
        "expected an exact HTTPS endpoint URL without credentials, query, or fragment",
    )
    return value


def env_name(value):
    require(
        isinstance(value, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,127}", value),
        "invalid credential environment variable name",
    )
    return value


def read_bytes(path, limit):
    require(path.is_file(), "evidence or profile must be a regular file")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, "evidence or profile exceeds its byte limit")
    return data


def file_sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def content_sha256(data):
    return hashlib.sha256(data).hexdigest()


def launch_sha256(argv, program_sha256, credential_env):
    identity = {"argv": argv, "program_sha256": program_sha256, "credential_env": credential_env}
    return content_sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode())


def read_profile(path):
    raw = json.loads(read_bytes(path, 1 << 18), object_pairs_hook=unique_keys)
    settings = object_fields(raw, ("version", "policy"), ("providers", "mcp", "acp", "ca_file"))
    require(type(settings["version"]) is int and settings["version"] == 1, "unsupported profile schema")
    policy = object_fields(
        settings["policy"],
        ("allowed_https_endpoints", "allowed_stdio_launches", "provider_request_limit",
         "provider_output_token_limit", "spend_cap_microusd", "project_cap_confirmed",
         "mcp_operation_limit", "timeout_seconds"),
    )
    endpoints = {endpoint(url) for url in items(policy["allowed_https_endpoints"])}
    launches = {digest(item) for item in items(policy["allowed_stdio_launches"])}
    requests = number(policy["provider_request_limit"], 0, len(ROUTES))
    output_tokens = number(policy["provider_output_token_limit"], 0, 1 << 15)
    spend_cap = number(policy["spend_cap_microusd"], 0, 100_000_000)
    mcp_operations = number(policy["mcp_operation_limit"], 0, 16)
    timeout = number(policy["timeout_seconds"], 1, 120)
    require(type(policy["project_cap_confirmed"]) is bool, "invalid provider project cap confirmation")

    providers = []
    for case in items(settings.get("providers", []), len(ROUTES)):
        object_fields(case, ("route", "model", "service_version", "credential_env", "max_output_tokens", "max_charge_microusd"))
        route = label(case["route"])
        require(route in ROUTES and ROUTES[route][1] in endpoints, "provider endpoint lacks approval")
        require(route not in {provider.route for provider in providers}, "duplicate provider route")
        providers.append(ProviderCase(
            route, label(case["model"]), label(case["service_version"]), env_name(case["credential_env"]),
            number(case["max_output_tokens"], 1, 4096), number(case["max_charge_microusd"], 1, 100_000_000),
        ))

    reserved_spend = sum(case.max_charge for case in providers)
    reserved_tokens = sum(case.output_tokens for case in providers)
    require(len(providers) <= requests, "provider request reservation exceeds cap")
    require(reserved_tokens <= output_tokens, "provider output token reservation exceeds cap")

    mcp = []
    for case in items(settings.get("mcp", [])):
        object_fields(
            case, ("name", "service_version", "revision", "resource", "content_sha256", "max_charge_microusd", "transport"),
        )
        transport = object_fields(case["transport"], (), ("http", "stdio"))
        require(len(transport) == 1, "choose one MCP transport")
        if "http" in transport:
            http = object_fields(transport["http"], ("endpoint",), ("authorization_env",))
            url = endpoint(http["endpoint"])
            require(url in endpoints, "MCP endpoint lacks approval")
            peer = HttpPeer(url, env_name(http["authorization_env"]) if "authorization_env" in http else None)
        else:
            stdio = object_fields(transport["stdio"], ("argv", "program_sha256"), ("credential_env",))
            argv = tuple(string(arg) for arg in items(stdio["argv"]))
            require(argv and Path(argv[0]).is_absolute(), "MCP stdio command must use an absolute executable")
            program_digest = digest(stdio["program_sha256"])
            credentials = stdio.get("credential_env", {})
            require(isinstance(credentials, dict) and len(credentials) <= 8, "invalid MCP stdio credential mapping")
            credentials = {env_name(name): env_name(source) for name, source in credentials.items()}
            require(len({name.upper() for name in credentials}) == len(credentials), "duplicate MCP stdio environment name")
            launch_digest = launch_sha256(argv, program_digest, credentials)
            require(launch_digest in launches, "MCP stdio launch lacks approval")
            peer = StdioPeer(argv, program_digest, launch_digest, credentials)
        revision = case["revision"]
        require(revision in MCP_REVISIONS, "unsupported MCP revision")
        name = label(case["name"])
        require(name not in {peer.name for peer in mcp}, "duplicate MCP case name")
        mcp.append(McpCase(
            name, label(case["service_version"]), revision, string(case["resource"]), digest(case["content_sha256"]),
            number(case["max_charge_microusd"], 0, 100_000_000), peer,
        ))
    require(len(mcp) <= mcp_operations, "MCP operation reservation exceeds cap")
    reserved_spend += sum(case.max_charge for case in mcp)
    require(reserved_spend <= spend_cap, "spend reservation exceeds cap")
    require(not reserved_spend or policy["project_cap_confirmed"], "service spend cap lacks confirmation")

    acp = []
    for case in items(settings.get("acp", [])):
        object_fields(
            case, ("editor", "editor_version", "candidate_sha256", "trace", "trace_sha256",
                   "answer_sha256", "observed_checks", "observed_exit"),
        )
        checks = tuple(label(name) for name in items(case["observed_checks"]))
        require(len(checks) == len(set(checks)) and set(checks) <= set(EDITOR_CHECKS), "unknown or duplicate ACP check")
        acp.append(EditorCase(
            label(case["editor"]), label(case["editor_version"]), digest(case["candidate_sha256"]),
            path.parent / string(case["trace"]), digest(case["trace_sha256"]), digest(case["answer_sha256"]),
            checks, number(case["observed_exit"], 0, 255),
        ))

    ca_file = (path.parent / string(settings["ca_file"])).resolve() if "ca_file" in settings else None
    return Profile(timeout, ca_file, {
        "provider_request_limit": requests,
        "provider_output_token_limit": output_tokens,
        "spend_cap_microusd": spend_cap,
        "project_cap_confirmed": policy["project_cap_confirmed"],
        "reserved_provider_requests": len(providers),
        "reserved_provider_output_tokens": reserved_tokens,
        "reserved_max_charge_microusd": reserved_spend,
        "reserved_mcp_operations": len(mcp),
        "mcp_operation_limit": mcp_operations,
        "timeout_seconds": timeout,
    }, tuple(providers), tuple(mcp), tuple(acp))


def child_env(references, ca_file, needs_tls):
    env = {key: os.environ[key] for key in ("SYSTEMROOT", "WINDIR", "TEMP", "TMP") if key in os.environ}
    for destination, reference in references.items():
        value = os.environ.get(reference)
        if not value:
            raise UnavailableCheck("configured credential is absent")
        env[destination] = value
    if needs_tls:
        if ca_file is None or not ca_file.is_file():
            raise UnavailableCheck("configured PEM trust bundle is absent")
        env["FOO_CA_FILE"] = str(ca_file)
    return env


def invoke(binary, args, config, profile, env, data=None):
    config = {
        **config,
        "retry_attempts": 0,
        "process": {"timeout_ms": profile.timeout_seconds * 1000},
        "limits": RESOURCE_LIMITS,
    }
    with tempfile.TemporaryDirectory(prefix="foo-live-") as directory:
        path = Path(directory).resolve() / "profile.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        result = subprocess.run(
            [str(binary), *args, "--config", str(path)], cwd=path.parent,
            input=data if data is not None else b"", capture_output=True,
            timeout=profile.timeout_seconds + 3, env=env,
        )
    if result.returncode != 0:
        raise FailedCheck(f"candidate exited with status {result.returncode}")
    if result.stderr:
        raise FailedCheck("candidate emitted diagnostics")
    return result.stdout


def probe_provider(binary, profile, case):
    family, url = ROUTES[case.route]
    endpoint_url = urlsplit(url)
    env = child_env({"FOO_LIVE_SECRET": case.credential}, profile.ca_file, needs_tls=True)
    marker = f"foo-{secrets.token_hex(8)}"
    prompt = (PROMPT_PREFIX + marker).encode()
    reply = invoke(binary, ["run", "--stdin"], {
        "model": f"{case.route}/{case.model}",
        "providers": {case.route: {
            "family": family,
            "base_url": f"{endpoint_url.scheme}://{endpoint_url.netloc}",
            "credential": {"environment": "FOO_LIVE_SECRET"},
            "models": {case.model: {"endpoint": url, "max_output_tokens": case.output_tokens}},
        }},
    }, profile, env, prompt)
    if reply.strip() != marker.encode():
        raise FailedCheck("response does not match the marker")
    return {
        "prompt_bytes": len(prompt), "prompt_sha256": content_sha256(prompt),
        "output_bytes": len(reply), "output_sha256": content_sha256(reply),
        "actual_bill": "unavailable",
    }


def probe_mcp(binary, profile, case):
    peer = case.peer
    references = {}
    if isinstance(peer, HttpPeer):
        transport = {"http": {"url": peer.endpoint}}
        if peer.authorization_env:
            references["FOO_LIVE_SECRET"] = peer.authorization_env
            transport["http"]["headers"] = [{"name": "Authorization", "value": {"environment": "FOO_LIVE_SECRET"}}]
    else:
        if not Path(peer.argv[0]).is_file() or file_sha256(Path(peer.argv[0])) != peer.program_sha256:
            raise FailedCheck("MCP executable differs from the approved launch")
        server_env = []
        for index, (name, source) in enumerate(peer.credential_env.items()):
            alias = f"FOO_LIVE_SECRET_{index}"
            references[alias] = source
            server_env.append({"name": name, "value": {"environment": alias}})
        transport = {"stdio": {"argv": peer.argv, "environment": server_env}}
    env = child_env(references, profile.ca_file, needs_tls=isinstance(peer, HttpPeer))
    raw = invoke(binary, ["mcp", "get", "resource", "verification", case.resource], {
        "model": "local/unused",
        "providers": {"local": {"family": "openai_chat", "base_url": "http://127.0.0.1:1", "models": {"unused": {}}}},
        "mcp_servers": [{"id": "verification", "revision": case.revision, "transport": transport}],
    }, profile, env)
    try:
        payload = json.loads(raw)
        ref = payload["reference"]
        if ref != {"server": "verification", "kind": "resource", "id": case.resource} or payload["truncated"] is not False:
            raise FailedCheck("resource identity differs or payload was truncated")
        data = payload["bytes"]
        match payload["encoding"]:
            case "utf8":
                content = data.encode("utf-8")
            case "base64":
                content = base64.b64decode(data, validate=True)
            case _:
                raise FailedCheck("unknown resource encoding")
    except (AttributeError, KeyError, TypeError, json.JSONDecodeError, UnicodeError, binascii.Error):
        raise FailedCheck("candidate returned a malformed MCP result") from None
    if content_sha256(content) != case.expected_content:
        raise FailedCheck("resource content differs from the expected SHA-256")
    return {
        "resource_sha256": content_sha256(case.resource.encode()), "content_sha256": case.expected_content,
        "content_bytes": len(content),
    }


def trace_request(frames, method, after):
    for index in range(after, len(frames)):
        direction, message = frames[index]
        if direction == "client" and message.get("method") == method and type(message.get("id")) in (int, str):
            return index, message
    raise FailedCheck(f"ACP trace lacks {method}")


def trace_reply(frames, index, request):
    request_id = request["id"]
    matches = [
        (position, message) for position, (direction, message) in enumerate(frames[index + 1:], index + 1)
        if direction == "agent" and "method" not in message
        and type(message.get("id")) is type(request_id) and message["id"] == request_id
    ]
    if len(matches) != 1 or "result" not in matches[0][1] or "error" in matches[0][1]:
        raise FailedCheck("ACP trace lacks a unique successful correlated response")
    position, message = matches[0]
    return position, message["result"]


def validate_editor(case, binary_sha):
    if case.candidate_sha256 != binary_sha:
        raise FailedCheck("editor evidence belongs to another executable")
    if not case.trace.is_file():
        raise UnavailableCheck("editor trace is absent")
    data = read_bytes(case.trace, 4 << 20)
    if content_sha256(data) != case.trace_sha256:
        raise FailedCheck("editor trace SHA-256 differs")
    frames = []
    for line in data.splitlines():
        frame = json.loads(line)
        direction = frame["direction"]
        message = frame["message"]
        if direction not in ("agent", "client") or message["jsonrpc"] != "2.0":
            raise FailedCheck("unknown direction or invalid JSON-RPC version in trace")
        frames.append((direction, message))

    initialize, request = trace_request(frames, "initialize", 0)
    client_info = request["params"].get("clientInfo")
    if client_info and (client_info.get("name"), client_info.get("version")) != (case.name, case.version):
        raise FailedCheck("editor identity differs from the initialize request")
    start, result = trace_reply(frames, initialize, request)
    if result["protocolVersion"] != 1:
        raise FailedCheck("ACP trace did not negotiate v1")
    opened, request = trace_request(frames, "session/new", start + 1)
    start, result = trace_reply(frames, opened, request)
    session = result["sessionId"]
    prompted, request = trace_request(frames, "session/prompt", start + 1)
    if request["params"]["sessionId"] != session:
        raise FailedCheck("ACP prompt used a different session")
    finished, result = trace_reply(frames, prompted, request)
    if result["stopReason"] != "end_turn" or case.observed_exit != 0:
        raise FailedCheck("ACP turn or disconnect did not complete")
    chunks = []
    for direction, message in frames[prompted + 1:finished]:
        if direction != "agent" or message.get("method") != "session/update":
            continue
        params = message["params"]
        if params["sessionId"] != session:
            raise FailedCheck("ACP update used a different session")
        update = params["update"]
        if update["sessionUpdate"] == "agent_message_chunk":
            chunks.append(update["content"]["text"])
    answer = "".join(chunks).encode()
    if not answer or content_sha256(answer) != case.answer_sha256:
        raise FailedCheck("ACP streamed answer differs from the expected SHA-256")
    return {
        "trace_sha256": case.trace_sha256,
        "answer_sha256": case.answer_sha256,
        "operator_observed": list(case.observed_checks),
        "missing_editor_checks": sorted(set(EDITOR_CHECKS) - set(case.observed_checks)),
    }


def outcome(check, **identity):
    try:
        data = check()
    except UnavailableCheck as exc:
        return {**identity, "status": "unavailable", "detail": str(exc)}
    except FailedCheck as exc:
        return {**identity, "status": "fail", "detail": str(exc)}
    except subprocess.TimeoutExpired:
        return {**identity, "status": "fail", "detail": "candidate exceeded its deadline"}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {**identity, "status": "fail", "detail": "invalid evidence or candidate could not be launched"}
    status = "unavailable" if data.get("missing_editor_checks") else "pass"
    return {**identity, "status": status, **data}


def missing_coverage(cases):
    covered_routes = {case["route"] for case in cases if case["kind"] == "provider"}
    for route in sorted(set(ROUTES) - covered_routes):
        yield {"kind": "provider", "route": route, "status": "unavailable", "detail": "not configured"}
    covered_mcp = {(case["transport"], case["revision"]) for case in cases if case["kind"] == "mcp"}
    for transport in ("http", "stdio"):
        for revision in MCP_REVISIONS:
            if (transport, revision) not in covered_mcp:
                yield {
                    "kind": "mcp", "transport": transport, "revision": revision, "status": "unavailable",
                    "detail": "not configured",
                }
    if not any(case["kind"] == "acp" for case in cases):
        yield {"kind": "acp", "status": "unavailable", "detail": "native editor evidence absent"}


def run(binary, profile_path):
    binary_sha = file_sha256(binary)
    report = {
        "version": 1, "lane": "live", "binary_sha256": binary_sha,
        "started_at": datetime.now(timezone.utc).isoformat(), "cases": [],
    }
    if profile_path is None:
        report.update(
            status="unavailable", detail="explicit live profile and authorization are absent",
            cases=list(missing_coverage([])),
        )
        return report
    try:
        profile = read_profile(profile_path)
    except InvalidProfile as exc:
        report.update(status="fail", detail=str(exc))
        return report
    except (OSError, ValueError, TypeError):
        report.update(status="fail", detail="live profile is unreadable or invalid JSON")
        return report

    report["budget"] = profile.budget
    cases = report["cases"]
    for case in profile.providers:
        family, url = ROUTES[case.route]
        cases.append(outcome(
            lambda: probe_provider(binary, profile, case), kind="provider", route=case.route,
            family=family, endpoint=url, model=case.model, service_version=case.version,
            max_output_tokens=case.output_tokens, max_charge_microusd=case.max_charge,
        ))
    for case in profile.mcp:
        cases.append(outcome(
            lambda: probe_mcp(binary, profile, case), kind="mcp", name=case.name, service_version=case.version,
            transport="http" if isinstance(case.peer, HttpPeer) else "stdio", revision=case.revision,
            max_charge_microusd=case.max_charge,
            endpoint_sha256=content_sha256(case.peer.endpoint.encode()) if isinstance(case.peer, HttpPeer) else None,
            launch_sha256=case.peer.launch_sha256 if isinstance(case.peer, StdioPeer) else None,
            program_sha256=case.peer.program_sha256 if isinstance(case.peer, StdioPeer) else None,
        ))
    for case in profile.acp:
        cases.append(outcome(
            lambda: validate_editor(case, binary_sha), kind="acp", source="operator_observed_editor",
            editor=case.name, editor_version=case.version,
        ))
    cases.extend(list(missing_coverage(cases)))
    statuses = {case["status"] for case in cases}
    report["status"] = "fail" if "fail" in statuses else "unavailable" if "unavailable" in statuses else "pass"
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--profiles", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = run(args.binary.resolve(), args.profiles)
    except OSError:
        parser.exit(1, "Unable to read the candidate executable.\n")
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Live qualification {result['status']}")
    return {"pass": 0, "fail": 1, "unavailable": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
