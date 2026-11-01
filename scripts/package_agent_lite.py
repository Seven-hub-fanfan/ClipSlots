#!/usr/bin/env python3
"""Package explicit local products into a new candidate; never install or launch GUI."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

import disk_guard
from package_inventory import inventory, sha, validate_tree, write_new_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="New directory; its parent must already exist.")
    parser.add_argument("--allow-adhoc", action="store_true",
                        help="Explicitly permit a local ad-hoc candidate, not a release signature.")
    args = parser.parse_args()
    disk_guard.check_space("Package Agent candidate", reserve_gib=2)
    repo = Path(__file__).resolve().parents[1]
    products = args.products_dir.resolve(strict=True)
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Output already exists; preserve it and choose a new directory.")
    output = output.resolve()
    if not output.parent.is_dir():
        raise ValueError("Output parent must already exist.")
    if output == Path("/Applications") or Path("/Applications") in output.parents:
        raise ValueError("Packaging cannot write to an installation directory.")
    if output == products or products in output.parents or output in products.parents:
        raise ValueError("Output must be separate from the products directory.")
    if not args.allow_adhoc and not os.environ.get("SIGN_IDENTITY"):
        raise ValueError("Use an existing SIGN_IDENTITY or explicitly pass --allow-adhoc.")
    info_path = repo / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not isinstance(version, str) or not all(x.isdigit() for x in version.split(".")):
        raise ValueError("Info.plist has an invalid version.")
    if not isinstance(build, str) or not build.isdigit():
        raise ValueError("Info.plist has an invalid build.")
    if info["CFBundleExecutable"] != "ClipSlots":
        raise ValueError("Unexpected GUI executable name.")
    product_names = {"ClipSlots": "ClipSlots", "ClipSlotsCLI": "clipslots-cli",
                     "ClipSlotsMCP": "clipslots-mcp"}
    sources = {}
    for name in product_names:
        path = products / name
        if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError("Missing regular executable: " + str(path))
        architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).strip()
        sources[name] = {"path": str(path), "bytes": path.stat().st_size,
                         "sha256": sha(path), "architecture": architecture}
    resource_sources = [
        (products / "ClipSlots_ClipSlotsKit.bundle", "Contents/Resources/ClipSlots_ClipSlotsKit.bundle"),
        (repo / "assets/AppIcon.icns", "Contents/Resources/AppIcon.icns"),
        (repo / "skills/clipslots-manager", "Contents/Resources/skills/clipslots-manager"),
    ]
    for path, _ in resource_sources:
        validate_tree(path)
    # Verify every source resource before making any output. A missing resource
    # bundle may otherwise be hidden by SwiftPM's absolute build-directory fallback.
    built_resources = inventory(resource_sources[0][0])
    source_resources = inventory(repo / "Sources/ClipSlotsKit/Resources")
    expected = {"Resources/" + name: value for name, value in source_resources.items()}
    if built_resources != expected:
        raise ValueError("Built Kit resources do not match the source resource tree.")
    output.mkdir()
    app = output / "ClipSlots.app"
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    (app / "Contents/Resources").mkdir()
    shutil.copy2(info_path, app / "Contents/Info.plist")
    records = []
    for source_name, target_name in product_names.items():
        target = macos / target_name
        shutil.copy2(products / source_name, target)
        copied = sha(target)
        if copied != sources[source_name]["sha256"]:
            raise ValueError("Product copy differs from source: " + source_name)
        records.append(dict(sources[source_name], sourceName=source_name,
                            destination="Contents/MacOS/" + target_name, copiedSHA256=copied))
    resource_records = []
    for source, relative in resource_sources:
        target = app / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, symlinks=False)
            entries = inventory(source)
            if entries != inventory(target):
                raise ValueError("Resource copy differs from source: " + str(source))
            for name, entry in entries.items():
                resource_records.append(dict(entry, source=str(source / name),
                                             destination=relative + "/" + name))
        else:
            shutil.copy2(source, target)
            if sha(source) != sha(target):
                raise ValueError("Resource copy differs from source: " + str(source))
            resource_records.append({"source": str(source), "destination": relative,
                                     "bytes": target.stat().st_size, "sha256": sha(target)})
    env = dict(os.environ)
    if args.allow_adhoc:
        env["ALLOW_ADHOC"] = "1"
    subprocess.run(["python3", str(repo / "scripts/sign_app_bundle.py"), str(app)],
                   env=env, check=True)
    for row in records:
        row["signedSHA256"] = sha(app / row["destination"])
    for row in resource_records:
        if sha(app / row["destination"]) != row["sha256"]:
            raise ValueError("Signed resource differs from source: " + row["destination"])
    signature = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
                               check=True, capture_output=True, text=True).stderr
    manifest = {
        "schema": "clipslots.package.v1", "version": version, "build": build,
        "bundleIdentifier": info["CFBundleIdentifier"], "minimumSystem": info["LSMinimumSystemVersion"],
        "app": str(app), "productsDirectory": str(products), "products": records,
        "resources": resource_records, "inventory": inventory(app),
        "signatureVerified": True, "signatureDetails": signature,
        "signatureKind": "ad-hoc" if "Signature=adhoc" in signature else "certificate",
        "preview": {"created": False, "isolationVerified": False,
                    "reason": "Data/config overrides alone do not isolate credentials, preferences and all persistence roots."},
        "codexRuntimeAbsent": not (app / "Contents/Resources/codex-runtime").exists(),
        "installed": False, "published": False, "guiLaunchVerified": False,
    }
    write_new_json(output / "manifest.json", manifest)
    print(json.dumps({k: v for k, v in manifest.items()
                      if k not in ("inventory", "resources", "signatureDetails")}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
