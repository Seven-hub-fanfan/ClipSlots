#!/usr/bin/env python3
"""Collect local, fixture-only evidence and verify the installed release."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess

repo = Path(__file__).resolve().parents[1]
out = repo.parent / "ClipSlots/deliverables/codex-only-removal-20261010"
evidence = out / "evidence"
evidence.mkdir(parents=True, exist_ok=True)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


for name in ["debug-build.log", "release-build.log", "kit-smoke.log",
             "full-baseline-kit-smoke.log", "agent-lite-install.json",
             "agent-lite-install.log", "agent-lite-audit.log"]:
    copy(repo / "build" / name, evidence / name)
for name in ["manifest.json", "launch-validation.json"]:
    copy(repo / "build/agent-lite-candidate" / name, evidence / name)
for folder in ["agent-workspace", "agent-groups", "text-input/agent-lite",
               "batch-generation", "canvas-agent-lite", "canvas-full-baseline",
               "canvas-agent-lite-repeat"]:
    root = repo / "build/validation" / folder
    for path in root.rglob("*"):
        if path.is_file() and path.suffix in {".json", ".jsonl", ".log", ".png"}:
            copy(path, evidence / "validation" / folder / path.relative_to(root))
for name in ["package_agent_lite.py", "create_agent_lite_dmg.py",
             "audit_agent_lite.py", "install_agent_lite.py",
             "validate_isolated_candidate.py", "collect_agent_lite_delivery.py"]:
    copy(repo / "scripts" / name, evidence / "scripts" / name)
copy(repo / "build/create_dmg.py", evidence / "scripts/create_dmg_executed.py")
copy(repo / "build/agent-lite-candidate/ClipSlots_v2.17.12.dmg",
     out / "ClipSlots_v2.17.12.dmg")
baseline = json.loads((repo / "build/full-source-baseline.json").read_text())
baseline = {p: v for p, v in baseline.items()
            if p.startswith(("Sources/", "Tests/", "scripts/", "licenses/"))
            or p in {"CLAUDE.md", "Info.plist", "Package.swift"}}
(evidence / "source-baseline.json").write_text(json.dumps(baseline, indent=2) + "\n")

installed = Path("/Applications/ClipSlots.app")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
info = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
actual = {str(p.relative_to(installed)): {"bytes": p.stat().st_size, "sha256": sha(p)}
          for p in sorted(installed.rglob("*")) if p.is_file() and not p.is_symlink()}
expected = json.loads((out / "应用文件清单.json").read_text())["agent_lite"]
install = json.loads((repo / "build/agent-lite-install.json").read_text())
cli = json.loads(subprocess.check_output(
    [str(installed / "Contents/MacOS/clipslots-cli"), "version"], text=True))
pids = subprocess.run(
    ["pgrep", "-f", r"^/Applications/ClipSlots.app/Contents/MacOS/ClipSlots( |$)"],
    capture_output=True, text=True).stdout.split()
dmg = json.loads((out / "体积数据.json").read_text())["dmg"]["agent_lite"]
checks = {
    "installed_version_2_17_12": info["CFBundleShortVersionString"] == "2.17.12",
    "installed_build_2171201": info["CFBundleVersion"] == "2171201",
    "installed_all_files_match_audited_candidate": actual == expected,
    "installed_process_running": bool(pids),
    "cli_version_2_17_12": cli.get("ok") is True and cli.get("version") == "2.17.12",
    "strict_signature_valid": True,
    "codex_runtime_absent": not (installed / "Contents/Resources/codex-runtime").exists(),
    "copied_dmg_matches_audited_hash": sha(out / "ClipSlots_v2.17.12.dmg") == dmg["sha256"],
    "post_install_data_and_config_unchanged": install["all_protected_bytes_unchanged"],
    "external_links_unchanged": install["external_links_unchanged"],
}
report = {"passed": all(checks.values()), "checks": checks, "pids": pids,
          "app_bytes": sum(v["bytes"] for v in actual.values()),
          "backup": install["backup"], "published": False}
(evidence / "final-verification.json").write_text(
    json.dumps(report, ensure_ascii=False, indent=2) + "\n")
assert report["passed"], report
entries = {str(p.relative_to(out)): {"bytes": p.stat().st_size, "sha256": sha(p)}
           for p in sorted(out.rglob("*"))
           if p.is_file() and p.name != "交付文件校验清单.json"}
(out / "交付文件校验清单.json").write_text(
    json.dumps(entries, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"files": len(entries), "verification": report},
                 ensure_ascii=False, indent=2))
