#!/usr/bin/env python3
"""M02 real loopback HTTP, SQLite and controlled OpenAI SSE consumer evidence.

All model requests terminate at a synthetic local HTTP listener.
"""
import base64
import copy
import json
import sqlite3
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from test_live import EVIDENCE, ProcessServer, command, segment


def steer_command(original, run, content, identity=None):
    identity = identity or str(uuid.uuid4())
    return {"schemaVersion": 1, "steerSchemaVersion": 1,
            "requestKey": "steer-" + identity, "binding": original["binding"],
            "runID": run, "clientInstanceID": original["clientInstanceID"],
            "submissionID": identity,
            "message": {"id": identity, "role": "user", "content": content}}


class ControlledUpstream:
    """Keep the first real provider round open until the test releases it."""
    def __init__(self, tools=False, fail=False, hold_follow_up=False, hold_timeout=8):
        self.requests = []
        self.ready = threading.Event()
        self.release = threading.Event()
        self.follow_ready = threading.Event()
        self.follow_release = threading.Event()
        self.tools, self.fail, self.hold_follow_up = tools, fail, hold_follow_up
        self.transcript = EVIDENCE / ("steer-upstream-" + uuid.uuid4().hex + ".json")
        self.run_id = None
        self.binding = None
        self.test_name = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                first = not owner.requests
                owner.requests.append(body)
                owner.save_transcript()
                round_index = len(owner.requests)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    def emit(value):
                        self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
                        self.wfile.flush()

                    if first:
                        emit({"choices": [{"index": 0, "delta": {"content": "kept-work"}}]})
                        owner.ready.set()
                        deadline = time.monotonic() + hold_timeout
                        while not owner.release.wait(min(5, max(0, deadline - time.monotonic()))):
                            if time.monotonic() >= deadline:
                                return
                            self.wfile.write(b": synthetic provider heartbeat\n\n")
                            self.wfile.flush()
                        if owner.fail:
                            emit({"error": {"message": "synthetic failure"}})
                            return
                    calls = first and owner.tools
                    if calls:
                        emit({"choices": [{"index": 0, "delta": {"tool_calls": [
                            {"index": i, "id": "steer-call-" + str(i), "type": "function",
                             "function": {"name": "live_test_tool", "arguments": "{}"}}
                            for i in range(2)]}}]})
                    elif not first:
                        emit({"choices": [{"index": 0, "delta": {"content": "follow-up"}}]})
                        if owner.hold_follow_up and round_index == 2:
                            owner.follow_ready.set()
                            if not owner.follow_release.wait(8):
                                return
                    emit({"choices": [{"index": 0, "delta": {},
                                       "finish_reason": "tool_calls" if calls else "stop"}]})
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.root = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def save_transcript(self):
        self.transcript.write_text(json.dumps({"provider": "synthetic-loopback-openai-sse",
            "remoteProviderRequests": 0, "runID": self.run_id, "binding": self.binding,
            "testName": self.test_name, "requests": self.requests}, ensure_ascii=False, indent=2) + "\n")

    def stop(self):
        self.release.set()
        self.follow_release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.save_transcript()


class SteerTests(unittest.TestCase):
    def begin(self, tools=False, fail=False, image=False, readonly=False, hold_follow_up=False):
        upstream = ControlledUpstream(tools=tools, fail=fail, hold_follow_up=hold_follow_up)
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.root)
        self.addCleanup(server.stop)
        original = command("synthetic initial", tools=tools)
        original["messageSchemaVersion"] = 1
        original["config"]["supportsImageInput"] = image
        if readonly:
            original["config"]["taskPolicy"] = "textPolish"
        run, receipt = server.create(original)
        upstream.run_id, upstream.binding, upstream.test_name = run, original["binding"], self.id()
        self.assertTrue(upstream.ready.wait(3))
        return upstream, server, original, run, receipt

    def post(self, server, run, body):
        return server.http("POST", f"runs/{segment(run)}/steer", body)

    def state(self, server, run, body):
        return server.http("GET", f"runs/{segment(run)}/steers/{segment(body['submissionID'])}")

    def assert_clean(self, server):
        with sqlite3.connect(server.db) as db:
            self.assertEqual(db.execute("PRAGMA quick_check").fetchone()[0], "ok")

    def test_accepted_is_not_placement_then_actual_provider_consumes_in_order(self):
        upstream, server, original, run, descriptor = self.begin()
        self.assertEqual(descriptor["steerCapability"]["schemaVersion"], 1)
        self.assertEqual(set(descriptor["steerCapability"]["safePoints"]),
                         {"model_boundary", "tools_resolved"})
        bodies = [steer_command(original, run, value) for value in
                  ["保留此前的工作 🙂\ne\u0301", "再增加一条指令"]]
        accepted = []
        for index, body in enumerate(bodies, 1):
            status, receipt = self.post(server, run, body)
            self.assertEqual(status, 200)
            self.assertEqual(receipt["state"], "accepted")
            self.assertEqual(receipt["revision"], 1)
            self.assertEqual(receipt["sequence"], index)
            self.assertNotIn("placement", receipt)
            self.assertEqual(self.state(server, run, body), (200, receipt))
            accepted.append(receipt)
        self.assertEqual(len(upstream.requests), 1)
        upstream.release.set()
        server.await_phase(run, {"completed"})
        self.assertEqual(len(upstream.requests), 2)
        messages = upstream.requests[1]["messages"]
        self.assertEqual(messages[-3], {"role": "assistant", "content": "kept-work"})
        self.assertEqual(messages[-2:], [dict(role="user", content=b["message"]["content"]) for b in bodies])
        self.assertEqual(upstream.requests[0]["tools"] if "tools" in upstream.requests[0] else [],
                         upstream.requests[1].get("tools", []))
        for index, body in enumerate(bodies):
            status, placed = self.state(server, run, body)
            self.assertEqual(status, 200)
            self.assertEqual(placed["state"], "placed")
            self.assertEqual(placed["revision"], 2)
            self.assertEqual(placed["placement"]["point"], "model_boundary")
            self.assertEqual(placed["placement"]["messageIndex"], len(messages) - 2 + index)
            self.assertEqual(placed["runID"], run)
            # Immutable accepted receipt cannot be misrepresented as consumed.
            self.assertEqual(self.post(server, run, body), (200, accepted[index]))
            self.assertEqual(server.http("GET", "requests/" + segment(body["requestKey"])),
                             (200, accepted[index]))
        status, events = server.events(run)
        self.assertEqual(status, 200)
        states = [e["data"]["payload"]["state"] for e in events if e["event"] == "steer_state"]
        self.assertEqual(states, ["accepted", "accepted", "placed", "placed"])
        self.assertEqual(sum(e["event"] == "run_completed" for e in events), 1)
        self.assertEqual(sum(e["event"] == "initial" for e in events), 2)
        self.assertEqual(len(upstream.requests), 2)
        self.assert_clean(server)

    def test_pending_tools_block_placement_until_all_results_are_durable(self):
        upstream, server, original, run, _ = self.begin(tools=True)
        upstream.release.set()
        frames = server.read_until(run, "client_tool_request",
            lambda p: p["callID"] == "steer-call-1")
        calls = [f["data"]["payload"] for f in frames if f["event"] == "client_tool_request"]
        self.assertEqual(len(calls), 2)
        body = steer_command(original, run, "保留两个工具结果")
        self.assertEqual(self.post(server, run, body)[0], 200)
        first = server.tool_result(original, run, calls[0], "result-one")
        self.assertEqual(server.http("POST", f"runs/{segment(run)}/tool-results", first)[0], 200)
        self.assertEqual(self.state(server, run, body)[1]["state"], "accepted")
        self.assertEqual(len(upstream.requests), 1)
        last = server.tool_result(original, run, calls[1], "result-two")
        self.assertEqual(server.http("POST", f"runs/{segment(run)}/tool-results", last)[0], 200)
        server.await_phase(run, {"completed"})
        placed = self.state(server, run, body)[1]
        self.assertEqual(placed["placement"]["point"], "tools_resolved")
        self.assertEqual(placed["placement"]["generation"], 1)
        messages = upstream.requests[1]["messages"]
        self.assertEqual([m["content"] for m in messages[-3:]], ["result-one", "result-two", "保留两个工具结果"])
        self.assertEqual([m["role"] for m in messages[-3:]], ["tool", "tool", "user"])
        self.assertEqual(server.http("POST", f"runs/{segment(run)}/tool-results", last)[0], 200)
        self.assertEqual(len(upstream.requests), 2)
        self.assert_clean(server)

    def test_cancellation_returns_unplaced_without_running_follow_up(self):
        upstream, server, original, run, _ = self.begin()
        body = steer_command(original, run, "取消后保留的草稿")
        self.assertEqual(self.post(server, run, body)[1]["state"], "accepted")
        cancel = {"schemaVersion": 1, "requestKey": str(uuid.uuid4()), "binding": original["binding"], "runID": run}
        self.assertEqual(server.http("POST", f"runs/{segment(run)}/cancel", cancel)[0], 200)
        returned = self.state(server, run, body)[1]
        self.assertEqual(returned["state"], "returned")
        self.assertEqual(returned["returnReason"], "TERMINAL_CANCELLED")
        self.assertNotIn("placement", returned)
        _, events = server.events(run)
        self.assertEqual([e["event"] for e in events][-2:], ["steer_state", "run_cancelled"])
        upstream.release.set()
        self.assertEqual(len(upstream.requests), 1)
        self.assert_clean(server)

    def test_interaction_returns_pending_before_waiting_event(self):
        server = ProcessServer()
        self.addCleanup(server.stop)
        original = command("test:steer-question", tools=False)
        run, _ = server.create(original)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with sqlite3.connect(server.db) as db:
                frames = db.execute("SELECT frame FROM events WHERE run=? ORDER BY seq", (run,)).fetchall()
            if any("before-wait" in frame[0] for frame in frames):
                break
            time.sleep(0.01)
        body = steer_command(original, run, "等待确认时退回")
        self.assertEqual(self.post(server, run, body)[1]["state"], "accepted")
        server.await_phase(run, {"waiting_question"})
        state = self.state(server, run, body)[1]
        self.assertEqual((state["state"], state["returnReason"]), ("returned", "RUN_WAITING"))
        _, events = server.events(run)
        self.assertEqual([event["event"] for event in events][-2:], ["steer_state", "waiting_question"])
        self.assert_clean(server)

    def test_provider_failure_returns_unplaced_and_preserves_saved_body(self):
        upstream, server, original, run, _ = self.begin(fail=True)
        body = steer_command(original, run, "失败后保留的输入")
        self.assertEqual(self.post(server, run, body)[0], 200)
        upstream.release.set()
        server.await_phase(run, {"failed"})
        returned = self.state(server, run, body)[1]
        self.assertEqual((returned["state"], returned["returnReason"]), ("returned", "TERMINAL_FAILED"))
        with sqlite3.connect(server.db) as db:
            saved = json.loads(db.execute("SELECT body FROM steers WHERE submission=?",
                                         (body["submissionID"],)).fetchone()[0])
            self.assertEqual(saved, body)
        self.assertEqual(len(upstream.requests), 1)

    def test_actual_sigkill_returns_accepted_but_does_not_resubmit(self):
        upstream, server, original, run, _ = self.begin()
        body = steer_command(original, run, "SIGKILL 保留 🙂")
        accepted = self.post(server, run, body)
        self.assertEqual(accepted[0], 200)
        server.restart(crash=True)
        self.assertEqual(server.await_phase(run, {"waiting_suspended"})["phase"], "waiting_suspended")
        returned = self.state(server, run, body)[1]
        self.assertEqual((returned["state"], returned["returnReason"]), ("returned", "PROCESS_RESTART"))
        self.assertEqual(server.http("GET", "requests/" + segment(body["requestKey"])), accepted)
        self.assertEqual(self.post(server, run, body), accepted)
        self.assertEqual(len(upstream.requests), 1)
        self.assert_clean(server)

    def test_placed_state_and_context_survive_restart_without_model_replay(self):
        upstream, server, original, run, _ = self.begin()
        body = steer_command(original, run, "持久消费位置")
        self.assertEqual(self.post(server, run, body)[0], 200)
        upstream.release.set()
        server.await_phase(run, {"completed"})
        placed = self.state(server, run, body)
        server.restart(crash=True)
        self.assertEqual(self.state(server, run, body), placed)
        self.assertEqual(len(upstream.requests), 2)
        self.assert_clean(server)

    def test_images_and_unicode_are_captured_and_forwarded_without_external_fetch(self):
        upstream, server, original, run, _ = self.begin(image=True)
        image = "data:image/png;base64," + base64.b64encode(b"\x89PNG\r\n\x1a\nsynthetic").decode()
        parts = [{"type": "text", "text": "图像引用 e\u0301\n🙂"},
                 {"type": "image_url", "image_url": {"url": image, "detail": "low"}}]
        body = steer_command(original, run, parts)
        self.assertEqual(self.post(server, run, body)[0], 200)
        upstream.release.set()
        server.await_phase(run, {"completed"})
        self.assertEqual(upstream.requests[1]["messages"][-1]["content"], parts)

    def test_conflict_scope_schema_and_permission_expansion_are_rejected(self):
        upstream, server, original, run, _ = self.begin()
        body = steer_command(original, run, "immutable")
        self.assertEqual(self.post(server, run, body)[0], 200)
        changed = copy.deepcopy(body)
        changed["message"]["content"] = "changed"
        self.assertEqual(self.post(server, run, changed)[0], 409)
        invalids = []
        for mutate, status in [
            (lambda b: b.update(steerSchemaVersion=2), 400),
            (lambda b: b.update(steerSchemaVersion=True), 400),
            (lambda b: b.update(clientInstanceID="different-client"), 409),
            (lambda b: b.update(binding={"sessionID": "different-session"}), 409),
            (lambda b: b.update(runID="different-run"), 409),
            (lambda b: b.update(config=original["config"]), 400),
            (lambda b: b["message"].update(role="system"), 400),
            (lambda b: b["message"].update(toolCalls=[]), 400),
            (lambda b: b["message"].update(content="a" * 262_145), 400),
            (lambda b: b["message"].update(content=[{"type": "image_url",
                 "image_url": {"url": "https://invalid.test/image.png"}}]), 400),
        ]:
            candidate = steer_command(original, run, "new")
            mutate(candidate)
            invalids.append((candidate, status))
        for candidate, status in invalids:
            self.assertEqual(self.post(server, run, candidate)[0], status)
            self.assertEqual(self.state(server, run, candidate)[0], 404)
        self.assertEqual(len(upstream.requests), 1)
        self.assertEqual(self.state(server, run, body)[1]["state"], "accepted")

    def test_read_only_run_has_no_capability_and_rejects_steer(self):
        upstream, server, original, run, descriptor = self.begin(readonly=True)
        self.assertNotIn("steerCapability", descriptor)
        self.assertNotIn("steerCapability", server.http("GET", "runs/" + segment(run))[1])
        self.assertEqual(self.post(server, run, steer_command(original, run, "new"))[0], 409)
        self.assertEqual(len(upstream.requests), 1)

    def test_pending_queue_limit_and_duplicate_receipt_do_not_create_extra_rows(self):
        upstream, server, original, run, _ = self.begin()
        bodies = [steer_command(original, run, str(i)) for i in range(33)]
        for body in bodies[:32]:
            self.assertEqual(self.post(server, run, body)[0], 200)
        self.assertEqual(self.post(server, run, bodies[32])[0], 429)
        self.assertEqual(self.post(server, run, bodies[0])[0], 200)
        with sqlite3.connect(server.db) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM steers").fetchone()[0], 32)
        self.assertEqual(len(upstream.requests), 1)

    def test_terminal_rejection_has_no_receipt_or_lost_input(self):
        upstream, server, original, run, _ = self.begin()
        upstream.release.set()
        server.await_phase(run, {"completed"})
        body = steer_command(original, run, "new")
        self.assertEqual(self.post(server, run, body)[0], 409)
        self.assertEqual(self.state(server, run, body)[0], 404)
        self.assertEqual(server.http("GET", "requests/" + segment(body["requestKey"]))[0], 404)
        self.assertEqual(len(upstream.requests), 1)

    def test_v1_database_upgrade_keeps_existing_runs_receipts_and_events(self):
        upstream, server, original, run, _ = self.begin()
        upstream.release.set()
        server.await_phase(run, {"completed"})
        _, before = server.events(run)
        server.stop()
        with sqlite3.connect(server.db) as db:
            db.execute("DROP TABLE steers")
            db.execute("PRAGMA user_version=1")
        server.start()
        self.assertEqual(server.events(run)[1], before)
        self.assertEqual(server.http("GET", "requests/" + segment(original["requestKey"]))[0], 200)
        with sqlite3.connect(server.db) as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 4)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM steers").fetchone()[0], 0)
        self.assertEqual(len(upstream.requests), 1)

    def test_partial_placement_transaction_rolls_back_then_returns_every_input(self):
        upstream, server, original, run, _ = self.begin()
        bodies = [steer_command(original, run, value) for value in ["one", "two"]]
        for body in bodies:
            self.assertEqual(self.post(server, run, body)[0], 200)
        # A real SQLite failure after the first placement. This exercises the
        # running service's transaction, rather than a mock placement callback.
        with sqlite3.connect(server.db) as db:
            db.execute("""CREATE TRIGGER fail_second_placement BEFORE UPDATE ON steers
                       WHEN NEW.state='placed' AND OLD.sequence=2
                       BEGIN SELECT RAISE(ABORT, 'synthetic transaction failure'); END""")
        upstream.release.set()
        server.await_phase(run, {"failed"})
        for body in bodies:
            receipt = self.state(server, run, body)[1]
            self.assertEqual((receipt["state"], receipt["returnReason"]), ("returned", "TERMINAL_FAILED"))
        _, events = server.events(run)
        states = [e["data"]["payload"]["state"] for e in events if e["event"] == "steer_state"]
        self.assertEqual(states, ["accepted", "accepted", "returned", "returned"])
        with sqlite3.connect(server.db) as db:
            messages = json.loads(db.execute("SELECT messages FROM runs WHERE id=?", (run,)).fetchone()[0])
            self.assertEqual([m["content"] for m in messages if m["role"] == "user"], ["synthetic initial"])
        self.assertEqual(len(upstream.requests), 1)
        self.assert_clean(server)

    def test_restart_continuation_requires_exact_placed_messages_and_original_order(self):
        upstream, server, original, run, _ = self.begin(hold_follow_up=True)
        bodies = [steer_command(original, run, value) for value in ["e\u0301", "two"]]
        for body in bodies:
            self.assertEqual(self.post(server, run, body)[0], 200)
        upstream.release.set()
        self.assertTrue(upstream.follow_ready.wait(3))
        before = [self.state(server, run, body)[1] for body in bodies]
        self.assertTrue(all(s["state"] == "placed" for s in before))
        server.restart(crash=True)
        self.assertEqual([self.state(server, run, b)[1] for b in bodies], before)
        continued = copy.deepcopy(original)
        continued["runID"] = run
        continued["requestKey"] = str(uuid.uuid4())
        path = f"runs/{segment(run)}/continue"
        self.assertEqual(server.http("POST", path, continued)[0], 409)
        for invalid in [
            [bodies[1]["message"], bodies[0]["message"]],
            [dict(bodies[0]["message"], content="é"), bodies[1]["message"]],
            [bodies[0]["message"], bodies[0]["message"], bodies[1]["message"]],
        ]:
            candidate = copy.deepcopy(continued)
            candidate["requestKey"] = str(uuid.uuid4())
            candidate["history"] += invalid
            self.assertEqual(server.http("POST", path, candidate)[0], 409)
        self.assertEqual(len(upstream.requests), 2)
        continued["history"] += [b["message"] for b in bodies]
        self.assertEqual(server.http("POST", path, continued)[0], 200)
        server.await_phase(run, {"completed"})
        self.assertEqual(len(upstream.requests), 3)
        self.assertEqual([m["content"] for m in upstream.requests[2]["messages"][-2:]], ["e\u0301", "two"])
        self.assert_clean(server)

    def test_existing_history_identity_cannot_be_reused_for_a_different_message(self):
        upstream, server, original, run, _ = self.begin()
        body = steer_command(original, run, "replace", identity=original["history"][0]["id"])
        self.assertEqual(self.post(server, run, body)[0], 409)
        self.assertEqual(self.state(server, run, body)[0], 404)
        self.assertEqual(len(upstream.requests), 1)

    def test_accepted_on_follow_up_waits_for_its_own_model_boundary(self):
        upstream, server, original, run, _ = self.begin(hold_follow_up=True)
        first = steer_command(original, run, "first")
        self.assertEqual(self.post(server, run, first)[0], 200)
        upstream.release.set()
        self.assertTrue(upstream.follow_ready.wait(3))
        second = steer_command(original, run, "second")
        accepted = self.post(server, run, second)[1]
        self.assertEqual((accepted["state"], accepted["sequence"]), ("accepted", 2))
        self.assertEqual(self.state(server, run, second)[1]["state"], "accepted")
        self.assertEqual(len(upstream.requests), 2)
        self.assertEqual(upstream.requests[1]["messages"][-1]["content"], "first")
        upstream.follow_release.set()
        server.await_phase(run, {"completed"})
        self.assertEqual(self.state(server, run, second)[1]["placement"]["generation"], 2)
        self.assertEqual(len(upstream.requests), 3)
        self.assertEqual([m["content"] for m in upstream.requests[2]["messages"][-3:]],
                         ["first", "follow-up", "second"])


if __name__ == "__main__":
    print(json.dumps({"evidence": str(EVIDENCE), "remoteProviderRequests": 0,
                      "provider": "controlled local OpenAI SSE fixture"}), flush=True)
    unittest.main(verbosity=2)
