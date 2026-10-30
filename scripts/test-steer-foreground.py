#!/usr/bin/env python3
"""Hold an isolated real App and real local gateway for Computer Use verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

repo = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo / "gateway"))
from test_live import ProcessServer
from test_steer import ControlledUpstream

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--mode", choices=["steer", "legacy"], default="steer")
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix="clipslots-interactive-", dir="/tmp"))
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
contents = root / "Steer Foreground.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
for name in ["data", "fixtures"]:
    (root / name).mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.interactive-s12-" + args.mode,
            CFBundleName="Steer Foreground", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
fixture = root / "crate_canvas_fixture.py"
shutil.copy2(repo / "scripts/crate_canvas_fixture.py", fixture)
fixture.chmod(0o755)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
upstream = ControlledUpstream(hold_timeout=1200)
gateway = ProcessServer(synthetic=False, token="live-auth", provider=upstream.root)

class Control(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        if self.path != "/release":
            self.send_error(404)
            return
        upstream.release.set()
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

control = ThreadingHTTPServer(("127.0.0.1", 0), Control)
thread = threading.Thread(target=control.serve_forever, daemon=True)
thread.start()
env = {k: v for k, v in os.environ.items()
       if not k.startswith(("CLIPSLOTS_", "GATEWAY_", "STEER_", "CANVAS_"))}
env.update(CLIPSLOTS_INTERACTIVE_STEER=str(root), CLIPSLOTS_DATA_DIR=str(root / "data"),
           CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"), CLIPSLOTS_FIXTURE_DIR=str(root / "fixtures"),
           CLIPSLOTS_CRATE_FIXTURE=str(fixture), CLIPSLOTS_CRATE_FIXTURE_SHA256=sha(fixture),
           STEER_GATEWAY_URL=gateway.root, STEER_CONTROL_URL=f"http://127.0.0.1:{control.server_port}",
           STEER_FOREGROUND_MODE=args.mode)
subject = {"root": str(root), "bundle": str(contents.parent), "mode": args.mode,
           "binarySHA256": sha(binary), "signedBinarySHA256": sha(contents / "MacOS/ClipSlots"),
           "sources": sources, "protected": protected, "gateway": gateway.root,
           "control": f"http://127.0.0.1:{control.server_port}",
           "serverEvidence": str(gateway.db.parent), "scope": "foreground App + local HTTP/SSE provider",
           "remoteProviderRequests": 0, "guiAccepted": False, "idleAccepted": False}
try:
    with (root / "run.log").open("w") as log:
        process = subprocess.Popen([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log)
        subject["pid"] = process.pid
        (root / "subject.json").write_text(json.dumps(subject, indent=2))
        print(json.dumps({"root": str(root), "pid": process.pid, "mode": args.mode}), flush=True)
        try:
            process.wait(timeout=1200)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=10)
        subject["exitCode"] = process.returncode
finally:
    upstream.stop()
    gateway.stop()
    control.shutdown()
    control.server_close()
    thread.join(timeout=2)
    shutil.copy2(upstream.transcript, root / "provider-wire.json")
    with sqlite3.connect(gateway.db) as db:
        db.backup(sqlite3.connect(root / "server.sqlite3"))
    subject.update(sourceUnchanged=all(sha(repo / p) == h for p, h in sources.items()),
                   protectedUnchanged=all(sha(Path(p)) == h for p, h in protected.items()),
                   localProviderRequests=len(upstream.requests))
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({k: subject[k] for k in ["root", "sourceUnchanged", "protectedUnchanged",
                                           "localProviderRequests", "guiAccepted"]}), flush=True)
