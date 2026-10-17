#!/usr/bin/env python3
"""Execute the real DEBUG CanvasStore in a gated temporary bundle without UI."""
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
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
options = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = options.binary.resolve(strict=True)
output = options.output.absolute()
assert str(output).startswith("/tmp/clipslots-store-regression-")
assert not output.exists(), "Keep prior evidence; use a new output directory."
output.mkdir()
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-bundle-", dir="/tmp"))
contents = root / "ClipSlots Store Regression.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
            CFBundleName="ClipSlots Store Regression", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
resource = binary.parent / "ClipSlots_ClipSlotsKit.bundle"
if resource.exists():
    shutil.copytree(resource, contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
subject = {
    "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    "source_binary_sha256": sha(binary), "isolated_binary_sha256": sha(contents / "MacOS/ClipSlots"),
    "started_unix_seconds": time.time(),
    "scope": "actual CanvasStore, temporary storage, no GUI or remote model",
    "runner_sha256": sha(Path(__file__).resolve()),
}
(output / "subject.json").write_text(json.dumps(subject, indent=2))
env = {key: value for key, value in os.environ.items()
       if not key.startswith("CLIPSLOTS_") and not key.startswith("CANVAS_")}
env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_DATA_DIR=str(output),
           CLIPSLOTS_CONFIG_PATH=str(output / "config.toml"))
with (output / "run.log").open("w") as log:
    process = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env, stdout=log,
                             stderr=subprocess.STDOUT, timeout=30)
report_path = output / "report.json"
if not report_path.exists():
    raise RuntimeError(f"Store regression produced no report; exit {process.returncode}; see {output / 'run.log'}")
report = json.loads(report_path.read_text())
assert report["gui"] is False and report["remote"] is False
print(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(process.returncode if process.returncode else (1 if report["failures"] else 0))
