#!/usr/bin/env python3
"""Hold a signed isolated App with real local synthetic decision HTTP for CU."""
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

repo = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo / "gateway"))
from test_live import ProcessServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix="clipslots-interactive-", dir="/tmp"))
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
contents = root / "Decision Foreground.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
for name in ["data", "fixtures", "sessions"]:
    (root / name).mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.interactive-s15-decision",
            CFBundleName="Decision Foreground", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
fixture = root / "crate_canvas_fixture.py"
shutil.copy2(repo / "scripts/crate_canvas_fixture.py", fixture)
fixture.chmod(0o755)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / name):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / name)
             for name in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
server = ProcessServer(token="decision-client-auth")
env = {k: v for k, v in os.environ.items()
       if not k.startswith(("CLIPSLOTS_", "GATEWAY_", "DECISION_", "CANVAS_"))}
env.update(CLIPSLOTS_INTERACTIVE_DECISION=str(root), CLIPSLOTS_DATA_DIR=str(root / "data"),
           CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"), CLIPSLOTS_FIXTURE_DIR=str(root / "fixtures"),
           CLIPSLOTS_CRATE_FIXTURE=str(fixture), CLIPSLOTS_CRATE_FIXTURE_SHA256=sha(fixture),
           DECISION_GATEWAY_URL=server.root)
subject = {"root": str(root), "bundle": str(contents.parent), "binarySHA256": sha(binary),
           "signedBinarySHA256": sha(contents / "MacOS/ClipSlots"), "sources": sources,
           "productionProtected": protected, "gateway": server.root, "serverEvidence": str(server.db.parent),
           "remoteProviderRequests": 0, "guiAccepted": False, "idleAccepted": False}
try:
    with (root / "run.log").open("w") as log:
        process = subprocess.Popen([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log)
        subject["pid"] = process.pid
        (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
        print(json.dumps({"root": str(root), "pid": process.pid}), flush=True)
        try:
            process.wait(timeout=1200)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=10)
        subject["exitCode"] = process.returncode
finally:
    server.stop()
    with sqlite3.connect(server.db) as db:
        db.backup(sqlite3.connect(root / "server.sqlite3"))
    subject.update(sourceUnchanged=all(sha(repo / p) == h for p, h in sources.items()),
                   productionUnchanged=all(sha(Path(p)) == h for p, h in protected.items()))
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({k: subject[k] for k in ["root", "sourceUnchanged", "productionUnchanged",
                                           "guiAccepted"]}), flush=True)
