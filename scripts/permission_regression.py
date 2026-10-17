#!/usr/bin/env python3
"""Run permission fixtures through Launch Services in a separate signed app."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--skip-build", action="store_true")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
if not args.skip_build:
    subprocess.run(["swift", "build"], cwd=repo, check=True)
work = Path(tempfile.mkdtemp(prefix="clipslots-permission-probe-", dir="/tmp"))
app = work / "ClipSlots Permission Probe.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.permission-repair-probe",
            CFBundleName="ClipSlots Permission Probe", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(repo / ".build/debug/ClipSlots", contents / "MacOS/ClipSlots")
shutil.copy2(repo / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
shutil.copytree(repo / ".build/debug/ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
subprocess.run(["/usr/bin/codesign", "--force", "--timestamp=none", "--sign", "-", str(app)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
data = work / "data"
data.mkdir()
command = ["/usr/bin/open", "-n", "-W", "--stdout", str(output / "run.log"),
           "--stderr", str(output / "run.log")]
for key, value in {
    "CLIPSLOTS_PERMISSION_PROBE": "1", "CLIPSLOTS_PERMISSION_OUTPUT": str(output),
    "CLIPSLOTS_DATA_DIR": str(data), "CLIPSLOTS_CONFIG_PATH": str(work / "config.toml"),
    "CLIPSLOTS_PERF_AUTOTEST": "1",
    "CLIPSLOTS_PERF_AUTOTEST_KEEP": "1", "CLIPSLOTS_PERF_AUTOTEST_SCENARIO": "permission-fixture",
}.items():
    command += ["--env", key + "=" + value]
command.append(str(app))
print("Isolated Launch Services probe:", app, flush=True)
for marker in ["accessibility-pid", "accessibility-ready", "report.json"]:
    (output / marker).unlink(missing_ok=True)
launch = subprocess.Popen(command)
deadline = time.monotonic() + 30
while not (output / "accessibility-pid").exists() and launch.poll() is None and time.monotonic() < deadline:
    time.sleep(0.1)
if (output / "accessibility-pid").exists():
    pid = (output / "accessibility-pid").read_text().strip()
    query = """
import ApplicationServices
import Foundation
guard let pid = Int32(CommandLine.arguments[1]) else { exit(1) }
let app = AXUIElementCreateApplication(pid)
let status = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
var windows: CFTypeRef?
let read = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
print("trusted=\\(AXIsProcessTrusted()) set=\\(status.rawValue) read=\\(read.rawValue)")
"""
    client = subprocess.run(["/usr/bin/swift", "-e", query, pid],
                            capture_output=True, text=True, timeout=20)
    (output / "accessibility-client.txt").write_text(client.stdout + client.stderr)
    (output / "accessibility-ready").touch()
if launch.wait(timeout=60) != 0:
    raise SystemExit("Launch Services probe failed; inspect run.log.")
report = json.loads((output / "report.json").read_text())
report.update(launch_services=True, candidate_bundle_id=info["CFBundleIdentifier"],
              candidate_path=str(app), data_directory=str(data))
(output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
raise SystemExit(1 if report["failures"] or not report["complete"] else 0)
