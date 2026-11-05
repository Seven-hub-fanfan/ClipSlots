#!/usr/bin/env python3
"""Create an explicit candidate DMG and verify mounted bytes; never install it."""
import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zlib

from package_inventory import inventory, logical_bytes, sha, write_new_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--temporary-parent", type=Path,
                        default=Path(os.environ.get("TMPDIR", "/private/tmp")),
                        help="Existing directory registered with disk_guard.")
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
    temporary_parent = args.temporary_parent.resolve(strict=True)
    if not temporary_parent.is_dir():
        raise ValueError("Temporary parent must be an existing directory.")
    root = Path(tempfile.mkdtemp(prefix="clipslots-candidate-dmg-", dir=temporary_parent))
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
        (mount / "Applications").symlink_to("/Applications", target_is_directory=True)
        background = mount / ".background"
        background.mkdir()
        def chunk(kind, data):
            return (struct.pack(">I", len(data)) + kind + data
                    + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
        width, height = 640, 360
        rows = b"".join(b"\x00" + bytes((248 - y * 8 // height,
            249 - y * 9 // height, 251 - y * 7 // height)) * width for y in range(height))
        (background / "background.png").write_bytes(b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
        (mount / "安装说明.txt").write_text(
            "将 ClipSlots.app 拖入 Applications，然后从应用程序目录启动。\n"
            "需要 macOS 13 或更高版本、Apple Silicon（arm64）。\n"
            "此构建使用 ad-hoc 签名，未进行 Apple 公证。\n",
            encoding="utf-8")
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
        if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
            raise ValueError("Applications installation link is missing or invalid.")
        if not (mount / ".background/background.png").is_file():
            raise ValueError("Installer background is missing.")
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
    shutil.rmtree(root)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
