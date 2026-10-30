#!/usr/bin/env python3
"""Actual AgentChatModel against synthetic-only real HTTP, independent restart."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo / "gateway"))
from test_live import ProcessServer, EVIDENCE

binary = args.binary.resolve(strict=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-", dir="/tmp"))
contents = root / "Decision Test.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
            CFBundleName="Decision Test", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle", contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
reports = []
try:
    for mode in ["normal", "unknown", "disconnect", "switch", "batch", "secret", "prepare",
                 "saved", "preparesaved", "preparepending"]:
        server = ProcessServer(token="decision-client-auth")
        directory = root / mode
        directory.mkdir()
        try:
            phases = [mode, {"prepare": "restore", "preparesaved": "restoresaved",
                             "preparepending": "restorepending"}[mode]] if mode.startswith("prepare") else [mode]
            for phase in phases:
                if phase.startswith("restore"): server.restart(crash=True)
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(("CLIPSLOTS_", "CANVAS_", "GATEWAY_", "DECISION_"))}
                env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_DECISION_REGRESSION="1",
                           CLIPSLOTS_DATA_DIR=str(directory), CLIPSLOTS_CONFIG_PATH=str(directory / "config.toml"),
                           DECISION_APP_MODE=phase, DECISION_GATEWAY_URL=server.root)
                with (directory / (phase + ".log")).open("w") as log:
                    result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env,
                                            stdout=log, stderr=log, timeout=50)
                report = json.loads((directory / "report.json").read_text())
                shutil.copy2(directory / "report.json", directory / (phase + "-report.json"))
                assert result.returncode == 0 and not report["failures"], (mode, phase, directory, report)
                reports.append(report)
        finally: server.stop()
finally:
    subject = {"root": str(root), "serverEvidence": str(EVIDENCE), "binarySHA256": sha(binary),
               "source": sources, "reports": reports,
               "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
               "productionProtected": protected,
               "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
               "remoteProviderRequests": 0, "gui": False, "M05Accepted": False, "goalComplete": False}
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({"root": str(root), "cases": len(reports),
                      "passed": sum(r["passed"] for r in reports)}), flush=True)
