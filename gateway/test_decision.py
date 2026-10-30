#!/usr/bin/env python3
"""M05 self-owned decision v1: real loopback HTTP, SQLite and process restart."""
import concurrent.futures
import copy
import hashlib
import http.client
import json
import sqlite3
import time
import unittest
import uuid
from pathlib import Path

from test_live import EVIDENCE, ProcessServer, command, segment


def fingerprint(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def answer_command(original, run, request, answer, key=None):
    return {"schemaVersion": 1, "decisionSchemaVersion": 1,
            "requestKey": key or str(uuid.uuid4()), "binding": original["binding"],
            "runID": run, "clientInstanceID": original["clientInstanceID"],
            "interactionID": request["interactionID"], "requestRevision": request["requestRevision"],
            "requestFingerprint": request["requestFingerprint"],
            "answerJSON": json.dumps(answer, ensure_ascii=False, separators=(",", ":"))}


class DecisionTests(unittest.TestCase):
    def setUp(self):
        self.server = ProcessServer(token="decision-test-auth")
        self.observations = []

    def tearDown(self):
        self.server.stop()
        with sqlite3.connect(self.server.db) as db:
            db.backup(sqlite3.connect(EVIDENCE / (self.id().rsplit(".", 1)[-1] + "-final.sqlite")))
        record = {"test": self.id(), "database": str(self.server.db),
                  "observations": self.observations, "remoteProviderRequests": 0,
                  "provider": "synthetic-test-only",
                  "sources": {name: hashlib.sha256((Path(__file__).parent / name).read_bytes()).hexdigest()
                              for name in ("server.py", "test_provider.py", "test_decision.py", "test_live.py")}}
        (EVIDENCE / (self.id().rsplit(".", 1)[-1] + ".json")).write_text(json.dumps(record, indent=2) + "\n")

    def waiting(self, params=None, kind="waiting_confirmation", ttl=300, identity=None, repeat=False):
        fixture = {"kind": kind, "ttl": ttl,
                   "repeat": repeat,
                   "params": params or {"title": "Synthetic decision", "availableDecisions": ["accept", "decline"]}}
        if identity is not None:
            fixture["id"] = identity
        body = command("test:decision:" + json.dumps(fixture))
        run, _ = self.server.create(body)
        self.server.await_phase(run, {kind})
        status, events = self.server.events(run)
        self.assertEqual(status, 200)
        request = events[-1]["data"]["payload"]
        return body, run, request

    def read(self, run, request):
        return self.server.http("GET", f"runs/{segment(run)}/interactions/{segment(request['interactionID'])}")

    def post(self, run, body):
        return self.server.http("POST", f"runs/{segment(run)}/continue", body)

    def counts(self, run):
        with sqlite3.connect(self.server.db) as db:
            row = db.execute("SELECT generation,messages FROM runs WHERE id=?", (run,)).fetchone()
            return row[0], json.loads(row[1]), db.execute(
                "SELECT COUNT(*) FROM interactions WHERE run=? AND decision IS NOT NULL", (run,)).fetchone()[0]

    def test_pending_metadata_and_scoped_opaque_lookup(self):
        original, run, request = self.waiting(identity="confirmation/a+汉字")
        status, snapshot = self.read(run, request)
        self.assertEqual(status, 200)
        self.assertEqual(snapshot["state"], "pending")
        for field in ("decisionSchemaVersion", "requestRevision", "requestFingerprint", "createdAt", "expiresAt"):
            self.assertEqual(snapshot[field], request[field])
        self.assertEqual(snapshot["binding"], original["binding"])
        self.assertEqual(snapshot["clientInstanceID"], original["clientInstanceID"])
        self.assertGreaterEqual(snapshot["serverTime"], request["serverTime"])
        self.assertLess(snapshot["serverTime"], snapshot["expiresAt"])
        self.assertNotIn("decision", snapshot)
        self.assertNotIn("params", snapshot)
        self.assertEqual(self.server.http("GET", f"runs/{segment(run)}/interactions/absent")[0], 404)
        self.assertEqual(self.server.http("GET", f"runs/other/interactions/{segment(request['interactionID'])}")[0], 404)
        self.assertEqual(self.server.http("GET", f"runs/{segment(run)}/interactions/{segment(request['interactionID'])}",
                                          auth=False)[0], 401)
        self.observations.append(snapshot)

    def test_accept_receipt_and_replay_are_atomic(self):
        original, run, request = self.waiting()
        answer = answer_command(original, run, request, {"decision": "accept"})
        status, receipt = self.post(run, answer)
        self.assertEqual(status, 200)
        decision = receipt["decisionReceipt"]
        self.assertEqual(decision["state"], "resolved")
        self.assertEqual(decision["decision"]["requestKey"], answer["requestKey"])
        self.assertEqual(decision["decision"]["answerSHA256"], fingerprint(answer["answerJSON"]))
        self.assertEqual(decision["decision"]["generation"], 1)
        self.assertEqual(decision["decision"]["messageIndex"], 2)  # system, original user
        self.assertEqual(self.post(run, answer), (status, receipt))
        self.server.await_phase(run, {"completed"})
        events = self.server.events(run)[1]
        resolved = [event["data"]["payload"] for event in events if event["event"] == "decision_resolved"]
        self.assertEqual(resolved, [decision])
        self.assertEqual(self.read(run, request)[1]["decision"], decision["decision"])
        generation, messages, count = self.counts(run)
        self.assertEqual((generation, count), (1, 1))
        self.assertEqual(messages[decision["decision"]["messageIndex"]],
                         {"role": "user", "content": '{"decision":"accept"}'})
        self.observations.append({"receipt": receipt, "replay": resolved})

    def test_expired_is_readable_and_never_accepted(self):
        original, run, request = self.waiting(ttl=-0.01)
        snapshot = self.read(run, request)[1]
        self.assertEqual(snapshot["state"], "expired")
        self.assertGreaterEqual(snapshot["serverTime"], snapshot["expiresAt"])
        answer = answer_command(original, run, request, {"decision": "accept"})
        self.assertEqual(self.post(run, answer)[0], 410)
        self.assertEqual(self.server.http("GET", "requests/" + answer["requestKey"])[0], 404)
        self.assertEqual(self.counts(run)[0::2], (0, 0))
        self.server.restart(crash=True)
        self.assertEqual(self.read(run, request)[1]["state"], "expired")
        self.observations.append(snapshot)

    def test_revision_fingerprint_binding_and_client_conflicts_preserve_pending(self):
        original, run, request = self.waiting()
        answer = answer_command(original, run, request, {"decision": "decline"})
        for field, value in (("requestRevision", 2), ("requestFingerprint", "0" * 64),
                             ("clientInstanceID", "stale-client"), ("interactionID", "stale-request"),
                             ("runID", "stale-run"), ("binding", {"sessionID": "stale-session"})):
            bad = dict(answer, **{field: value})
            self.assertEqual(self.post(run, bad)[0], 409, field)
        self.assertEqual(self.read(run, request)[1]["state"], "pending")
        self.assertEqual(self.counts(run)[0::2], (0, 0))
        self.assertEqual(self.post(run, answer)[0], 200)

    def test_two_reply_identities_only_one_decision_wins(self):
        original, run, request = self.waiting()
        yes = answer_command(original, run, request, {"decision": "accept"})
        no = answer_command(original, run, request, {"decision": "decline"})
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda body: self.post(run, body), [yes, no]))
        self.assertEqual(sorted(r[0] for r in results), [200, 409])
        winner = next(body for body, result in zip([yes, no], results) if result[0] == 200)
        snapshot = self.read(run, request)[1]
        self.assertEqual(snapshot["decision"]["requestKey"], winner["requestKey"])
        self.assertEqual(snapshot["decision"]["answerSHA256"], fingerprint(winner["answerJSON"]))
        self.assertEqual(self.counts(run)[2], 1)
        self.observations.append(snapshot)

    def test_same_key_same_body_is_idempotent_changed_body_conflicts(self):
        original, run, request = self.waiting()
        answer = answer_command(original, run, request, {"decision": "accept"})
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.post(run, answer), range(4)))
        self.assertTrue(all(r == results[0] for r in results))
        changed = dict(answer, answerJSON='{"decision":"decline"}')
        self.assertEqual(self.post(run, changed)[0], 409)
        self.assertEqual(self.counts(run)[2], 1)

    def test_reply_accepted_before_response_loss_survives_real_sigkill(self):
        original, run, request = self.waiting()
        answer = answer_command(original, run, request, {"decision": "accept"})
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=5)
        raw = json.dumps(answer)
        connection.request("POST", f"/v1/runs/{segment(run)}/continue", raw,
                           {"Content-Type": "application/json", "Idempotency-Key": answer["requestKey"],
                            "Authorization": "Bearer " + self.server.token})
        # Close without reading the response: acceptance is unknown to this sender.
        connection.close()
        deadline = time.monotonic() + 5
        while True:
            status, snapshot = self.read(run, request)
            if status == 200 and snapshot["state"] == "resolved":
                break
            self.assertLess(time.monotonic(), deadline)
        self.server.restart(crash=True)
        restored = self.read(run, request)[1]
        self.assertEqual(restored["state"], "resolved")
        self.assertEqual(restored["decision"], snapshot["decision"])
        receipt = self.server.http("GET", "requests/" + answer["requestKey"])
        self.assertEqual(receipt[0], 200)
        self.assertEqual(receipt[1]["decisionReceipt"]["decision"], restored["decision"])
        self.assertEqual(self.post(run, answer), receipt)
        self.assertEqual(self.post(run, dict(answer, requestKey=str(uuid.uuid4())))[0], 409)
        self.assertEqual(self.counts(run)[2], 1)
        self.observations.append({"lostResponse": True, "realSIGKILL": True, "readback": restored})

    def test_receipt_insert_failure_rolls_back_decision_message_event_and_generation(self):
        original, run, request = self.waiting()
        answer = answer_command(original, run, request, {"decision": "accept"}, key="fixture-abort")
        with sqlite3.connect(self.server.db) as db:
            db.execute("CREATE TRIGGER decision_fixture_abort BEFORE INSERT ON receipts "
                       "WHEN NEW.key='fixture-abort' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        before = self.counts(run)
        self.assertEqual(self.post(run, answer)[0], 500)
        self.assertEqual(self.counts(run), before)
        self.assertEqual(self.read(run, request)[1]["state"], "pending")
        self.assertFalse(any(e["event"] == "decision_resolved" for e in self.server.events(run)[1]))
        with sqlite3.connect(self.server.db) as db:
            db.execute("DROP TRIGGER decision_fixture_abort")
        self.assertEqual(self.post(run, answer)[0], 200)
        self.assertEqual(self.counts(run)[2], 1)
        self.observations.append({"realSQLiteAbort": True, "before": before})

    def test_batch_modifications_original_order_and_cost_are_exact(self):
        params = {"items": [
            {"index": 9, "action": "write_file", "allowedModifications": ["path", "text"]},
            {"index": 2, "action": "organize", "allowedModifications": ["destination"]}],
            "cost": {"estimate": 0.25, "currency": "synthetic-credit", "availableDecisions": ["accept", "decline"]}}
        original, run, request = self.waiting(params)
        result = {"items": [
            {"index": 9, "action": "write_file", "decision": "accept",
             "modifications": {"path": "临时/🙂.txt", "text": "原始\n正文e\u0301"}},
            {"index": 2, "action": "organize", "decision": "decline", "modifications": {}}],
            "costDecision": "decline"}
        body = answer_command(original, run, request, result)
        status, receipt = self.post(run, body)
        self.assertEqual(status, 200)
        messages = self.counts(run)[1]
        position = receipt["decisionReceipt"]["decision"]["messageIndex"]
        self.assertEqual(json.loads(messages[position]["content"]), result)
        self.assertEqual(receipt["decisionReceipt"]["decision"]["answerSHA256"], fingerprint(body["answerJSON"]))
        self.observations.append({"original": params, "answer": result, "wire": messages[position],
                                  "receipt": receipt})

    def test_batch_all_declined_and_cost_remains_independent(self):
        params = {"items": [{"index": 6, "action": "write_file"}, {"index": 1, "action": "organize"}],
                  "cost": {"availableDecisions": ["accept", "decline"]}}
        original, run, request = self.waiting(params)
        result = {"items": [{**item, "decision": "decline", "modifications": {}} for item in params["items"]],
                  "costDecision": "accept"}
        status, receipt = self.post(run, answer_command(original, run, request, result))
        self.assertEqual(status, 200)
        wire = self.counts(run)[1][receipt["decisionReceipt"]["decision"]["messageIndex"]]
        self.assertEqual(json.loads(wire["content"]), result)
        self.observations.append({"allDeclined": True, "costIndependent": True, "answer": result})

    def test_batch_missing_reordered_duplicate_or_altered_identity_and_modifications_rejected(self):
        params = {"items": [{"index": 8, "action": "write", "allowedModifications": ["text"]},
                            {"index": 3, "action": "move"}], "cost": {}}
        original, run, request = self.waiting(params)
        result = {"items": [{"index": 8, "action": "write", "decision": "accept", "modifications": {"text": "ok"}},
                            {"index": 3, "action": "move", "decision": "decline", "modifications": {}}],
                  "costDecision": "decline"}
        bad_results = []
        for change in ("missing", "reordered", "duplicate", "index-bool", "action", "extra-modification",
                       "declined-modification", "missing-cost", "extra-key"):
            bad = copy.deepcopy(result)
            if change == "missing": bad["items"].pop()
            elif change == "reordered": bad["items"].reverse()
            elif change == "duplicate": bad["items"][1] = bad["items"][0]
            elif change == "index-bool": bad["items"][1]["index"] = True
            elif change == "action": bad["items"][0]["action"] = "delete"
            elif change == "extra-modification": bad["items"][0]["modifications"]["path"] = "new"
            elif change == "declined-modification": bad["items"][1]["modifications"]["text"] = "new"
            elif change == "missing-cost": del bad["costDecision"]
            elif change == "extra-key": bad["decision"] = "accept"
            bad_results.append((change, bad))
        for label, result in bad_results:
            self.assertEqual(self.post(run, answer_command(original, run, request, result))[0], 400, label)
        self.assertEqual(self.read(run, request)[1]["state"], "pending")
        self.assertEqual(self.counts(run)[0::2], (0, 0))

    def test_secret_questions_digest_without_plaintext_in_readback_receipt_or_event(self):
        params = {"questions": [
            {"id": "style", "question": "Style?", "options": [{"label": "natural"}]},
            {"id": "secret", "question": "Secret?", "isSecret": True, "isOther": True}]}
        original, run, request = self.waiting(params, kind="waiting_question")
        secret = "SYNTHETIC-PRIVATE-🙂\nquote\""
        answer = answer_command(original, run, request, {"answers": {
            "style": {"answers": ["natural"]}, "secret": {"answers": [secret]}}})
        status, receipt = self.post(run, answer)
        self.assertEqual(status, 200)
        self.assertEqual(receipt["decisionReceipt"]["decision"]["answerSHA256"], fingerprint(answer["answerJSON"]))
        values = [receipt, self.read(run, request)[1],
                  self.server.http("GET", "requests/" + answer["requestKey"])[1],
                  [e for e in self.server.events(run)[1] if e["event"] == "decision_resolved"]]
        # The synthetic provider intentionally echoes its user message in content.
        # Only decision readback/event/receipts, not provider content, are checked.
        self.assertTrue(all(secret not in json.dumps(value, ensure_ascii=False) for value in values))
        self.assertTrue(all("SYNTHETIC-PRIVATE" not in json.dumps(value) for value in values))
        self.observations.append({"secretReadbackAbsent": True, "receipt": receipt})

    def test_question_identity_options_and_single_answer_validation(self):
        params = {"questions": [{"id": "q", "question": "Choice?", "options": [{"label": "one"}]}]}
        original, run, request = self.waiting(params, kind="waiting_question")
        for result in ({"answers": {}}, {"answers": {"wrong": {"answers": ["one"]}}},
                       {"answers": {"q": {"answers": ["two"]}}}, {"answers": {"q": {"answers": ["one", "one"]}}},
                       {"answers": {"q": {"answers": [" "]}}}, {"answers": {"q": {"answers": ["one"], "extra": 1}}}):
            self.assertEqual(self.post(run, answer_command(original, run, request, result))[0], 400)
        self.assertEqual(self.counts(run)[2], 0)

    def test_malformed_answers_and_versions_fail_before_any_decision(self):
        original, run, request = self.waiting()
        valid = answer_command(original, run, request, {"decision": "accept"})
        for changes in ({"decisionSchemaVersion": True}, {"decisionSchemaVersion": 2},
                        {"answerJSON": '{"decision":"accept","decision":"decline"}'},
                        {"answerJSON": '{"number":NaN}'}, {"answerJSON": "[]"},
                        {"requestRevision": True}, {"requestFingerprint": "xyz"},
                        {"answer": {"decision": "accept"}}, {"answerJSON": '{"decision":"accept","extra":true}'}):
            self.assertEqual(self.post(run, dict(valid, **changes))[0], 400)
        self.assertEqual(self.read(run, request)[1]["state"], "pending")
        self.assertEqual(self.counts(run)[2], 0)

    def test_complete_context_budget_rejects_reply_without_partial_acceptance(self):
        fixture = {"kind": "waiting_question", "params": {
            "questions": [{"id": "q", "question": "Freeform?", "isOther": True}]}}
        original = command("test:decision:" + json.dumps(fixture))
        original["history"].insert(0, {"id": str(uuid.uuid4()), "role": "user", "content": "h" * (6 * 1024 * 1024)})
        run, _ = self.server.create(original)
        self.server.await_phase(run, {"waiting_question"})
        request = self.server.events(run)[1][-1]["data"]["payload"]
        answer = answer_command(original, run, request, {"answers": {"q": {"answers": ["a" * (3 * 1024 * 1024)]}}})
        # POST itself is under 8 MiB; only the complete resulting context exceeds it.
        self.assertLess(len(json.dumps(answer).encode()), 8 * 1024 * 1024)
        before = self.counts(run)
        status, rejection = self.post(run, answer)
        self.assertEqual(status, 413)
        self.assertEqual(rejection["error"]["code"], "DECISION_CONTEXT_LIMIT")
        self.assertEqual(self.counts(run), before)
        self.assertEqual(self.read(run, request)[1]["state"], "pending")
        self.assertEqual(self.server.http("GET", "requests/" + answer["requestKey"])[0], 404)
        self.observations.append({"completeContextLimit": True, "noPartialAccept": True})

    def test_cancel_and_legacy_continue_supersede_unanswered_request(self):
        original, run, request = self.waiting()
        cancel = {"schemaVersion": 1, "requestKey": str(uuid.uuid4()), "binding": original["binding"]}
        self.assertEqual(self.server.http("POST", f"runs/{segment(run)}/cancel", cancel)[0], 200)
        self.assertEqual(self.read(run, request)[1]["state"], "superseded")
        self.assertEqual(self.post(run, answer_command(original, run, request, {"decision": "accept"}))[0], 409)
        original, run, request = self.waiting()
        continuation = copy.deepcopy(original)
        continuation["requestKey"] = str(uuid.uuid4())
        continuation["history"][0]["content"] = "ordinary continue"
        self.assertEqual(self.post(run, continuation)[0], 200)
        self.assertEqual(self.read(run, request)[1]["state"], "superseded")
        self.assertEqual(self.counts(run)[2], 0)

    def test_v2_pending_migration_preserves_events_and_receipts(self):
        original, run, request = self.waiting()
        self.server.stop()
        with sqlite3.connect(self.server.db) as db:
            old = {k: v for k, v in request.items()
                   if k not in {"decisionSchemaVersion", "requestRevision", "requestFingerprint", "serverTime", "createdAt"}}
            db.execute("UPDATE runs SET interaction=? WHERE id=?", (json.dumps(old), run))
            db.execute("DROP TABLE interactions")
            db.execute("PRAGMA user_version=2")
            events = db.execute("SELECT id,frame FROM events ORDER BY seq").fetchall()
            receipts = db.execute("SELECT * FROM receipts").fetchall()
        self.server.start()
        status, readback = self.read(run, old)
        self.assertEqual(status, 200)
        self.assertEqual(readback["state"], "pending")
        with sqlite3.connect(self.server.db) as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 4)
            self.assertEqual(db.execute("SELECT id,frame FROM events ORDER BY seq").fetchall(), events)
            self.assertEqual(db.execute("SELECT * FROM receipts").fetchall(), receipts)
        result = self.post(run, answer_command(original, run, readback, {"decision": "decline"}))
        self.assertEqual(result[0], 200)
        self.observations.append({"migrationV2ToV3": True, "oldEventsAndReceiptsUnchanged": True})

    def test_v2_cancelled_request_does_not_break_migration_or_invent_a_decision(self):
        original, run, request = self.waiting()
        cancel = {"schemaVersion": 1, "requestKey": str(uuid.uuid4()), "binding": original["binding"]}
        self.server.http("POST", f"runs/{segment(run)}/cancel", cancel)
        self.server.stop()
        with sqlite3.connect(self.server.db) as db:
            db.execute("DROP TABLE interactions")
            db.execute("PRAGMA user_version=2")
            before = db.execute("SELECT * FROM receipts").fetchall()
        self.server.start()
        self.assertEqual(self.server.http("GET", "runs/" + segment(run))[1]["phase"], "cancelled")
        self.assertEqual(self.read(run, request)[0], 404)
        with sqlite3.connect(self.server.db) as db:
            self.assertEqual(db.execute("SELECT * FROM receipts").fetchall(), before)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM interactions").fetchone()[0], 0)

    def test_legacy_unstructured_pending_request_migrates_but_cannot_claim_v1_validation(self):
        original, run, request = self.waiting(kind="waiting_question", params={
            "questions": [{"id": "q", "question": "Synthetic?"}]})
        self.server.stop()
        with sqlite3.connect(self.server.db) as db:
            legacy = {"interactionID": request["interactionID"], "expiresAt": request["expiresAt"],
                      "params": {"legacyPrompt": "old unstructured question"}}
            db.execute("UPDATE runs SET interaction=? WHERE id=?", (json.dumps(legacy), run))
            db.execute("DROP TABLE interactions")
            db.execute("PRAGMA user_version=2")
        self.server.start()
        status, snapshot = self.read(run, request)
        self.assertEqual(status, 200)
        self.assertEqual(snapshot["state"], "pending")
        reply = answer_command(original, run, snapshot, {"answers": {"q": {"answers": ["answer"]}}})
        self.assertEqual(self.post(run, reply)[0], 400)
        self.assertEqual(self.counts(run)[2], 0)

    def test_same_interaction_identifier_is_scoped_to_its_original_run(self):
        first, run1, request1 = self.waiting(identity="shared-id")
        second, run2, request2 = self.waiting(identity="shared-id")
        reply = answer_command(first, run1, request1, {"decision": "accept"})
        self.assertEqual(self.post(run1, reply)[0], 200)
        self.assertEqual(self.read(run1, request1)[1]["state"], "resolved")
        self.assertEqual(self.read(run2, request2)[1]["state"], "pending")
        self.assertEqual(self.post(run2, reply)[0], 409)
        self.assertEqual(self.counts(run2)[2], 0)

    def test_reusing_original_identity_with_changed_request_is_rejected(self):
        original, run, request = self.waiting(identity="one-request")
        continuation = copy.deepcopy(original)
        fixture = {"id": "one-request", "params": {"title": "Changed operation"}}
        continuation["history"][0]["content"] = "test:decision:" + json.dumps(fixture)
        continuation["requestKey"] = str(uuid.uuid4())
        self.assertEqual(self.post(run, continuation)[0], 200)
        self.server.await_phase(run, {"failed"})
        self.assertEqual(self.read(run, request)[1]["requestFingerprint"], request["requestFingerprint"])
        self.assertEqual(self.read(run, request)[1]["state"], "superseded")
        events = self.server.events(run)[1]
        self.assertEqual(sum(e["event"] == "waiting_confirmation" for e in events), 1)
        self.assertEqual(events[-1]["data"]["payload"]["code"], "INTERACTION_ID_REUSED")
        self.assertEqual(self.counts(run)[2], 0)

    def test_malformed_source_request_never_becomes_pending(self):
        cases = [
            {"kind": "waiting_confirmation", "params": {"availableDecisions": [{}]}},
            {"kind": "waiting_confirmation", "params": {"items": [{"index": True, "action": "write"}]}},
            {"kind": "waiting_confirmation", "params": {"cost": {"availableDecisions": ["maybe"]}}},
            {"kind": "waiting_question", "params": {"questions": [{"id": "q", "question": "Choose",
                                                                  "options": [{"label": "x"}, {"label": "x"}]}]}}]
        for fixture in cases:
            original = command("test:decision:" + json.dumps(fixture))
            run, _ = self.server.create(original)
            self.server.await_phase(run, {"failed"})
            self.assertFalse(any(e["event"].startswith("waiting_") for e in self.server.events(run)[1]))
            with sqlite3.connect(self.server.db) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM interactions WHERE run=?", (run,)).fetchone()[0], 0)

    def test_real_128_confirmation_rounds_are_retained_then_limit_rejects_only_new_request(self):
        original, run, request = self.waiting(repeat=True)
        accepted = []
        for _ in range(128):
            body = answer_command(original, run, request, {"decision": "decline"})
            status, receipt = self.post(run, body)
            self.assertEqual(status, 200)
            accepted.append(receipt["decisionReceipt"]["decision"])
            # Read SSE to a real waiting event; the 129th request hits the cap.
            self.server.await_phase(run, {"waiting_confirmation", "failed"})
            events = self.server.events(run)[1]
            if events[-1]["event"] == "run_failed":
                break
            request = events[-1]["data"]["payload"]
        self.assertEqual(len(accepted), 128)
        self.server.await_phase(run, {"failed"})
        events = self.server.events(run)[1]
        self.assertEqual(events[-1]["data"]["payload"]["code"], "INTERACTION_LIMIT")
        self.assertEqual(sum(e["event"] == "decision_resolved" for e in events), 128)
        generation, messages, count = self.counts(run)
        self.assertEqual((generation, count), (128, 128))
        for decision in accepted:
            self.assertEqual(json.loads(messages[decision["messageIndex"]]["content"]), {"decision": "decline"})
        self.server.restart(crash=True)
        self.assertEqual(self.counts(run)[2], 128)
        self.observations.append({"actualReplyRounds": len(accepted), "durableAcceptedDecisions": count,
                                  "newRequestLimit": True, "realSIGKILL": True})


if __name__ == "__main__":
    print(json.dumps({"evidence": str(EVIDENCE), "remoteProviderRequests": 0}), flush=True)
    unittest.main()
