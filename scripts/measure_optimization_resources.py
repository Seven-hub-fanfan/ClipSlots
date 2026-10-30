#!/usr/bin/env python3
"""One-hour Release Kit resource workload with raw samples and explicit limits."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build", type=Path, required=True)
parser.add_argument("--mode", choices=["mixed", "idle"], required=True)
options = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
build = options.build.resolve(strict=True)
assert (build / "release/Modules/ClipSlotsKit.swiftmodule").exists(), "Build Release Kit first"
root = Path(tempfile.mkdtemp(prefix="clipslots-resource-soak-", dir="/private/tmp"))
(root / "isolated.marker").write_text("Release Kit workload, never production data\n")
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
sources = sorted((repo / "Sources/ClipSlotsKit").rglob("*.swift"))
for source in sources:
    archived = root / "source" / source.relative_to(repo)
    archived.parent.mkdir(parents=True, exist_ok=True)
    archived.write_bytes(source.read_bytes())
identity = {
    "scope": "native Release Kit; headless; no GUI or device-matrix acceptance",
    "sourceSHA256": {str(p.relative_to(repo)): sha(p) for p in sources},
    "runnerSHA256": sha(Path(__file__)), "probeSHA256": sha(repo / "scripts/OptimizationResourceSoak.swift"),
    "architecture": platform.machine(), "macOS": platform.mac_ver()[0],
    "physicalMemoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"])),
    "powerBefore": subprocess.check_output(["pmset", "-g", "batt"], text=True),
    "mode": options.mode, "foreground": "not applicable; headless", "pointer": "not applicable",
    "sampling": {"seconds": 3600, "warmupSeconds": 900, "steadySeconds": 2700,
                 "cpuUnit": "single core 100%", "rssUnit": "bytes", "footprintUnit": "bytes",
                 "percentile": "nearest rank ceil(p*n)-1", "fps": "not measured"},
    "idle75SecondWindows": {"count": 5, "warmupSecondsPerWindow": 15,
                           "validForGUIK02": False, "reason": "headless workload"}
}
objects = sorted((build / "release/ClipSlotsKit.build").glob("*.o"))
assert objects, "No Release Kit object files"
command = ["swiftc", "-O", "-parse-as-library", "-I", str(build / "release/Modules"),
           str(repo / "scripts/OptimizationResourceSoak.swift")] + [str(p) for p in objects] + ["-o", str(root / "probe")]
with (root / "compile.log").open("w") as log:
    subprocess.run(command, stdout=log, stderr=log, check=True)
identity["binarySHA256"] = sha(root / "probe")
identity["objectSHA256"] = {p.name: sha(p) for p in objects}
identity["startUnixSeconds"] = time.time()
(root / "subject.json").write_text(json.dumps(identity, ensure_ascii=False, indent=2) + "\n")
env = {key: value for key, value in os.environ.items()
       if not key.startswith("CLIPSLOTS_") and not key.startswith("CANVAS_")}
env.update(CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
print(json.dumps({"evidence": str(root), "mode": options.mode, "started": True}), flush=True)
with (root / "run.log").open("w") as log:
    process = subprocess.run([str(root / "probe"), str(root), options.mode], env=env,
                             stdout=log, stderr=log, timeout=3720)
if process.returncode or not (root / "workload.json").is_file():
    raise RuntimeError("Incomplete/failed workload; preserve evidence: " + str(root))
samples = [json.loads(line) for line in (root / "samples.jsonl").read_text().splitlines()]
workload = json.loads((root / "workload.json").read_text())
assert workload["elapsedSeconds"] >= 3600 and workload["samples"] >= 3500
steady = [s for s in samples if s["elapsedSeconds"] >= 900]
def percentile(values, p):
    return sorted(values)[max(0, math.ceil(p * len(values)) - 1)]
def stats(rows):
    result = {}
    for key in ["cpuPercentSingleCore", "rssBytes", "physicalFootprintBytes", "sampleGapSeconds"]:
        values = [s[key] for s in rows]
        result[key] = {"mean": sum(values) / len(values), "p95": percentile(values, 0.95), "max": max(values)}
    return result
xs = [s["elapsedSeconds"] / 60 for s in steady]
ys = [s["physicalFootprintBytes"] / 1048576 for s in steady]
xmean, ymean = sum(xs) / len(xs), sum(ys) / len(ys)
slope = sum((x - xmean) * (y - ymean) for x, y in zip(xs, ys)) / sum((x - xmean) ** 2 for x in xs)
windows = []
for index in range(5):
    start = 900 + index * 75
    rows = [s for s in samples if start + 15 <= s["elapsedSeconds"] < start + 75]
    windows.append({"windowSeconds": 75, "excludedWarmupSeconds": 15, "sampleCount": len(rows),
                    "metrics": stats(rows), "validForGUIK02": False})
report = {
    "subject": identity, "workload": workload, "steady": stats(steady),
    "physicalFootprintSlopeMiBPerMinute": slope, "slopeTargetMiBPerMinute": 1,
    "localSlopePassed": slope <= 1, "idleWindows": windows,
    "powerAfter": subprocess.check_output(["pmset", "-g", "batt"], text=True),
    "sourceChangedDuringWorkload": any(sha(repo / p) != digest for p, digest in identity["sourceSHA256"].items()),
    "externalDeviceMatrixPassed": False, "GUIK02K03K06Passed": False,
    "limitations": ["Concurrent build/system load is uncontrolled", "No media/GUI workload",
                    "No 8/16 GiB physical device", "No hardware frame or pointer measurement"]
}
(root / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"evidence": str(root), "completed": True, "localSlopePassed": slope <= 1}), flush=True)
