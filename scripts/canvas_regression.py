#!/usr/bin/env python3
"""Run native canvas regression in an isolated bundle, with a local fake Crate."""
import argparse
import functools
import hashlib
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--binary", type=pathlib.Path, help="Use a preserved baseline binary for before/after comparison")
parser.add_argument("--model-workspace", action="store_true", help="Run model and navigation probes instead of canvas probes")
options = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parent.parent
if os.environ.get("CANVAS_SYSTEM_MOUSE") == "1" or (
    os.environ.get("CLIPSLOTS_TEXT_INPUT_PROBE") == "1"
    and os.environ.get("CLIPSLOTS_TEXT_INPUT_LIFECYCLE") != "1"
):
    console = plistlib.loads(subprocess.check_output(["ioreg", "-a", "-n", "Root", "-d1"]))
    if isinstance(console, list):
        console = console[0]
    if console.get("IOConsoleLocked"):
        raise SystemExit("System input test blocked: macOS session is screen-locked.")
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
info["ClipSlotsIsolatedCandidate"] = True
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy(options.binary or repo / ".build/debug/ClipSlots", contents / "MacOS/ClipSlots")
if os.environ.get("CLIPSLOTS_AGENT_CONTINUATION_PROBE") == "1":
    cli = (options.binary.parent if options.binary else repo / ".build/debug") / "ClipSlotsCLI"
    shutil.copy2(cli, contents / "MacOS/clipslots-cli")
shutil.copy(repo / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
kit_resources = (options.binary.parent if options.binary else repo / ".build/debug") / "ClipSlots_ClipSlotsKit.bundle"
if kit_resources.exists():
    shutil.copytree(kit_resources, contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
if os.environ.get("CLIPSLOTS_AGENT_WORKSPACE_PROBE") == "1" or os.environ.get("CLIPSLOTS_CREATIVE_PROBE") == "1":
    skill = contents / "Resources/skills/composer-fixture/SKILL.md"
    skill.parent.mkdir(parents=True)
    skill.write_text("---\nname: composer-fixture\ndescription: 原生输入回归专用技能\n---\n"
                     "COMPOSER_SNAPSHOT_SENTINEL\n用三个镜头描述场景。\n")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
subject = {
    "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    "source_binary_sha256": sha(options.binary or repo / ".build/debug/ClipSlots"),
    "isolated_binary_sha256": sha(contents / "MacOS/ClipSlots"),
    "started_unix_seconds": time.time(), "runner_sha256": sha(pathlib.Path(__file__)),
    "scope": "native debug probe; local fixtures; not release or target equivalence",
    "input": "system CGEvent" if os.environ.get("CANVAS_SYSTEM_MOUSE") == "1"
        else "in-process AppKit router / AX fixture",
}
(fixtures / "subject.json").write_text(json.dumps(subject, indent=2))
fixture_source = repo / "scripts/crate_canvas_fixture.py"
assert fixture_source.is_file() and not fixture_source.is_symlink(), "Local fixture source required"
fixture_cli = root / "crate_canvas_fixture.py"
shutil.copy2(fixture_source, fixture_cli)
fixture_cli.chmod(0o755)
fixture_hash = sha(fixture_cli)
assert fixture_hash == sha(fixture_source), "Copied fixture differs from source"
subject["crate_fixture_sha256"] = fixture_hash
(fixtures / "subject.json").write_text(json.dumps(subject, indent=2))
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(fixtures))
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, CLIPSLOTS_CANVAS_REGRESSION="1", CLIPSLOTS_PERF_AUTOTEST="1",
           CLIPSLOTS_PERF_LOG="1", CLIPSLOTS_DATA_DIR=str(data),
           CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"),
           CLIPSLOTS_FIXTURE_DIR=str(fixtures), CLIPSLOTS_FIXTURE_PORT=str(server.server_port),
           CLIPSLOTS_CRATE_FIXTURE=str(fixture_cli), CLIPSLOTS_CRATE_FIXTURE_SHA256=fixture_hash)
env["CLIPSLOTS_TEST_DOWNLOAD_DIR"] = str(fixtures / "downloads")
if options.model_workspace:
    env.pop("CLIPSLOTS_CANVAS_REGRESSION", None)
    env["CLIPSLOTS_MODEL_REGRESSION"] = str(fixtures)
print(f"Isolated run: {root}", flush=True)
mouse_driver = None
if env.get("CANVAS_SYSTEM_MOUSE") == "1":
    mouse_driver = subprocess.Popen(["swift", str(repo / "scripts/canvas_mouse_driver.swift"), str(fixtures)])
if env.get("CLIPSLOTS_MENU_SAMPLE") == "1":
    def sample_menu():
        ready = fixtures / "menu-sample-ready"
        deadline = time.monotonic() + 90
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if ready.exists():
            subprocess.run(["sample", ready.read_text(), "8", "1", "-file",
                            str(fixtures / "menu-stacks.txt")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    threading.Thread(target=sample_menu, daemon=True).start()
if env.get("CLIPSLOTS_CREATIVE_SAMPLE") == "1":
    def sample_creative_refresh():
        ready = fixtures / "creative-sample-ready"
        deadline = time.monotonic() + 120
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if ready.exists():
            subprocess.run(["sample", ready.read_text(), "10", "1", "-file",
                            str(fixtures / "creative-refresh-stacks.txt")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    threading.Thread(target=sample_creative_refresh, daemon=True).start()
try:
    with (root / "run.log").open("w") as log:
        process = subprocess.Popen([str(contents / "MacOS/ClipSlots")], env=env, stdout=log,
                                   stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 15
            while process.poll() is None and time.monotonic() < deadline:
                if "App launched" in (root / "run.log").read_text(errors="replace"):
                    break
                time.sleep(0.02)
            if process.poll() is None:
                subprocess.run(["open", "-a", str(contents.parent)], check=True, timeout=15)
            code = process.wait(timeout=180)
            if code:
                raise subprocess.CalledProcessError(code, process.args)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
finally:
    server.shutdown()
    if mouse_driver is not None:
        mouse_driver.terminate()
        mouse_driver.wait(timeout=5)
report = json.loads((fixtures / "report.json").read_text())
if env.get("CLIPSLOTS_SKILL_LAYOUT_PROBE") == "1":
    geometry = json.loads((fixtures / "skill-layout-geometry.json").read_text())
    assert report["geometryCases"] == len(geometry) and len(geometry) > 0
    assert report["systemInputValidated"] is False
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {fixtures}")
    raise SystemExit(1 if report["failures"] else 0)
if options.model_workspace:
    output = repo / "build/validation/model-and-navigation"
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(fixtures, output, dirs_exist_ok=True)
    shutil.copy2(root / "run.log", output / "run.log")
    print(json.dumps({"ok": report["ok"], "passed": len(report["passed"]), "failed": report["failed"],
                      "realPaidRequests": report["realPaidRequests"]}, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(0 if report["ok"] and not report["failed"] else 1)
if env.get("CLIPSLOTS_SMOOTHNESS_PROBE") == "1" or env.get("CLIPSLOTS_TAPNOW_MOTION_PROBE") == "1":
    output = pathlib.Path(env.get("CLIPSLOTS_SMOOTHNESS_OUTPUT", "/tmp/clipslots-smoothness-native"))
    output.mkdir(parents=True, exist_ok=True)
    for source in [*fixtures.glob("*.png"), *fixtures.glob("*-frames.json"), fixtures / "report.json",
                   fixtures / "subject.json", root / "run.log"]:
        if source.exists():
            shutil.copy2(source, output / source.name)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] or not report["complete"] else 0)
if env.get("CLIPSLOTS_AGENT_CONTINUATION_PROBE") == "1":
    output = pathlib.Path(env.get("CLIPSLOTS_AGENT_CONTINUATION_OUTPUT", "/tmp/clipslots-agent-continuation-native"))
    output.mkdir(parents=True, exist_ok=True)
    for source in [*fixtures.glob("*.png"), fixtures / "report.json", root / "run.log"]:
        if source.exists():
            shutil.copy2(source, output / source.name)
    report["isolatedDataRoot"] = str(data)
    report["fixtureRoot"] = str(fixtures)
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] or not report["complete"] else 0)
if env.get("CLIPSLOTS_GROUP_REPLICA_PROBE") == "1" or env.get("CLIPSLOTS_STRUCTURE_REPLICA_PROBE") == "1":
    output = pathlib.Path(env["CLIPSLOTS_STRUCTURE_OUTPUT"] if env.get("CLIPSLOTS_STRUCTURE_REPLICA_PROBE") == "1"
                          else env["CLIPSLOTS_GROUP_OUTPUT"])
    output.mkdir(parents=True, exist_ok=True)
    for source in [*fixtures.glob("*.png"), fixtures / "report.json", fixtures / "subject.json",
                   fixtures / "workflow.json", root / "run.log"]:
        if source.exists():
            shutil.copy2(source, output / source.name)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] or not report["complete"] else 0)
if env.get("CLIPSLOTS_CONNECTION_INTERACTION_PROBE") == "1" or env.get("CLIPSLOTS_COMPOSER_LAYER_PROBE") == "1":
    output = pathlib.Path(env["CLIPSLOTS_COMPOSER_LAYER_OUTPUT"] if env.get("CLIPSLOTS_COMPOSER_LAYER_PROBE") == "1"
                          else env["CLIPSLOTS_CONNECTION_OUTPUT"])
    assert str(output).startswith("/tmp/")
    output.mkdir(parents=True, exist_ok=True)
    for source in [*fixtures.glob("*.png"), fixtures / "report.json", fixtures / "subject.json",
                   fixtures / "mouse-events.jsonl", fixtures / "mouse-acks.jsonl",
                   fixtures / "mouse-driver-result.json", root / "run.log"]:
        if source.exists():
            shutil.copy2(source, output / source.name)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] or not report["complete"] else 0)
if env.get("CLIPSLOTS_GENERATION_CHAIN_PROBE") == "1":
    output = pathlib.Path(env["CLIPSLOTS_CHAIN_OUTPUT"])
    output.mkdir(parents=True, exist_ok=True)
    for source in [fixtures / "report.json", fixtures / "commands.jsonl",
                   fixtures / "effective-parameters.jsonl", root / "run.log"]:
        if source.exists():
            shutil.copy2(source, output / source.name)
    if env.get("CLIPSLOTS_CHAIN_MODE") == "independence":
        shutil.copytree(fixtures / "downloads", output / "downloads", dirs_exist_ok=True)
        for source in fixtures.glob("*.png"):
            shutil.copy2(source, output / source.name)
    commands = [json.loads(line) for line in (fixtures / "commands.jsonl").read_text().splitlines()]
    submissions = [command for command in commands if command[:1] == ["generate"]]
    if len(submissions) != report["expectedCrateSubmissions"]:
        report["failures"].append(f"Expected {report['expectedCrateSubmissions']} submissions, received {len(submissions)}")
    report["crateSubmissions"] = len(submissions)
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "observations"}, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] or not report["complete"] else 0)
if env.get("CLIPSLOTS_NODE_DESIGN_PROBE") == "1":
    output = pathlib.Path(env.get("CLIPSLOTS_NODE_DESIGN_OUTPUT", str(repo / "build/validation/node-design")))
    output.mkdir(parents=True, exist_ok=True)
    for source in [*fixtures.glob("*.png"), fixtures / "report.json",
                   fixtures / "commands.jsonl", fixtures / "mouse-events.jsonl",
                   fixtures / "mouse-ready", root / "run.log"]:
        if source.exists():
            shutil.copy(source, output / source.name)
    commands = [json.loads(line) for line in (fixtures / "commands.jsonl").read_text().splitlines()]
    if any(command[:1] == ["generate"] for command in commands):
        report["failures"].append("Size interactions unexpectedly submitted generation")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] or not report["complete"] else 0)
if env.get("CLIPSLOTS_AGENT_GROUPS_PROBE") == "1":
    output = repo / "build/validation/agent-groups"
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.glob("*.png"):
        shutil.copy(source, output / source.name)
    for source in [root / "run.log", fixtures / "report.json", fixtures / "commands.jsonl"]:
        if source.exists():
            shutil.copy(source, output / source.name)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_TEXT_INPUT_PROBE") == "1" or env.get("CLIPSLOTS_ADVANCED_TEXT_PROBE") == "1":
    output = repo / "build/validation/text-input" / env.get("CANVAS_DEBUG_RUN", "system-pinyin")
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.glob("*.png"):
        shutil.copy(source, output / source.name)
    for source in [root / "run.log", fixtures / "report.json"]:
        shutil.copy(source, output / source.name)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_MENU_LATENCY_PROBE") == "1":
    output = pathlib.Path(env["CLIPSLOTS_MENU_OUTPUT"])
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.iterdir():
        if source.is_file():
            shutil.copy(source, output / source.name)
    shutil.copy(root / "run.log", output / "run.log")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_CREATIVE_PROBE") == "1":
    output = pathlib.Path(env["CLIPSLOTS_CREATIVE_OUTPUT"]) if env.get("CLIPSLOTS_CREATIVE_OUTPUT") else (
        repo / "build/validation/creative-visuals" / env.get("CLIPSLOTS_TEST_SKIN", "minimal"))
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.glob("creative-*"):
        if source.is_file():
            shutil.copy(source, output / source.name)
    for source in [root / "run.log", fixtures / "report.json"]:
        shutil.copy(source, output / source.name)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_BATCH_PROBE") == "1":
    output = pathlib.Path(env.get("CLIPSLOTS_BATCH_OUTPUT", str(repo / "build/validation/batch-generation")))
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.glob("batch-*.png"):
        shutil.copy(source, output / source.name)
    for source in [root / "run.log", fixtures / "report.json", fixtures / "commands.jsonl"]:
        shutil.copy(source, output / source.name)
    for name in ["concurrency.json", "process-events.jsonl"]:
        if (fixtures / name).exists():
            shutil.copy(fixtures / name, output / name)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] else 0)
if env.get("CLIPSLOTS_AGENT_WORKSPACE_PROBE") == "1":
    output = repo / "build/validation/agent-workspace"
    output.mkdir(parents=True, exist_ok=True)
    for source in fixtures.glob("*.png"):
        shutil.copy(source, output / source.name)
    shutil.copy(root / "run.log", output / "run.log")
    shutil.copy(fixtures / "report.json", output / "report.json")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {output}")
    raise SystemExit(1 if report["failures"] or not report["complete"] else 0)
if env.get("CLIPSLOTS_INPUT_UPLOAD_PROBE") == "1":
    output = repo / "build/validation"
    output.mkdir(parents=True, exist_ok=True)
    suffix = env.get("CANVAS_DEBUG_RUN", "pre-fix")
    for name in ["report.json", "canvas-input-upload.png", "canvas-source-image.png", "canvas-source-video.png"]:
        if (fixtures / name).exists():
            shutil.copy(fixtures / name, output / f"input-upload-{suffix}-{name}")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Evidence: {fixtures}")
    raise SystemExit(1 if report["failures"] else 0)
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
