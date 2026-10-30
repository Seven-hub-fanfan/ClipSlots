#!/usr/bin/env python3
"""Supervise actual Swift/POSIX process tests; retain failures and raw output."""
import argparse
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    result = {"cases": [], "failures": []}
    for mode in ("duplex", "descendant", "cancel-descendant", "budget", "malformed-output",
                 "closed-stdin", "blocked-stdin", "precancelled"):
        root = pathlib.Path(tempfile.mkdtemp(prefix="clipslots-directory-process-", dir="/private/tmp"))
        started = time.monotonic()
        process = subprocess.Popen([args.binary, str(root), mode], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=6)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        child_file = root / "child.pid"
        child = int(child_file.read_text()) if child_file.exists() else None
        child_running = False
        if child:
            status = subprocess.run(["/bin/ps", "-p", str(child), "-o", "state=", "-o", "command="],
                                    text=True, capture_output=True).stdout.strip()
            child_running = bool(status) and not status.startswith("Z")
            # This PID was created by this private fixture. Check identity before cleanup.
            if child_running and (str(root) in status or "python" in status):
                os.kill(child, signal.SIGKILL)
        data = None
        try:
            data = json.loads(stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            pass
        checks = {
            "returned_within_budget": not timed_out and data is not None and data["seconds"] < 3,
            "combined_output_budget": data is not None and data["stdoutBytes"] + data["stderrBytes"] <= 512,
            "no_live_child_after_return": not child_running,
        }
        if mode == "duplex":
            checks["successful_duplex"] = data is not None and data["succeeded"]
        elif mode == "descendant":
            checks["descendant_timeout_reported"] = data is not None and data["timedOut"]
        elif mode == "cancel-descendant":
            checks["cancel_not_success_or_timeout"] = data is not None and not data["succeeded"] and not data["timedOut"]
        elif mode == "blocked-stdin":
            checks["blocked_stdin_deadline_stops_process"] = data is not None and data["timedOut"] and not data["succeeded"]
        elif mode == "precancelled":
            checks["pre_cancel_does_not_launch"] = data is not None and data["cancelled"] and not child_file.exists()
        case = {"mode": mode, "root": str(root), "supervisorTimeout": timed_out,
                "exitCode": process.returncode, "elapsed": time.monotonic() - started,
                "rawStdout": stdout, "rawStderr": stderr, "result": data,
                "childPID": child, "childRunningOnReturn": child_running, "checks": checks}
        result["cases"].append(case)
        result["failures"].extend(f"{mode}:{key}" for key, passed in checks.items() if not passed)
    pathlib.Path(args.report).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"cases": len(result["cases"]), "failures": result["failures"]}, ensure_ascii=False))
    return bool(result["failures"])


if __name__ == "__main__":
    raise SystemExit(main())
