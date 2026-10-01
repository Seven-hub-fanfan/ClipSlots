#!/usr/bin/env python3
"""Run native canvas regression in an isolated bundle, with a local fake Crate."""
import argparse
import functools
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--binary", type=pathlib.Path, help="Use a preserved baseline binary for before/after comparison")
options = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parent.parent
if not options.skip_build and options.binary is None:
    subprocess.run(["swift", "build"], cwd=repo, check=True)
root = pathlib.Path(tempfile.mkdtemp(prefix="clipslots-v2174-", dir="/tmp"))
fixtures = root / "fixtures"
fixtures.mkdir()
data = root / "data"
data.mkdir()
contents = root / "ClipSlots-dev.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info["CFBundleIdentifier"] = "com.clipslots.app.canvas-v2174-test"
info["CFBundleName"] = "ClipSlots V2.17.4 Test"
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy(options.binary or repo / ".build/debug/ClipSlots", contents / "MacOS/ClipSlots")
shutil.copy(repo / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
fixture_cli = repo / "scripts/crate_canvas_fixture.py"
if not os.access(fixture_cli, os.X_OK):
    fixture_cli.chmod(0o755)
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(fixtures))
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, CLIPSLOTS_CANVAS_REGRESSION="1", CLIPSLOTS_PERF_AUTOTEST="1",
           CLIPSLOTS_PERF_LOG="1", CLIPSLOTS_DATA_DIR=str(data),
           CLIPSLOTS_FIXTURE_DIR=str(fixtures), CLIPSLOTS_FIXTURE_PORT=str(server.server_port),
           CLIPSLOTS_CRATE_FIXTURE=str(fixture_cli))
print(f"Isolated run: {root}", flush=True)
mouse_driver = None
if env.get("CANVAS_SYSTEM_MOUSE") == "1":
    mouse_driver = subprocess.Popen(["swift", str(repo / "scripts/canvas_mouse_driver.swift"), str(fixtures)])
try:
    with (root / "run.log").open("w") as log:
        subprocess.run([str(contents / "MacOS/ClipSlots")], env=env, stdout=log,
                       stderr=subprocess.STDOUT, timeout=180, check=True)
finally:
    server.shutdown()
    if mouse_driver is not None:
        mouse_driver.terminate()
        mouse_driver.wait(timeout=5)
report = json.loads((fixtures / "report.json").read_text())
if env.get("CLIPSLOTS_AGENT_PERF") == "1":
    output = repo / "build/validation"
    output.mkdir(parents=True, exist_ok=True)
    suffix = env.get("CANVAS_DEBUG_RUN", "pre-fix")
    shutil.copy(root / "run.log", output / f"agent-perf-{suffix}.log")
    shutil.copy(fixtures / "report.json", output / f"agent-perf-{suffix}.json")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {fixtures}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_WINDOW_PROBE") == "1":
    output = repo / "build/validation"
    output.mkdir(parents=True, exist_ok=True)
    suffix = env.get("CANVAS_DEBUG_RUN", "pre-fix")
    shutil.copy(root / "run.log", output / f"window-{suffix}.log")
    shutil.copy(fixtures / "report.json", output / f"window-{suffix}.json")
    print(json.dumps({key: value for key, value in report.items() if key != "snapshots"}, ensure_ascii=False, indent=2))
    print(f"Evidence: {fixtures}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_SLOT_AGENT_PROBE") == "1":
    output = repo / "build/validation"
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.glob("canvas-*.png"):
        shutil.copy(source, output / source.name)
    suffix = env.get("CANVAS_DEBUG_RUN", "pre-fix")
    shutil.copy(root / "run.log", output / f"slot-agent-{suffix}.log")
    shutil.copy(fixtures / "report.json", output / f"slot-agent-{suffix}.json")
    if (fixtures / "commands.jsonl").exists():
        shutil.copy(fixtures / "commands.jsonl", output / f"slot-agent-{suffix}-commands.jsonl")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {fixtures}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_MEDIA_THEME_PROBE") == "1":
    output = repo / "build/validation"
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.glob("canvas-*.png"):
        shutil.copy(source, output / source.name)
    shutil.copy(root / "run.log", output / "media-theme-regression.log")
    shutil.copy(fixtures / "report.json", output / "media-theme-report.json")
    suffix = env.get("CLIPSLOTS_TEST_SKIN", "colorful") + "-" + env.get("CLIPSLOTS_TEST_APPEARANCE", "light")
    shutil.copy(fixtures / "report.json", output / f"media-theme-{suffix}.json")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {fixtures}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_PROMPT_PROBE") == "1":
    output = repo / "build/validation"
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.glob("canvas-*.png"):
        shutil.copy(source, output / source.name)
    shutil.copy(root / "run.log", output / "prompt-regression.log")
    shutil.copy(fixtures / "report.json", output / "prompt-report.json")
    if (fixtures / "live-image-prompt.txt").exists():
        shutil.copy(fixtures / "live-image-prompt.txt", output / "live-image-prompt.txt")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {fixtures}")
    raise SystemExit(1 if report["failures"] else 0)
commands = [json.loads(line) for line in (fixtures / "commands.jsonl").read_text().splitlines()]
submits = [cmd for cmd in commands if cmd[:1] == ["generate"]]
expected_submits = report.get("expectedCrateSubmissions", 2)
if len(submits) != expected_submits:
    report["failures"].append(f"Expected {expected_submits} submits, received {len(submits)}")
if env.get("CLIPSLOTS_OPTIMIZATION_PROBE") == "1" and len(submits) >= 4:
    if "--image" not in submits[3]:
        report["failures"].append("Dependent batch submission is missing upstream image")
report["crateSubmissions"] = len(submits)
report["taskQueries"] = sum(cmd[:2] == ["task", "get"] for cmd in commands)
output = repo / "build/validation"
output.mkdir(parents=True, exist_ok=True)
for source in fixtures.glob("canvas-*.png"):
    shutil.copy(source, output / source.name)
shutil.copy(root / "run.log", output / "canvas-regression.log")
shutil.copy(fixtures / "commands.jsonl", output / "crate-commands.jsonl")
(output / "canvas-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
print(f"Evidence: {output}")
raise SystemExit(1 if report["failures"] else 0)
