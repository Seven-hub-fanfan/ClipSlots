#!/usr/bin/env python3
"""Build and verify file ingestion using the existing bounded task output."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
root = args.root.resolve(strict=True)
evidence = args.evidence.resolve(strict=True)
repo = Path(__file__).resolve().parent.parent
assert str(root).startswith("/private/tmp/clipslots-editor-")
env = dict(os.environ, TMPDIR=str(root), CLIPSLOTS_DATA_DIR=str(root / "full-smoke"),
           CLIPSLOTS_CONFIG_PATH=str(root / "full-smoke/config.toml"))


def run(name, command):
    subprocess.run([sys.executable, "scripts/disk_guard.py", "check", "--reserve-gib", "0.3"],
                   cwd=repo, check=True, env=env)
    print(name, flush=True)
    with (evidence / (name + ".log")).open("w") as log:
        subprocess.run([sys.executable, "scripts/disk_guard.py", "run",
                        "--output", str(repo / ".build"), "--output", str(root),
                        "--budget-gib", "4", "--"] + command, cwd=repo, env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True)


for product in ["ClipSlotsKitSmokeTests", "ClipSlotsCLI", "ClipSlotsMCP", "ClipSlots"]:
    run("build-" + product, ["swift", "build", "--product", product])
run("file-kit", [str(repo / ".build/debug/ClipSlotsKitSmokeTests"), "--slot-editor-only"])
run("full-kit", [str(repo / ".build/debug/ClipSlotsKitSmokeTests")])
run("disk-guard", [sys.executable, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_disk_guard.py"])
run("backup-checkpoint", [sys.executable, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_backup_checkpoint.py"])

native = root / "prepared-native"
if native.exists():
    bundle = native / "ClipSlots Editor Test.app"
    assert plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["ClipSlotsIsolatedCandidate"]
    active = subprocess.check_output(["ps", "-axo", "comm="], text=True)
    assert str(bundle) not in active
    for name in ["app-regression.json", "storage-responsiveness.json", "mascot-raster.json", "mascot-scheduled.json"]:
        if (native / name).exists():
            shutil.copy2(native / name, evidence / ("before-final-" + name))
    if (native / "data").exists():
        shutil.rmtree(native / "data")
run("native", [sys.executable, "scripts/test-slot-editor.py",
               "--root", str(native), "--binary", str(repo / ".build/debug/ClipSlots")])
report = json.loads((native / "app-regression.json").read_text())
assert report["passed"] and not report["failures"]
for name in ["app-regression.json", "storage-responsiveness.json", "mascot-raster.json", "mascot-scheduled.json"]:
    shutil.copy2(native / name, evidence / name)
print(json.dumps({"passed": True, "native_passes": report["passes"], "evidence": str(evidence)}), flush=True)
