#!/usr/bin/env python3
"""Actual native WebKit bridge and independent App-process state restoration."""
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
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = args.binary.resolve(strict=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-", dir="/tmp"))
contents = root / "Artifact Page Test.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
            CFBundleName="Artifact Page Test", ClipSlotsIsolatedCandidate=True)
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
env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_ARTIFACT_PAGE_REGRESSION="1",
           CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
reports = []
try:
    for phase in ["session", "restart"]:
        if phase == "restart":
            env["CLIPSLOTS_ARTIFACT_PAGE_RESTART"] = "1"
        with (root / (phase + ".log")).open("w") as log:
            result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env,
                                    stdout=log, stderr=log, timeout=90)
        report = json.loads((root / "report.json").read_text())
        shutil.copy2(root / "report.json", root / (phase + "-report.json"))
        reports.append(report)
        assert result.returncode == 0 and not report["failures"], (root, phase, report)
finally:
    subject = {"root": str(root), "binarySHA256": sha(binary), "sources": sources,
               "reports": reports, "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
               "productionProtected": protected, "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
               "foregroundAccepted": False, "M06Accepted": False, "goalComplete": False}
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({"root": str(root), "cases": len(reports),
                      "passed": sum(r["passed"] for r in reports),
                      "failures": [f for r in reports for f in r["failures"]]}), flush=True)
