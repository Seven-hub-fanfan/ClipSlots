#!/usr/bin/env python3
"""Run the isolated native Agent suite on an unlocked Mac.

Build ClipSlots in DEBUG first. Invoke this runner through disk_guard.py run,
registering .build and the supplied output directory. Requires Python PyObjC
(Quartz), Accessibility input access and screen capture access.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

import Quartz

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
root = args.output.resolve()
assert str(root).startswith("/private/tmp/clipslots-agent-background-")
static_only = os.environ.get("CLIPSLOTS_FOLLOWUP_STATIC_ONLY") == "1"
assert static_only or not Quartz.CGSessionCopyCurrentDictionary().get("CGSSessionScreenIsLocked", False), \
    "Unlock the Mac before validating native input and animation."
root.mkdir(parents=True, exist_ok=True)
app = root / "Agent Onboarding Test.app"
contents = app / "Contents"
for folder in (contents / "MacOS", contents / "Resources", root / "data"):
    folder.mkdir(parents=True, exist_ok=True)
products = repo / ".build/arm64-apple-macosx/debug"
shutil.copy2(products / "ClipSlots", contents / "MacOS/ClipSlots")
shutil.copytree(products / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle", dirs_exist_ok=True)
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.agent-onboarding-regression",
            CFBundleName="ClipSlots Agent Onboarding Test", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
env.update(CLIPSLOTS_ONBOARDING_REGRESSION=str(root), CLIPSLOTS_DATA_DIR=str(root / "data"),
           CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
if static_only:
    env["CLIPSLOTS_FOLLOWUP_STATIC_ONLY"] = "1"
with (root / "app.log").open("w") as log:
    process = subprocess.Popen([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log)
    print(json.dumps({"pid": process.pid, "root": str(root)}), flush=True)
    try:
        deadline = time.monotonic() + 140
        while process.poll() is None:
            if time.monotonic() > deadline:
                raise subprocess.TimeoutExpired(process.args, 140)
            request = root / "scroll-request.json"
            if request.exists():
                data = json.loads(request.read_text())
                request.unlink()
                assert data["pid"] == process.pid
                assert Path(data["receipt"]).name == data["receipt"]
                assert Quartz.CGPreflightPostEventAccess()
                point = (data["x"], data["y"])
                windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, 0)
                target = next((w for w in windows
                    if w.get("kCGWindowLayer") == 0 or w.get("kCGWindowNumber") == data["window"]
                    if w.get("kCGWindowAlpha", 1) > 0
                    if w["kCGWindowBounds"]["X"] <= point[0] <= w["kCGWindowBounds"]["X"] + w["kCGWindowBounds"]["Width"]
                    if w["kCGWindowBounds"]["Y"] <= point[1] <= w["kCGWindowBounds"]["Y"] + w["kCGWindowBounds"]["Height"]), None)
                matched = bool(target and target["kCGWindowOwnerPID"] == process.pid
                               and target["kCGWindowNumber"] == data["window"])
                if matched:
                    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
                    move = Quartz.CGEventCreateMouseEvent(source, Quartz.kCGEventMouseMoved, point, 0)
                    Quartz.CGEventSetFlags(move, 0)
                    Quartz.CGEventPost(Quartz.kCGHIDEventTap, move)
                    Quartz.CFRunLoopRunInMode(Quartz.kCFRunLoopDefaultMode, 0.08, False)
                    packets = [(data["delta"], 0)]
                    if data.get("kind", "").endswith("gesture"):
                        packets = [(-12, 1), (-36, 2), (0, 4)]
                    for delta, phase in packets:
                        event = Quartz.CGEventCreateScrollWheelEvent(source, Quartz.kCGScrollEventUnitPixel, 1, delta)
                        Quartz.CGEventSetLocation(event, point)
                        Quartz.CGEventSetFlags(event, 0)
                        Quartz.CGEventSetIntegerValueField(event, Quartz.kCGScrollWheelEventScrollPhase, phase)
                        Quartz.CGEventSetIntegerValueField(event, Quartz.kCGScrollWheelEventMomentumPhase, 0)
                        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
                        Quartz.CFRunLoopRunInMode(Quartz.kCFRunLoopDefaultMode, 0.025, False)
                    Quartz.CFRunLoopRunInMode(Quartz.kCFRunLoopDefaultMode, 0.12, False)
                (root / data["receipt"]).write_text(json.dumps({"success": matched,
                    "window": target.get("kCGWindowNumber") if target else None}))
            time.sleep(0.025)
        code = process.returncode
    except BaseException:
        process.terminate()
        process.wait(timeout=10)
        raise
report = root / ("followup-static-regression.json" if static_only else "app-regression.json")
if report.exists():
    result = json.loads(report.read_text())
    print(json.dumps({k: v for k, v in result.items() if k != "diagnostics"}, ensure_ascii=False, indent=2))
else:
    print((root / "app.log").read_text()[-4000:])
raise SystemExit(code)
