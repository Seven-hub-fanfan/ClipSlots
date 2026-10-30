#!/usr/bin/env python3
"""Actual Swift HTTP/SQLite, process restart, SIGKILL, and original reply wire identity."""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "gateway"))
from test_live import ProcessServer, command, segment
from test_app_reply import artifact

parser = argparse.ArgumentParser()
parser.add_argument("--binary", type=Path, required=True)
args = parser.parse_args()
BINARY = args.binary.resolve(strict=True)
ROOT = Path(tempfile.mkdtemp(prefix="clipslots-app-reply-native-", dir="/tmp"))


class Proxy:
    """Real HTTP listener; records every POST and forwards to the actual gateway."""
    def __init__(self, upstream):
        self.mode, self.requests, self.upstream = "normal", [], upstream
        self.marker, self.redirect = None, None
        self.lock = threading.Lock()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def handle_request(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                with owner.lock:
                    owner.requests.append({"method": self.command, "path": self.path,
                                           "body": raw.decode(), "key": self.headers.get("Idempotency-Key")})
                    mode = owner.mode
                fields = {k: v for k, v in self.headers.items() if k.lower() not in {"host", "content-length"}}
                if (self.command == "POST" and mode == "redirect-post") or (
                        self.command == "GET" and mode == "redirect-manifest" and self.path.endswith("/app-reply-manifest")):
                    self.send_response(307)
                    self.send_header("Location", owner.redirect)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.command == "POST" and mode.startswith("http-"):
                    status = int(mode.split("-")[1])
                    data = b'{"error":"synthetic-rejection"}'
                elif self.command == "POST" and mode == "drop-before":
                    self.close_connection = True
                    return
                elif mode == "health-disabled" and self.path.endswith("/health"):
                    status, data = 200, b'{"appReplyExecution":false}'
                else:
                    conn = http.client.HTTPConnection("127.0.0.1", owner.upstream.port, timeout=5)
                    conn.request(self.command, self.path, raw or None, fields)
                    response = conn.getresponse()
                    status, data = response.status, response.read()
                    conn.close()
                if self.command == "POST" and mode == "delay-response":
                    owner.marker.write_text("accepted-response-held")
                    threading.Event().wait(1)
                if self.command == "POST" and mode == "drop-after":
                    self.close_connection = True
                    return
                if status == 200 and self.command == "POST":
                    if mode == "bad-receipt":
                        data = b'{"accepted":true}'
                    elif mode == "wrong-receipt":
                        value = json.loads(data)
                        value["binding"]["sessionID"] = "foreign"
                        data = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_GET = handle_request
            do_POST = handle_request

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1"

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class NativeReply(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self.id().rsplit(".", 1)[-1]
        self.root.mkdir()
        self.server = ProcessServer(token="synthetic-app-reply-token")
        self.proxy = Proxy(self.server)
        app = artifact()
        original = command("test:app-artifact:" + json.dumps(app))
        run, _ = self.server.create(original)
        self.server.await_phase(run, {"completed"})
        event = next(e["data"]["payload"] for e in self.server.events(run)[1] if e["event"] == "artifact_updated")
        self.origin = {"endpoint": self.proxy.url, "authority": event["appReplyAuthority"]}
        self.identity = "55b901e4-0ed9-400f-8a55-562fdf17f233"
        self.raw = '{ "reply_id" : "' + self.identity + '", "action":"previs_reply", "payload":{"text":"é🙂","n":1e0}}'
        self.calls = []
        self.call_lock, self.call_number = threading.Lock(), 0

    def tearDown(self):
        self.proxy.stop()
        self.server.stop()
        with sqlite3.connect(self.server.db) as db, sqlite3.connect(self.root / "server.sqlite") as target:
            db.backup(target)
        (self.root / "wire.json").write_text(json.dumps(self.proxy.requests, ensure_ascii=False, indent=2) + "\n")
        (self.root / "calls.json").write_text(json.dumps(self.calls, ensure_ascii=False, indent=2) + "\n")

    def invoke(self, mode="submit", **changes):
        config = {"mode": mode, "directory": (self.root / "ledger").as_uri(),
                  "origin": self.origin, "replyJSON": self.raw, "replyID": self.identity}
        config.update(changes)
        with self.call_lock:
            self.call_number += 1
            number = self.call_number
        path = self.root / f"config-{number}-{mode}.json"
        path.write_text(json.dumps(config, ensure_ascii=False))
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "GATEWAY_", "APP_REPLY_"))}
        env["APP_REPLY_TEST_TOKEN"] = self.server.token
        output = subprocess.run([str(BINARY), str(path)], capture_output=True, text=True, env=env, timeout=30)
        if mode.startswith("crash-"):
            self.assertEqual(output.returncode, -signal.SIGKILL, (mode, output.stderr))
            self.calls.append({"mode": mode, "realSIGKILL": True})
            return None
        self.assertEqual(output.returncode, 0, output.stderr)
        value = json.loads(output.stdout.splitlines()[-1])
        self.calls.append(value)
        return value

    def posts(self):
        return [r for r in self.proxy.requests if r["method"] == "POST"]

    def test_acceptance_restart_and_original_utf8(self):
        result = self.invoke()
        self.assertIsNone(result["errorCode"])
        self.assertEqual(result["record"]["state"], "accepted")
        receipt = result["record"]["receipt"]
        self.assertEqual(receipt["replySHA256"], hashlib.sha256(self.raw.encode()).hexdigest())
        self.assertEqual(json.loads(self.posts()[0]["body"])["replyJSON"].encode(), self.raw.encode())
        self.assertIn("app%2F%E6%B1%89%E5%AD%97%2Bopaque", self.proxy.requests[0]["path"])
        self.assertIn("run%2F", self.posts()[0]["path"])
        self.server.await_phase(receipt["runID"], {"completed"})
        restored = self.invoke("reconcile")
        self.assertEqual(restored["record"]["receipt"]["state"], "terminal")
        self.assertEqual(restored["record"]["receipt"]["runID"], receipt["runID"])
        self.assertIsNone(self.invoke()["errorCode"])
        self.assertEqual(len(self.posts()), 1)

    def test_lost_acceptance_response_is_read_only_after_restart(self):
        self.proxy.mode = "drop-after"
        result = self.invoke()
        self.assertEqual(result["errorCode"], -32012)
        self.assertEqual(result["record"]["state"], "unknown")
        self.proxy.mode = "normal"
        self.assertEqual(self.invoke()["errorCode"], -32012)
        self.assertIsNone(self.invoke("reconcile")["errorCode"])
        self.assertEqual(len(self.posts()), 1)

    def test_missing_receipt_needs_explicit_same_identity_retry(self):
        self.proxy.mode = "drop-before"
        result = self.invoke()
        self.assertEqual(result["record"]["attempt"], 1)
        self.proxy.mode = "normal"
        self.assertEqual(self.invoke("reconcile")["errorCode"], -32012)
        self.assertEqual(self.invoke()["errorCode"], -32012)
        self.assertEqual(len(self.posts()), 1)
        restored = self.invoke("retry", expectedAttempt=1)
        self.assertIsNone(restored["errorCode"])
        self.assertEqual([p["body"] for p in self.posts()], [self.posts()[0]["body"]] * 2)
        self.assertEqual([p["key"] for p in self.posts()], [self.identity] * 2)

    def test_processes_reserve_only_one_initial_attempt(self):
        self.invoke("prepare")
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(lambda _: self.invoke(), range(5)))
        self.assertTrue(any(r["errorCode"] is None for r in results))
        self.assertEqual(len(self.posts()), 1)
        self.assertEqual(self.invoke("snapshot")["record"]["attempt"], 1)

    def test_raw_whitespace_unicode_and_origin_are_immutable(self):
        self.invoke("prepare")
        for changed in [self.raw + " ", self.raw.replace("é", "é"), self.raw.replace("1e0", "1")]:
            self.assertEqual(self.invoke(replyJSON=changed)["errorCode"], -32010)
        changed = dict(self.origin, endpoint="http://127.0.0.1:1/v1")
        self.assertEqual(self.invoke(origin=changed)["errorCode"], -32010)
        self.assertEqual(self.posts(), [])
        self.assertEqual(self.invoke("snapshot")["record"]["submission"]["replyJSON"].encode(), self.raw.encode())

    def test_saving_quota_failure_and_revoked_permission_do_not_post(self):
        result = self.invoke(quota=0)
        self.assertEqual(result["errorCode"], -32010)
        self.assertNotIn("record", result)
        result = self.invoke(revokedAfter=1)
        self.assertEqual(result["errorCode"], -32010)
        self.assertEqual(result["record"]["state"], "saved")
        self.assertEqual(self.posts(), [])

    def test_unsupported_health_is_preflight_without_chat_submission(self):
        self.proxy.mode = "health-disabled"
        self.assertEqual(self.invoke()["errorCode"], -32010)
        self.assertEqual(self.invoke("snapshot")["record"]["attempt"], 0)
        self.assertEqual(self.posts(), [])

    def test_permission_revoked_after_post_preserves_acceptance_and_reports_unknown(self):
        result = self.invoke(revokedAfterPost=True)
        self.assertEqual(result["errorCode"], -32012)
        self.assertEqual(result["record"]["state"], "accepted")
        self.assertEqual(len(self.posts()), 1)
        self.assertIsNone(self.invoke("reconcile")["errorCode"])
        self.assertEqual(len(self.posts()), 1)

    def test_server_sigkill_retains_acceptance_but_reports_execution_unknown(self):
        self.raw = json.dumps({"reply_id": self.identity, "action": "previs_reply", "payload": {"slow": True}})
        receipt = self.invoke()["record"]["receipt"]
        self.server.restart(crash=True)
        result = self.invoke("reconcile")
        self.assertIsNone(result["errorCode"])
        self.assertEqual(result["record"]["receipt"]["runID"], receipt["runID"])
        self.assertEqual(result["record"]["receipt"]["state"], "unknown")
        self.assertEqual(result["record"]["state"], "accepted")
        self.assertIsNone(self.invoke("retry", expectedAttempt=1)["errorCode"])
        self.assertEqual(len(self.posts()), 1)

    def test_business_failure_does_not_erase_acceptance(self):
        self.raw = json.dumps({"reply_id": self.identity, "action": "previs_reply", "payload": {"fail": True}})
        receipt = self.invoke()["record"]["receipt"]
        self.server.await_phase(receipt["runID"], {"failed"})
        result = self.invoke("reconcile")
        self.assertIsNone(result["errorCode"])
        self.assertEqual(result["record"]["state"], "accepted")
        self.assertEqual(result["record"]["receipt"]["phase"], "failed")
        self.assertEqual(len(self.posts()), 1)

    def test_receipt_save_quota_abort_leaves_unknown_until_readback(self):
        result = self.invoke("fail-accept")
        self.assertEqual(result["errorCode"], -32012)
        self.assertEqual(self.invoke("snapshot")["record"]["state"], "unknown")
        self.assertIsNone(self.invoke("reconcile")["errorCode"])
        self.assertEqual(len(self.posts()), 1)

    def test_cancellation_after_post_only_reconciles_original_receipt(self):
        self.proxy.mode = "delay-response"
        self.proxy.marker = self.root / "post-started"
        result = self.invoke("cancel", cancellationMarker=self.proxy.marker.as_uri())
        self.assertEqual(result["errorCode"], -32012)
        self.assertEqual(self.invoke("snapshot")["record"]["state"], "unknown")
        self.proxy.mode = "normal"
        self.assertIsNone(self.invoke("reconcile")["errorCode"])
        self.assertEqual(len(self.posts()), 1)

    def test_http_redirects_never_receive_body_or_credentials(self):
        trap = Proxy(self.server)
        try:
            self.proxy.redirect = trap.url + "/trap"
            self.proxy.mode = "redirect-manifest"
            self.assertEqual(self.invoke()["errorCode"], -32010)
            self.assertEqual(self.posts(), [])
            self.proxy.mode = "redirect-post"
            self.assertEqual(self.invoke()["errorCode"], -32012)
            self.assertEqual(len(self.posts()), 1)
            self.assertEqual(trap.requests, [])
        finally:
            trap.stop()

    def test_explicit_http_rejections_and_ambiguous_http_remain_distinct(self):
        for status in [400, 401, 403, 404, 405, 409, 413, 422, 429, 408, 425, 500, 502, 503]:
            self.identity = f"55b901e4-0ed9-400f-8a55-{status:012d}"
            self.raw = json.dumps({"reply_id": self.identity, "action": "previs_reply", "payload": {}})
            self.proxy.mode = f"http-{status}"
            result = self.invoke()
            rejected = status in [400, 401, 403, 404, 405, 409, 413, 422, 429]
            self.assertEqual(result["errorCode"], -32011 if rejected else -32012)
            self.assertEqual(result["record"]["state"], "rejected" if rejected else "unknown")
            before = len(self.posts())
            self.invoke()
            self.assertEqual(len(self.posts()), before)

    def test_invalid_or_foreign_receipt_keeps_unknown_and_reconciles(self):
        for mode in ["bad-receipt", "wrong-receipt"]:
            self.identity = "55b901e4-0ed9-400f-8a55-" + ("111111111111" if mode == "bad-receipt" else "222222222222")
            self.raw = json.dumps({"reply_id": self.identity, "action": "previs_reply", "payload": {}})
            self.proxy.mode = mode
            self.assertEqual(self.invoke()["errorCode"], -32012)
            self.proxy.mode = "normal"
            self.assertIsNone(self.invoke("reconcile")["errorCode"])
        self.assertEqual(len(self.posts()), 2)

    def test_sigkill_inside_claim_rolls_back_and_after_commit_retains_unknown(self):
        self.invoke("prepare")
        self.invoke("crash-claim")
        self.assertEqual(self.invoke("snapshot")["record"]["state"], "saved")
        self.invoke("crash-after-claim")
        self.assertEqual(self.invoke("snapshot")["record"]["state"], "unknown")
        self.assertEqual(self.invoke()["errorCode"], -32012)
        self.assertEqual(self.posts(), [])
        self.assertIsNone(self.invoke("retry", expectedAttempt=1)["errorCode"])
        self.assertEqual(len(self.posts()), 1)

    def test_sigkill_after_remote_accept_before_local_receipt_recovers(self):
        self.invoke("crash-accept")
        self.assertEqual(self.invoke("snapshot")["record"]["state"], "unknown")
        self.assertEqual(self.invoke()["errorCode"], -32012)
        self.assertIsNone(self.invoke("reconcile")["errorCode"])
        self.assertEqual(len(self.posts()), 1)

    def test_duplicate_fields_invalid_unicode_and_large_raw_are_preflight(self):
        inputs = [
            '{"reply_id":"' + self.identity + '","action":"previs_reply","payload":{"x":1,"x":2}}',
            '{"reply_id":"' + self.identity + '","action":"previs_reply","payload":{"x":"\\ud800"}}',
            '{"reply_id":"' + self.identity + '","action":"previs_reply","payload":{"x":1e9999}}',
            json.dumps({"reply_id": self.identity, "action": "previs_reply", "payload": {"x": "🙂" * 8192}}, ensure_ascii=False),
        ]
        for raw in inputs:
            self.assertEqual(self.invoke(replyJSON=raw)["errorCode"], -32010)
        self.assertEqual(self.posts(), [])


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(NativeReply)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    summary = {"tests": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
               "root": str(ROOT), "binarySHA256": hashlib.sha256(BINARY.read_bytes()).hexdigest(),
               "remoteProviderRequests": 0, "actualSwiftHTTP": True, "actualSIGKILL": True,
               "nativeWebKitAccepted": False, "M06Accepted": False, "goalComplete": False,
               "sources": {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for folder in ["Sources", "gateway", "scripts"]
                           for p in (REPO / folder).rglob("*")
                           if p.is_file() and p.suffix in {".swift", ".py"} and "__pycache__" not in p.parts}}
    (ROOT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)
    sys.exit(not result.wasSuccessful())
