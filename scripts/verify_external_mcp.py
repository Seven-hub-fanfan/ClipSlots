#!/usr/bin/env python3
"""Verify the real stdio CLI against a previously completed isolated native probe."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--native-report", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--expected-version", required=True)
options = parser.parse_args()
native = json.loads(options.native_report.read_text())
root = Path(native["isolatedDataRoot"]).resolve()
fixtures = Path(native["fixtureRoot"]).resolve()
assert str(root).startswith("/private/tmp/clipslots-v2174-") or str(root).startswith("/tmp/clipslots-v2174-")
assert native["complete"] and not native["failures"]
snapshot_file = max((root / "agent-canvas-snapshots").rglob("*.json"), key=lambda p: p.stat().st_mtime)
snapshot = json.loads(snapshot_file.read_text())
graph = snapshot["graph"]
project = graph["projectID"]
canvas = snapshot.get("canvasID", project)
snapshot_id = graph["snapshotID"]
session = json.loads((root / "agent-sessions/gateway-native.json").read_text())["current"]["id"]
env = dict(os.environ, CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root.parent / "config.toml"))
arguments = [str(options.binary.resolve()), "--mcp", "--project-id", project, "--canvas-id", canvas,
             "--snapshot-id", snapshot_id, "--session-id", session]
checks = []


def check(passed, name):
    checks.append({"name": name, "passed": bool(passed)})


def files():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file() and not p.name.endswith(".lock")}


def request(method, params=None, number=1):
    value = {"jsonrpc": "2.0", "id": number, "method": method}
    if params is not None:
        value["params"] = params
    return value


def call(name, fields=None, number=1):
    return request("tools/call", {"name": name, "arguments": fields or {}}, number)


def roundtrip(values, args=None):
    completed = subprocess.run(args or arguments, input="".join(json.dumps(v, ensure_ascii=False) + "\n" for v in values),
                               env=env, text=True, capture_output=True, timeout=20)
    assert completed.returncode == 0, completed.stderr
    return [json.loads(line) for line in completed.stdout.splitlines()]


def content(value):
    return json.loads(value["result"]["content"][0]["text"])


before = files()
first = roundtrip([request("initialize", number=1), {"jsonrpc": "2.0", "method": "notifications/initialized"},
                   request("tools/list", number=3), call("clipslots_context", number=4),
                   call("artifact_list", number=5)])
check([v["id"] for v in first] == [1, 3, 4, 5], "notifications receive no response; request IDs remain correlated")
check(first[0]["result"]["serverInfo"]["version"] == options.expected_version, "real CLI reports current MCP server version")
names = {v["name"] for v in first[1]["result"]["tools"]}
check(len(names) == 9 and {"canvas_read_node", "artifact_read"} <= names, "real scoped catalog advertises nine readers")
check(not {"write_slot", "shell", "run_skill_script"} & names, "catalog exposes no write or shell executor")
identity = content(first[2])
check(identity["project_id"] == project and identity["canvas_id"] == canvas and identity["read_only"],
      "real process binds immutable project and canvas")
check(identity["snapshot_id"] == snapshot_id and identity["session_id"] == session, "fixed snapshot and session correlation survive stdio")
artifacts = content(first[3])["artifacts"]
check(len(artifacts) == 1 and "chunk" not in content(first[3]), "artifact listing is scoped metadata only")
artifact = artifacts[0]
node = graph["nodes"][0]["configuration"]
node_id = f'{node["groupId"]}#{node["slot"]}'
responses = roundtrip([
    call("artifact_read", {"path": artifact["path"], "revision": artifact["revision"]}, 10),
    call("canvas_read_node", {"snapshot_id": snapshot_id, "node_id": node_id, "field": "body"}, 11),
    call("write_slot", {"text": "must never write"}, 12),
    call("artifact_metadata", {"path": "../outside"}, 13),
    call("artifact_read", {"path": artifact["path"], "revision": "0"}, 14),
    call("canvas_overview", {"snapshot_id": "00000000-0000-0000-0000-000000000000"}, 15),
    request("unknown-method", number=16),
])
check("产物🙂" in content(responses[0])["chunk"], "real artifact reader delivers persisted Unicode HTML")
check(content(responses[1])["chunk"] == "保持此原文🙂", "real canvas reader delivers exact saved body")
for row, name in zip(responses[2:6], ["unadvertised mutation", "artifact traversal", "stale revision", "foreign snapshot"]):
    check(row["result"]["isError"], f"real CLI rejects {name}")
check(responses[6]["error"]["code"] == -32601, "unknown methods receive explicit protocol errors")
foreign = list(arguments)
foreign[foreign.index("--canvas-id") + 1] = "foreign-canvas"
denied = subprocess.run(foreign, input="", env=env, text=True, capture_output=True, timeout=20)
check(denied.returncode != 0 and not denied.stdout, "same-project foreign canvas fails before serving any tool")
check(files() == before, "all isolated business data remain byte-identical after real CLI reads and rejections")
options.output.parent.mkdir(parents=True, exist_ok=True)
report = {"complete": True, "passed": sum(c["passed"] for c in checks),
          "failures": [c["name"] for c in checks if not c["passed"]], "checks": checks,
          "scope": "actual CLI stdio process using persisted isolated native snapshot and artifact; no external client or live gateway",
          "comparisonExcludes": ["*.lock: process bookkeeping only"],
          "projectID": project, "canvasID": canvas, "snapshotID": snapshot_id, "sessionID": session}
options.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "checks"}, ensure_ascii=False, indent=2))
raise SystemExit(bool(report["failures"]))
