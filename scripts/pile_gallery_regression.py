#!/usr/bin/env python3
"""Run Pile motion evidence using an already-built binary; never builds or installs."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=pathlib.Path, required=True)
    parser.add_argument("--image", type=pathlib.Path, required=True, help="Decodable local image fixture")
    parser.add_argument("--video", type=pathlib.Path, required=True, help="Decodable local video fixture")
    parser.add_argument("--system-mouse", action="store_true", help="Use system CGEvent input (the default for full validation)")
    parser.add_argument("--appkit-mouse", action="store_true",
                        help="Diagnostic synthetic NSEvent queue; does not establish physical mouse behavior")
    parser.add_argument("--presentation-only", action="store_true",
                        help="Validate native lifecycle/data only; does not validate mouse or buttons")
    parser.add_argument("--accessibility-only", action="store_true",
                        help="Validate native lifecycle/data and public AX buttons; excludes mouse")
    parser.add_argument("--reduce-motion", action="store_true", help="Force reduced motion only inside the gated Pile probe")
    parser.add_argument("--output", type=pathlib.Path, help="Evidence directory under /tmp")
    options = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    for name in ("binary", "image", "video"):
        path = getattr(options, name).expanduser().resolve()
        if not path.is_file():
            parser.error(f"--{name} is not a file: {path}")
        setattr(options, name, path)
    if sum([options.presentation_only, options.accessibility_only, options.system_mouse, options.appkit_mouse]) > 1:
        parser.error("Choose only one input scope")
    system_mouse = not (options.presentation_only or options.accessibility_only or options.appkit_mouse)
    console = plistlib.loads(subprocess.check_output(["ioreg", "-a", "-n", "Root", "-d1"]))
    if isinstance(console, list):
        console = console[0]
    if console.get("IOConsoleLocked") and not (options.presentation_only or options.accessibility_only):
        raise SystemExit("Native mouse/button validation blocked: desktop is locked. "
                         "Use --presentation-only for the separately labelled lifecycle/data checks.")
    if options.output is not None:
        output = options.output.expanduser().absolute()
        if not str(output).startswith("/tmp/"):
            parser.error("--output must be under /tmp")
        output.mkdir(parents=True, exist_ok=True)
    else:
        output = None

    root = pathlib.Path(tempfile.mkdtemp(prefix="clipslots-v2174-pile-", dir="/tmp"))
    fixtures = root / "fixtures"
    fixtures.mkdir()
    data = root / "data"
    data.mkdir()
    contents = root / "ClipSlots-pile-test.app/Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    info = plistlib.loads((repo / "Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.clipslots.app.canvas-v2174-test",
                CFBundleName="ClipSlots Pile Motion Test", ClipSlotsIsolatedCandidate=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copy2(options.binary, contents / "MacOS/ClipSlots")
    shutil.copy2(repo / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
    resources = options.binary.parent / "ClipSlots_ClipSlotsKit.bundle"
    if resources.exists():
        shutil.copytree(resources, contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    subject = {
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "source_binary": str(options.binary), "source_binary_sha256": sha(options.binary),
        "isolated_binary": str(contents / "MacOS/ClipSlots"),
        "isolated_signed_binary_sha256": sha(contents / "MacOS/ClipSlots"),
        "image_sha256": sha(options.image), "video_sha256": sha(options.video),
        "scripts": {name: sha(repo / "scripts" / name) for name in [
            "pile_gallery_regression.py", "canvas_mouse_driver.swift",
            "pile_accessibility_driver.swift", "pile_capture_driver.swift"]},
        "started_unix_seconds": time.time(),
        "input": "system CGEvent" if system_mouse else "public AX" if options.accessibility_only
            else "presentation only" if options.presentation_only else "diagnostic AppKit queue",
        "forced_reduce_motion": options.reduce_motion,
        "scope": "Built debug binary and local fixtures; not a release or TapNow equivalence result"
    }
    (fixtures / "subject.json").write_text(json.dumps(subject, indent=2))
    env = dict(os.environ, CLIPSLOTS_CANVAS_REGRESSION="1", CLIPSLOTS_PILE_PROBE="1",
               CLIPSLOTS_PILE_ISOLATED_HOST="1",
               CLIPSLOTS_PILE_PRESENTATION_ONLY="1" if options.presentation_only else "0",
               CLIPSLOTS_PILE_ACCESSIBILITY_ONLY="1" if options.accessibility_only else "0",
               CLIPSLOTS_PILE_REDUCE_MOTION="1" if options.reduce_motion else "0",
               CLIPSLOTS_PERF_AUTOTEST="1", CLIPSLOTS_DATA_DIR=str(data),
               CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"), CLIPSLOTS_FIXTURE_DIR=str(fixtures),
               CLIPSLOTS_PILE_IMAGE_FIXTURE=str(options.image), CLIPSLOTS_PILE_VIDEO_FIXTURE=str(options.video),
               CANVAS_SYSTEM_MOUSE="1" if system_mouse else "0")
    driver = None
    ax_driver = None
    capture_driver = None
    print(f"Isolated Pile run: {root}", flush=True)
    try:
        capture_driver = subprocess.Popen(["swift", "-target", platform.machine() + "-apple-macosx13.0",
                                           str(repo / "scripts/pile_capture_driver.swift"), str(fixtures)])
        ready = fixtures / "capture-ready"
        deadline = time.monotonic() + 30
        while not ready.exists() and capture_driver.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        if not ready.exists() or ready.read_text() != "ready":
            reason = ready.read_text() if ready.exists() else "capture driver did not become ready"
            raise RuntimeError(f"Native motion capture unavailable: {reason}; no permission was changed")
        if not options.presentation_only:
            ax_driver = subprocess.Popen(["swift", str(repo / "scripts/pile_accessibility_driver.swift"), str(fixtures)])
            ready = fixtures / "ax-ready"
            deadline = time.monotonic() + 30
            while not ready.exists() and ax_driver.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if not ready.exists() or ready.read_text() != "ready":
                reason = ready.read_text() if ready.exists() else "AX driver did not become ready"
                raise RuntimeError(f"Native button validation unavailable: {reason}; no permission was changed")
        if system_mouse:
            driver = subprocess.Popen(["swift", str(repo / "scripts/canvas_mouse_driver.swift"), str(fixtures)])
            ready = fixtures / "mouse-ready"
            deadline = time.monotonic() + 30
            while not ready.exists() and driver.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if not ready.exists() or ready.read_text() != "ready":
                reason = ready.read_text() if ready.exists() else "driver did not become ready"
                raise RuntimeError(f"System mouse unavailable: {reason}; no permission or system setting was changed")
        with (root / "run.log").open("w") as log:
            app_process = subprocess.Popen([str(contents / "MacOS/ClipSlots")], env=env, stdout=log,
                                           stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 15
                launched = False
                while app_process.poll() is None and time.monotonic() < deadline:
                    if "App launched" in (root / "run.log").read_text(errors="replace"):
                        launched = True
                        break
                    time.sleep(0.02)
                if not launched:
                    raise RuntimeError("Isolated app did not finish registration; no second launch attempted")
                # A direct executable launch can remain a background process
                # with no SwiftUI window. An explicit LaunchServices open targets
                # this bundle and its already-running isolated data environment.
                subprocess.run(["/usr/bin/open", "-a", str(contents.parent)], check=True, timeout=15)
                code = app_process.wait(timeout=180)
                if code:
                    raise subprocess.CalledProcessError(code, app_process.args)
            finally:
                if app_process.poll() is None:
                    app_process.terminate()
                    app_process.wait(timeout=10)
        report = json.loads((fixtures / "report.json").read_text())
        if output is not None:
            for source in [*fixtures.glob("*.png"), fixtures / "report.json", fixtures / "subject.json",
                           fixtures / "mouse-events.jsonl", fixtures / "native-button-actions.jsonl",
                           fixtures / "capture-requests.jsonl", fixtures / "capture-results.jsonl",
                           fixtures / "native-pointer-routing.jsonl", fixtures / "mouse-acks.jsonl",
                           fixtures / "mouse-driver-result.json",
                           root / "run.log"]:
                if source.exists():
                    shutil.copy2(source, output / source.name)
        print(json.dumps({key: value for key, value in report.items() if key != "galleryMotion"}, indent=2))
        print(f"Timestamped motion records: {fixtures / 'report.json'}")
        print(f"Evidence: {output or fixtures}")
        return 1 if report["failures"] or not report["complete"] else 0
    except Exception as error:
        failure = {"complete": False, "passed": 0, "failures": [type(error).__name__ + ": " + str(error)],
                   "scope": "isolated probe launcher; no canvas acceptance result",
                   "isolatedRoot": str(root)}
        (root / "harness-failure.json").write_text(json.dumps(failure, indent=2))
        if output is not None:
            shutil.copy2(root / "harness-failure.json", output / "harness-failure.json")
            shutil.copy2(fixtures / "subject.json", output / "subject.json")
            if (root / "run.log").exists():
                shutil.copy2(root / "run.log", output / "run.log")
        raise
    finally:
        if capture_driver is not None and capture_driver.poll() is None:
            capture_driver.terminate()
            capture_driver.wait(timeout=5)
        if driver is not None and driver.poll() is None:
            driver.terminate()
            driver.wait(timeout=5)
        if ax_driver is not None and ax_driver.poll() is None:
            ax_driver.terminate()
            ax_driver.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
