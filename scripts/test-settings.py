#!/usr/bin/env python3
"""Compile a native settings fixture using the production GUI sources.

Run inside disk_guard.py run; requires a completed release ClipSlots build.
The fixture replaces only the app entry point and uses isolated preferences/data.
Whole-module optimized objects must stay together: replacing only main.swift.o
would discard generic specializations shared by the other production objects.
"""
from pathlib import Path
import argparse
import json
import os
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--bundle", type=Path, required=True, help="Existing reusable test app bundle")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
products = repo / ".build/arm64-apple-macosx/release"
desc = json.loads((products / "description.json").read_text())
command = next(v for v in desc["swiftCommands"].values() if v.get("moduleName") == "ClipSlots")
original = repo / "Sources/ClipSlots/main.swift"
replacement = root / "main.swift"
source = original.read_text()
assert source.count("@main\nstruct ClipSlotsApp: App") == 1
replacement.write_text(source.replace("@main\nstruct ClipSlotsApp: App", "struct ClipSlotsApp: App") +
                       "\n" + (repo / "Tests/SettingsRegression/Fixture.swift").read_text())
sources = [str(replacement) if Path(p) == original else p for p in command["sources"]]
sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
binary = args.bundle / "Contents/MacOS/ClipSlots"
assert (args.bundle / "Contents/Resources").is_dir(), "Reuse an existing probe bundle"
assert not subprocess.run(["pgrep", "-f", "^" + str(binary)], capture_output=True).stdout.strip(), "Probe must be stopped"
temporary = root / "temporary"
temporary.mkdir(exist_ok=True)
flags = ["-module-name", "ClipSlots", "-target", "arm64-apple-macosx13.0",
         "-I", str(products / "Modules"), "-I", str(repo / "Sources/CArchive"),
         "-O", "-whole-module-optimization", "-D", "SWIFT_PACKAGE", "-swift-version", "5",
         "-parse-as-library", "-module-cache-path", str(products / "ModuleCache"),
         "-sdk", sdk, "-package-name", "clipslots",
         *sources, *map(str, sorted((products / "ClipSlotsKit.build").glob("*.swift.o"))),
         "-larchive", "-lsqlite3", "-o", str(binary)]
with (root / "compile.log").open("w") as log:
    result = subprocess.run([command["executable"], *flags], cwd=repo, stdout=log, stderr=log,
                            env={**os.environ, "TMPDIR": str(temporary)})
if result.returncode:
    raise SystemExit((root / "compile.log").read_text()[-18000:])
subprocess.run(["strip", "-S", "-x", str(binary)], check=True)
info = plistlib.loads((repo / "Info.plist").read_bytes())
bundle_id = "com.clipslots.app.settings-regression"
info.update(CFBundleIdentifier=bundle_id, CFBundleName="ClipSlots Settings Regression", ClipSlotsIsolatedCandidate=True)
(args.bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--sign", "-", str(args.bundle)], check=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_", "DEBUG_"))}
env.update(CLIPSLOTS_DATA_DIR=str(root / "data"), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
with (root / "run.log").open("w") as log:
    result = subprocess.run([str(binary), str(root)], env=env, cwd=repo, stdout=log, stderr=log, timeout=180)
print((root / "run.log").read_text()[-5000:])
raise SystemExit(result.returncode)
