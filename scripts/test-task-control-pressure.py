#!/usr/bin/env python3
"""Reproduce child checkpoint amplification using a private completed-journal copy."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--scratch", required=True, type=Path)
parser.add_argument("--seed", required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
build = args.scratch.resolve(strict=True) / "debug"
seed = args.seed.resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix="clipslots-child-control-", dir="/tmp"))
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
databases = list(seed.glob("gateway-*.sqlite3"))
assert len(databases) == 1 and not databases[0].is_symlink()
seed_paths = [p for p in seed.glob(databases[0].name + "*") if p.is_file()]
seed_hashes = {p.name: sha(p) for p in seed_paths}
for p in seed_paths:
    shutil.copy2(p, root / p.name)
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources/ClipSlotsKit").rglob("*.swift")}
driver = "scripts/gateway-fixtures/TaskControlPressureMain.swift"
runner = "scripts/test-task-control-pressure.py"
for relative in [*sources, driver, runner]:
    target = root / "source" / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(repo / relative, target)
objects = sorted((build / "ClipSlotsKit.build").glob("*.swift.o"))
subject = {"root": str(root), "source": sources, "seed": str(seed), "seedSHA256": seed_hashes,
           "objects": {p.name: sha(p) for p in objects}, "driverSHA256": sha(repo / driver),
           "runnerSHA256": sha(Path(__file__)), "scope": "20 ordinary saves; private 50k database; no GUI/provider"}
target = root / "probe"
with (root / "compile.log").open("w") as log:
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-I", str(build / "Modules"),
                    str(repo / driver), *map(str, objects), "-o", str(target)],
                   stdout=log, stderr=log, check=True, timeout=60)
subject["binarySHA256"] = sha(target)
print(json.dumps({"root": str(root), "started": True}), flush=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
env.update(CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
try:
    with (root / "run.log").open("w") as log:
        result = subprocess.run([str(target), str(root)], env=env, stdout=log, stderr=log, timeout=120)
    subject.update(exitCode=result.returncode,
                   sourcesUnchanged=all(sha(repo / p) == h for p, h in sources.items()),
                   seedUnchanged=all(sha(seed / p) == h for p, h in seed_hashes.items()))
    assert subject["sourcesUnchanged"] and subject["seedUnchanged"]
    assert result.returncode == 0
    print((root / "report.json").read_text(), flush=True)
finally:
    (root / "subject.json").write_text(json.dumps(subject, indent=2))
