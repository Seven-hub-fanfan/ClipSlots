#!/usr/bin/env python3
"""Freeze source/object identity and measure an isolated journal; never use a service."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--scratch", required=True)
p.add_argument("--root", required=True)
p.add_argument("--label", choices=["baseline-mixed", "candidate-mixed"], required=True)
args = p.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch, root = Path(args.scratch).resolve(), Path(args.root)
assert str(scratch).startswith("/private/tmp/") or str(scratch).startswith("/tmp/")
assert str(root).startswith(("/private/tmp/clipslots-journal-", "/tmp/clipslots-journal-"))
assert not root.exists(), "Use a new evidence root; do not overwrite a previous run"
assert root.parent.is_dir()
root.mkdir(mode=0o700)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
bin_path = scratch / "debug"
objects = sorted((bin_path / "ClipSlotsKit.build").glob("*.swift.o"))
assert objects
fixtures = repo / "scripts/gateway-fixtures"
entry = [fixtures / name for name in ["JournalBenchmarkMain.swift", "JournalBaselineReference.swift"]]
source = [(path, str(path.relative_to(repo))) for path in (repo / "Sources/ClipSlotsKit").glob("*.swift")]
source += [(path, str(path.relative_to(repo))) for path in entry]
frozen = root / "source"
frozen.mkdir()
sources = []
for path, relative in source:
    target = frozen / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
    sources.append({"path": relative, "sha256": sha(path)})
binary = root / "journal-probe"
command = ["swiftc", "-O", "-parse-as-library", "-I", str(bin_path / "Modules")]
command += [str(path) for path in entry] + [str(path) for path in objects] + ["-o", str(binary)]
with (root / "compile.log").open("w") as log:
    subprocess.run(command, check=True, stdout=log, stderr=log)
subject = {
    "sources": sorted(sources, key=lambda row: row["path"]),
    "objects": [{"path": str(path), "sha256": sha(path)} for path in objects],
    "binarySHA256": sha(binary), "configuration": "Debug Kit objects, optimized benchmark entry/reference",
    "label": args.label, "providerRequests": 0,
    "metric": "encoded payload handed to persistence and process disk write bytes, measured separately",
    "otherWorkloads": "H07 headless mixed/idle resource soaks and explicitly recorded stage builds",
}
(root / "subject.json").write_text(json.dumps(subject, ensure_ascii=False, indent=2) + "\n")
env = dict(os.environ, CLIPSLOTS_DATA_DIR=str(root))
with (root / "run.log").open("w") as log:
    subprocess.run([str(binary), str(root), args.label], check=True, env=env, stdout=log, stderr=log)
assert all(sha(repo / row["path"]) == row["sha256"] for row in sources), "Sources changed while measuring"
results = json.loads((root / "report.json").read_text())
assert len(results) == 3
assert all(row["recoveredCursorMatches"] and row["recoveredContentMatches"] and
           row["recoveredToolsMatch"] and row["recoveredArtifactUpdatesMatch"] and
           row["unknownReceiptRetained"] for row in results)
if args.label == "candidate-mixed":
    assert all(row["completeRequestedScenario"] and row["persistentCommitP95MS"] <= 50 for row in results)
print(json.dumps({"root": str(root), "label": args.label, "finished": True}, ensure_ascii=False))
