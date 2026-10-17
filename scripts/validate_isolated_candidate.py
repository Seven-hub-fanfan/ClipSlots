#!/usr/bin/env python3
"""Validate a candidate in a temporary copy without installing it."""
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

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
source = args.app.resolve()
info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
assert info.get("ClipSlotsIsolatedCandidate") is True, "Candidate isolation marker required"
assert info["CFBundleIdentifier"] != "com.clipslots.app"
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)


def fingerprint(path):
    if path.is_symlink():
        return {"symlink": os.readlink(path)}
    if path.is_file():
        return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    return {"exists": path.exists()}


protected = [
    Path("/Applications/ClipSlots.app/Contents/Info.plist"),
    Path("/Applications/ClipSlots.app/Contents/MacOS/ClipSlots"),
]
protected += [Path.home() / folder / "skills/clipslots-manager"
              for folder in [".codex", ".claude", ".cursor", ".gemini"]]
before = {str(path): fingerprint(path) for path in protected}
root = Path(tempfile.mkdtemp(prefix="clipslots-batch-launch-", dir="/tmp"))
app = root / source.name
shutil.copytree(source, app, symlinks=True)
launcher = app / "Contents/MacOS/ClipSlots"
isolation = subprocess.check_output([str(launcher), "--isolation-info"], text=True)
locations = dict(line.split("=", 1) for line in isolation.splitlines())
assert Path(locations["data"]).resolve() == (root / "CandidateData").resolve()
assert Path(locations["config"]).resolve() == (root / "CandidateData/config.toml").resolve()
env = {key: value for key, value in os.environ.items()
       if not key.startswith("CLIPSLOTS_") and not key.startswith("CANVAS_")}
env.update(CLIPSLOTS_PERF_AUTOTEST="1", CLIPSLOTS_PERF_AUTOTEST_SCENARIO="launch-only",
           CLIPSLOTS_PERF_AUTOTEST_KEEP="1")
log_path = root / "launch.log"
with log_path.open("w") as log:
    process = subprocess.Popen([str(launcher)], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        time.sleep(8)
        running = process.poll() is None
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
log_text = log_path.read_text()
after = {str(path): fingerprint(path) for path in protected}
checks = {
    "signature_verified": True,
    "launcher_roots_in_temporary_copy": True,
    "process_running_after_8_seconds": running,
    "temporary_data_created": (root / "CandidateData/special_slots").is_dir(),
    "external_skill_autosync_skipped": "isolated candidate, skip external agent skill auto-sync" in log_text,
    "production_app_and_agent_links_unchanged": before == after,
}
report = {
    "build": info["CFBundleVersion"],
    "bundle_id": info["CFBundleIdentifier"],
    "source_binary_sha256": fingerprint(source / "Contents/MacOS/ClipSlots-bin")["sha256"],
    "temporary_copy": str(app),
    "log": str(log_path),
    "checks": checks,
    "passed": all(checks.values()),
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if report["passed"] else 1)
