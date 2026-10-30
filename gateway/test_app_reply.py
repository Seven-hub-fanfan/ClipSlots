"""App reply v1: actual HTTP, concurrent submissions, WAL and SIGKILL recovery."""
import concurrent.futures
import hashlib
import http.client
import json
import signal
import sqlite3
import subprocess
import sys
import unittest
import uuid
from pathlib import Path

from test_live import EVIDENCE, ProcessServer, Upstream, command, segment


def artifact(revision=1, manifest="a" * 64):
    result = {"artifactID": "app/汉字+opaque", "path": "apps/board.html", "revision": revision,
              "content": "<p>isolated synthetic App</p>", "mimeType": "text/html"}
    if manifest is not None:
        result["appReplyManifest"] = {"schemaVersion": 1, "manifestRevision": manifest,
                                    "actions": ["previs_reply"]}
    return result


def reply_body(original, run, app, payload=None, identity=None):
    identity = identity or str(uuid.uuid4())
    return {"schemaVersion": 1, "appReplySchemaVersion": 1, "requestKey": identity,
            "binding": original["binding"], "originRunID": run, "artifactID": app["artifactID"],
            "artifactRevision": app["revision"],
            "manifestRevision": app["appReplyManifest"]["manifestRevision"],
            "replyJSON": json.dumps({"reply_id": identity, "action": "previs_reply",
                                    "payload": payload or {"selection": "原始🙂"},
                                    "expected_manifest_revision": app["appReplyManifest"]["manifestRevision"]},
                                   ensure_ascii=False, separators=(",", ":"))}


class AppReplyTests(unittest.TestCase):
    def setUp(self):
        self.server = ProcessServer(token="app-reply-test-auth")
        self.observations = []

    def tearDown(self):
        self.server.stop()
        name = self.id().rsplit(".", 1)[-1]
        with sqlite3.connect(self.server.db) as db, sqlite3.connect(EVIDENCE / (name + "-final.sqlite")) as target:
            db.backup(target)
        (EVIDENCE / (name + ".json")).write_text(json.dumps({
            "test": self.id(), "observations": self.observations, "remoteProviderRequests": 0,
            "database": str(self.server.db), "provider": "synthetic-test-only",
            "sources": {p: hashlib.sha256((Path(__file__).parent / p).read_bytes()).hexdigest()
                        for p in ("server.py", "app_reply.py", "test_app_reply.py", "test_provider.py", "test_live.py")}
        }, ensure_ascii=False, indent=2) + "\n")

    def source(self, app=None, original=None):
        app = app or artifact()
        body = command("test:app-artifact:" + json.dumps(app))
        if original is not None:
            body["binding"] = original["binding"]
        run, _ = self.server.create(body)
        self.server.await_phase(run, {"completed"})
        return body, run, app

    def manifest(self, run, app):
        return self.server.http("GET", f"runs/{segment(run)}/artifacts/{segment(app['artifactID'])}/app-reply-manifest")

    def post(self, run, body):
        return self.server.http("POST", f"runs/{segment(run)}/app-replies", body)

    def read(self, run, identity):
        return self.server.http("GET", f"runs/{segment(run)}/app-replies/{segment(identity)}")

    def count(self, identity):
        with sqlite3.connect(self.server.db) as db:
            record = db.execute("SELECT * FROM app_replies WHERE id=?", (identity,)).fetchall()
            return len(record), db.execute("SELECT COUNT(*) FROM receipts WHERE key=?", (identity,)).fetchone()[0]

    def test_gateway_issues_authority_distinct_from_html_and_numeric_revision(self):
        original, run, app = self.source()
        status, authority = self.manifest(run, app)
        self.assertEqual(status, 200)
        self.assertEqual(authority, {"schemaVersion": 1, "binding": original["binding"],
            "originRunID": run, "artifactID": app["artifactID"], "path": app["path"],
            "artifactRevision": 1, "manifestRevision": "a" * 64, "actions": ["previs_reply"]})
        event = next(e["data"]["payload"] for e in self.server.events(run)[1] if e["event"] == "artifact_updated")
        self.assertEqual(event["appReplyAuthority"], authority)
        self.assertNotEqual(authority["manifestRevision"], hashlib.sha256(app["content"].encode()).hexdigest())
        self.assertEqual(self.server.http("GET", f"runs/{segment(run)}/artifacts/absent/app-reply-manifest")[0], 404)
        self.assertEqual(self.server.http("GET", f"runs/{segment(run)}/artifacts/{segment(app['artifactID'])}/app-reply-manifest",
                                         auth=False)[0], 401)
        self.observations.append(authority)

    def test_submission_is_structured_and_receipt_atomic_with_run(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        status, accepted = self.post(run, body)
        self.assertEqual(status, 200)
        self.assertFalse(accepted["deduped"])
        self.assertEqual(accepted["replySHA256"], hashlib.sha256(body["replyJSON"].encode()).hexdigest())
        self.assertNotEqual(accepted["runID"], run)
        self.assertEqual(self.count(body["requestKey"]), (1, 1))
        self.server.await_phase(accepted["runID"], {"completed"})
        with sqlite3.connect(self.server.db) as db:
            stored_command, messages = db.execute("SELECT command,messages FROM runs WHERE id=?",
                                                  (accepted["runID"],)).fetchone()
            parent = json.loads(db.execute("SELECT messages FROM runs WHERE id=?", (run,)).fetchone()[0])
        child = json.loads(messages)
        self.assertEqual(child[:-1], parent)
        self.assertEqual(json.loads(stored_command)["appReply"]["reply"], json.loads(body["replyJSON"]))
        self.assertEqual(child[-1]["content"], "synthetic-structured-app-reply")
        events = self.server.events(accepted["runID"])[1]
        self.assertEqual(events[0]["event"], "app_reply_accepted")
        self.assertEqual(events[0]["data"]["payload"], accepted)
        self.assertEqual([e["data"]["payload"]["code"] for e in events if e["event"] == "note"],
                         ["TEST_APP_REPLY_STRUCTURED_CALLBACK"])
        self.assertEqual(self.read(run, body["requestKey"])[1]["state"], "terminal")
        self.observations.append({"receipt": accepted, "events": events})

    def test_same_identity_parallel_submissions_dispatch_only_once(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.post(run, body), range(6)))
        self.assertEqual([r[0] for r in results], [200] * 6)
        self.assertEqual(len({r[1]["runID"] for r in results}), 1)
        self.assertEqual(sum(not r[1]["deduped"] for r in results), 1)
        self.assertEqual(self.count(body["requestKey"]), (1, 1))
        child = results[0][1]["runID"]
        self.server.await_phase(child, {"completed"})
        self.assertEqual(sum(e["event"] == "initial" for e in self.server.events(child)[1]), 1)
        self.observations.append(results)

    def test_changed_payload_or_original_scope_cannot_reuse_reply_identity(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        self.assertEqual(self.post(run, body)[0], 200)
        changed = reply_body(original, run, app, {"selection": "changed"}, body["requestKey"])
        self.assertEqual(self.post(run, changed)[0], 409)
        # Byte identity includes whitespace and equivalent escape encodings.
        changed = dict(body, replyJSON=json.dumps(json.loads(body["replyJSON"]), ensure_ascii=True))
        self.assertEqual(self.post(run, changed)[0], 409)
        other, other_run, other_app = self.source()
        self.assertEqual(self.post(other_run, reply_body(other, other_run, other_app,
                                                        identity=body["requestKey"]))[0], 409)
        self.assertEqual(self.read(other_run, body["requestKey"])[0], 404)
        self.assertEqual(self.count(body["requestKey"]), (1, 1))

    def test_scope_manifest_revision_and_origin_mismatch_have_no_side_effect(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        for field, value in (("binding", {"sessionID": "other"}), ("originRunID", "other"),
                             ("artifactRevision", 2), ("manifestRevision", "b" * 64),
                             ("artifactID", "other")):
            bad = dict(body, **{field: value})
            self.assertIn(self.post(run, bad)[0], (404, 409))
            self.assertEqual(self.count(body["requestKey"]), (0, 0))
        self.assertEqual(self.post(run, body)[0], 200)

    def test_strict_reply_shape_duplicate_json_uuid_and_expected_manifest(self):
        original, run, app = self.source()
        base = reply_body(original, run, app)
        malformed = [None, [], {"reply_id": "invalid", "action": "previs_reply", "payload": {}},
                     dict(json.loads(base["replyJSON"]), payload=[]),
                     dict(json.loads(base["replyJSON"]), action="send_chat"),
                     dict(json.loads(base["replyJSON"]), unknown=True),
                     dict(json.loads(base["replyJSON"]), expected_manifest_revision="b" * 64)]
        for value in malformed:
            body = dict(base, replyJSON=json.dumps(value))
            self.assertIn(self.post(run, body)[0], (400, 409))
        raw = base["replyJSON"].replace('"payload":', '"reply_id":"duplicate","payload":')
        for raw in (raw, '{"payload":{"n":NaN}}', '{"payload":{"x":"\\ud800"}}'):
            self.assertEqual(self.post(run, dict(base, replyJSON=raw))[0], 400)
        self.assertEqual(self.count(base["requestKey"]), (0, 0))
        # Optional expected revision: authority fields remain mandatory.
        value = json.loads(base["replyJSON"])
        del value["expected_manifest_revision"]
        self.assertEqual(self.post(run, dict(base, replyJSON=json.dumps(value)))[0], 200)

    def test_utf8_limit_is_on_actual_reply_bytes(self):
        original, run, app = self.source()
        body = reply_body(original, run, app, {"text": ""})
        fixed = len(body["replyJSON"].encode())
        value = json.loads(body["replyJSON"])
        value["payload"]["text"] = "🙂" * ((32768 - fixed) // 4) + "x" * ((32768 - fixed) % 4)
        body["replyJSON"] = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        self.assertEqual(len(body["replyJSON"].encode()), 32768)
        self.assertEqual(self.post(run, dict(body, replyJSON=body["replyJSON"][:-2] + "x" + body["replyJSON"][-2:]))[0], 413)
        self.assertEqual(self.count(body["requestKey"]), (0, 0))
        self.assertEqual(self.post(run, body)[0], 200)

    def test_lost_http_response_reconciles_without_another_post(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=5)
        connection.request("POST", f"/v1/runs/{segment(run)}/app-replies", json.dumps(body), {
            "Authorization": "Bearer " + self.server.token, "Content-Type": "application/json",
            "Idempotency-Key": body["requestKey"]})
        connection.getresponse()  # Read headers only; the receipt body is deliberately lost.
        connection.close()
        status, readback = self.read(run, body["requestKey"])
        self.assertEqual(status, 200)
        self.assertEqual(readback["replySHA256"], hashlib.sha256(body["replyJSON"].encode()).hexdigest())
        self.assertEqual(self.count(body["requestKey"]), (1, 1))
        self.observations.append(readback)

    def test_sigkill_preserves_acceptance_suspends_execution_and_never_resubmits(self):
        original, run, app = self.source()
        body = reply_body(original, run, app, {"slow": True})
        status, accepted = self.post(run, body)
        self.assertEqual(status, 200)
        self.server.read_until(accepted["runID"], "note")
        self.server.restart(crash=True)
        status, restored = self.read(run, body["requestKey"])
        self.assertEqual(status, 200)
        self.assertEqual((restored["state"], restored["phase"]), ("unknown", "waiting_suspended"))
        self.assertEqual(restored["runID"], accepted["runID"])
        self.assertEqual(self.count(body["requestKey"]), (1, 1))
        replay = self.server.events(accepted["runID"])[1]
        self.assertEqual(sum(e["event"] == "app_reply_accepted" for e in replay), 1)
        self.assertEqual(sum(e["event"] == "initial" for e in replay), 1)
        # Explicit retry keeps the original identity and does not restart a suspended operation.
        duplicate = self.post(run, body)
        self.assertEqual(duplicate[0], 200)
        self.assertTrue(duplicate[1]["deduped"])
        self.assertEqual(self.read(run, body["requestKey"])[1]["state"], "unknown")
        self.observations.extend([accepted, restored])

    def test_replacing_or_revoking_manifest_does_not_erase_accepted_reply(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        accepted = self.post(run, body)[1]
        _, replacement_run, _ = self.source(artifact(2, None), original=original)
        self.assertEqual(self.manifest(run, app)[0], 404)
        self.assertEqual(self.post(run, reply_body(original, run, app))[0], 404)
        self.assertEqual(self.post(run, body)[1]["runID"], accepted["runID"])
        self.assertEqual(self.read(run, body["requestKey"])[0], 200)
        self.assertEqual(self.server.events(replacement_run)[0], 200)

    def test_legacy_command_cannot_smuggle_structured_reply(self):
        body = command()
        body["appReply"] = {"reply": {"action": "previs_reply"}}
        self.assertEqual(self.server.http("POST", "runs", body)[0], 400)
        self.assertEqual(self.server.http("GET", "requests/" + body["requestKey"])[0], 404)

    def test_unconfigured_provider_rejects_without_receipt_or_chat_fallback(self):
        original, run, app = self.source()
        self.server.stop()
        self.server.synthetic = False
        self.server.start()
        body = reply_body(original, run, app)
        self.assertEqual(self.post(run, body)[0], 503)
        self.assertEqual(self.count(body["requestKey"]), (0, 0))
        self.assertFalse(self.server.http("GET", "health")[1]["appReplyExecution"])

    def test_auth_and_framing_reject_without_acceptance(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        path = f"runs/{segment(run)}/app-replies"
        self.assertEqual(self.server.http("POST", path, body, auth=False)[0], 401)
        self.assertEqual(self.server.http("POST", path, body, headers={"Idempotency-Key": "other"})[0], 400)
        self.assertEqual(self.server.http("POST", path + "?query=unknown", body)[0], 400)
        self.assertEqual(self.count(body["requestKey"]), (0, 0))

    def test_sqlite_failure_after_reservation_rolls_back_run_event_and_receipt(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        with sqlite3.connect(self.server.db) as db:
            before = db.execute("SELECT COUNT(*) FROM runs").fetchone()[0]
            db.execute("CREATE TRIGGER reject_app_receipt BEFORE INSERT ON receipts "
                       "WHEN NEW.key = '" + body["requestKey"] + "' "
                       "BEGIN SELECT RAISE(ABORT, 'synthetic disk failure'); END")
        self.assertEqual(self.post(run, body)[0], 500)  # Client classification must be unknown.
        self.assertEqual(self.count(body["requestKey"]), (0, 0))
        with sqlite3.connect(self.server.db) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM runs").fetchone()[0], before)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM events WHERE frame LIKE '%app_reply_accepted%'").fetchone()[0], 0)
            db.execute("DROP TRIGGER reject_app_receipt")
        self.assertEqual(self.read(run, body["requestKey"])[0], 404)
        self.assertEqual(self.post(run, body)[0], 200)  # Explicit retry of the original identity.

    def test_configured_chat_provider_does_not_receive_an_app_reply(self):
        original, run, app = self.source()
        upstream = Upstream()
        try:
            self.server.stop()
            self.server.synthetic = False
            self.server.provider = upstream.url
            self.server.start()
            body = reply_body(original, run, app)
            self.assertEqual(self.post(run, body)[0], 422)
            self.assertEqual(self.count(body["requestKey"]), (0, 0))
            self.assertEqual(upstream.requests, [])
        finally:
            upstream.stop()

    def test_manifest_requires_complete_exact_identity_and_canonical_path(self):
        app = artifact()
        for field, bad in (("manifestRevision", "A" * 64), ("manifestRevision", 1),
                           ("actions", ["previs_reply", "send_chat"]), ("schemaVersion", True)):
            invalid = dict(app, appReplyManifest=dict(app["appReplyManifest"], **{field: bad}))
            original = command("test:app-artifact:" + json.dumps(invalid))
            run, _ = self.server.create(original)
            self.server.await_phase(run, {"failed"})
            self.assertEqual(self.manifest(run, invalid)[0], 404)
        invalid = dict(app, appReplyAuthority={"manifestRevision": "b" * 64})
        run, _ = self.server.create(command("test:app-artifact:" + json.dumps(invalid)))
        self.server.await_phase(run, {"failed"})
        self.assertEqual(self.manifest(run, invalid)[0], 404)
        for path in ("a/../b.html", "/b.html", "a//b.html", "a\\b.html", "a/./b.html"):
            invalid = dict(app, path=path)
            run, _ = self.server.create(command("test:app-artifact:" + json.dumps(invalid)))
            self.server.await_phase(run, {"failed"})
            self.assertEqual(self.manifest(run, invalid)[0], 404)

    def test_v3_migration_keeps_existing_receipts_events_and_messages_byte_identical(self):
        original, run, app = self.source()
        self.server.stop()
        with sqlite3.connect(self.server.db) as db:
            db.execute("DROP TABLE app_artifacts")
            db.execute("DROP TABLE app_replies")
            db.execute("PRAGMA user_version=3")
            before = {table: db.execute("SELECT * FROM " + table).fetchall()
                      for table in ("receipts", "events", "runs", "tools", "steers", "interactions")}
        self.server.start()
        with sqlite3.connect(self.server.db) as db:
            after = {table: db.execute("SELECT * FROM " + table).fetchall() for table in before}
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 4)
        self.assertEqual(before, after)
        # No inferred authority from historical HTML or numeric revision.
        self.assertEqual(self.manifest(run, app)[0], 404)
        self.assertEqual(self.post(run, reply_body(original, run, app))[0], 404)

    def test_explicit_continuation_preserves_reply_and_never_uses_chat_history(self):
        original, run, app = self.source()
        body = reply_body(original, run, app, payload={"slow": True})
        status, accepted = self.post(run, body)
        self.assertEqual(status, 200)
        reply_run = accepted["runID"]
        self.server.restart(crash=True)
        self.assertEqual(self.read(run, body["requestKey"])[1]["phase"], "waiting_suspended")
        continuation = {"schemaVersion": 1, "binding": original["binding"],
                        "requestKey": str(uuid.uuid4()), "clientInstanceID": original["clientInstanceID"]}
        path = f"runs/{segment(reply_run)}/app-reply-continue"
        bad = dict(continuation, history=[])
        self.assertEqual(self.server.http("POST", path, bad)[0], 400)
        self.assertEqual(self.server.http("POST", path, dict(continuation, clientInstanceID="another-client"))[0], 409)
        chat = dict(original, requestKey=str(uuid.uuid4()))
        self.assertEqual(self.server.http("POST", f"runs/{segment(reply_run)}/continue", chat)[0], 409)
        self.assertEqual(self.server.http("POST", path, continuation)[0], 200)
        self.server.await_phase(reply_run, {"completed"})
        self.assertEqual(self.server.http("POST", path, continuation)[0], 200)
        with sqlite3.connect(self.server.db) as db:
            command, messages = db.execute("SELECT command,messages FROM runs WHERE id=?", (reply_run,)).fetchone()
            self.assertEqual(json.loads(command)["appReply"]["reply"]["reply_id"], body["requestKey"])
            self.assertEqual(len([m for m in json.loads(messages) if m["role"] == "user"]), 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM events WHERE run=? "
                "AND frame LIKE '%TEST_APP_REPLY_CONTINUATION%'", (reply_run,)).fetchone()[0], 1)
        self.assertEqual(self.read(run, body["requestKey"])[1]["state"], "terminal")

    def test_sigkill_inside_acceptance_transaction_rolls_back_every_reservation(self):
        original, run, app = self.source()
        body = reply_body(original, run, app)
        self.server.stop()
        with sqlite3.connect(self.server.db) as db:
            before = {table: db.execute("SELECT * FROM " + table).fetchall()
                      for table in ("runs", "app_replies", "events", "receipts")}
        # The real child process executes the production transaction. A SQLite
        # trace callback kills it after run/reply/event insertion, before receipt
        # insertion and commit. No production environment hook is introduced.
        code = """
import json, os, signal, sys
import app_reply
from server import Store, Service, encode
class Provider:
    def generate_app_reply(self, *args):
        raise RuntimeError("must not execute before durable acceptance")
store = Store(sys.argv[1])
service = Service(store, Provider())
def boundary(statement):
    if statement.startswith("INSERT INTO receipts"):
        os.kill(os.getpid(), signal.SIGKILL)
store.db.set_trace_callback(boundary)
app_reply.submit(service, encode(["runs", sys.argv[2], "app-replies"]), sys.argv[2], json.load(sys.stdin))
raise RuntimeError("SIGKILL boundary was not reached")
"""
        result = subprocess.run([sys.executable, "-B", "-c", code, str(self.server.db), run],
                                cwd=Path(__file__).parent, input=json.dumps(body),
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
        with sqlite3.connect(self.server.db) as db:
            after = {table: db.execute("SELECT * FROM " + table).fetchall() for table in before}
        self.assertEqual(before, after)
        self.server.start()
        self.assertEqual(self.read(run, body["requestKey"])[0], 404)
        self.assertEqual(self.count(body["requestKey"]), (0, 0))
        self.assertEqual(self.post(run, body)[0], 200)
        self.assertEqual(self.count(body["requestKey"]), (1, 1))


if __name__ == "__main__":
    print("APP_REPLY_EVIDENCE=" + str(EVIDENCE), flush=True)
    unittest.main()
