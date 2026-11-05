#!/usr/bin/env python3
"""Install a signed local editor candidate with verified data backup and rollback."""
import argparse
import atexit
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import shutil
import time
import disk_guard
import backup_checkpoint

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--candidate", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--expected-installed-sha256", required=True)
parser.add_argument("--reuse-backup", type=Path,
                    help="Reuse this task's verified full backup for a follow-up local candidate.")
parser.add_argument("--backup-limit-gib", type=float, default=30,
                    help="Explicit per-install allowance, 30–31 GiB; requires user authorization above 30.")
args = parser.parse_args()
candidate = args.candidate.resolve(strict=True)
evidence = args.evidence.resolve(strict=True)
installed = Path("/Applications/ClipSlots.app")
data = Path.home() / ".local/share/clipslots"
config = Path.home() / ".config/clipslots"


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def files(root, normalized=False, hashed=None):
    result = {}
    for path in sorted(root.rglob("*")):
        name = str(path.relative_to(root))
        if path.is_symlink():
            result[name] = {"link": os.readlink(path)}
        elif path.is_file():
            if normalized and path.name.endswith(".lock"):
                continue
            if normalized and name == "special_slots/index.json":
                # JSONEncoder can reorder object keys on launch. Preserve every
                # value and array order; only object-key serialization is ignored.
                value = json.loads(path.read_text())
                result[name] = {"semantic_sha256": hashlib.sha256(
                    json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()}
            elif normalized and name.startswith("canvas/projects/") and path.name == "canvas.json":
                value = json.loads(path.read_text())
                value.pop("updatedAt", None)
                if value.get("appliedAgentMutationIDs") == []:
                    value.pop("appliedAgentMutationIDs")
                result[name] = {"semantic_sha256": hashlib.sha256(
                    json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()}
            else:
                result[name] = hashed[name] if hashed is not None and name in hashed else {
                    "sha256": sha(path), "bytes": path.stat().st_size}
    return result


def links():
    paths = [Path("/usr/local/bin/clipslots"), Path.home() / "bin/clipslots"]
    paths += [Path.home() / folder / "skills/clipslots-manager"
              for folder in [".claude", ".cursor", ".gemini", ".codex"]]
    return {str(p): os.readlink(p) if p.is_symlink() else sha(p) if p.is_file() else p.exists()
            for p in paths}


def pids():
    return subprocess.run(["pgrep", "-f", r"^/Applications/ClipSlots.app/Contents/MacOS/ClipSlots( |$)"],
                          capture_output=True, text=True).stdout.split()


def quit_app():
    if pids():
        subprocess.run(["osascript", "-e", 'tell application id "com.clipslots.app" to quit'],
                       check=True, timeout=15)
        for _ in range(100):
            if not pids():
                return
            time.sleep(0.1)
    assert not pids(), "Existing app did not quit; replacement stopped."


def clone(source, destination):
    subprocess.run(["/bin/cp", "-cR", str(source), str(destination)], check=True)


def verify(bundle):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)


verify(candidate)
assert candidate != installed and sha(installed / "Contents/MacOS/ClipSlots") == args.expected_installed_sha256
assert json.loads((evidence / "app-regression.json").read_text())["passed"]
package = json.loads((evidence / "package.json").read_text())
assert package["gui_sha256"] == sha(candidate / "Contents/MacOS/ClipSlots")
assert package["kit_regression_passed"] and package["source_format_passed"]
before_bundle = files(installed)
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
lease = disk_guard.reserve_backup("Install editor candidate",
                                 [installed] if args.reuse_backup else [data, config, installed],
                                 reuse_backup=args.reuse_backup, max_backup_gib=args.backup_limit_gib)
backup = args.reuse_backup.resolve(strict=True) if args.reuse_backup else lease.root / (stamp + "-editor-217107")
stage = Path("/Applications/.ClipSlots-editor-" + stamp + ".app")
assert backup.parent == lease.root and not backup.is_symlink() and not stage.exists()
if not args.reuse_backup:
    assert not backup.exists()
    backup.mkdir()
clone(candidate, stage)
verify(stage)

def recover_preinstall_failure():
    # Failures during checkpoint reservation/verification happen before replacement.
    # Restore the running state and remove only this invocation's disposable stage.
    if stage.exists() and installed.exists() and sha(installed / "Contents/MacOS/ClipSlots") == args.expected_installed_sha256:
        shutil.rmtree(stage)
        if not pids():
            subprocess.run(["open", str(installed)], check=False)

atexit.register(recover_preinstall_failure)
quit_app()
print("Application closed; hashing protected data and configuration.", flush=True)
before_raw = {"data": files(data), "config": files(config)}
before = {"data": files(data, True, before_raw["data"]),
          "config": files(config, True, before_raw["config"]), "links": links()}
if args.reuse_backup:
    print("Verifying the full backup and saving a checkpoint of subsequent edits.", flush=True)
    original = json.loads((backup / "protected-before.json").read_text())
    backup_raw = {"data": files(backup / "data"), "config": files(backup / "config")}
    assert backup_raw == original, "Existing backup bytes changed; replacement stopped."
    delta_bytes = backup_checkpoint.changed_bytes(original, before_raw)
    lease.reserve_additional(delta_bytes)
    checkpoint = backup / ("checkpoint-" + stamp)
    backup_checkpoint.create(backup, before_raw, {"data": data, "config": config}, checkpoint)
    print("Latest protected snapshot verified; delta bytes: " + str(delta_bytes), flush=True)
else:
    checkpoint = None
    delta_bytes = 0
    (backup / "protected-before.json").write_text(json.dumps(before_raw, indent=2))
    print("Creating full APFS backup and checking every copied file.", flush=True)
    clone(data, backup / "data")
    clone(config, backup / "config")
    assert files(backup / "data") == before_raw["data"]
    assert files(backup / "config") == before_raw["config"]
assert files(data) == before_raw["data"] and files(config) == before_raw["config"]
assert not pids() and files(installed) == before_bundle
old_app = backup / ("ClipSlots-" + stamp + ".app") if args.reuse_backup else backup / "ClipSlots.app"
assert not old_app.exists()
if checkpoint:
    (checkpoint / "application.json").write_text(json.dumps({
        "previous_application": str(old_app),
        "previous_gui_sha256": args.expected_installed_sha256,
        "protected_links": before["links"],
        "base_backup": str(backup),
        "restore": "backup_checkpoint.materialize(base_backup, checkpoint, NEW_destination); "
                   "verify before replacing any live directory"
    }, indent=2))
installed.rename(old_app)
try:
    stage.rename(installed)
    verify(installed)
    subprocess.run(["open", str(installed)], check=True)
    for _ in range(100):
        if pids():
            break
        time.sleep(0.1)
    assert pids(), "Candidate did not launch."
    print("Candidate launched; checking protected content and external links.", flush=True)
    time.sleep(5)
    assert pids(), "Candidate exited after launch."
    after_raw = {"data": files(data), "config": files(config)}
    after = {"data": files(data, True, after_raw["data"]),
             "config": files(config, True, after_raw["config"]), "links": links()}
    if before != after:
        differences = {
            kind: {name: {"before": before[kind].get(name), "after": after[kind].get(name)}
                   for name in sorted(set(before[kind]) | set(after[kind]))
                   if before[kind].get(name) != after[kind].get(name)}
            for kind in before
        }
        (evidence / ("install-differences-" + stamp + ".json")).write_text(
            json.dumps(differences, ensure_ascii=False, indent=2))
    assert before == after, "Protected content changed; rolling back application."
except Exception as error:
    failed_app = backup / ("Failed-ClipSlots-" + stamp + ".app")
    quit_app()
    if installed.exists():
        installed.rename(failed_app)
    old_app.rename(installed)
    subprocess.run(["open", str(installed)], check=False)
    (evidence / ("install-failure-" + stamp + ".json")).write_text(json.dumps({
        "error": str(error), "rolled_back": True, "checkpoint": str(checkpoint),
        "candidate_preserved": str(failed_app),
        "restored_gui_sha256": args.expected_installed_sha256
    }, indent=2))
    raise
report = {
    "installed": str(installed), "backup": str(backup), "pids": pids(),
    "version": plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"],
    "build": plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"],
    "gui_sha256": sha(installed / "Contents/MacOS/ClipSlots"),
    "signature_verified": True, "full_backup_hash_verified": True,
    "protected_content_unchanged": True, "external_links_unchanged": True,
    "protected_data_files": len(before_raw["data"]),
    "protected_config_files": len(before_raw["config"]),
    "full_backup_reused": bool(args.reuse_backup),
    "latest_checkpoint": str(checkpoint) if checkpoint else None,
    "checkpoint_delta_bytes": delta_bytes,
    "backup_limit_gib": args.backup_limit_gib,
    "backup_limit_default_gib": 30,
    "latest_checkpoint_all_files_verified": True,
    "previous_application": str(old_app),
    "comparison_excludes": ["*.lock", "canvas/projects/*/canvas.json:updatedAt",
                            "empty appliedAgentMutationIDs default only",
                            "special_slots/index.json: object key serialization order only"],
    "cli_runtime_invoked": False, "published": False
}
(evidence / "install.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
