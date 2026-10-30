#!/usr/bin/env python3
"""Real WebKit presentation probe in a dedicated bundle with protected production bytes."""
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
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--expect-pre-fix", action="store_true")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = args.binary.resolve(strict=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-", dir="/tmp"))
contents = root / "Artifact Presentation Test.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
            CFBundleName="Artifact Presentation Test", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_", "GATEWAY_"))}
env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_ARTIFACT_PRESENTATION_REGRESSION="1",
           CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
with (root / "app.log").open("w") as log:
    result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log, timeout=90)
report = json.loads((root / "report.json").read_text())
subject = {"root": str(root), "binarySHA256": sha(binary), "sources": sources, "report": report,
           "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
           "productionProtected": protected, "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
           "remoteProviderRequests": 0, "foregroundAccepted": False, "M06Accepted": False, "goalComplete": False}
(root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
print(json.dumps({"root": str(root), "passed": report["passed"], "failures": report["failures"]}), flush=True)
assert subject["sourceUnchanged"] and subject["productionUnchanged"]
if args.expect_pre_fix:
    assert result.returncode == 1 and report["failures"] == [
        "initialized page receives tracked presentation state", "actual page size notification is accepted"]
else:
    assert result.returncode == 0 and not report["failures"]
