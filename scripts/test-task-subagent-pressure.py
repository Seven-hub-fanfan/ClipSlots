#!/usr/bin/env python3
"""Measure real child projection and SQLite writes without network access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--scratch", required=True, type=Path)
parser.add_argument("--physical-io-mib", type=int, default=512)
parser.add_argument("--seconds", type=int, default=180)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
build = args.scratch.resolve(strict=True) / "debug"
root = Path(tempfile.mkdtemp(prefix="clipslots-child-pressure-", dir="/tmp"))
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources/ClipSlotsKit").rglob("*.swift")}
assert 512 <= args.physical_io_mib <= 4096 and 180 <= args.seconds <= 600
objects = sorted((build / "ClipSlotsKit.build").glob("*.swift.o"))
subject = {"root": str(root), "source": sources, "objects": {p.name: sha(p) for p in objects},
           "runnerSHA256": sha(Path(__file__)), "driverSHA256": sha(repo / "scripts/gateway-fixtures/TaskSubagentPressureMain.swift"),
           "scope": "Actual Debug Kit projection and SQLite; optimized driver; no GUI/provider"}
subject["limits"] = {"logicalBytes": 1073741824, "physicalBytes": args.physical_io_mib * 1048576,
                     "seconds": args.seconds}
for rel in sources:
    p = root / "source" / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    shutil_source = repo / rel
    p.write_bytes(shutil_source.read_bytes())
for relative in ["scripts/gateway-fixtures/TaskSubagentPressureMain.swift", "scripts/test-task-subagent-pressure.py"]:
    target_source = root / "source" / relative
    target_source.parent.mkdir(parents=True, exist_ok=True)
    target_source.write_bytes((repo / relative).read_bytes())
target = root / "probe"
with (root / "compile.log").open("w") as log:
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-I", str(build / "Modules"),
                    str(repo / "scripts/gateway-fixtures/TaskSubagentPressureMain.swift"),
                    *map(str, objects), "-o", str(target)], stdout=log, stderr=log, check=True, timeout=60)
subject["binarySHA256"] = sha(target)
(root / "subject.json").write_text(json.dumps(subject, indent=2))
print(json.dumps({"root": str(root), "started": True}), flush=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
env.update(CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
try:
    with (root / "run.log").open("w") as log:
        result = subprocess.run([str(target), str(root), "1073741824", str(args.physical_io_mib * 1048576),
                                 str(args.seconds)], env=env, stdout=log, stderr=log, timeout=args.seconds + 120)
    subject.update(exitCode=result.returncode, sourcesUnchanged=all(sha(repo / p) == h for p, h in sources.items()))
    assert subject["sourcesUnchanged"]
    print((root / "report.json").read_text(), flush=True)
    report = json.loads((root / "report.json").read_text())
    if (result.returncode or not report["full50kCompleted"] or
            not all(report[k] for k in ["recoveredProjectionMatches", "recoveredCursorMatches", "unknownReceiptRetained"]) or
            report["recoveredBodyBytes"] != report["expectedBodyBytes"]):
        raise SystemExit(1)
except subprocess.TimeoutExpired:
    subject.update(exitCode=None, timeout=True, full50kCompleted=False)
    raise
finally:
    (root / "subject.json").write_text(json.dumps(subject, indent=2))
