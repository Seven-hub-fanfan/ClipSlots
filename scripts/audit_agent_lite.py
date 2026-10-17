#!/usr/bin/env python3
"""Count fixed artifacts and source bytes without conflating source and binaries."""
from pathlib import Path
import hashlib
import json
import subprocess

repo = Path(__file__).resolve().parents[1]
main = repo.parent / "ClipSlots"
out = main / "deliverables/codex-only-removal-20261010"
out.mkdir(parents=True, exist_ok=True)
baseline = json.loads((repo / "build/full-source-baseline.json").read_text())
full = repo.parent / "ClipSlots-lean/build/install-backups/20261010-131740-2171006-to-2171101/ClipSlots.app"
lean = repo.parent / "ClipSlots-lean/build/lean-candidate/ClipSlots.app"
new = repo / "build/agent-lite-candidate/ClipSlots.app"
dmg_full = repo.parent / "ClipSlots-agent-loop/build/size-audit-20261010/package-ab/full.dmg"
dmg_lean = repo.parent / "ClipSlots-lean/build/lean-candidate/ClipSlots_v2.17.11.dmg"
dmg_new = repo / "build/agent-lite-candidate/ClipSlots_v2.17.12.dmg"

def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()

def inventory(root):
    return {str(p.relative_to(root)): {"bytes": p.stat().st_size, "sha256": sha(p)}
            for p in sorted(root.rglob("*")) if p.is_file() and not p.is_symlink()}

def total(entries):
    return sum(x["bytes"] for x in entries.values())

apps = {name: inventory(path) for name, path in [("full", full), ("previous_lean", lean), ("agent_lite", new)]}
assert total(apps["full"]) == 371115775
runtime = {p: v for p, v in apps["full"].items() if p.startswith("Contents/Resources/codex-runtime/")}
assert len(runtime) == 44 and total(runtime) == 332979715
assert not any("codex-runtime" in p for p in apps["agent_lite"])
sources_before = {p: v for p, v in baseline.items() if p.startswith("Sources/")}
sources_after = inventory(repo / "Sources")
sources_after = {"Sources/" + p: v for p, v in sources_after.items()}
changed = []
for path in sorted(sources_before.keys() | sources_after.keys()):
    a, b = sources_before.get(path), sources_after.get(path)
    if a == b:
        continue
    changed.append({"path": path, "status": "added" if a is None else "deleted" if b is None else "modified",
                    "before_bytes": a["bytes"] if a else 0, "after_bytes": b["bytes"] if b else 0,
                    "reduction_bytes": (a["bytes"] if a else 0) - (b["bytes"] if b else 0),
                    "before_sha256": a["sha256"] if a else None, "after_sha256": b["sha256"] if b else None})
deleted = [p for p in sources_before if p not in sources_after]
ui = ["Sources/ClipSlots/" + f for f in ["AgentSidebarView.swift", "AgentWorkspaceView.swift", "AgentConfigView.swift"]]
ui += [p for p in deleted if p.startswith("Sources/ClipSlots/")]
ui_before = sum(sources_before[p]["bytes"] for p in ui)
ui_after = sum(sources_after.get(p, {"bytes": 0})["bytes"] for p in ui)
app_totals = {k: total(v) for k, v in apps.items()}
dmgs = {name: {"path": str(path), "bytes": path.stat().st_size, "sha256": sha(path)}
        for name, path in [("full", dmg_full), ("previous_lean", dmg_lean), ("agent_lite", dmg_new)]}
names = [p for p in apps["full"] if p not in runtime]
bundle_changes = [{"path": p, "before_bytes": apps["full"].get(p, {"bytes": 0})["bytes"],
                   "after_bytes": apps["agent_lite"].get(p, {"bytes": 0})["bytes"]}
                  for p in sorted(set(names) | set(apps["agent_lite"]))]
result = {
    "version": "2.17.12 (2171201)", "architecture": "arm64", "configuration": "SwiftPM release, unstripped, ad-hoc signed",
    "byte_unit": "logical file length; MiB = 1048576 bytes; no symlink target duplication",
    "app_bytes": app_totals,
    "app_reduction_vs_full": app_totals["full"] - app_totals["agent_lite"],
    "agent_restoration_increment_vs_previous_lean": app_totals["agent_lite"] - app_totals["previous_lean"],
    "dmg": dmgs,
    "runtime_removed": {"files": len(runtime), "bytes": total(runtime)},
    "non_runtime_bundle": bundle_changes,
    "source": {"before_bytes": total(sources_before), "after_bytes": total(sources_after),
               "deleted_files": len(deleted), "deleted_bytes": sum(sources_before[p]["bytes"] for p in deleted),
               "note": "All Sources, including DEBUG-only regression files; not installed size."},
    "page_source": {"paths": ui, "before_bytes": ui_before, "after_bytes": ui_after,
                    "reduction_bytes": ui_before - ui_after},
    "swift_package_external_dependencies": 0,
    "attribution_note": "Source, runtime and binary savings are overlapping views and must not be added together.",
}
(out / "体积数据.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
(out / "源码变更清单.json").write_text(json.dumps(changed, ensure_ascii=False, indent=2) + "\n")
(out / "应用文件清单.json").write_text(json.dumps(apps, ensure_ascii=False, indent=2) + "\n")
(out / "已移除运行时清单.json").write_text(json.dumps(runtime, ensure_ascii=False, indent=2) + "\n")
support = []
support_paths = {p for p in baseline
                 if p.startswith(("Tests/", "licenses/", "scripts/"))
                 or p in ("Package.swift", "Info.plist", "CLAUDE.md")}
for folder in ("Tests", "licenses", "scripts"):
    support_paths.update(str(p.relative_to(repo)) for p in (repo / folder).rglob("*")
                         if p.is_file() and "__pycache__" not in p.parts)
for path in sorted(support_paths):
    a = baseline.get(path)
    p = repo / path
    b = {"bytes": p.stat().st_size, "sha256": sha(p)} if p.is_file() else None
    if a != b:
        support.append({"path": path, "before": a, "after": b})
(out / "辅助变更清单.json").write_text(json.dumps(support, ensure_ascii=False, indent=2) + "\n")
diff = subprocess.check_output(
    ["git", "diff", "--binary", "--", "Sources", "Tests", "licenses", "scripts",
     "Package.swift", "Info.plist", "CLAUDE.md"], cwd=repo)
added = (sources_after.keys() - sources_before.keys()) | {
    row["path"] for row in support if row["before"] is None
}
for path in sorted(added):
    diff += subprocess.run(["git", "diff", "--no-index", "--", "/dev/null", path],
                           cwd=repo, capture_output=True).stdout
(out / "源码调整.patch").write_bytes(diff)
print(json.dumps(result, ensure_ascii=False, indent=2))
