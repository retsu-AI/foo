from pathlib import Path
import json
import os
import subprocess

root = Path(__file__).resolve().parents[2]
exe = root / "zig-out/bin" / ("foo.exe" if os.name == "nt" else "foo")
for args, code, stream, expected in [
    (["--version"], 0, "stdout", "foo 0.0.0-bootstrap"),
    (["--help"], 0, "stdout", "not implemented yet"),
    ([], 2, "stderr", "unavailable"),
    (["run"], 2, "stderr", "unavailable"),
    (["rpc"], 2, "stderr", "unavailable"),
    (["acp"], 2, "stderr", "unavailable"),
    (["tui"], 2, "stderr", "unavailable"),
    (["config", "check"], 2, "stderr", "unavailable"),
    (["--version", "unexpected"], 2, "stderr", "unavailable"),
]:
    result = subprocess.run([str(exe), *args], capture_output=True, text=True, check=False)
    assert result.returncode == code, (args, result)
    assert expected in getattr(result, stream), (args, result)
    assert not getattr(result, "stderr" if stream == "stdout" else "stdout"), (args, result)

for args, expected in [
    (["test", "-Dmodule=mcp"], "unavailable"),
    (["test", "-Dmodule=unknown"], "Unknown test module"),
    (["acceptance"], "unavailable"),
    (["acceptance-live"], "unavailable"),
    (["bench"], "unavailable"),
    (["release"], "unavailable"),
]:
    result = subprocess.run(["zig", "build", *args], cwd=root, capture_output=True, text=True, check=False)
    assert result.returncode != 0 and expected in result.stderr, (args, result)

manifest = json.loads((root / ".github/zig.json").read_text())
assert manifest["version"] == (root / ".zig-version").read_text().strip()
print("Bootstrap command, stream, and unavailable-suite checks passed.")
