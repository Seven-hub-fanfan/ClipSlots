#!/usr/bin/env python3
"""Actual AgentChatModel in isolated App processes against real local gateway."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from test_live import ProcessServer
from test_steer import ControlledUpstream

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SHA = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def run_case(binary, mode):
    directory = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-", dir="/tmp"))
    upstream = ControlledUpstream()
    gateway = ProcessServer(synthetic=False, token="live-auth", provider=upstream.root)
    contents = directory / "Steer Test.app/Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    info = plistlib.loads((REPO / "Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
                CFBundleName="Steer Test", ClipSlotsIsolatedCandidate=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copy2(binary, contents / "MacOS/ClipSlots")
    shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                    contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
    protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
                 SHA(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
                 for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
    sources = {str(p.relative_to(REPO)): SHA(p) for p in (REPO / "Sources").rglob("*.swift")}

    class Control(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path != "/release":
                self.send_error(404)
                return
            upstream.release.set()
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

    control = ThreadingHTTPServer(("127.0.0.1", 0), Control)
    thread = threading.Thread(target=control.serve_forever, daemon=True)
    thread.start()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "GATEWAY_", "STEER_", "CANVAS_"))}
    env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_STEER_REGRESSION="1",
               CLIPSLOTS_DATA_DIR=str(directory), CLIPSLOTS_CONFIG_PATH=str(directory / "config.toml"),
               STEER_GATEWAY_URL=gateway.root, STEER_CONTROL_URL=f"http://127.0.0.1:{control.server_port}")
    phases = ["prepare", "restore"] if mode == "restart" else [mode]
    reports = []
    try:
        for phase in phases:
            env["STEER_APP_MODE"] = phase
            with (directory / (phase + ".log")).open("w") as log:
                result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log, timeout=40)
            report = json.loads((directory / "report.json").read_text())
            shutil.copy2(directory / "report.json", directory / ("report-" + phase + ".json"))
            assert result.returncode == 0 and report["passed"] > 0 and not report["failures"], (directory, report)
            assert report["gui"] is False and report["remoteProviderRequests"] == 0
            reports.append(report)
        if mode == "savefailure":
            checks = {check for report in reports for check in report["checks"]}
            assert {"App queue is persisted before save failure injection",
                    "App session save failure leaves unsubmitted queue editable",
                    "App session save failure explains that no submission occurred",
                    "App session save failure sends no steer POST",
                    "App session save failure preserves running provider"}.issubset(checks)
        with sqlite3.connect(gateway.db) as db:
            assert db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
            db.backup(sqlite3.connect(directory / "server.sqlite3"))
            row = db.execute("SELECT id,binding FROM runs").fetchone()
            upstream.run_id, upstream.binding = row[0], json.loads(row[1])
            placements = db.execute("SELECT body,placement FROM steers WHERE state='placed'").fetchall()
        upstream.test_name = "app-" + mode
        upstream.save_transcript()
        (directory / "provider-wire.json").write_text(upstream.transcript.read_text())
        for raw, p in placements:
            body, placement = json.loads(raw), json.loads(p)
            actual = upstream.requests[placement["generation"]]["messages"][placement["messageIndex"]]
            assert actual == {"role": "user", "content": body["message"]["content"]}
        assert len(upstream.requests) == (2 if mode in {"session", "restart", "preflight", "savefailure"} else 1)
        if mode in {"preflight", "savefailure"}:
            assert len(placements) == 1
            with sqlite3.connect(gateway.db) as db:
                assert db.execute("SELECT count(*) FROM steers").fetchone()[0] == 1
        record = {"case": mode, "directory": str(directory), "passed": sum(r["passed"] for r in reports),
                  "gui": False, "failures": [], "providerRequests": len(upstream.requests),
                  "remoteProviderRequests": 0, "placements": len(placements), "sources": sources,
                  "binarySHA256": SHA(binary), "protected": protected,
                  "protectedUnchanged": all(SHA(Path(p)) == h for p, h in protected.items()),
                  "sourceUnchanged": all(SHA(REPO / p) == h for p, h in sources.items())}
        assert record["protectedUnchanged"] and record["sourceUnchanged"]
        (directory / "verification.json").write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps({k: v for k, v in record.items() if k not in {"sources", "protected"}}), flush=True)
    finally:
        upstream.stop()
        gateway.stop()
        control.shutdown()
        control.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=["session", "cancel", "switch", "restart", "preflight", "savefailure"])
    args = parser.parse_args()
    for case in [args.case] if args.case else ["session", "cancel", "switch", "restart", "preflight", "savefailure"]:
        run_case(args.binary.resolve(strict=True), case)
