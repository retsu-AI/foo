"""Offline checks for the live qualification policy and result handling."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import live


class LivePolicyTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        directory = Path(temp.name)
        self.binary = directory / "candidate"
        self.binary.write_bytes(b"fixture executable")
        self.path = directory / "live.json"
        self.ca_file = directory / "ca.pem"
        self.ca_file.touch()
        self.profile = {
            "version": 1,
            "ca_file": self.ca_file.name,
            "policy": {
                "allowed_https_endpoints": [live.ROUTES["openai-responses"][1]],
                "allowed_stdio_launches": [],
                "provider_request_limit": 1,
                "provider_output_token_limit": 32,
                "spend_cap_microusd": 100,
                "project_cap_confirmed": True,
                "mcp_operation_limit": 0,
                "timeout_seconds": 5,
            },
            "providers": [{
                "route": "openai-responses",
                "model": "fixture",
                "service_version": "fixture-1",
                "credential_env": "FOO_CONTROL_ONLY",
                "max_output_tokens": 32,
                "max_charge_microusd": 100,
            }],
        }

    def run_profile(self):
        self.path.write_text(json.dumps(self.profile), encoding="utf-8")
        return live.run(self.binary, self.path)

    def test_missing_opt_in_does_not_launch(self):
        with patch.object(subprocess, "run") as invoke:
            report = live.run(self.binary, None)
        self.assertEqual(report["status"], "unavailable")
        self.assertEqual({case["kind"] for case in report["cases"]}, {"provider", "mcp", "acp"})
        self.assertEqual({case["status"] for case in report["cases"]}, {"unavailable"})
        invoke.assert_not_called()

    def test_allowlist_and_budget_precede_all_launches(self):
        for key, value in (
            ("allowed_https_endpoints", []), ("provider_request_limit", 0),
            ("provider_output_token_limit", 31), ("spend_cap_microusd", 99),
            ("project_cap_confirmed", False),
        ):
            with self.subTest(key=key), patch.dict(self.profile["policy"], {key: value}):
                with patch.object(subprocess, "run") as invoke:
                    self.assertEqual(self.run_profile()["status"], "fail")
                invoke.assert_not_called()

    def test_credentials_do_not_load_ambient_configuration_or_appear_in_report(self):
        secret = "fixture-unique-auth"

        def run(args, *, cwd, input, capture_output, timeout, env):
            config = json.loads(Path(args[-1]).read_text())
            self.assertEqual(config["retry_attempts"], 0)
            self.assertEqual(config["limits"]["model_turns"], 1)
            self.assertEqual(config["model"]["max_output_tokens"], 32)
            self.assertEqual(config["model"]["credential"], {"environment": "FOO_LIVE_SECRET"})
            self.assertEqual(env["FOO_LIVE_SECRET"], secret)
            self.assertNotIn("FOO_CONFIG_JSON", env)
            self.assertTrue(input.startswith(live.PROMPT_PREFIX.encode()))
            self.assertEqual(timeout, 8)
            return subprocess.CompletedProcess(args, 0, b"", secret.encode())

        with patch.dict(os.environ, {"FOO_CONTROL_ONLY": secret, "FOO_CONFIG_JSON": "{}"}):
            with patch.object(subprocess, "run", side_effect=run) as invoke:
                report = self.run_profile()
        invoke.assert_called_once()
        self.assertEqual(report["status"], "fail")
        self.assertNotIn(secret, json.dumps(report))

    def test_successful_subset_still_needs_other_routes(self):
        def run(args, *, input, **_):
            response = input.removeprefix(live.PROMPT_PREFIX.encode()) + b"\n"
            return subprocess.CompletedProcess(args, 0, response, b"")

        with patch.dict(os.environ, {"FOO_CONTROL_ONLY": "fixture"}):
            with patch.object(subprocess, "run", side_effect=run):
                report = self.run_profile()
        self.assertEqual(report["cases"][0]["status"], "pass")
        self.assertEqual(report["status"], "unavailable")

    def test_stdio_launch_pins_the_program_and_credential_mapping(self):
        creds = {"MCP_SERVER_TOKEN": "FOO_CONTROL_ONLY"}
        argv = [str(self.binary.resolve())]
        binary_digest = live.file_sha256(self.binary)
        self.profile["providers"].clear()
        self.profile["policy"]["mcp_operation_limit"] = 1
        self.profile["policy"]["allowed_stdio_launches"] = [live.launch_sha256(argv, binary_digest, creds)]
        self.profile["mcp"] = [{
            "name": "fixture",
            "service_version": "fixture-1",
            "revision": "2025-11-25",
            "resource": "fixture://example",
            "content_sha256": live.content_sha256(b"hello"),
            "max_charge_microusd": 0,
            "transport": {"stdio": {"argv": argv, "program_sha256": binary_digest, "credential_env": creds}},
        }]
        reply = {
            "reference": {"server": "verification", "kind": "resource", "id": "fixture://example"},
            "truncated": False, "bytes": "hello", "encoding": "utf8",
        }

        def run(args, *, env, **_):
            config = json.loads(Path(args[-1]).read_text())
            self.assertEqual(config["mcp_servers"][0]["transport"]["stdio"]["environment"], [
                {"name": "MCP_SERVER_TOKEN", "value": {"environment": "FOO_LIVE_SECRET_0"}},
            ])
            self.assertEqual(env["FOO_LIVE_SECRET_0"], "fixture-key")
            return subprocess.CompletedProcess(args, 0, json.dumps(reply).encode(), b"")

        with patch.dict(os.environ, {"FOO_CONTROL_ONLY": "fixture-key"}):
            with patch.object(subprocess, "run", side_effect=run) as invoke:
                report = self.run_profile()
        invoke.assert_called_once()
        self.assertEqual(next(case for case in report["cases"] if case.get("name") == "fixture")["status"], "pass")
        creds["MCP_SERVER_TOKEN"] = "OTHER_KEY"
        with patch.object(subprocess, "run") as invoke:
            self.assertEqual(self.run_profile()["status"], "fail")
        invoke.assert_not_called()

    def test_editor_trace_checks_correlation_and_manual_scope(self):
        messages = [
            ("client", {"id": 1, "method": "initialize", "params": {
                "protocolVersion": 1, "clientInfo": {"name": "fixture-editor", "version": "0.1"},
            }}),
            ("agent", {"id": 1, "result": {"protocolVersion": 1}}),
            ("client", {"id": 2, "method": "session/new"}),
            ("agent", {"id": 2, "result": {"sessionId": "a"}}),
            ("client", {"id": 3, "method": "session/prompt", "params": {"sessionId": "a"}}),
            ("agent", {"method": "session/update", "params": {"sessionId": "a", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hello"},
            }}}),
            ("agent", {"id": 3, "result": {"stopReason": "end_turn"}}),
        ]
        trace = self.path.with_name("trace.jsonl")
        self.profile["providers"].clear()
        case = {
            "editor": "fixture-editor", "editor_version": "0.1",
            "candidate_sha256": live.file_sha256(self.binary),
            "trace": trace.name, "answer_sha256": live.content_sha256(b"hello"),
            "observed_exit": 0, "observed_checks": list(live.EDITOR_CHECKS[:-1]),
        }
        self.profile["acp"] = [case]

        def validate():
            trace.write_text("".join(
                json.dumps({"direction": direction, "message": {"jsonrpc": "2.0", **message}}) + "\n"
                for direction, message in messages
            ), encoding="utf-8")
            case["trace_sha256"] = live.file_sha256(trace)
            return next(item for item in self.run_profile()["cases"] if item["kind"] == "acp")

        self.assertEqual(validate()["status"], "unavailable")
        case["observed_checks"] = list(live.EDITOR_CHECKS)
        self.assertEqual(validate()["status"], "pass")
        messages.append(messages[-1])
        self.assertEqual(validate()["status"], "fail")


if __name__ == "__main__":
    unittest.main()
