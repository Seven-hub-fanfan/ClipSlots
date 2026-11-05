#!/usr/bin/env python3
"""Compare signed pre/post bundles with the same offline native mascot probe."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", type=Path, required=True)
parser.add_argument("--candidate", type=Path, required=True)
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--idle-only", action="store_true")
parser.add_argument("--baseline-idle-measurement", type=Path)
parser.add_argument("--idle-seconds", type=int, default=30)
args = parser.parse_args()
root = args.root.resolve()
assert str(root).startswith("/private/tmp/clipslots-editor-")
results = {}
for label, app in [("baseline", args.baseline), ("candidate", args.candidate)]:
    if label == "baseline" and args.baseline_idle_measurement:
        assert args.idle_only
        measured = json.loads(args.baseline_idle_measurement.read_text())
        assert not measured["native_checks"]["failures"]
        results[label] = {"idle": measured}
        continue
    runs = {}
    for mode in (["idle"] if args.idle_only else ["idle", "regression"]):
        output = root / (label + "-" + mode)
        output.mkdir(parents=True, exist_ok=False)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
        env.update(CLIPSLOTS_DATA_DIR=str(output / "data").replace("/private/tmp/", "/tmp/"),
                   CLIPSLOTS_CONFIG_PATH=str(output / "config.toml"),
                   CLIPSLOTS_MASCOT_OPTIMIZATION_PROBE=str(output),
                   CLIPSLOTS_PERF_AUTOTEST="1", CLIPSLOTS_PERF_AUTOTEST_SCENARIO="launch-only",
                   CLIPSLOTS_PERF_AUTOTEST_KEEP="1")
        if mode == "idle":
            env["CLIPSLOTS_MASCOT_PROBE_HOLD"] = "1"
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        start = time.monotonic()
        foreground_requests = 0
        with (output / "app.log").open("w") as log:
            process = subprocess.Popen([str(app / "Contents/MacOS/ClipSlots")],
                                       env=env, stdout=log, stderr=log)
            try:
                expected = output / ("ready.json" if mode == "idle" else "report.json")
                while not expected.exists() and process.poll() is None and time.monotonic() - start < 150:
                    # The IDE can reclaim foreground after LaunchServices' first
                    # activation. Keep the explicitly focused fixture in front
                    # only during its input/latency phase, never during idle CPU.
                    if mode == "regression" and not (output / "event-latency.json").exists():
                        text = (output / "app.log").read_text(errors="replace")
                        if "Mascot editor fixture has stable actual OS foreground focus" in text:
                            subprocess.run(["open", "-a", str(app)], check=True,
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            foreground_requests += 1
                    time.sleep(0.2)
                assert expected.exists(), f"{label}/{mode}: missing native report"
                report = json.loads(expected.read_text())
                assert not report["failures"], report["failures"]
                if mode == "idle":
                    # Sample cumulative CPU, avoiding ps %cpu's lifetime average.
                    def meter():
                        fields = subprocess.check_output(
                            ["ps", "-p", str(process.pid), "-o", "time=", "-o", "rss="], text=True).split()
                        parts = [float(x) for x in fields[0].split(":")]
                        seconds = sum(x * 60 ** i for i, x in enumerate(reversed(parts)))
                        return seconds, int(fields[1]) / 1024
                    cpu0, rss0 = meter()
                    measured = time.monotonic()
                    time.sleep(args.idle_seconds)
                    cpu1, rss1 = meter()
                    runs[mode] = {"window_seconds": time.monotonic() - measured,
                                  "cpu_seconds": cpu1 - cpu0,
                                  "cpu_percent_one_core": (cpu1 - cpu0) / (time.monotonic() - measured) * 100,
                                  "rss_mib_start": rss0, "rss_mib_end": rss1,
                                  "native_checks": report}
                else:
                    process.wait(timeout=10)
                    after = resource.getrusage(resource.RUSAGE_CHILDREN)
                    runs[mode] = {"cpu_seconds": after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
                                  "wall_seconds": time.monotonic() - start, "native_checks": report,
                                  "bounded_foreground_requests": foreground_requests,
                                  "event_latency": json.loads((output / "event-latency.json").read_text())}
                (output / "measurement.json").write_text(json.dumps(runs[mode], indent=2))
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
        print(f"{label}/{mode}: passed", flush=True)
    results[label] = runs
    (root / "comparison-progress.json").write_text(json.dumps(results, indent=2))
base, candidate = results["baseline"], results["candidate"]
checks = {
    "both_idle_probes_zero_failures": all(not v["idle"]["native_checks"]["failures"] for v in results.values()),
    "candidate_idle_cpu_within_one_percentage_point": candidate["idle"]["cpu_percent_one_core"] <= base["idle"]["cpu_percent_one_core"] + 1,
    "candidate_idle_rss_within_8mib": candidate["idle"]["rss_mib_end"] <= base["idle"]["rss_mib_end"] + 8,
}
if not args.idle_only:
    checks.update(
        both_full_probes_zero_failures=all(not v["regression"]["native_checks"]["failures"] for v in results.values()),
        candidate_event_p95_under_50ms=candidate["regression"]["event_latency"]["p95_ms"] <= 50)
report = {"scope": "Same machine, offline native fixture; exact idle window lengths are recorded per bundle.",
          "physical_input_or_display_scanout_measured": False, "results": results,
          "checks": checks, "passed": all(checks.values())}
(root / "comparison.json").write_text(json.dumps(report, indent=2))
print(json.dumps(checks, indent=2), flush=True)
raise SystemExit(0 if report["passed"] else 1)
