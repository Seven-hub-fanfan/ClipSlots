#!/usr/bin/env python3
"""Guarded local bundle swap with verified APFS data backup; no TCC reset."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--delivery", type=Path, required=True)
parser.add_argument("--expected-installed-version", required=True, help="Stop if another version was installed concurrently")
options = parser.parse_args()
delivery = options.delivery.resolve()
installed = Path("/Applications/ClipSlots.app")
candidate = delivery / "ClipSlots.app"
data = Path.home() / ".local/share/clipslots"
config = Path.home() / ".config/clipslots"
manifest = json.loads((delivery / "evidence/package-verification.json").read_text())
launch = json.loads((delivery / "evidence/release-launch.json").read_text())
assert launch["passed"]
version = manifest["version"]
candidate_info = plistlib.loads((candidate / "Contents/Info.plist").read_bytes())
assert candidate_info["CFBundleShortVersionString"] == version
assert candidate_info["CFBundleVersion"] == manifest["build"]
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = delivery / "backups" / stamp
stage = Path(f"/Applications/.ClipSlots-rea-{stamp}.app")


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def pids():
    return subprocess.run(["pgrep", "-f", r"^/Applications/ClipSlots.app/Contents/MacOS/ClipSlots( |$)"],
                          text=True, capture_output=True).stdout.split()


def quit_app():
    if pids():
        subprocess.run(["osascript", "-e", 'tell application id "com.clipslots.app" to quit'],
                       check=True, timeout=15)
        for _ in range(100):
            if not pids():
                return
            time.sleep(0.1)
    assert not pids(), "Existing app did not quit; bundle replacement stopped."


def clone(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/bin/cp", "-cR", str(source), str(target)], check=True)


def files(root, normalized=False):
    result = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() and not path.is_symlink():
            continue
        name = str(path.relative_to(root))
        if normalized and path.name.endswith(".lock"):
            continue
        if path.is_symlink():
            result[name] = {"link": os.readlink(path)}
        elif normalized and name.startswith("canvas/projects/") and path.name == "canvas.json":
            value = json.loads(path.read_text())
            value.pop("updatedAt", None)
            if value.get("appliedAgentMutationIDs") == []:
                value.pop("appliedAgentMutationIDs")
            result[name] = {"semantic_sha256": hashlib.sha256(
                json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()}
        else:
            result[name] = {"sha256": sha(path), "bytes": path.stat().st_size}
    return result


def links():
    paths = [Path("/usr/local/bin/clipslots"), Path.home() / "bin/clipslots"]
    paths += [Path.home() / f"{folder}/skills/clipslots-manager" for folder in [".claude", ".cursor", ".gemini", ".codex"]]
    return {str(p): os.readlink(p) if p.is_symlink() else sha(p) if p.is_file() else p.exists() for p in paths}


def business_files(snapshot):
    # CLI version queries also update their process-lock PID. Retain lock files
    # in the clone, but compare business bytes independently of live bookkeeping.
    return {name: value for name, value in snapshot.items() if not Path(name).name.endswith(".lock")}


def verify(app):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


verify(candidate)
assert sha(candidate / "Contents/MacOS/ClipSlots") == manifest["gui_sha256"]
assert sha(candidate / "Contents/MacOS/clipslots-cli") == manifest["cli_sha256"]
assert sha(candidate / "Contents/MacOS/clipslots-mcp") == manifest["mcp_sha256"]
old = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
previous_version = old["CFBundleShortVersionString"]
assert previous_version == options.expected_installed_version
assert not backup.exists() and not stage.exists()
backup.mkdir(parents=True)
clone(candidate, stage)
quit_app()
print("Application closed; hashing all data and configuration.", flush=True)
before_raw = {"data": files(data), "config": files(config)}
before = {"data": files(data, True), "config": files(config, True), "links": links()}
(backup / "protected-before.json").write_text(json.dumps(before_raw, indent=2) + "\n")
print("Creating full APFS clones, including runtime lock files.", flush=True)
clone(data, backup / "data")
clone(config, backup / "config")
backup_files = {"data": files(backup / "data"), "config": files(backup / "config")}
assert all(business_files(backup_files[key]) == business_files(before_raw[key]) for key in before_raw)
assert business_files(files(data)) == business_files(before_raw["data"])
assert business_files(files(config)) == business_files(before_raw["config"])
assert not pids(), "App restarted during backup; replacement stopped."
old_backup = backup / f"ClipSlots_v{previous_version}.app"
installed.rename(old_backup)
try:
    stage.rename(installed)
    verify(installed)
    subprocess.run(["open", str(installed)], check=True)
    for _ in range(100):
        if pids():
            break
        time.sleep(0.1)
    assert pids(), "New application did not remain running."
    time.sleep(5)
    cli = json.loads(subprocess.check_output([str(installed / "Contents/MacOS/clipslots-cli"), "version"], text=True))
    assert cli["ok"] and cli["version"] == version
    assert sha(installed / "Contents/MacOS/clipslots-mcp") == manifest["mcp_sha256"]
    after = {"data": files(data, True), "config": files(config, True), "links": links()}
    if before != after:
        differences = {key: [name for name in set(before[key]) | set(after[key])
                             if before[key].get(name) != after[key].get(name)]
                       for key in before}
        (backup / "launch-differences.json").write_text(json.dumps(differences, indent=2) + "\n")
        raise RuntimeError("Protected data differs after launch; bundle rolled back, data kept for diagnosis.")
except Exception:
    quit_app()
    if installed.exists():
        installed.rename(backup / f"Failed-ClipSlots_v{version}.app")
    old_backup.rename(installed)
    subprocess.run(["open", str(installed)], check=False)
    raise
report = {"version": version, "previous_version": previous_version,
          "installed": str(installed), "backup": str(backup), "pids": pids(), "cli": cli,
          "signature_verified": True, "atomic_bundle_swap": True,
          "full_data_backup_verified": True, "protected_data_files": len(before_raw["data"]),
          "runtime_lock_files_in_full_backup": True,
          "backup_lock_differences": {key: [name for name in set(backup_files[key]) | set(before_raw[key])
                                           if backup_files[key].get(name) != before_raw[key].get(name)]
                                      for key in before_raw},
          "protected_data_bytes": sum(v.get("bytes", 0) for v in before_raw["data"].values()),
          "protected_config_files": len(before_raw["config"]), "protected_content_unchanged": before == after,
          "comparison_excludes": ["*.lock", "canvas/projects/*/canvas.json:updatedAt",
                                  "empty appliedAgentMutationIDs default only"],
          "external_links_unchanged": before["links"] == after["links"],
          "tcc_reset_executed": False, "published": False,
          "gui_sha256": manifest["gui_sha256"], "cli_sha256": manifest["cli_sha256"],
          "mcp_sha256": manifest["mcp_sha256"]}
(delivery / "evidence/install-verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
