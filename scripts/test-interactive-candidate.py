#!/usr/bin/env python3
"""Hold an isolated signed App for manual Computer Use verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = args.binary.resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix="clipslots-interactive-", dir="/tmp"))
for name in ["data", "fixtures"]:
    (root / name).mkdir()
contents = root / "ClipSlots S11.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.interactive-s11-test",
            CFBundleName="ClipSlots S11", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle", contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
shutil.copy2(repo / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
fixture = root / "crate_canvas_fixture.py"
shutil.copy2(repo / "scripts/crate_canvas_fixture.py", fixture)
fixture.chmod(0o755)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
protected = [Path("/Applications/ClipSlots.app/Contents/MacOS") / n
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]]
before = {str(p): sha(p) for p in protected}
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
env.update(CLIPSLOTS_INTERACTIVE_CANDIDATE=str(root), CLIPSLOTS_DATA_DIR=str(root / "data"),
           CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"), CLIPSLOTS_FIXTURE_DIR=str(root / "fixtures"),
           CLIPSLOTS_CRATE_FIXTURE=str(fixture), CLIPSLOTS_CRATE_FIXTURE_SHA256=sha(fixture))
subject = {"root": str(root), "bundle": str(contents.parent), "sourceBinarySHA256": sha(binary),
           "isolatedBinarySHA256": sha(contents / "MacOS/ClipSlots"), "sources": sources,
           "runnerSHA256": sha(Path(__file__)), "protected": before,
           "scope": "Actual App foreground fixture; manually supplied input; synthetic backend only"}
(root / "subject.json").write_text(json.dumps(subject, indent=2))
print(json.dumps({"root": str(root), "started": True}), flush=True)
with (root / "run.log").open("w") as log:
    process = subprocess.Popen([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log)
    subject["pid"] = process.pid
    (root / "subject.json").write_text(json.dumps(subject, indent=2))
    try:
        process.wait(timeout=1800)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=10)
    finally:
        subject.update(exitCode=process.returncode,
                       sourcesUnchanged=all(sha(repo / p) == h for p, h in sources.items()),
                       productionProductsUnchanged=all(sha(Path(p)) == h for p, h in before.items()))
        (root / "subject.json").write_text(json.dumps(subject, indent=2))
print(json.dumps({"root": str(root), "exit": process.returncode}), flush=True)
