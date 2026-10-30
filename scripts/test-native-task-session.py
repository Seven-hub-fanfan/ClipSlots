#!/usr/bin/env python3
"""Run the actual App task session and process restart in a private test bundle."""
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
contents = root / "Task Session Test.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
            CFBundleName="Task Session Test", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
protected = [Path("/Applications/ClipSlots.app/Contents/MacOS") / name
             for name in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]]
before = {str(p): sha(p) for p in protected}
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
subject = {"root": str(root), "binarySHA256": sha(binary), "source": sources,
           "protected": before, "runnerSHA256": sha(Path(__file__)),
           "scope": "Actual AgentChatModel in App process; synthetic backend; no windows"}
for path in sources:
    target = root / "source" / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes((repo / path).read_bytes())
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
env = {k: v for k, v in os.environ.items()
       if not k.startswith(("CLIPSLOTS_", "CANVAS_", "GATEWAY_"))}
env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_SUBAGENT_REGRESSION="1",
           CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
reports = []
try:
    for phase in ["session", "restart"]:
        if phase == "restart":
            env["CLIPSLOTS_SUBAGENT_VERIFY_RESTART"] = "1"
        with (root / (phase + ".log")).open("w") as output:
            result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env,
                                    stdout=output, stderr=output, timeout=45)
        report = json.loads((root / "report.json").read_text())
        shutil.copy2(root / "report.json", root / ("report-" + phase + ".json"))
        assert result.returncode == 0 and report["passed"] > 0 and not report["failures"]
        assert report["passed"] == len(report["checks"]) and report["gui"] is False
        assert report["providerRequests"] == 0 and report["remote"] is False
        reports.append(report)
    subject.update(passed=sum(r["passed"] for r in reports), failures=[],
                   protectedUnchanged=all(sha(Path(p)) == h for p, h in before.items()),
                   sourceUnchanged=all(sha(repo / p) == h for p, h in sources.items()))
    assert subject["protectedUnchanged"] and subject["sourceUnchanged"]
finally:
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({"root": str(root), "passed": subject.get("passed"),
                      "protectedUnchanged": subject.get("protectedUnchanged")}), flush=True)
