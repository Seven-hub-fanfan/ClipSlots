#!/usr/bin/env python3
"""Package local release products and sources; never install, commit or publish."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-root", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
options = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
output = options.output.resolve()
output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((repo / "Info.plist").read_bytes())
version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
assert all(part.isdigit() for part in version.split(".")) and build.isdigit()
products = options.build_root / "release"
app = output / "ClipSlots.app"
assert not app.exists(), "Existing package must be archived before repackaging."
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


for source, name in [("ClipSlots", "ClipSlots"), ("ClipSlotsCLI", "clipslots-cli")]:
    shutil.copy2(products / source, contents / "MacOS" / name)
shutil.copy2(repo / "Info.plist", contents / "Info.plist")
shutil.copy2(repo / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
shutil.copytree(repo / "skills/clipslots-manager", contents / "Resources/skills/clipslots-manager")
shutil.copytree(products / "ClipSlots_ClipSlotsKit.bundle", contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
for name in ["ClipSlots", "clipslots-cli"]:
    subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(contents / "MacOS" / name)], check=True)
subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
with tempfile.TemporaryDirectory(prefix="clipslots-package-version-") as temporary:
    env = dict(os.environ, CLIPSLOTS_DATA_DIR=str(Path(temporary) / "data"),
               CLIPSLOTS_CONFIG_PATH=str(Path(temporary) / "config.toml"))
    cli = json.loads(subprocess.check_output([str(contents / "MacOS/clipslots-cli"), "version"], text=True, env=env))
assert cli["ok"] and cli["version"] == version
assert not (contents / "Resources/codex-runtime").exists()
source_zip = output / f"ClipSlots_{version}_source.zip"
assert not source_zip.exists()
source_paths = [repo / name for name in ["Info.plist", "Package.swift", "CLAUDE.md", "MEMORY.md", ".gitignore"]]
source_paths += [p for folder in ["Sources", "Tests", "scripts", "skills", "assets", "gateway"]
                 for p in (repo / folder).rglob("*") if p.is_file() and "__pycache__" not in p.parts]
with zipfile.ZipFile(source_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(source_paths):
        archive.write(path, "ClipSlots/" + str(path.relative_to(repo)))
dmg = output / f"ClipSlots_v{version}.dmg"
assert not dmg.exists()
subprocess.run(["hdiutil", "create", "-fs", "HFS+", "-srcfolder", str(app),
                "-volname", f"ClipSlots v{version}", "-format", "UDZO", str(dmg)], check=True)
evidence = output / "evidence"
evidence.mkdir(exist_ok=True)
resource_hashes = {str(p.relative_to(contents / "Resources")): sha(p)
                   for p in (contents / "Resources").rglob("*") if p.is_file()}
manifest = {"version": version, "build": build, "app": str(app), "gui_sha256": sha(contents / "MacOS/ClipSlots"),
            "cli_sha256": sha(contents / "MacOS/clipslots-cli"), "cli": cli,
            "resources": resource_hashes, "source_files": len(source_paths),
            "app_bytes": sum(p.stat().st_size for p in app.rglob("*") if p.is_file()),
            "dmg_sha256": sha(dmg), "dmg_bytes": dmg.stat().st_size,
            "source_sha256": sha(source_zip), "signature": "ad-hoc", "signature_verified": True,
            "codex_runtime_absent": True, "published": False}
(evidence / "package-verification.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in manifest.items() if k != "resources"}, ensure_ascii=False, indent=2))
