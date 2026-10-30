#!/usr/bin/env python3
"""Real loopback HTTP/SSE tests. Providers in this suite are synthetic."""
import argparse
import base64
import concurrent.futures
import copy
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
import time
import unittest
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = Path(__file__).resolve().parent
EVIDENCE = Path(tempfile.mkdtemp(prefix="clipslots-gateway-live-python-", dir="/tmp"))


def command(content="test:plain", tools=False):
    return {"schemaVersion": 1, "requestKey": str(uuid.uuid4()),
            "binding": {"sessionID": str(uuid.uuid4()), "projectID": "p", "canvasID": "c"},
            "clientInstanceID": "test-client",
            "history": [{"id": str(uuid.uuid4()), "role": "user", "content": content,
                         "toolCallID": None, "toolCalls": []}],
            "config": {"model": "test", "systemPrompt": "", "thinkingMode": "serverDefault",
                       "taskPolicy": "chat", "maxToolRounds": 8},
            "tools": ([{"type": "function", "function": {"name": "live_test_tool",
                       "description": "test only", "parameters": {"type": "object", "properties": {}}}}]
                      if tools else [])}


def segment(value):
    return urllib.parse.quote(value, safe="")


class ProcessServer:
    def __init__(self, synthetic=True, token="", provider=None, port=0):
        self.db = EVIDENCE / (uuid.uuid4().hex + ".sqlite")
        self.synthetic, self.token, self.provider = synthetic, token, provider
        self.port = port
        self.starts = 0
        self.start()

    def start(self):
        self.starts += 1
        self.log_path = EVIDENCE / (self.db.stem + f"-{self.starts}.log")
        self.log = open(self.log_path, "w")
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("GATEWAY_"):
                del env[key]
        env["GATEWAY_AUTH_TOKEN"] = self.token
        if self.provider:
            env.update({"GATEWAY_PROVIDER_BASE_URL": self.provider,
                        "GATEWAY_PROVIDER_API_KEY": "synthetic-upstream-key",
                        "GATEWAY_PROVIDER_MODEL": "synthetic-upstream-model"})
        argv = [sys.executable, "-B", str(HERE / "server.py"), "--port", str(getattr(self, "port", 0)),
                "--db", str(self.db)]
        if self.synthetic:
            argv.append("--test-only-provider")
        self.process = subprocess.Popen(argv, stdout=self.log, stderr=self.log, env=env)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            lines = self.log_path.read_text().splitlines()
            if lines and lines[0].startswith("{"):
                self.info = json.loads(lines[0])
                self.root = self.info["listening"]
                self.port = urllib.parse.urlsplit(self.root).port
                return
            if self.process.poll() is not None:
                break
            time.sleep(0.02)
        self.stop()
        raise RuntimeError(f"server did not start: {self.log_path}")

    def stop(self, crash=False):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGKILL if crash else signal.SIGINT)
            self.process.wait(timeout=5)
        self.log.close()

    def restart(self, crash=False):
        self.stop(crash)
        self.start()

    def http(self, method, path, body=None, headers=None, auth=True, raw=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        fields = {"Accept": "application/json"}
        if self.token and auth:
            fields["Authorization"] = "Bearer " + self.token
        if body is not None:
            fields.update({"Content-Type": "application/json", "Idempotency-Key": body.get("requestKey", "")})
        fields.update(headers or {})
        connection.request(method, "/v1/" + path, raw if raw is not None else (json.dumps(body) if body is not None else None), fields)
        response = connection.getresponse()
        data = response.read()
        status = response.status
        content_type = response.getheader("Content-Type")
        connection.close()
        if content_type == "text/event-stream":
            return status, data.decode()
        return status, json.loads(data)

    def create(self, body):
        status, receipt = self.http("POST", "runs", body)
        if status != 200:
            raise AssertionError((status, receipt))
        return receipt["runID"], receipt

    def events(self, run, cursor=None, headers=None):
        path = f"runs/{segment(run)}/events"
        if cursor is not None:
            path += "?" + urllib.parse.urlencode({"cursor": cursor})
        status, data = self.http("GET", path, headers=headers)
        if status != 200:
            return status, data
        events = []
        for frame in data.split("\n\n"):
            if not frame or frame.startswith(":"):
                continue
            fields = dict(line.split(": ", 1) for line in frame.splitlines())
            fields["data"] = json.loads(fields["data"])
            events.append(fields)
        return status, events

    def await_phase(self, run, phases):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            status, result = self.http("GET", "runs/" + segment(run))
            if status == 200 and result["phase"] in phases:
                return result
            time.sleep(0.01)
        raise AssertionError("phase timeout")

    def tool_result(self, body, run, request, content="synthetic result"):
        return {"schemaVersion": 1, "requestKey": "tool-" + request["executionID"],
                "binding": body["binding"], "runID": run,
                "executionID": request["executionID"], "callID": request["callID"],
                "content": content, "isFailure": False}

    def read_until(self, run, event_type, predicate=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Authorization": "Bearer " + self.token} if self.token else {}
        conn.request("GET", "/v1/runs/" + segment(run) + "/events", headers=headers)
        response = conn.getresponse()
        frames, frame = [], {}
        while True:
            line = response.readline().decode().rstrip("\r\n")
            if not line and frame:
                frame["data"] = json.loads(frame["data"])
                frames.append(frame)
                if frame["event"] == event_type and (predicate is None or predicate(frame["data"]["payload"])):
                    conn.close()
                    return frames
                frame = {}
            elif ": " in line and not line.startswith(":"):
                key, value = line.split(": ", 1)
                frame[key] = value


class Upstream:
    """Test-only OpenAI wire fixture, a real listener, NOT a remote model."""
    def __init__(self, mode="normal"):
        self.mode, self.requests, self.leaked = mode, [], 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.requests.append(value)
                if self.path == "/redirect-target":
                    owner.leaked += 1
                if owner.mode == "redirect":
                    self.send_response(307)
                    self.send_header("Location", "/redirect-target")
                    self.end_headers()
                    return
                tool_round = sum(m["role"] == "tool" for m in value["messages"])
                if owner.mode == "reasoning-two-tools" and tool_round < 2:
                    deltas = [
                        {"reasoning_content": f"工具轮{tool_round}：\n"},
                        {"reasoning_content": "保留空白 🙂 "},
                        {"tool_calls": [{"index": 0, "id": f"reason-call-{tool_round}",
                                         "function": {"name": "live_test_tool", "arguments": "{}"}}]}]
                    finish = "tool_calls"
                elif owner.mode == "tool" and value["messages"][-1]["role"] != "tool":
                    deltas = [
                        {"tool_calls": [{"index": 0, "id": "upstream-call", "function": {"name": "live_test_tool", "arguments": '{"text":'}}]},
                        {"tool_calls": [{"index": 0, "function": {"arguments": '"synthetic"}'}}]}]
                    finish = "tool_calls"
                else:
                    deltas = [{"content": "adapter-"}, {"content": "synthetic"}, {"reasoning_content": "test"}]
                    finish = "stop"
                chunks = [{"choices": [{"index": 0, "delta": d}]} for d in deltas]
                if owner.mode != "eof":
                    chunks += [{"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]},
                               {"choices": [], "usage": {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5}}]
                data = "".join("data: " + json.dumps(c) + "\n\n" for c in chunks)
                if owner.mode != "eof":
                    data += "data: [DONE]\n\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data.encode())

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1"

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class FaultServer:
    """Deliberately invalid TEST-ONLY HTTP service for URLSession rejection tests."""
    def __init__(self):
        self.commands, self.redirect_hits = {}, 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, status, value, mime="application/json"):
                data = value.encode() if isinstance(value, str) else json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                scenario = self.path.split("/")[2]
                owner.commands[scenario] = body
                if scenario == "redirect":
                    self.send_response(307)
                    self.send_header("Location", "/v1/redirect-sink/runs")
                    self.end_headers()
                    return
                if scenario == "redirect-sink":
                    owner.redirect_hits += 1
                receipt = {"schemaVersion": 1, "binding": body["binding"], "runID": "fault-run",
                           "phase": "streaming", "requestKey": body["requestKey"]}
                if scenario == "bad-receipt":
                    receipt["schemaVersion"] = 2
                if scenario == "wrong-binding":
                    receipt["binding"] = {"sessionID": "wrong"}
                self.reply(200, receipt)

            def do_GET(self):
                scenario = self.path.split("/")[2]
                body = owner.commands[scenario]
                descriptor = {"schemaVersion": 1, "binding": body["binding"],
                              "runID": "fault-run", "phase": "completed"}
                if "/events" not in self.path:
                    self.reply(200, descriptor)
                    return
                message_id = "F2CADB49-AD93-4BAC-914F-7A4CCFA16A71"

                def frame(event, event_id, payload):
                    envelope = dict(descriptor, eventID=event_id, payload=payload)
                    envelope.pop("phase")
                    if scenario == "event-id-mismatch":
                        envelope["eventID"] = "different"
                    return f"event: {event}\nid: {event_id}\ndata: {json.dumps(envelope)}\n\n"

                data = frame("initial", "start", {"messageID": message_id})
                if scenario == "bad-metadata":
                    data += frame("artifact_updated", "metadata", {"artifactID": "a", "revision": -1})
                elif scenario == "bad-usage":
                    data += frame("usage", "usage", {"promptTokens": 0.5, "completionTokens": 1, "totalTokens": 1})
                elif scenario == "task-subagents":
                    def child(phase, parent="one", **extra):
                        return dict(schema_version="subagent_event.v1", subagent_id="child",
                                    parent_tool_call_id=parent, phase=phase,
                                    agent_type="分析子任务", task_description="synthetic", **extra)
                    data += frame("content", "before|1", {"messageID": message_id, "delta": "中e"})
                    data += frame("task_snapshot", "plan|2", {"schema_version": "agent_task_snapshot.v1",
                        "plan_ready": True, "tasks": [{"task_id": "one", "subject": "分析", "status": "in_progress"}]})
                    data += frame("subagent_event", "child|3", child("started"))
                    text = frame("subagent_event", "child|4", child("content", text="正文🙂"))
                    data += text + text
                    data += frame("subagent_event", "same|4", child("content", text="重复"))
                    data += frame("subagent_event", "old|2", child("content", text="旧"))
                    tool = dict(schema_version="tool_event.v1", type="tool_event", tool_call_id="tool",
                                tool="Read", status="started", request={"path": "synthetic"}, response=None)
                    data += frame("subagent_event", "tool|5", child("tool_started", tool_event=tool))
                    tool = dict(tool, status="completed", request={}, response="已读取")
                    data += frame("subagent_event", "tool|6", child("tool_completed", tool_event=tool))
                    data += frame("subagent_event", "stop|7", child("stopped"))
                    data += frame("subagent_event", "progress|8", child("progress"))
                    data += frame("subagent_event", "successor|9", child("started", parent="two"))
                    data += frame("subagent_event", "retired|10", child("started"))
                    data += frame("subagent_event", "retired-content|11", child("content", text="旧实例"))
                    data += frame("content", "after|12", {"messageID": message_id, "delta": "\u0301后"})
                elif scenario == "context-usage":
                    def usage(revision, **updates):
                        value = {"conversation_id": body["binding"]["sessionID"], "run_id": "fault-run",
                                 "runtime_session_id": None, "revision": revision, "used_tokens": 200,
                                 "max_tokens": 100, "percentage": 200, "model": "test", "source": "sdk",
                                 "status": "ready", "observed_at": "2026-10-29T02:00:00.123Z"}
                        value.update(updates)
                        return value
                    data += frame("context_usage", "context-one", usage(1))
                    data += frame("content", "compact-before", {"messageID": message_id, "delta": "中e"})
                    data += frame("thinking", "compact-thinking", {"messageID": message_id, "delta": "思考🙂"})
                    data += frame("compact", "compact-start", {"phase": "started"})
                    data += frame("compact", "compact-start-duplicate", {"phase": "started"})
                    data += frame("context_usage", "context-stale", usage(2, status="stale"))
                    data += frame("compact", "compact-finish", {"phase": "finished"})
                    data += frame("content", "compact-after", {"messageID": message_id, "delta": "\u0301后"})
                    data += frame("context_usage", "context-old", usage(1))
                    data += frame("context_usage", "context-other", usage(99, conversation_id="other"))
                    data += frame("context_usage", "context-invalid", usage(99, max_tokens=0))
                    data += frame("context_usage", "context-three", {"context_usage": usage(3)})
                elif scenario == "unknown":
                    data += frame("execute_arbitrary_action", "unknown", {"secret": "TEST_SECRET_MUST_NOT_SURFACE"})
                else:
                    data += frame("content", "text", {"messageID": message_id, "delta": "fixture-wire"})
                if scenario != "eof":
                    done = frame("run_completed", "done", {"messageID": message_id})
                    data += done.rstrip("\n") if scenario == "incomplete" else done
                self.reply(200, data, "text/event-stream")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1"

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.server = ProcessServer()
        self.addCleanup(self.server.stop)

    def test_concurrent_create_exact_receipt(self):
        body = command()
        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
            replies = list(pool.map(lambda _: self.server.http("POST", "runs", body), range(10)))
        self.assertTrue(all(r == replies[0] for r in replies))
        self.assertEqual(replies[0][0], 200)
        with sqlite3.connect(self.server.db) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM runs").fetchone()[0], 1)
        run = replies[0][1]["runID"]
        self.assertIn("/", run)
        self.assertIn("+", run)
        self.server.await_phase(run, {"completed"})
        events = self.server.events(run)[1]
        self.assertEqual(sum(e["event"] == "initial" for e in events), 1)

    def test_create_key_body_and_route_conflict(self):
        body = command()
        run, receipt = self.server.create(body)
        other = copy.deepcopy(body)
        other["history"][0]["content"] = "changed"
        self.assertEqual(self.server.http("POST", "runs", other)[0], 409)
        self.assertEqual(self.server.http("POST", f"runs/{segment(run)}/cancel", body)[0], 409)
        self.assertEqual(self.server.http("GET", "requests/" + segment(body["requestKey"])), (200, receipt))

    def test_receipt_durable_restart(self):
        body = command()
        run, receipt = self.server.create(body)
        self.server.await_phase(run, {"completed"})
        events = self.server.events(run)[1]
        self.server.restart()
        self.assertEqual(self.server.http("POST", "runs", body), (200, receipt))
        self.assertEqual(self.server.events(run)[1], events)
        self.assertEqual(self.server.http("GET", "requests/absent")[0], 404)
        self.assertEqual(os.stat(self.server.db).st_mode & 0o777, 0o600)

    def test_crash_replay_suspend_explicit_continue(self):
        body = command("test:slow")
        run, receipt = self.server.create(body)
        before = self.server.read_until(run, "content")
        self.server.restart(crash=True)
        self.assertEqual(self.server.http("GET", "requests/" + segment(body["requestKey"])), (200, receipt))
        self.assertEqual(self.server.await_phase(run, {"waiting_suspended"})["phase"], "waiting_suspended")
        replay = self.server.events(run)[1]
        self.assertEqual(replay[:len(before)], before)
        self.assertEqual(replay[-1]["event"], "waiting_suspended")
        self.assertNotIn("run_completed", [e["event"] for e in replay])
        self.assertEqual(self.server.events(run, before[-1]["id"])[1], replay[len(before):])
        next_body = copy.deepcopy(body)
        next_body["requestKey"] = str(uuid.uuid4())
        next_body["history"][0]["content"] = "explicit recovery"
        self.assertEqual(self.server.http("POST", f"runs/{segment(run)}/continue", next_body)[0], 200)
        self.server.await_phase(run, {"completed"})

    def test_cursor_headers_opaque_foreign_missing(self):
        run, _ = self.server.create(command())
        self.server.await_phase(run, {"completed"})
        events = self.server.events(run)[1]
        for index, event in enumerate(events):
            self.assertEqual(event["id"], event["data"]["eventID"])
            self.assertEqual(self.server.events(run, event["id"], {"Last-Event-ID": event["id"]})[1], events[index+1:])
        self.assertEqual(self.server.events(run, "absent")[0], 409)
        self.assertEqual(self.server.events(run, events[0]["id"], {"Last-Event-ID": "different"})[0], 400)
        other, _ = self.server.create(command())
        self.assertEqual(self.server.events(other, events[0]["id"])[0], 409)

    def test_status_query_has_no_cursor(self):
        run, _ = self.server.create(command())
        result = self.server.await_phase(run, {"completed"})
        self.assertNotIn("cursor", result)
        self.assertNotIn("requestKey", result)
        self.assertEqual(self.server.events(run)[1], self.server.events(run)[1])

    def test_cancel_active_no_late_output(self):
        body = command("test:slow")
        run, _ = self.server.create(body)
        self.server.read_until(run, "content")
        cancel = {"schemaVersion": 1, "binding": body["binding"], "requestKey": str(uuid.uuid4())}
        path = f"runs/{segment(run)}/cancel"
        status, receipt = self.server.http("POST", path, cancel)
        self.assertEqual(status, 200)
        self.assertEqual(self.server.http("POST", path, cancel), (200, receipt))
        self.assertEqual(self.server.await_phase(run, {"cancelled"})["phase"], "cancelled")
        events = self.server.events(run)[1]
        self.assertEqual(events[-1]["event"], "run_cancelled")
        time.sleep(0.1)
        self.assertEqual(events, self.server.events(run)[1])

    def test_cancel_completed_not_falsely_cancelled(self):
        body = command()
        run, _ = self.server.create(body)
        self.server.await_phase(run, {"completed"})
        cancel = {"schemaVersion": 1, "binding": body["binding"], "requestKey": str(uuid.uuid4())}
        self.assertEqual(self.server.http("POST", f"runs/{segment(run)}/cancel", cancel)[1]["phase"], "completed")

    def test_continue_receipt_and_client_binding_conflicts(self):
        body = command("test:question")
        run, _ = self.server.create(body)
        self.server.await_phase(run, {"waiting_question"})
        continuation = copy.deepcopy(body)
        continuation["requestKey"] = str(uuid.uuid4())
        continuation["history"][0]["content"] = "continue"
        path = f"runs/{segment(run)}/continue"
        bad = copy.deepcopy(continuation)
        bad["binding"]["canvasID"] = "other"
        self.assertEqual(self.server.http("POST", path, bad)[0], 409)
        bad = copy.deepcopy(continuation)
        bad["clientInstanceID"] = "other"
        self.assertEqual(self.server.http("POST", path, bad)[0], 409)
        receipt = self.server.http("POST", path, continuation)
        self.assertEqual(receipt[0], 200)
        self.assertEqual(receipt[1]["runID"], run)
        self.server.await_phase(run, {"completed"})
        self.assertEqual(self.server.http("POST", path, continuation), receipt)
        self.server.restart()
        self.assertEqual(self.server.http("GET", "requests/" + segment(continuation["requestKey"])), receipt)

    def test_interaction_answer(self):
        body = command("test:confirmation")
        run, _ = self.server.create(body)
        event = self.server.events(run)[1][-1]
        answer = {"schemaVersion": 1, "requestKey": str(uuid.uuid4()),
                  "binding": body["binding"], "clientInstanceID": body["clientInstanceID"],
                  "interactionID": "wrong", "answer": {"approved": True}}
        path = f"runs/{segment(run)}/continue"
        self.assertEqual(self.server.http("POST", path, answer)[0], 409)
        answer["interactionID"] = event["data"]["payload"]["interactionID"]
        self.assertEqual(self.server.http("POST", path, answer)[0], 200)
        self.server.await_phase(run, {"completed"})

    def test_tool_result_exactly_once_durable(self):
        body = command("test:tool", tools=True)
        run, _ = self.server.create(body)
        request = self.server.read_until(run, "client_tool_request")[-1]["data"]["payload"]
        result = self.server.tool_result(body, run, request)
        path = f"runs/{segment(run)}/tool-results"
        receipt = self.server.http("POST", path, result)
        self.assertEqual(receipt[0], 200)
        self.server.await_phase(run, {"completed"})
        self.server.restart()
        self.assertEqual(self.server.http("POST", path, result), receipt)
        changed = dict(result, content="different")
        self.assertEqual(self.server.http("POST", path, changed)[0], 409)
        with sqlite3.connect(self.server.db) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM tools WHERE result IS NOT NULL").fetchone()[0], 1)
        events = self.server.events(run)[1]
        self.assertEqual(sum(e["event"] == "initial" for e in events), 2)
        self.assertEqual(sum(e["event"] == "note" for e in events), 2)

    def test_pending_tools_crash_no_automatic_model_retry(self):
        body = command("test:tool-double", tools=True)
        run, _ = self.server.create(body)
        self.server.read_until(run, "client_tool_request")
        with sqlite3.connect(self.server.db) as db:
            requests = [json.loads(r[0]) for r in db.execute("SELECT request FROM tools ORDER BY execution")]
        self.assertEqual(len(requests), 2)
        self.server.restart(crash=True)
        continuation = copy.deepcopy(body)
        continuation["requestKey"] = str(uuid.uuid4())
        continuation["history"][0]["content"] = "resolved"
        self.assertEqual(self.server.http("POST", f"runs/{segment(run)}/continue", continuation)[0], 409)
        for request in requests:
            result = self.server.tool_result(body, run, request)
            self.assertEqual(self.server.http("POST", f"runs/{segment(run)}/tool-results", result)[0], 200)
        self.assertEqual(self.server.await_phase(run, {"waiting_suspended"})["phase"], "waiting_suspended")
        self.assertEqual(self.server.http("POST", f"runs/{segment(run)}/continue", continuation)[0], 200)
        self.server.await_phase(run, {"completed"})

    def test_tool_result_reject_wrong_key_call_and_run(self):
        body = command("test:tool", tools=True)
        run, _ = self.server.create(body)
        request = self.server.read_until(run, "client_tool_request")[-1]["data"]["payload"]
        result = self.server.tool_result(body, run, request)
        path = f"runs/{segment(run)}/tool-results"
        self.assertEqual(self.server.http("POST", path, dict(result, requestKey="wrong"))[0], 400)
        self.assertEqual(self.server.http("POST", path, dict(result, callID="wrong"))[0], 409)
        self.assertEqual(self.server.http("POST", path, dict(result, runID="wrong"))[0], 409)
        self.assertEqual(self.server.http("POST", path, dict(result, isFailure=1))[0], 400)
        self.server.http("POST", f"runs/{segment(run)}/cancel",
                         {"schemaVersion": 1, "binding": body["binding"], "requestKey": str(uuid.uuid4())})

    def test_metadata_schema_terminal_order(self):
        body = command("test:metadata")
        run, _ = self.server.create(body)
        events = self.server.events(run)[1]
        types = [e["event"] for e in events]
        self.assertEqual(types[0], "initial")
        self.assertEqual(types[-2:], ["assistant_completed", "run_completed"])
        metadata = next(e["data"]["payload"] for e in events if e["event"] == "artifact_updated")
        self.assertEqual(metadata["revision"], 1)
        self.assertIs(type(metadata["revision"]), int)
        for event in events:
            self.assertEqual(event["data"]["schemaVersion"], 1)
            self.assertEqual(event["data"]["runID"], run)
            self.assertEqual(event["data"]["binding"], body["binding"])

    def test_schema_history_and_read_only_rejections(self):
        mutations = [
            lambda b: b.update(schemaVersion=2),
            lambda b: b.update(schemaVersion=True),
            lambda b: b["config"].update(maxToolRounds=21),
            lambda b: b["history"][0].update(toolCalls=[{"id": "x", "name": "n", "argumentsJSON": "[]"}]),
            lambda b: b["history"][0].update(toolCalls=[{"id": "x", "name": "n", "argumentsJSON": "{}"}] * 21),
            lambda b: b["config"].update(taskPolicy="textPolish"),
            lambda b: b["tools"][0]["function"].update(parameters=[])]
        for change in mutations:
            body = command(tools=True)
            change(body)
            self.assertEqual(self.server.http("POST", "runs", body)[0], 400)

    def test_invalid_json_duplicate_nan_and_auth_framing(self):
        for data in ['{"requestKey":"a","requestKey":"b"}', '{"requestKey":NaN}', "[]", "{"]:
            status, _ = self.server.http("POST", "runs", headers={"Content-Type": "application/json",
                "Idempotency-Key": "x"}, raw=data)
            self.assertEqual(status, 400)
        body = command()
        self.assertEqual(self.server.http("POST", "runs", body, {"Idempotency-Key": "wrong"})[0], 400)
        self.assertEqual(self.server.http("POST", "runs", body, {"Content-Type": "text/plain"})[0], 415)

    def test_auth_all_routes(self):
        server = ProcessServer(token="test-only-token")
        self.addCleanup(server.stop)
        body = command()
        self.assertEqual(server.http("POST", "runs", body, auth=False)[0], 401)
        run, _ = server.create(body)
        for path in [f"runs/{segment(run)}", f"runs/{segment(run)}/events",
                     "requests/" + segment(body["requestKey"])]:
            self.assertEqual(server.http("GET", path, auth=False)[0], 401)
        self.assertTrue(server.info["authRequired"])

    def test_production_without_explicit_provider_fails(self):
        server = ProcessServer(synthetic=False)
        self.addCleanup(server.stop)
        body = command()
        self.assertEqual(server.info["provider"], "not-configured")
        self.assertEqual(server.http("POST", "runs", body)[0], 503)
        self.assertEqual(server.http("GET", "requests/" + segment(body["requestKey"]))[0], 404)

    def test_default_8787_real_listener_no_fake_model(self):
        server = ProcessServer(synthetic=False, port=8787)
        self.addCleanup(server.stop)
        self.assertEqual(server.root, "http://127.0.0.1:8787/v1")
        self.assertEqual(server.http("POST", "runs", command())[0], 503)
        self.assertEqual(server.http("GET", "requests/absent")[0], 404)

    def test_provider_adapter_real_http_synthetic_upstream(self):
        upstream = Upstream()
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.url)
        self.addCleanup(server.stop)
        run, _ = server.create(command())
        events = server.events(run)[1]
        output = "".join(e["data"]["payload"]["delta"] for e in events if e["event"] == "content")
        self.assertEqual(output, "adapter-synthetic")
        self.assertEqual(events[-1]["event"], "run_completed")
        self.assertEqual(upstream.requests[0]["model"], "synthetic-upstream-model")
        self.assertNotIn("thinking", upstream.requests[0])
        self.assertNotIn("tools", upstream.requests[0])

    def test_provider_adapter_fragmented_tools(self):
        upstream = Upstream("tool")
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.url)
        self.addCleanup(server.stop)
        body = command(tools=True)
        run, _ = server.create(body)
        request = server.read_until(run, "client_tool_request")[-1]["data"]["payload"]
        self.assertEqual(json.loads(request["argumentsJSON"]), {"text": "synthetic"})
        result = server.tool_result(body, run, request)
        self.assertEqual(server.http("POST", f"runs/{segment(run)}/tool-results", result)[0], 200)
        self.assertEqual(server.events(run)[1][-1]["event"], "run_completed")
        self.assertEqual(len(upstream.requests), 2)
        self.assertEqual(upstream.requests[1]["messages"][-1]["tool_call_id"], "upstream-call")

    def test_image_content_roundtrip_and_restart(self):
        upstream = Upstream()
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.url)
        self.addCleanup(server.stop)
        image = "data:image/png;base64," + (
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6pAoAAAAASUVORK5CYII=")
        content = [{"type": "text", "text": "仅检查结构：中文🙂"},
                   {"type": "image_url", "image_url": {"url": image}}]
        body = command(content)
        body["messageSchemaVersion"] = 1
        body["config"]["supportsImageInput"] = True
        run, receipt = server.create(body)
        events = server.events(run)[1]
        self.assertEqual(events[-1]["event"], "run_completed")
        self.assertEqual(upstream.requests[0]["messages"][-1]["content"], content)
        with sqlite3.connect(server.db) as db:
            saved = json.loads(db.execute("SELECT messages FROM runs WHERE id=?", (run,)).fetchone()[0])
        self.assertEqual(saved[1]["content"], content)
        server.restart(crash=True)
        self.assertEqual(server.http("POST", "runs", body), (200, receipt))
        self.assertEqual(server.events(run)[1], events)
        self.assertEqual(len(upstream.requests), 1)

    def test_structured_content_rejects_invalid_or_unclaimed_images_before_provider(self):
        upstream = Upstream()
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.url)
        self.addCleanup(server.stop)
        png = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"x" * 32).decode()
        valid = {"type": "image_url", "image_url": {"url": "data:image/png;base64," + png}}
        cases = [
            ([], "INVALID_MESSAGE_CONTENT"),
            ([{"type": "text", "text": "x", "hidden": "x"}], "INVALID_MESSAGE_CONTENT"),
            ([{"type": "tool", "text": "x"}], "INVALID_MESSAGE_CONTENT"),
            ([{"type": "text", "text": 1}], "INVALID_STRING"),
            ([{"type": "image_url", "image_url": {"url": "https://fixture.invalid/private"}}], "INVALID_IMAGE"),
            ([{"type": "image_url", "image_url": {"url": "data:image/png;base64,!!!"}}], "INVALID_IMAGE"),
            ([{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + png}}], "INVALID_IMAGE"),
            ([dict(valid, extra="x")], "INVALID_MESSAGE_CONTENT"),
            ([{"type": "image_url", "image_url": {"url": valid["image_url"]["url"], "detail": "invalid"}}], "INVALID_IMAGE"),
            ([valid] * 7, "IMAGE_LIMIT"),
        ]
        for content, expected in cases:
            with self.subTest(expected=expected, content_type=str(content)[:70]):
                body = command(content)
                body["messageSchemaVersion"] = 1
                body["config"]["supportsImageInput"] = True
                status, response = server.http("POST", "runs", body)
                self.assertEqual(status, 400)
                self.assertEqual(response["error"]["code"], expected)
        for mutation, expected in [
            (lambda b: b.pop("messageSchemaVersion"), "MESSAGE_SCHEMA_VERSION"),
            (lambda b: b.update(messageSchemaVersion=True), "MESSAGE_SCHEMA_VERSION"),
            (lambda b: b["config"].pop("supportsImageInput"), "IMAGE_INPUT_UNSUPPORTED"),
            (lambda b: b["config"].update(supportsImageInput=False), "IMAGE_INPUT_UNSUPPORTED"),
            (lambda b: b["config"].update(supportsImageInput="true"), "INVALID_IMAGE_CAPABILITY"),
            (lambda b: b["history"][0].update(role="assistant"), "INVALID_MESSAGE_CONTENT"),
        ]:
            body = command([valid])
            body["messageSchemaVersion"] = 1
            body["config"]["supportsImageInput"] = True
            mutation(body)
            status, response = server.http("POST", "runs", body)
            self.assertEqual((status, response["error"]["code"]), (400, expected))
        self.assertEqual(upstream.requests, [])
        with sqlite3.connect(server.db) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM runs").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM receipts").fetchone()[0], 0)

    def test_reasoning_history_and_two_tool_turns_survive_restart(self):
        upstream = Upstream("reasoning-two-tools")
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.url)
        self.addCleanup(server.stop)
        body = command(tools=True)
        historical = "已有思考\n\t🙂 "
        body["history"].insert(0, {"id": str(uuid.uuid4()), "role": "assistant",
                                  "content": "earlier", "reasoning": historical, "toolCalls": []})
        body["messageSchemaVersion"] = 1
        run, _ = server.create(body)
        request = server.read_until(run, "client_tool_request")[-1]["data"]["payload"]
        for round_index in range(2):
            with sqlite3.connect(server.db) as db:
                saved = json.loads(db.execute("SELECT messages FROM runs WHERE id=?", (run,)).fetchone()[0])
            self.assertEqual(saved[-1]["reasoning_content"], f"工具轮{round_index}：\n保留空白 🙂 ")
            result = server.tool_result(body, run, request)
            self.assertEqual(server.http("POST", f"runs/{segment(run)}/tool-results", result)[0], 200)
            if round_index == 0:
                previous_call = request["callID"]
                request = server.read_until(run, "client_tool_request",
                    lambda payload: payload["callID"] != previous_call)[-1]["data"]["payload"]
        final = server.events(run)[1]
        self.assertEqual(final[-1]["event"], "run_completed")
        self.assertEqual(len(upstream.requests), 3)
        for sent in upstream.requests:
            self.assertEqual(sent["messages"][1]["reasoning_content"], historical)
        self.assertEqual([m["reasoning_content"] for m in upstream.requests[-1]["messages"] if m["role"] == "assistant"],
                         [historical, "工具轮0：\n保留空白 🙂 ", "工具轮1：\n保留空白 🙂 "])
        server.restart(crash=True)
        self.assertEqual(server.events(run)[1], final)
        with sqlite3.connect(server.db) as db:
            restored = json.loads(db.execute("SELECT messages FROM runs WHERE id=?", (run,)).fetchone()[0])
        self.assertEqual([m["reasoning_content"] for m in restored if m["role"] == "assistant"],
                         [historical, "工具轮0：\n保留空白 🙂 ", "工具轮1：\n保留空白 🙂 ", "test"])
        self.assertNotIn(historical, server.log_path.read_text())

    def test_message_byte_limits_and_reasoning_roles(self):
        from server import GatewayError, validate_command, wire_history
        def content(size):
            payload = b"\x89PNG\r\n\x1a\n" + b"x" * (size - 8)
            return {"type": "image_url", "image_url": {
                "url": "data:image/png;base64," + base64.b64encode(payload).decode()}}
        body = command([content(1_048_576), content(1_048_576)])
        body["messageSchemaVersion"] = 1
        body["config"]["supportsImageInput"] = True
        self.assertEqual(validate_command(body), body["binding"])
        for images in [[content(1_048_577)], [content(1_048_576), content(1_048_576), content(8)]]:
            bad = copy.deepcopy(body)
            bad["history"][0]["content"] = images
            with self.assertRaises(GatewayError) as error:
                validate_command(bad)
            self.assertEqual(error.exception.code, "IMAGE_LIMIT")
        for role, reason, expected in [("user", "not allowed", "INVALID_REASONING_ROLE"),
                                      ("assistant", [], "INVALID_STRING"),
                                      ("assistant", "\ud800", "INVALID_STRING")]:
            bad = command()
            bad["history"][0].update(role=role, reasoning=reason)
            with self.assertRaises(GatewayError) as error:
                validate_command(bad)
            self.assertEqual(error.exception.code, expected)
        empty = command()
        empty["history"][0].update(role="assistant", reasoning="")
        validate_command(empty)
        self.assertEqual(wire_history(empty)[-1]["reasoning_content"], "")
        legacy = command()
        validate_command(legacy)
        self.assertNotIn("reasoning_content", wire_history(legacy)[-1])

    def test_reasoning_pending_tool_crash_then_explicit_continue(self):
        upstream = Upstream("reasoning-two-tools")
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.url)
        self.addCleanup(server.stop)
        body = command(tools=True)
        body["messageSchemaVersion"] = 1
        run, _ = server.create(body)
        request = server.read_until(run, "client_tool_request")[-1]["data"]["payload"]
        server.restart(crash=True)
        self.assertEqual(server.await_phase(run, {"waiting_suspended"})["phase"], "waiting_suspended")
        self.assertEqual(len(upstream.requests), 1)
        result = server.tool_result(body, run, request)
        self.assertEqual(server.http("POST", f"runs/{segment(run)}/tool-results", result)[0], 200)
        self.assertEqual(len(upstream.requests), 1)  # recovery never silently retries the provider
        continuation = copy.deepcopy(body)
        continuation["requestKey"] = str(uuid.uuid4())
        continuation["history"] += [
            {"id": str(uuid.uuid4()), "role": "assistant", "content": "",
             "reasoning": "工具轮0：\n保留空白 🙂 ",
             "toolCalls": [{"id": request["callID"], "name": request["name"], "argumentsJSON": request["argumentsJSON"]}]},
            {"id": str(uuid.uuid4()), "role": "tool", "content": result["content"], "toolCallID": request["callID"]}
        ]
        self.assertEqual(server.http("POST", f"runs/{segment(run)}/continue", continuation)[0], 200)
        next_request = server.read_until(run, "client_tool_request",
            lambda p: p["callID"] != request["callID"])[-1]["data"]["payload"]
        self.assertEqual(upstream.requests[1]["messages"][-2]["reasoning_content"], "工具轮0：\n保留空白 🙂 ")
        self.assertEqual(server.http("POST", f"runs/{segment(run)}/tool-results",
                                    server.tool_result(body, run, next_request))[0], 200)
        self.assertEqual(server.events(run)[1][-1]["event"], "run_completed")
        self.assertEqual(len(upstream.requests), 3)

    def test_provider_eof_is_not_success(self):
        upstream = Upstream("eof")
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.url)
        self.addCleanup(server.stop)
        run, _ = server.create(command())
        events = server.events(run)[1]
        self.assertEqual(events[-1]["event"], "run_failed")
        self.assertNotIn("run_completed", [e["event"] for e in events])

    def test_provider_redirect_denied(self):
        upstream = Upstream("redirect")
        self.addCleanup(upstream.stop)
        server = ProcessServer(synthetic=False, provider=upstream.url)
        self.addCleanup(server.stop)
        run, _ = server.create(command())
        self.assertEqual(server.events(run)[1][-1]["event"], "run_failed")
        self.assertEqual(len(upstream.requests), 1)
        self.assertEqual(upstream.leaked, 0)
        self.assertNotIn("synthetic-upstream-key", server.log_path.read_text())

    def test_single_process_database_lock(self):
        log_path = EVIDENCE / "second-owner.log"
        with open(log_path, "w") as log:
            result = subprocess.run([sys.executable, str(HERE / "server.py"), "--port", "0",
                "--db", str(self.server.db), "--test-only-provider"], stdout=log, stderr=log, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DATABASE_ALREADY_OWNED", log_path.read_text())

    def test_test_provider_explicitly_labelled(self):
        self.assertEqual(self.server.info["provider"], "TEST-ONLY-SYNTHETIC-NOT-A-REMOTE-MODEL")


def run_swift(binary):
    server = ProcessServer(token="test-only-token")
    fault = FaultServer()
    reports = []
    try:
        env = os.environ.copy()
        env["CLIPSLOTS_LIVE_TEST_URL"] = server.root
        env["CLIPSLOTS_LIVE_FAULT_URL"] = fault.url
        env["CLIPSLOTS_LIVE_TEST_TOKEN"] = server.token
        env["CLIPSLOTS_LIVE_TEST_JOURNAL"] = str(EVIDENCE / "swift-journals")

        def invoke(phase):
            log = EVIDENCE / ("swift-urlsession-" + phase + ".log")
            env["CLIPSLOTS_LIVE_TEST_PHASE"] = phase
            with open(log, "w") as output:
                result = subprocess.run([binary], env=env, stdout=output, stderr=output, timeout=90)
            data = log.read_text()
            print(data, end="")
            for line in data.splitlines():
                if line.startswith('{"swiftCases"'):
                    reports.append(json.loads(line))
            return result.returncode

        status = invoke("suite")
        if status == 0:
            status = invoke("tool-record")
        if status == 0:
            status = invoke("tool-replay")
        if status == 0:
            status = invoke("crash-record")
        if status == 0:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                with sqlite3.connect(server.db) as db:
                    count = db.execute("SELECT COUNT(*) FROM events WHERE frame LIKE '%after-disconnect%'").fetchone()[0]
                if count:
                    break
                time.sleep(0.02)
            if not count:
                raise AssertionError("server did not commit disconnected content")
            server.restart(crash=True)
            env["CLIPSLOTS_LIVE_TEST_URL"] = server.root
            status = invoke("crash-replay")
        if fault.redirect_hits:
            raise AssertionError("URLSession forwarded a denied redirect")
        return status, reports
    finally:
        server.stop()
        fault.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-bin")
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(LiveTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    swift_status, swift_reports = run_swift(args.swift_bin) if args.swift_bin else (None, [])
    summary = {"pythonTests": result.testsRun, "failures": len(result.failures),
               "errors": len(result.errors), "swiftExit": swift_status,
               "swiftCases": sum(r["swiftCases"] for r in swift_reports),
               "swiftAssertions": sum(r["assertions"] for r in swift_reports),
               "evidence": str(EVIDENCE), "remoteModel": "NOT_TESTED_NO_EXPLICIT_CREDENTIALS",
               "transport": "REAL_LOOPBACK_HTTP_SSE", "providers": "TEST_ONLY_SYNTHETIC"}
    (EVIDENCE / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))
    return 0 if result.wasSuccessful() and swift_status in (None, 0) else 1


if __name__ == "__main__":
    sys.exit(main())
