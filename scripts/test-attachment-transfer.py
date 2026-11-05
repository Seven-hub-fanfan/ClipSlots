#!/usr/bin/env python3
"""Verify attachment transfers in a signed native bundle with isolated storage."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--show-ui", action="store_true")
options = parser.parse_args()
root = options.root.resolve()
assert str(root).startswith("/private/tmp/clipslots-editor-")
repo = Path(__file__).resolve().parent.parent
bundle = root / "Attachment Test.app"
contents = bundle / "Contents"
for folder in [contents / "MacOS", contents / "Resources", root / "data"]:
    folder.mkdir(parents=True, exist_ok=True)
binary = options.binary.resolve(strict=True)
shutil.copy2(binary, contents / "MacOS/ClipSlots")
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.attachment-regression",
            CFBundleName="Attachment Test", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
resource = binary.parent / "ClipSlots_ClipSlotsKit.bundle"
shutil.copytree(resource, contents / "Resources" / resource.name, dirs_exist_ok=True)
shutil.copy2(repo / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
env.update(CLIPSLOTS_ATTACHMENT_REGRESSION=str(root), CLIPSLOTS_DATA_DIR=str(root / "data"),
           CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
if options.show_ui:
    env["CLIPSLOTS_ATTACHMENT_SHOW_UI"] = "1"
with (root / "app.log").open("w") as log:
    process = subprocess.Popen([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log)
    print(json.dumps({"pid": process.pid, "bundle": str(bundle), "root": str(root)}), flush=True)
    try:
        code = process.wait(timeout=1800 if options.show_ui else 90)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=10)
        raise
report = root / "app-regression.json"
if report.exists():
    print(report.read_text())
raise SystemExit(code)
