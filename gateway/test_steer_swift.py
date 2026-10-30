#!/usr/bin/env python3
"""Real Swift URLSession, controlled provider, SQLite and independent restart."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from test_live import ProcessServer
from test_steer import ControlledUpstream


def run_case(binary, mode):
    directory = Path(tempfile.mkdtemp(prefix="clipslots-gateway-steer-", dir="/tmp"))
    upstream = ControlledUpstream(tools=mode == "tools", hold_follow_up=mode == "continue")
    gateway = ProcessServer(synthetic=False, token="live-auth", provider=upstream.root)

    class Control(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/restart":
                gateway.restart(crash=True)
                upstream.follow_release.set()
            elif self.path == "/release":
                upstream.release.set()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

    control = ThreadingHTTPServer(("127.0.0.1", 0), Control)
    thread = threading.Thread(target=control.serve_forever, daemon=True)
    thread.start()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "GATEWAY_", "STEER_"))}
    env.update(STEER_GATEWAY_URL=gateway.root, STEER_TEST_DIR=str(directory),
               STEER_CONTROL_URL=f"http://127.0.0.1:{control.server_port}", STEER_TEST_MODE=mode)
    try:
        with (directory / "swift.log").open("w") as log:
            result = subprocess.run([str(binary)], env=env, stdout=log, stderr=log, timeout=40)
        assert result.returncode == 0, (directory / "swift.log").read_text()
        if mode == "restart":
            # Original binding is part of the journal identity, including across restart.
            env["STEER_TEST_MODE"] = "restore"
            with (directory / "swift-restore.log").open("w") as log:
                restored = subprocess.run([str(binary)], env=env, stdout=log, stderr=log, timeout=40)
            assert restored.returncode == 0, (directory / "swift-restore.log").read_text()
        state = json.loads((directory / "client-state.json").read_text())
        upstream.run_id = state["runID"]
        upstream.binding = {"sessionID": "swift-" + mode, "projectID": "p", "canvasID": "c"}
        upstream.test_name = "swift-" + mode
        upstream.save_transcript()
        (directory / "provider-wire.json").write_text(upstream.transcript.read_text())
        with sqlite3.connect(gateway.db) as db:
            assert db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
            db.backup(sqlite3.connect(directory / "server.sqlite3"))
            placements = db.execute("SELECT body,placement FROM steers WHERE state='placed' ORDER BY sequence").fetchall()
        for raw, placed in placements:
            message, placement = json.loads(raw)["message"], json.loads(placed)
            request = upstream.requests[placement["generation"]]
            assert request["messages"][placement["messageIndex"]] == {"role": "user", "content": message["content"]}
        if mode == "continue":
            assert len(upstream.requests) == 3
        elif mode in {"hold", "unknown", "tools", "restart"}:
            assert len(upstream.requests) == 2
        else:
            assert len(upstream.requests) == 1
        requests = json.loads((directory / "client-requests.json").read_text())
        if mode == "restart":
            recovered_requests = json.loads((directory / "client-restore-requests.json").read_text())
            assert not any(r["method"] == "POST" for r in recovered_requests)
            requests += recovered_requests
        record = {"case": mode, "directory": str(directory), "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                  "providerRequests": len(upstream.requests), "remoteProviderRequests": 0,
                  "placements": len(placements), "steerPOSTs": sum(r["method"] == "POST" and r["url"].endswith("/steer") for r in requests)}
        (directory / "verification.json").write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(record), flush=True)
        return record
    finally:
        upstream.stop()
        gateway.stop()
        control.shutdown()
        control.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=["hold", "unknown", "missing", "tools", "cancel", "restart", "continue"])
    args = parser.parse_args()
    for case in [args.case] if args.case else ["hold", "unknown", "missing", "tools", "cancel", "restart", "continue"]:
        run_case(args.binary.resolve(strict=True), case)
