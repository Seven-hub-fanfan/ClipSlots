#!/usr/bin/env python3
"""Create an explicit candidate DMG and verify mounted bytes; never install it."""
import argparse
import json
import math
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from package_inventory import inventory, logical_bytes, sha, write_new_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    for path in [args.output, args.report]:
        if path.exists() or path.is_symlink() or not path.parent.is_dir():
            raise ValueError("Output/report must be new files with existing parents.")
        if Path("/Applications") in path.resolve().parents:
            raise ValueError("Image creation cannot write to an installation directory.")
    if args.output.suffix != ".dmg":
        raise ValueError("Output must end in .dmg.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    before = inventory(app)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    root = Path(tempfile.mkdtemp(prefix="clipslots-candidate-dmg-", dir="/private/tmp"))
    writable = root / "writable.dmg"
    mount = root / "volume"
    mount.mkdir()
    size_mb = max(64, math.ceil(logical_bytes(before) / 1048576) + 32)
    subprocess.run(["hdiutil", "create", "-size", str(size_mb) + "m", "-fs", "HFS+",
                    "-volname", "ClipSlots v" + version, str(writable)], check=True)
    subprocess.run(["hdiutil", "attach", "-nobrowse", "-noautoopen", "-mountpoint",
                    str(mount), str(writable)], check=True)
    try:
        (mount / ".metadata_never_index").touch()
        subprocess.run(["ditto", str(app), str(mount / "ClipSlots.app")], check=True)
        if inventory(mount / "ClipSlots.app") != before:
            raise ValueError("Writable image copy differs from the signed candidate.")
        subprocess.run(["codesign", "--verify", "--deep", "--strict",
                        str(mount / "ClipSlots.app")], check=True)
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True)
    subprocess.run(["hdiutil", "convert", str(writable), "-format", "UDZO",
                    "-imagekey", "zlib-level=9", "-o", str(args.output.resolve())], check=True)
    subprocess.run(["hdiutil", "verify", str(args.output.resolve())], check=True)
    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                    "-mountpoint", str(mount), str(args.output.resolve())], check=True)
    try:
        readback = inventory(mount / "ClipSlots.app")
        if readback != before:
            raise ValueError("Compressed mounted image differs from the signed candidate.")
        subprocess.run(["codesign", "--verify", "--deep", "--strict",
                        str(mount / "ClipSlots.app")], check=True)
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True)
    if inventory(app) != before:
        raise ValueError("Source candidate changed during image creation.")
    report = {"schema": "clipslots.dmg.v1", "version": version, "build": build,
              "candidate": str(app), "temporaryRoot": str(root), "dmg": str(args.output.resolve()),
              "dmgBytes": args.output.stat().st_size, "dmgSHA256": sha(args.output),
              "appBytes": logical_bytes(before), "signatureVerified": True,
              "mountedReadbackVerified": True, "inventory": readback, "installed": False, "published": False}
    write_new_json(args.report, report)
    print(json.dumps({k: v for k, v in report.items() if k != "inventory"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
