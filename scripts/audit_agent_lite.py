#!/usr/bin/env python3
"""Audit an explicit candidate and optional identified baseline; never reuse historical defaults."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

from package_inventory import inventory, logical_bytes, sha, write_new_json


def app_record(app):
    app = app.resolve(strict=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    entries = inventory(app)
    binaries = {name: entries["Contents/MacOS/" + name]
                for name in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
    resources = {name: row for name, row in entries.items() if name.startswith("Contents/Resources/")}
    links = {name: row for name, row in entries.items() if row["kind"] == "symlink"}
    return {
        "path": str(app), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "bundleIdentifier": info["CFBundleIdentifier"], "minimumSystem": info["LSMinimumSystemVersion"],
        "signatureVerified": True, "logicalBytes": logical_bytes(entries),
        "products": binaries, "productBytes": logical_bytes(binaries),
        "resourcesBytes": logical_bytes(resources), "otherBytes": logical_bytes(entries) - logical_bytes(binaries) - logical_bytes(resources),
        "symlinks": links, "inventory": entries,
        "codexRuntimeAbsent": not any("codex-runtime" in name.split("/") for name in entries),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-app", type=Path)
    parser.add_argument("--baseline-id", help="Identity/role of this independently verified baseline.")
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--dmg", type=Path)
    args = parser.parse_args()
    if bool(args.baseline_app) != bool(args.baseline_id):
        raise ValueError("Baseline app and identity must be supplied together.")
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("Audit output already exists; choose a new file.")
    if not args.output.parent.is_dir():
        raise ValueError("Audit output parent must already exist.")
    manifest = json.loads(args.manifest.read_text())
    if manifest.get("schema") != "clipslots.package.v1":
        raise ValueError("Unsupported package manifest.")
    current = app_record(args.app)
    if current["inventory"] != manifest["inventory"]:
        raise ValueError("Candidate inventory differs from the package manifest.")
    for key in ["version", "build", "bundleIdentifier", "minimumSystem"]:
        if current[key] != manifest[key]:
            raise ValueError("Candidate metadata differs from the package manifest: " + key)
    result = {
        "schema": "clipslots.size-audit.v1",
        "byteUnit": "Logical lengths of regular files. MiB = 1048576 bytes; symlink targets counted once.",
        "current": current, "packageManifestSHA256": sha(args.manifest),
        "baseline": None, "comparison": None, "source": None, "dmg": None,
        "attribution": "Source, app resources, products and DMG are separate views; do not add them.",
        "guiLaunchVerified": False, "installed": False, "published": False,
    }
    if args.baseline_app:
        baseline = app_record(args.baseline_app)
        result["baseline"] = dict(baseline, identity=args.baseline_id)
        delta = current["logicalBytes"] - baseline["logicalBytes"]
        growth = delta / baseline["logicalBytes"] if baseline["logicalBytes"] else None
        result["comparison"] = {"logicalBytesDelta": delta, "growthRatio": growth,
                                "withinSuggestedFivePercent": growth is not None and growth <= 0.05,
                                "identity": args.baseline_id}
    if args.source_root:
        sources = inventory(args.source_root)
        result["source"] = {"path": str(args.source_root.resolve()), "logicalBytes": logical_bytes(sources),
                            "regularFiles": sum(v["kind"] == "file" for v in sources.values()),
                            "inventory": sources, "installedBytes": False}
    if args.dmg:
        result["dmg"] = {"path": str(args.dmg.resolve(strict=True)), "bytes": args.dmg.stat().st_size,
                         "sha256": sha(args.dmg), "mountedReadbackVerified": False}
    write_new_json(args.output, result)
    print(json.dumps({"version": current["version"], "build": current["build"],
                      "appBytes": current["logicalBytes"], "productBytes": current["productBytes"],
                      "resourceBytes": current["resourcesBytes"], "comparison": result["comparison"]},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
