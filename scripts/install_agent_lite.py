#!/usr/bin/env python3
"""Install the verified Agent-preserving candidate with a data clone and rollback."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

repo = Path(__file__).resolve().parent.parent
candidate = repo / "build/agent-lite-candidate"
installed = Path("/Applications/ClipSlots.app")
source = candidate / "ClipSlots.app"
data = Path.home() / ".local/share/clipslots"
config = Path.home() / ".config/clipslots"
# StorageLock writes the PID at launch. Back it up, but compare business files
# independently of this process-specific lock record.
volatile_files = {"special_slots/.storage.lock"}


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def files(root):
    return {
        str(p.relative_to(root)): {"link": os.readlink(p)}
        if p.is_symlink() else {"sha256": sha(p), "bytes": p.stat().st_size}
        for p in sorted(root.rglob("*"))
        if (p.is_file() or p.is_symlink())
        and str(p.relative_to(root)) not in volatile_files
    }


def links():
    paths = [Path.home() / folder / "skills/clipslots-manager"
             for folder in [".codex", ".claude", ".cursor", ".gemini"]]
    paths += [Path("/usr/local/bin/clipslots"), Path.home() / "bin/clipslots"]
    return {str(p): os.readlink(p) if p.is_symlink()
            else sha(p) if p.is_file() else p.exists() for p in paths}


def pids():
    return subprocess.run(
        ["pgrep", "-f", r"^/Applications/ClipSlots.app/Contents/MacOS/ClipSlots( |$)"],
        capture_output=True, text=True
    ).stdout.split()


def quit_app():
    if pids():
        subprocess.run(["osascript", "-e", 'tell application id "com.clipslots.app" to quit'],
                       check=True, timeout=15)
        for _ in range(100):
            if not pids():
                return
            time.sleep(0.1)
    assert not pids(), "App did not quit; installation aborted"


def signed(app):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def clone(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/bin/cp", "-cR", str(src), str(dst)], check=True)


manifest = json.loads((candidate / "manifest.json").read_text())
validation = json.loads((candidate / "launch-validation.json").read_text())
assert validation["passed"] and validation["build"] == "2171201"
assert sha(source / "Contents/MacOS/ClipSlots") == manifest["gui_sha256"]
assert sha(source / "Contents/MacOS/clipslots-cli") == manifest["cli_sha256"]
assert not (source / "Contents/Resources/codex-runtime").exists()
old_info = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
new_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
assert old_info["CFBundleVersion"] == "2171101"
assert new_info["CFBundleVersion"] == "2171201"
gates = {
    "agent-workspace/report.json": 326,
    "agent-groups/report.json": 104,
    "text-input/agent-lite/report.json": 56,
    "batch-generation/report.json": 117,
}
for path, passed in gates.items():
    result = json.loads((repo / "build/validation" / path).read_text())
    assert result["failures"] == [] and result["passed"] == passed, path
smoke = (repo / "build/kit-smoke.log").read_text()
baseline = (repo / "build/full-baseline-kit-smoke.log").read_text()
failures = [line for line in smoke.splitlines() if line.startswith("✗ ")]
baseline_failures = [line for line in baseline.splitlines() if line.startswith("✗ ")]
assert len(failures) == 4 and failures == baseline_failures
assert "通过 33014，失败 4" in smoke and "通过 33015，失败 4" in baseline
signed(source)
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = repo / f"build/install-backups/{stamp}-2171101-to-2171201"
assert not backup.exists()
backup.mkdir(parents=True)
stage = Path("/Applications/.ClipSlots-agent-lite-stage.app")
if stage.exists():
    # A previous attempt may have stopped at the pre-install data gate.
    signed(stage)
    assert files(stage) == files(source), "Existing stage does not match this candidate"
else:
    clone(source, stage)
quit_app()
print("Old app closed; hashing all protected data and config.", flush=True)
before = {"data": files(data), "config": files(config), "links": links()}
(backup / "protected-before.json").write_text(json.dumps(before, indent=2))
print("Cloning data and config, including the volatile lock record.", flush=True)
clone(data, backup / "data")
clone(config, backup / "config")
assert files(backup / "data") == before["data"]
assert files(backup / "config") == before["config"]
print("Backup hashes verified; rechecking live files before replacement.", flush=True)
quit_app()
assert files(data) == before["data"] and files(config) == before["config"]
assert not pids(), "App reopened during verification; installation aborted"
print(f"Verified full backup: {len(before['data'])} data files.", flush=True)
installed.rename(backup / "ClipSlots.app")
try:
    stage.rename(installed)
    signed(installed)
    subprocess.run(["open", str(installed)], check=True)
    time.sleep(8)
    assert pids(), "New installed app exited"
    cli = json.loads(subprocess.check_output(
        [str(installed / "Contents/MacOS/clipslots-cli"), "version"], text=True))
    assert cli["ok"] and cli["version"] == "2.17.12"
    print("New app running; verifying all protected bytes after launch.", flush=True)
    after = {"data": files(data), "config": files(config), "links": links()}
    assert before == after, "Protected files changed after launch; rolling back"
    assert not (installed / "Contents/Resources/codex-runtime").exists()
except Exception:
    quit_app()
    installed.rename(backup / "Failed-ClipSlots.app")
    (backup / "ClipSlots.app").rename(installed)
    # Keep the failed state before restoring only changed files.
    clone(data, backup / "failed-data")
    clone(config, backup / "failed-config")
    for root, key in [(data, "data"), (config, "config")]:
        current = files(root)
        for name in set(current) | set(before[key]):
            if current.get(name) == before[key].get(name):
                continue
            path = root / name
            if path.exists() or path.is_symlink():
                path.unlink()
            if name in before[key]:
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(backup / key / name, path, follow_symlinks=False)
    subprocess.run(["open", str(installed)], check=False)
    raise

report = {
    "version": new_info["CFBundleShortVersionString"], "build": new_info["CFBundleVersion"],
    "previous_version": old_info["CFBundleShortVersionString"],
    "installed": str(installed), "backup": str(backup), "pids": pids(), "cli": cli,
    "protected_data_files": len(before["data"]), "protected_config_files": len(before["config"]),
    "protected_data_bytes": sum(f.get("bytes", 0) for f in before["data"].values()),
    "all_protected_bytes_unchanged": before == after,
    "external_links_unchanged": before["links"] == after["links"],
    "volatile_file_excluded_from_byte_comparison": sorted(volatile_files),
    "volatile_file_included_in_full_backup": True,
    "full_data_backup_verified": True, "signature_verified": True,
    "runtime_absent": True, "gui_sha256": manifest["gui_sha256"],
    "cli_sha256": manifest["cli_sha256"],
    "passing_validation_gates": gates,
    "kit_failures_identical_to_full_baseline": failures,
    "canvas_probe_limitations": "See canvas-agent-lite, canvas-full-baseline and canvas-agent-lite-repeat reports.",
    "published": False,
}
(repo / "build/agent-lite-install.json").write_text(
    json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
