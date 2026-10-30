#!/usr/bin/env python3
"""Run actual Debug App sessions before normal startup in a guarded temporary bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("scratch", type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = args.scratch.resolve() / "debug/ClipSlots"
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
sources = sorted((repo / "Sources").rglob("*.swift"))
identity = {"sources": {str(p.relative_to(repo)): sha(p) for p in sources},
            "sourceBinarySHA256": sha(binary), "runnerSHA256": sha(Path(__file__)),
            "providerRequests": 0, "productionRestarted": False}
protected = [Path("/Applications/ClipSlots.app/Contents/MacOS") / name
             for name in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]]
before = {str(p): sha(p) for p in protected}
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-cloud-", dir="/tmp"))
app = root / "Cloud Session Test.app"
macos = app / "Contents/MacOS"
macos.mkdir(parents=True)
target = macos / "ClipSlots"
shutil.copy2(binary, target)
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression", CFBundleExecutable="ClipSlots",
            ClipSlotsIsolatedCandidate=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
identity["isolatedBinarySHA256"] = sha(target)
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_CLOUD_SESSION_REGRESSION="1",
           CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
with (root / "run.log").open("w") as log:
    process = subprocess.run([str(target)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60)
identity["exitCode"] = process.returncode
identity["productionProductHashesUnchanged"] = before == {str(p): sha(p) for p in protected}
identity["sourcesUnchanged"] = all(sha(repo / p) == digest for p, digest in identity["sources"].items())
(root / "subject.json").write_text(json.dumps(identity, indent=2) + "\n")
print(json.dumps({"root": str(root), "exitCode": process.returncode}))
assert process.returncode == 0, (root / "run.log").read_text()
report = json.loads((root / "report.json").read_text())
assert not report["failures"] and report["providerRequests"] == 0 and report["foregroundRequired"] is False
assert identity["sourcesUnchanged"] and identity["productionProductHashesUnchanged"]
print(json.dumps(report, ensure_ascii=False))
