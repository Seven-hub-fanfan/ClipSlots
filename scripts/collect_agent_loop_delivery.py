"""Collect this turn's delta and local evidence, without copying user data."""
from pathlib import Path
import argparse
import difflib
import hashlib
import json
import plistlib
import shutil
import subprocess
from datetime import datetime

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--composer", action="store_true", help="Collect the 21781102 composer candidate separately")
options = parser.parse_args()
out = repo / ("build/agent-composer-delivery-20261004" if options.composer else "build/agent-loop-delivery-20261003")
out.mkdir(parents=True, exist_ok=True)
baseline = json.loads((repo / ".dbg/agent-loop-baseline/manifest.json").read_text())
source = Path(baseline["source"])
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
changed_source = [p for p, h in baseline["files"].items()
                  if not (source / p).is_file() or digest(source / p) != h]
assert not changed_source, changed_source
paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                                cwd=repo).decode().split("\0")
delta = []
patch = []
for name in sorted(set(paths) - {""}):
    if name.startswith(("build/", ".dbg/", ".git/")):
        continue
    path = repo / name
    previous = baseline["files"].get(name)
    if path.is_file() and digest(path) == previous:
        continue
    delta.append({"path": name, "before": previous, "after": digest(path) if path.is_file() else None})
    if path.suffix in {".swift", ".md", ".py", ".json", ".csv", ".plist"}:
        before = (source / name).read_text().splitlines(keepends=True) if previous else []
        after = path.read_text().splitlines(keepends=True) if path.is_file() else []
        patch.extend(difflib.unified_diff(before, after, fromfile="a/" + name if previous else "/dev/null",
                                          tofile="b/" + name if path.is_file() else "/dev/null"))
(out / "本轮源码变更.patch").write_text("".join(patch))
logs = (["agent-composer-final-build.log", "agent-composer-smoke.log", "agent-composer-protocol.log",
         "agent-composer-native.log", "agent-composer-package.log"] if options.composer else
        ["agent-loop-build.log", "agent-loop-kit.log", "agent-loop-protocol.log",
         "agent-loop-native.log", "agent-loop-package.log"])
for name in logs:
    shutil.copy2(repo / ".dbg" / name, out / name)
if (repo / ".dbg/focus-session-state.json").is_file():
    shutil.copy2(repo / ".dbg/focus-session-state.json", out / "focus-session-state.json")
for name in ["report.json", "run.log", "canvas-agent-text-preview.png", "canvas-agent-approval.png"]:
    shutil.copy2(repo / "build/validation/agent-workspace" / name, out / name)
shutil.copy2(repo / "docs/agent-canvas-loop-execution.md", out / "执行记录.md")
if options.composer:
    shutil.copy2(repo / "docs/agent-composer-2026-10-04.md", out / "输入与技能引用修复.md")
    for name in ["canvas-agent-menu-canvas.png", "canvas-agent-menu-agent.png",
                 "canvas-agent-composer-canvas.png", "canvas-agent-composer-agent.png"]:
        shutil.copy2(repo / "build/validation/agent-workspace" / name, out / name)
shutil.copy2(repo / "build/agent-loop-candidate/launch-validation.json", out / "candidate-launch-validation.json")
plan = repo / "docs/plans/agent-action-2026-10-03"
for name in ["行动跟踪表.xlsx", "行动清单.csv", "execution-status.json", "action-data.json"]:
    shutil.copy2(plan / name, out / name)
app = Path("/Applications/ClipSlots.app/Contents")
info = plistlib.loads((app / "Info.plist").read_bytes())
manifest = {
    "baseline": baseline["head"], "source_files_checked": len(baseline["files"]),
    "source_changed": changed_source, "delta": delta,
    "installed_build": info.get("CFBundleVersion"),
    "installed_binary_sha256": digest(app / "MacOS/ClipSlots"),
    "installed_binary_mtime": datetime.fromtimestamp((app / "MacOS/ClipSlots").stat().st_mtime).isoformat(),
    "candidate": "../agent-loop-candidate/ClipSlots Agent Loop.app",
    "candidate_manifest": json.loads((repo / "build/agent-loop-candidate/candidate-manifest.json").read_text()),
    "evidence": {p.name: digest(p) for p in out.iterdir() if p.is_file() and p.name != "delivery-manifest.json"},
}
(out / "delivery-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print(f"Collected {len(delta)} changed files; source {len(baseline['files'])} files unchanged.")
print(out)
