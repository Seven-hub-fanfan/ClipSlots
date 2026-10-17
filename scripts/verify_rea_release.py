#!/usr/bin/env python3
"""Check packaged bytes, mounted DMG and isolated native release launch."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--delivery", type=Path, required=True)
options = parser.parse_args()
delivery = options.delivery.resolve()
app = delivery / "ClipSlots.app"
manifest = json.loads((delivery / "evidence/package-verification.json").read_text())


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fingerprint(path):
    if path.is_symlink():
        return {"symlink": os.readlink(path)}
    if path.is_file():
        return {"sha256": sha(path)}
    return {"exists": path.exists()}


def macho_payload_sha(path):
    # A different preview Info.plist requires a fresh main-executable signature.
    # Compare every non-signature byte, normalizing only the signature load
    # command and the LINKEDIT sizes that include it.
    data = bytearray(path.read_bytes())
    assert struct.unpack_from("<I", data)[0] == 0xFEEDFACF, "Expected a thin 64-bit Mach-O"
    commands = struct.unpack_from("<I", data, 16)[0]
    position = 32
    signature = None
    for _ in range(commands):
        command, size = struct.unpack_from("<II", data, position)
        assert size >= 8 and position + size <= len(data)
        if command == 0x1D:
            signature = struct.unpack_from("<II", data, position + 8)
            data[position + 8:position + 16] = bytes(8)
        elif command == 0x19 and data[position + 8:position + 24].rstrip(b"\0") == b"__LINKEDIT":
            struct.pack_into("<Q", data, position + 32, 0)
            struct.pack_into("<Q", data, position + 48, 0)
        position += size
    assert signature is not None
    offset, size = signature
    assert offset >= position and offset + size == len(data), "Signature must be the final Mach-O data"
    return hashlib.sha256(data[:offset]).hexdigest()


def verify_bundle(bundle):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    contents = bundle / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    assert info["CFBundleShortVersionString"] == manifest["version"]
    assert info["CFBundleVersion"] == manifest["build"]
    assert sha(contents / "MacOS/ClipSlots") == manifest["gui_sha256"]
    assert sha(contents / "MacOS/clipslots-cli") == manifest["cli_sha256"]
    resources = {str(p.relative_to(contents / "Resources")): sha(p)
                 for p in (contents / "Resources").rglob("*") if p.is_file()}
    assert resources == manifest["resources"]
    return info


info = verify_bundle(app)
dmg = delivery / f'ClipSlots_v{manifest["version"]}.dmg'
assert sha(dmg) == manifest["dmg_sha256"]
subprocess.run(["hdiutil", "verify", str(dmg)], check=True)
mount = Path(tempfile.mkdtemp(prefix="clipslots-rea-release-mount-", dir="/tmp"))
try:
    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount),
                    str(dmg)], check=True)
    bundles = list(mount.glob("*.app"))
    assert len(bundles) == 1
    verify_bundle(bundles[0])
finally:
    subprocess.run(["hdiutil", "detach", str(mount)], check=True)

root = Path(tempfile.mkdtemp(prefix="clipslots-rea-release-launch-", dir="/tmp"))
preview = root / "ClipSlots REA Preview.app"
subprocess.run(["/bin/cp", "-cR", str(app), str(preview)], check=True)
preview_info = dict(info, CFBundleIdentifier="com.clipslots.app.rea-release-preview",
                    CFBundleName="ClipSlots REA Preview", ClipSlotsIsolatedCandidate=True)
(preview / "Contents/Info.plist").write_bytes(plistlib.dumps(preview_info))
subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(preview)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(preview)], check=True)
assert macho_payload_sha(preview / "Contents/MacOS/ClipSlots") == macho_payload_sha(app / "Contents/MacOS/ClipSlots")
assert sha(preview / "Contents/MacOS/clipslots-cli") == manifest["cli_sha256"]
protected = [Path("/Applications/ClipSlots.app/Contents/Info.plist"),
             Path("/Applications/ClipSlots.app/Contents/MacOS/ClipSlots"),
             Path("/usr/local/bin/clipslots"), Path.home() / "bin/clipslots"]
protected += [Path.home() / folder / "skills/clipslots-manager"
              for folder in [".codex", ".claude", ".cursor", ".gemini"]]
before = {str(p): fingerprint(p) for p in protected}
env = {k: v for k, v in os.environ.items()
       if not k.startswith("CLIPSLOTS_") and not k.startswith("CANVAS_")}
data, config = root / "CandidateData", root / "CandidateData/config.toml"
env.update(CLIPSLOTS_DATA_DIR=str(data), CLIPSLOTS_CONFIG_PATH=str(config),
           CLIPSLOTS_PERF_AUTOTEST="1", CLIPSLOTS_PERF_AUTOTEST_SCENARIO="launch-only",
           CLIPSLOTS_PERF_AUTOTEST_KEEP="1")
log_path = root / "launch.log"
with log_path.open("w") as log:
    process = subprocess.Popen([str(preview / "Contents/MacOS/ClipSlots")],
                               env=env, stdout=log, stderr=subprocess.STDOUT)
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
cli = json.loads(subprocess.check_output([str(preview / "Contents/MacOS/clipslots-cli"),
                                         "version"], env=env, text=True))
checks = {
    "package_signature_and_resource_hashes_verified": True,
    "dmg_checksum_and_mounted_bundle_verified": True,
    "preview_uses_identical_packaged_non_signature_macho_payload": True,
    "data_and_config_redirected_to_temporary_roots": True,
    "process_running_after_8_seconds": running,
    "temporary_data_created": (data / "special_slots").is_dir(),
    "external_skill_autosync_skipped":
        "isolated candidate, skip external agent skill auto-sync" in log_path.read_text(),
    "production_app_and_agent_links_unchanged":
        before == {str(p): fingerprint(p) for p in protected},
    "packaged_cli_version_matches": cli.get("ok") and cli.get("version") == manifest["version"],
}
report = {"version": manifest["version"], "build": manifest["build"],
          "bundle_id": preview_info["CFBundleIdentifier"], "temporary_copy": str(preview),
          "isolated_data": str(data), "log": str(log_path),
          "gui_sha256": manifest["gui_sha256"], "cli_sha256": manifest["cli_sha256"],
          "preview_gui_sha256": sha(preview / "Contents/MacOS/ClipSlots"),
          "non_signature_macho_payload_sha256": macho_payload_sha(app / "Contents/MacOS/ClipSlots"),
          "preview_signature_differs_for_isolated_bundle_metadata": True,
          "checks": checks, "passed": all(checks.values()),
          "scope": "release startup and packaged bytes; no UI interaction or target-equivalence claim"}
shutil.copy2(log_path, delivery / "evidence/release-launch.log")
(delivery / "evidence/release-launch.json").write_text(
    json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if report["passed"] else 1)
