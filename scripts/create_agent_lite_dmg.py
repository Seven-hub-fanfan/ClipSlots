#!/usr/bin/env python3
"""Create a compressed DMG through a manually mounted temporary HFS+ volume."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="clipslots-21712-dmg-", dir="/tmp"))
image = work / "writable.dmg"
mount = work / "volume"
mount.mkdir()
candidate = repo / "build/agent-lite-candidate/ClipSlots.app"
output = repo / "build/agent-lite-candidate/ClipSlots_v2.17.12.dmg"
assert not output.exists(), "Keep the previously measured DMG unchanged"
subprocess.run(["hdiutil", "create", "-size", "64m", "-fs", "HFS+", "-volname",
                "ClipSlots v2.17.12", str(image)], check=True)
subprocess.run(["hdiutil", "attach", "-nobrowse", "-noautoopen", "-mountpoint",
                str(mount), str(image)], check=True)
try:
    (mount / ".metadata_never_index").touch()
    subprocess.run(["ditto", str(candidate), str(mount / "ClipSlots.app")], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict",
                    str(mount / "ClipSlots.app")], check=True)
finally:
    result = subprocess.run(["hdiutil", "detach", str(mount)])
    if result.returncode:
        subprocess.run(["hdiutil", "detach", "-force", str(mount)], check=True)
subprocess.run(["hdiutil", "convert", str(image), "-format", "UDZO", "-imagekey",
                "zlib-level=9", "-o", str(output)], check=True)
subprocess.run(["hdiutil", "verify", str(output)], check=True)
print(str(output), output.stat().st_size, flush=True)
