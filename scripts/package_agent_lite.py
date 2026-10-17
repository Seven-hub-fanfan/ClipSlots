#!/usr/bin/env python3
"""Package the verified native release and a separate data-isolated preview."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess

repo = Path(__file__).resolve().parent.parent
output = repo / "build/agent-lite-candidate"
output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((repo / "Info.plist").read_bytes())
assert info["CFBundleVersion"] == "2171201"

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def sign(app):
    for path in (app / "Contents/MacOS").iterdir():
        if path.name != "ClipSlots" or not (app / "Contents/MacOS/ClipSlots-bin").exists():
            subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(path)], check=True)
    subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)

production = output / "ClipSlots.app"
assert not production.exists(), "Archive the previous candidate before repackaging"
contents = production / "Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
for source, target in [("ClipSlots", "ClipSlots"), ("ClipSlotsCLI", "clipslots-cli")]:
    shutil.copy2(repo / ".build/release" / source, contents / "MacOS" / target)
shutil.copy2(repo / "Info.plist", contents / "Info.plist")
shutil.copy2(repo / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
shutil.copytree(repo / "skills/clipslots-manager", contents / "Resources/skills/clipslots-manager")
sign(production)

preview = output / "ClipSlots Agent Preview.app"
shutil.copytree(production, preview, symlinks=True)
c = preview / "Contents"
preview_info = dict(info, CFBundleIdentifier="com.clipslots.app.agent-lite-preview",
                    CFBundleDisplayName="ClipSlots Agent Preview", ClipSlotsIsolatedCandidate=True)
(c / "Info.plist").write_bytes(plistlib.dumps(preview_info))
(c / "MacOS/ClipSlots").rename(c / "MacOS/ClipSlots-bin")
(c / "MacOS/ClipSlots").write_text('''#!/bin/bash
set -euo pipefail
MACOS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$MACOS/../../.." && pwd)/CandidateData"
export CLIPSLOTS_DATA_DIR="$ROOT"
export CLIPSLOTS_CONFIG_PATH="$ROOT/config.toml"
if [ "${1:-}" = "--isolation-info" ]; then
  printf 'data=%s\\nconfig=%s\\n' "$CLIPSLOTS_DATA_DIR" "$CLIPSLOTS_CONFIG_PATH"
  exit 0
fi
mkdir -p "$ROOT"
exec "$MACOS/ClipSlots-bin" "$@"
''')
(c / "MacOS/ClipSlots").chmod(0o755)
sign(preview)
manifest = {
    "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    "production": str(production), "preview": str(preview),
    "source_binary_sha256": sha(repo / ".build/release/ClipSlots"),
    "gui_sha256": sha(contents / "MacOS/ClipSlots"),
    "cli_sha256": sha(contents / "MacOS/clipslots-cli"),
    "runtime_absent": not (contents / "Resources/codex-runtime").exists(),
    "published": False,
}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
