#!/usr/bin/env python3
"""Dedicated signed App, prelaunch product/source identities, real WKWebView and protected production bytes."""
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
parser.add_argument("--published-sdk", type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = args.binary.resolve(strict=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-", dir="/tmp"))
contents = root / "Artifact Template Test.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
            CFBundleName="Artifact Template Test", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
requests = []
fixture = (repo / "scripts/gateway-fixtures/ArtifactTemplateFixture.html").read_bytes()
sdk = args.published_sdk.read_bytes() if args.published_sdk else b""
sdk_hash = hashlib.sha256(sdk).hexdigest()[:8]
(root / "template-fixture.html").write_bytes(fixture)
(root / "published-sdk.html").write_bytes(sdk)
release_id = "r-0123456789abcdef"

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        requests.append({"path": self.path, "method": self.command,
                         "sdk": self.server.is_sdk,
                         "cookiePresent": bool(self.headers.get("Cookie")),
                         "authorizationPresent": bool(self.headers.get("Authorization")),
                         "accept": self.headers.get("Accept")})
        payload, status = fixture, 200
        if "/channels/" in self.path:
            payload = json.dumps({"schema_version": "mcp_app_channel.v1", "release_id": release_id}).encode()
        elif "/releases/" in self.path:
            widget_hash = sdk_hash if self.server.is_sdk else "0123abcd"
            payload = json.dumps({"schema_version": "mcp_app_release.v1", "release_id": release_id, "widgets": {
                name + "@v3": {"hash": widget_hash, "csp": {"img_domains": ["https://files.tapnow.art"]},
                              "presentation": {"allow_expanded": True, "auto_expand_on_ready": True, "max_inline_height": 520}}
                for name in ["previs", "slow", "missing", "blocked"]}}).encode()
        elif self.server.is_sdk and self.path == f"/apps/previs@v3.{sdk_hash}.html":
            payload = sdk
        elif self.path == "/apps/slow@v3.0123abcd.html":
            time.sleep(0.3)
        elif self.path == "/apps/missing@v3.0123abcd.html":
            status = 404
        elif self.path == "/apps/blocked@v3.0123abcd.html":
            payload = fixture.replace(b"</body>", b"<img src='file:///fixture-denied.png'></body>")
        elif self.path != "/apps/previs@v3.0123abcd.html":
            status = 404
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Type", "text/html; charset=utf-8" if self.path.endswith(".html") else "application/json")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.is_sdk = False
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
sdk_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
sdk_server.is_sdk = True
threading.Thread(target=sdk_server.serve_forever, daemon=True).start()
(root / "fixture-config.json").write_text(json.dumps({
    "baseURL": f"http://127.0.0.1:{server.server_port}", "sdkHash": sdk_hash,
    "sdkBaseURL": f"http://127.0.0.1:{sdk_server.server_port}",
    "sdkSHA256": hashlib.sha256(sdk).hexdigest(), "sdkBytes": len(sdk)}) + "\n")
sources = {str(p.relative_to(repo)): sha(p) for folder in ["Sources", "Tests", "scripts", "docs", "gateway", "assets", "skills"]
           for p in (repo / folder).rglob("*") if p.is_file() and not any(
               part in ["__pycache__", "node_modules", ".build", ".DS_Store"] for part in p.parts)}
for name in [".gitignore", "CLAUDE.md", "Info.plist", "Package.swift", "agent.md"]:
    sources[name] = sha(repo / name)
snapshot = root / "source-snapshot"
for name in sources:
    target = snapshot / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(repo / name, target)
product = {str(p.relative_to(contents.parent)): sha(p) for p in contents.parent.rglob("*") if p.is_file()}
prelaunch = {"timeNS": time.time_ns(), "sourceBinarySHA256": sha(binary),
             "sources": sources, "productMembers": product, "productionProtected": protected,
             "fixtureSHA256": sha(root / "template-fixture.html"), "sdkSHA256": sha(root / "published-sdk.html")}
(root / "prelaunch.json").write_text(json.dumps(prelaunch, indent=2) + "\n")
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_", "GATEWAY_"))}
env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_ARTIFACT_TEMPLATE_REGRESSION="1",
           CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
report = None
try:
    with (root / "app.log").open("w") as log:
        result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log, timeout=90)
    report = json.loads((root / "report.json").read_text())
finally:
    server.shutdown()
    server.server_close()
    sdk_server.shutdown()
    sdk_server.server_close()
    (root / "requests.json").write_text(json.dumps(requests, indent=2) + "\n")
    subject = {"root": str(root), "prelaunch": prelaunch, "report": report,
               "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
               "productUnchanged": all(sha(contents.parent / p) == h for p, h in product.items()),
               "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
               "remoteProviderRequests": 0, "foregroundAccepted": False, "M06Accepted": False, "goalComplete": False}
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({"root": str(root), "passed": report and report["passed"],
                     "failures": report and report["failures"]}), flush=True)
assert subject["sourceUnchanged"] and subject["productUnchanged"] and subject["productionUnchanged"]
assert all(r["method"] == "GET" and not r["cookiePresent"] and not r["authorizationPresent"] for r in requests)
if args.expect_pre_fix:
    assert result.returncode == 1 and report["failures"] == [
        "declared resource runs inside opaque iframe", "declared resource loads published template",
        "standard SDK postMessage initialize receives response"]
else:
    assert result.returncode == 0 and not report["failures"]
