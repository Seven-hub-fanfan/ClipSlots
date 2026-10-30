#!/usr/bin/env python3
"""Signed isolated native Panel; actual HTTP; prelaunch full sources/products; no production restart."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--expect-pre-fix", action="store_true")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = args.binary.resolve(strict=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-", dir="/tmp"))
contents = root / "Remote Panel Test.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression", CFBundleName="Remote Panel Test",
            ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / name):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / name)
             for name in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
fixture = (repo / "scripts/gateway-fixtures/ArtifactRemotePanelFixture.html").read_bytes()
(root / "template-fixture.html").write_bytes(fixture)
requests = []
policies = {
    "manual": {"allow_expanded": True, "auto_expand_on_ready": False, "max_inline_height": 300},
    "auto": {"allow_expanded": True, "auto_expand_on_ready": True, "max_inline_height": 480},
    "deny": {"allow_expanded": False, "auto_expand_on_ready": True, "max_inline_height": 240},
}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        requests.append({"path": self.path, "method": "GET", "variant": self.server.variant,
                         "timeNS": time.time_ns(), "cookiePresent": bool(self.headers.get("Cookie")),
                         "authorizationPresent": bool(self.headers.get("Authorization"))})
        release = "r-0123456789abcdef"
        status, payload = 200, fixture
        if "/channels/" in self.path:
            payload = json.dumps({"schema_version": "mcp_app_channel.v1", "release_id": release}).encode()
        elif "/releases/" in self.path:
            if self.server.variant == "deny":
                time.sleep(0.5)  # Real pending HTTP window for the early native expand action.
            payload = json.dumps({"schema_version": "mcp_app_release.v1", "release_id": release,
                "widgets": {"previs@v3": {"hash": "0123abcd", "csp": {},
                                         "presentation": policies[self.server.variant]}}}).encode()
        elif self.path == "/apps/previs@v3.0123abcd.html":
            pass
        else:
            status = 404
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Type", "text/html" if self.path.endswith(".html") else "application/json")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

servers, endpoints = [], {}
for variant in policies:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.variant = variant
    threading.Thread(target=server.serve_forever, daemon=True).start()
    servers.append(server)
    endpoints[variant] = f"http://127.0.0.1:{server.server_port}"
(root / "fixture-config.json").write_text(json.dumps(endpoints) + "\n")
sources = {str(p.relative_to(repo)): sha(p)
           for folder in ["Sources", "Tests", "scripts", "docs", "gateway", "assets", "skills"]
           for p in (repo / folder).rglob("*") if p.is_file() and not any(
               part in ["__pycache__", "node_modules", ".build", ".DS_Store"] for part in p.parts)}
for name in [".gitignore", "CLAUDE.md", "Info.plist", "Package.swift", "agent.md"]:
    sources[name] = sha(repo / name)
for name in sources:
    target = root / "source-snapshot" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(repo / name, target)
products = {str(p.relative_to(contents.parent)): sha(p) for p in contents.parent.rglob("*") if p.is_file()}
prelaunch = {"timeNS": time.time_ns(), "sourceBinarySHA256": sha(binary), "sources": sources,
             "productMembers": products, "productionProtected": protected,
             "fixtureSHA256": sha(root / "template-fixture.html")}
(root / "prelaunch.json").write_text(json.dumps(prelaunch, indent=2) + "\n")
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_", "GATEWAY_"))}
env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_ARTIFACT_REMOTE_PANEL_REGRESSION="1",
           CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
report, result = None, None
try:
    with (root / "app.log").open("w") as log:
        result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log, timeout=180)
    report = json.loads((root / "report.json").read_text())
finally:
    for server in servers:
        server.shutdown()
        server.server_close()
    (root / "requests.json").write_text(json.dumps(requests, indent=2) + "\n")
    subject = {"root": str(root), "returncode": result and result.returncode, "prelaunch": prelaunch, "report": report,
               "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
               "productUnchanged": all(sha(contents.parent / p) == h for p, h in products.items()),
               "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
               "remoteProviderRequests": 0, "foregroundAccepted": False, "M06Accepted": False, "goalComplete": False}
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({"root": str(root), "passed": report and report["passed"],
                     "failures": report and report["failures"]}), flush=True)
def require(condition, message):
    if not condition:
        raise RuntimeError(message)
require(subject["sourceUnchanged"] and subject["productUnchanged"] and subject["productionUnchanged"],
        "source, isolated product or production bytes changed")
require(all(r["method"] == "GET" and not r["cookiePresent"] and not r["authorizationPresent"] for r in requests),
        "unexpected request credentials")
require(report is not None and result is not None, "missing completed native report")
if args.expect_pre_fix:
    require(result.returncode == 1 and len(report["failures"]) >= 2
            and "remote native panel reads initial persisted state exactly once" in report["failures"]
            and "hung remote native get_state has explicit bounded initialization timeout" in report["failures"],
            "required actual defect baseline not reproduced")
else:
    require(result.returncode == 0 and not report["failures"], "native regression failed")
