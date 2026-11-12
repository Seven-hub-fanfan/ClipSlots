#!/usr/bin/env python3
"""Run inside disk_guard.py run, registering .build and --output.

Compiles the real GUI import/export sources against the shared library's release
objects. No production data, preferences, CLI startup or application UI is used.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--baseline", action="store_true")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
release = repo / ".build/arm64-apple-macosx/release"
fixtures = repo / "Tests/PackTransferRegression"
sources = [repo / "Sources/ClipSlots" / (name + ".swift")
           for name in ("PackExporter", "PackImporter", "PackArchive")]
if args.baseline:
    sources = sources[:2]
    for i, name in enumerate(("PackExporter", "PackImporter")):
        path = root / (name + ".swift")
        path.write_bytes(subprocess.check_output(["git", "show", "HEAD:Sources/ClipSlots/" + name + ".swift"], cwd=repo))
        sources[i] = path
binary = root / "PackTransferRegression"
command = ["swiftc", "-O", "-I", str(release / "Modules"), "-I", str(repo / "Sources/CArchive")]
if args.baseline:
    command += ["-D", "BASELINE"]
command += list(map(str, sources + [fixtures / "main.swift", fixtures / "HeadlessCache.swift"]))
command += list(map(str, sorted((release / "ClipSlotsKit.build").glob("*.swift.o"))))
command += ["-lsqlite3", "-Xlinker", "-dead_strip", "-o", str(binary)]
result = subprocess.run(command, capture_output=True, text=True, cwd=repo)
(root / "build.log").write_text(result.stdout + result.stderr)
if result.returncode:
    print((result.stdout + result.stderr)[-14000:])
    raise SystemExit(result.returncode)
all_results = []
for language in ("en_US.UTF-8", "C"):
    sandbox = root / ("sandbox-" + language)
    # Refuse to reuse a populated store; callers choose/clean their own test output.
    sandbox.mkdir(exist_ok=False)
    env = {**os.environ, "CLIPSLOTS_DATA_DIR": str(sandbox / "data"),
           "CLIPSLOTS_CONFIG_PATH": str(sandbox / "config.toml"), "LANG": language, "LC_ALL": language}
    result = subprocess.run([str(binary), str(sandbox), str(fixtures / "fixtures.py")],
                            cwd=sandbox, env=env, capture_output=True, text=True, timeout=180)
    (sandbox / "run.log").write_text(result.stdout + result.stderr)
    print(language + ": " + result.stdout, flush=True)
    if not (sandbox / "results.json").exists():
        print(result.stderr[-10000:])
        raise SystemExit(result.returncode or 1)
    all_results += [{**item, "locale": language} for item in json.loads((sandbox / "results.json").read_text())]
(root / "results.json").write_text(json.dumps(all_results, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(item["passed"] for item in all_results) else 1)
