#!/usr/bin/env python3
"""Render the production task and subagent card without opening App windows."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--scratch", required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch = args.scratch.resolve(strict=True)
assert str(scratch).startswith(("/private/tmp/", "/tmp/"))
binary = scratch / "debug"
root = Path(tempfile.mkdtemp(prefix="clipslots-task-card-", dir="/tmp"))
sources = ["Sources/ClipSlots/CanvasTapSkin.swift", "Sources/ClipSlots/CanvasSkin.swift",
           "Sources/ClipSlots/AppSkinCenter.swift", "Sources/ClipSlots/AgentTaskSubagentCard.swift",
           "scripts/gateway-fixtures/TaskSubagentCardMain.swift"]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
subject = {"root": str(root), "sources": {s: sha(repo / s) for s in sources},
           "runnerSHA256": sha(Path(__file__)), "gui": False, "productionRestarted": False,
           "providerRequests": 0}
objects = sorted((binary / "ClipSlotsKit.build").glob("*.swift.o"))
assert objects
target = root / "task-card"
subject["kitObjects"] = {p.name: sha(p) for p in objects}
command = ["swiftc", "-parse-as-library", "-I", str(binary / "Modules"),
           *[str(repo / s) for s in sources], *map(str, objects), "-o", str(target)]
try:
    with (root / "compile.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
    subject["binarySHA256"] = sha(target)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
    env.update(CLIPSLOTS_ISOLATED_CARD_RENDER="1", CLIPSLOTS_DATA_DIR=str(root),
               CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
    with (root / "run.log").open("w") as log:
        process = subprocess.run([str(target), str(root)], env=env, stdout=log,
                                 stderr=subprocess.STDOUT, timeout=30)
    subject["exitCode"] = process.returncode
    subject["sourcesUnchanged"] = all(sha(repo / s) == digest for s, digest in subject["sources"].items())
    report = json.loads((root / "report.json").read_text())
    assert process.returncode == 0 and report["passed"] == 24 and not report["failures"] and not report["gui"]
    assert subject["sourcesUnchanged"]
except subprocess.TimeoutExpired:
    subject.update(exitCode=None, timedOut=True)
    raise
finally:
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps(subject))
