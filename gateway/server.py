#!/usr/bin/env python3
"""Self-owned Gateway v1. Local HTTP transport; no bundled model credentials."""
import argparse
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 8 * 1024 * 1024
TERMINAL = {"completed", "failed", "cancelled"}
WAITING = {"waiting_question", "waiting_confirmation", "waiting_suspended"}


class GatewayError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status, self.code = status, code


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False)


def decode(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("non-finite number")

    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=constant)
    except (ValueError, UnicodeError, RecursionError):
        raise GatewayError(400, "INVALID_JSON") from None


def text(value, limit=1024, empty=False):
    if not isinstance(value, str) or (not empty and not value) or len(value.encode()) > limit:
        raise GatewayError(400, "INVALID_STRING")
    return value


def opaque(value):
    text(value)
    if value in {".", ".."} or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise GatewayError(400, "INVALID_IDENTIFIER")
    return value


def integer(value, maximum=9_007_199_254_740_990):
    if type(value) is not int or not 0 <= value <= maximum:
        raise GatewayError(400, "INVALID_INTEGER")
    return value


def binding(value):
    if not isinstance(value, dict) or set(value) - {"sessionID", "projectID", "canvasID"}:
        raise GatewayError(400, "INVALID_BINDING")
    normalized = {"sessionID": opaque(value.get("sessionID"))}
    for key in ("projectID", "canvasID"):
        if value.get(key) is not None:
            normalized[key] = opaque(value[key])
    return normalized


def validate_command(body, interaction=False):
    if not isinstance(body, dict) or type(body.get("schemaVersion")) is not int or body["schemaVersion"] != 1:
        raise GatewayError(400, "SCHEMA_VERSION")
    opaque(body.get("requestKey"))
    scope = binding(body.get("binding"))
    if interaction:
        opaque(body.get("clientInstanceID"))
        opaque(body.get("interactionID"))
        if "answer" not in body:
            raise GatewayError(400, "MISSING_ANSWER")
        return scope
    opaque(body.get("clientInstanceID"))
    config = body.get("config")
    if not isinstance(config, dict):
        raise GatewayError(400, "INVALID_CONFIG")
    text(config.get("model"), 256)
    text(config.get("systemPrompt"), MAX_BODY, empty=True)
    if config.get("thinkingMode") not in {"serverDefault", "enabled", "disabled"}:
        raise GatewayError(400, "INVALID_THINKING_MODE")
    if config.get("taskPolicy") not in {"chat", "textPolish"}:
        raise GatewayError(400, "INVALID_TASK_POLICY")
    integer(config.get("maxToolRounds"), 20)
    tools = body.get("tools")
    history = body.get("history")
    if not isinstance(tools, list) or len(tools) > 128 or not isinstance(history, list) or len(history) > 1000:
        raise GatewayError(400, "INVALID_HISTORY_OR_TOOLS")
    names = set()
    for tool in tools:
        function = tool.get("function") if isinstance(tool, dict) else None
        if not isinstance(tool, dict) or tool.get("type") != "function" or not isinstance(function, dict):
            raise GatewayError(400, "INVALID_TOOL_SCHEMA")
        name = text(function.get("name"), 256)
        if name in names or not isinstance(function.get("parameters"), dict) or function["parameters"].get("type") != "object":
            raise GatewayError(400, "INVALID_TOOL_SCHEMA")
        text(function.get("description", ""), MAX_BODY, empty=True)
        names.add(name)
    for message in history:
        if not isinstance(message, dict) or message.get("role") not in {"system", "user", "assistant", "tool"}:
            raise GatewayError(400, "INVALID_MESSAGE")
        try:
            uuid.UUID(text(message.get("id")))
        except ValueError:
            raise GatewayError(400, "INVALID_MESSAGE_ID") from None
        text(message.get("content"), MAX_BODY, empty=True)
        calls = message.get("toolCalls", [])
        if not isinstance(calls, list) or len(calls) > 20:
            raise GatewayError(400, "INVALID_TOOL_CALLS")
        for call in calls:
            validate_call(call)
        if message.get("toolCallID") is not None:
            opaque(message["toolCallID"])
        if message["role"] == "tool" and not message.get("toolCallID"):
            raise GatewayError(400, "MISSING_TOOL_CALL_ID")
        if config["taskPolicy"] == "textPolish" and (calls or message.get("toolCallID")):
            raise GatewayError(400, "READ_ONLY_HISTORY")
    if config["taskPolicy"] == "textPolish" and tools:
        raise GatewayError(400, "READ_ONLY_TOOLS")
    return scope


def validate_call(call):
    if not isinstance(call, dict):
        raise GatewayError(400, "INVALID_TOOL_CALL")
    opaque(call.get("id"))
    text(call.get("name"), 256)
    arguments = text(call.get("argumentsJSON"), 1_048_576)
    if not isinstance(decode(arguments), dict):
        raise GatewayError(400, "INVALID_TOOL_ARGUMENTS")


def wire_history(command):
    result = [{"role": "system", "content": command["config"]["systemPrompt"]}]
    for item in command["history"]:
        message = {"role": item["role"], "content": item["content"]}
        if item.get("toolCallID"):
            message["tool_call_id"] = item["toolCallID"]
        if item.get("toolCalls"):
            message["tool_calls"] = [
                {"id": c["id"], "type": "function",
                 "function": {"name": c["name"], "arguments": c["argumentsJSON"]}}
                for c in item["toolCalls"]
            ]
        result.append(message)
    return result


class Store:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock_file = open(str(path) + ".lock", "a")
        os.chmod(self.lock_file.name, 0o600)
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lock_file.close()
            raise GatewayError(409, "DATABASE_ALREADY_OWNED") from None
        self.changed = threading.Condition(threading.RLock())
        self.db = sqlite3.connect(path, check_same_thread=False, timeout=10)
        self.db.row_factory = sqlite3.Row
        os.chmod(path, 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        if self.db.execute("PRAGMA user_version").fetchone()[0] not in (0, 1):
            raise GatewayError(409, "UNSUPPORTED_DATABASE_VERSION")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY, binding TEXT NOT NULL, client TEXT NOT NULL,
                phase TEXT NOT NULL, command TEXT NOT NULL, messages TEXT NOT NULL,
                message_id TEXT, generation INTEGER NOT NULL DEFAULT 0,
                interaction TEXT);
            CREATE TABLE IF NOT EXISTS receipts (
                key TEXT PRIMARY KEY, route TEXT NOT NULL, digest TEXT NOT NULL,
                body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                run TEXT NOT NULL, frame TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS replay ON events(run, seq);
            CREATE TABLE IF NOT EXISTS tools (
                execution TEXT PRIMARY KEY, run TEXT NOT NULL, call TEXT NOT NULL,
                generation INTEGER NOT NULL, request TEXT NOT NULL, result TEXT,
                UNIQUE(run, call));
            PRAGMA user_version=1;
        """)
        with self.changed, self.db:
            for row in self.db.execute("SELECT * FROM runs WHERE phase IN ('starting','streaming','cancelling')").fetchall():
                self.db.execute("UPDATE runs SET phase='waiting_suspended', generation=generation+1 WHERE id=?", (row["id"],))
                self.append(row, "waiting_suspended", {"code": "PROCESS_RESTART_REQUIRES_CONTINUE"})

    def run(self, run):
        row = self.db.execute("SELECT * FROM runs WHERE id=?", (run,)).fetchone()
        if row is None:
            raise GatewayError(404, "RUN_NOT_FOUND")
        return row

    def descriptor(self, row, key=None):
        result = {"schemaVersion": 1, "binding": decode(row["binding"]),
                  "runID": row["id"], "phase": row["phase"]}
        if key is not None:
            result["requestKey"] = key
        return result

    def receipt(self, key, route=None, body=None):
        row = self.db.execute("SELECT * FROM receipts WHERE key=?", (key,)).fetchone()
        if row is None:
            return None
        if route is not None and (row["route"] != route or row["digest"] != hashlib.sha256(encode(body).encode()).hexdigest()):
            raise GatewayError(409, "IDEMPOTENCY_CONFLICT")
        return decode(row["body"])

    def save_receipt(self, key, route, body, receipt):
        self.db.execute("INSERT INTO receipts VALUES (?,?,?,?)",
                        (key, route, hashlib.sha256(encode(body).encode()).hexdigest(), encode(receipt)))

    def append(self, row, event, payload):
        if not isinstance(payload, dict):
            raise GatewayError(400, "INVALID_EVENT_PAYLOAD")
        if event == "artifact_updated":
            text(payload.get("artifactID"), 256)
            integer(payload.get("revision"))
        if event == "usage":
            for field in ("promptTokens", "completionTokens", "totalTokens"):
                integer(payload.get(field))
        event_id = "evt/" + uuid.uuid4().hex + "+opaque"
        envelope = {"schemaVersion": 1, "binding": decode(row["binding"]),
                    "runID": row["id"], "eventID": event_id, "payload": payload}
        data = encode(envelope)
        if len(data.encode()) + 7 > 1_048_576:
            raise GatewayError(502, "EVENT_TOO_LARGE")
        frame = f"event: {event}\nid: {event_id}\ndata: {data}\n\n"
        self.db.execute("INSERT INTO events(id,run,frame) VALUES (?,?,?)", (event_id, row["id"], frame))
        return event_id


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class OpenAIProvider:
    label = "explicit-openai-compatible"

    def __init__(self, url, key, model, timeout=30):
        parts = urllib.parse.urlsplit(url)
        if parts.username or parts.password or parts.query or parts.fragment or not parts.hostname:
            raise GatewayError(400, "INVALID_PROVIDER_URL")
        if parts.scheme != "https" and not (parts.scheme == "http" and parts.hostname == "127.0.0.1"):
            raise GatewayError(400, "PROVIDER_REQUIRES_TLS")
        if "\r" in key or "\n" in key:
            raise GatewayError(400, "INVALID_PROVIDER_KEY")
        self.url = url.rstrip("/") + "/chat/completions"
        self.key, self.model, self.timeout = key, model, timeout
        self.opener = urllib.request.build_opener(NoRedirect())

    def generate(self, command, messages, emit, alive):
        request_body = {"model": self.model, "messages": messages, "stream": True,
                        "stream_options": {"include_usage": True}}
        if command["tools"]:
            request_body["tools"] = command["tools"]
        # This optional extension is sent only on an explicit user choice.
        mode = command["config"]["thinkingMode"]
        if mode != "serverDefault":
            request_body["thinking"] = {"type": mode}
        request = urllib.request.Request(self.url, encode(request_body).encode(),
            {"Content-Type": "application/json", "Accept": "text/event-stream",
             "Authorization": "Bearer " + self.key}, method="POST")
        calls, content, reason, finish, done, data, usage = {}, "", "", None, False, [], None
        with self.opener.open(request, timeout=self.timeout) as response:
            if response.headers.get_content_type() != "text/event-stream":
                raise GatewayError(502, "PROVIDER_NOT_SSE")
            while alive():
                line = response.readline(1_048_577)
                if len(line) > 1_048_576:
                    raise GatewayError(502, "PROVIDER_FRAME_TOO_LARGE")
                if not line:
                    break
                if line.strip():
                    if line.startswith(b"data:"):
                        data.append(line[5:].strip())
                    if sum(map(len, data)) > 2 * 1_048_576:
                        raise GatewayError(502, "PROVIDER_FRAME_TOO_LARGE")
                    continue
                if not data:
                    continue
                payload = b"\n".join(data)
                data = []
                if payload == b"[DONE]":
                    done = True
                    break
                value = decode(payload)
                if value.get("error"):
                    raise GatewayError(502, "PROVIDER_ERROR")
                if value.get("usage"):
                    u = value["usage"]
                    usage = {"promptTokens": integer(u.get("prompt_tokens")),
                             "completionTokens": integer(u.get("completion_tokens")),
                             "totalTokens": integer(u.get("total_tokens"))}
                for choice in value.get("choices", []):
                    if choice.get("index") != 0:
                        continue
                    delta = choice.get("delta", {})
                    if delta.get("content") is not None:
                        part = text(delta["content"], MAX_BODY, empty=True)
                        content += part
                        emit("content", {"delta": part})
                    if delta.get("reasoning_content") is not None:
                        part = text(delta["reasoning_content"], MAX_BODY, empty=True)
                        reason += part
                        emit("thinking", {"delta": part})
                    for call in delta.get("tool_calls", []):
                        index = integer(call.get("index"), 19)
                        target = calls.setdefault(index, {"id": "", "name": "", "argumentsJSON": ""})
                        target["id"] += call.get("id") or ""
                        function = call.get("function", {})
                        target["name"] += function.get("name") or ""
                        target["argumentsJSON"] += function.get("arguments") or ""
                        if len(target["argumentsJSON"].encode()) > 1_048_576:
                            raise GatewayError(502, "PROVIDER_TOOL_TOO_LARGE")
                    if choice.get("finish_reason") is not None:
                        finish = choice["finish_reason"]
                if len(content.encode()) + len(reason.encode()) > MAX_BODY:
                    raise GatewayError(502, "PROVIDER_OUTPUT_TOO_LARGE")
        if not alive():
            return None
        if not done or finish not in {"stop", "tool_calls"} or data:
            raise GatewayError(502, "PROVIDER_INCOMPLETE")
        if (finish == "tool_calls") != bool(calls):
            raise GatewayError(502, "PROVIDER_TOOL_PROTOCOL")
        if usage:
            emit("usage", usage)
        return {"content": content, "calls": [calls[i] for i in sorted(calls)]}


class Service:
    def __init__(self, store, provider):
        self.store, self.provider = store, provider
        self.stopping = False
        self.workers = set()

    def alive(self, run, generation):
        with self.store.changed:
            row = self.store.run(run)
            return not self.stopping and row["generation"] == generation and row["phase"] == "streaming"

    def emit(self, run, generation, event, payload):
        with self.store.changed, self.store.db:
            row = self.store.run(run)
            if not self.alive(run, generation):
                return
            if event in {"content", "thinking"}:
                text(payload.get("delta"), MAX_BODY, empty=True)
                payload = dict(payload, messageID=row["message_id"])
            self.store.append(row, event, payload)
            if event in {"waiting_question", "waiting_confirmation"}:
                opaque(payload.get("interactionID"))
                if not isinstance(payload.get("params"), dict) or type(payload.get("expiresAt")) not in (int, float):
                    raise GatewayError(400, "INVALID_INTERACTION")
                self.store.db.execute("UPDATE runs SET phase=?, interaction=? WHERE id=?", (event, encode(payload), run))
            self.store.changed.notify_all()

    def spawn(self, run, generation):
        worker = threading.Thread(target=self.work, args=(run, generation), daemon=True)
        with self.store.changed:
            self.workers.add(worker)
        worker.start()

    def work(self, run, generation):
        try:
            with self.store.changed, self.store.db:
                row = self.store.run(run)
                if not self.alive(run, generation):
                    return
                if row["message_id"] is None:
                    message_id = str(uuid.uuid4())
                    self.store.db.execute("UPDATE runs SET message_id=? WHERE id=?", (message_id, run))
                    row = self.store.run(run)
                    self.store.append(row, "initial", {"messageID": message_id})
                command, messages = decode(row["command"]), decode(row["messages"])
                self.store.changed.notify_all()
            emit = lambda event, payload: self.emit(run, generation, event, payload)
            # Provider-side typed proposals must bind to the real persisted run.
            # This context is not part of the user command or upstream wire body.
            provider_command = dict(command, gatewayRunID=run)
            result = self.provider.generate(provider_command, messages, emit, lambda: self.alive(run, generation))
            if result is None:
                return
            with self.store.changed, self.store.db:
                row = self.store.run(run)
                if not self.alive(run, generation):
                    return
                calls = result.get("calls", [])
                allowed = {t["function"]["name"] for t in command["tools"]}
                if len(calls) > 20 or len({c["id"] for c in calls}) != len(calls):
                    raise GatewayError(502, "PROVIDER_INVALID_TOOLS")
                used = self.store.db.execute("SELECT COUNT(*) FROM tools WHERE run=?", (run,)).fetchone()[0]
                if used + len(calls) > command["config"]["maxToolRounds"]:
                    raise GatewayError(502, "TOOL_LIMIT")
                assistant = {"role": "assistant", "content": result["content"]}
                for call in calls:
                    validate_call(call)
                    if call["name"] not in allowed:
                        raise GatewayError(502, "PROVIDER_UNAUTHORIZED_TOOL")
                if calls:
                    assistant["tool_calls"] = [
                        {"id": c["id"], "type": "function",
                         "function": {"name": c["name"], "arguments": c["argumentsJSON"]}}
                        for c in calls]
                messages.append(assistant)
                self.store.db.execute("UPDATE runs SET messages=? WHERE id=?", (encode(messages), run))
                if calls:
                    for call in calls:
                        request = {"executionID": uuid.uuid4().hex, "callID": call["id"],
                                   "name": call["name"], "argumentsJSON": call["argumentsJSON"],
                                   "targetClientInstanceID": row["client"], "expiresAt": time.time() + 300}
                        self.store.db.execute("INSERT INTO tools VALUES (?,?,?,?,?,NULL)",
                            (request["executionID"], run, call["id"], generation, encode(request)))
                        self.store.append(row, "client_tool_request", request)
                else:
                    self.store.append(row, "assistant_completed", {"messageID": row["message_id"]})
                    self.store.append(row, "run_completed", {"messageID": row["message_id"]})
                    self.store.db.execute("UPDATE runs SET phase='completed', message_id=NULL WHERE id=?", (run,))
                self.store.changed.notify_all()
        except Exception:
            # Provider exceptions and HTTP bodies may contain secrets.
            with self.store.changed, self.store.db:
                if self.alive(run, generation):
                    row = self.store.run(run)
                    self.store.append(row, "run_failed", {"code": "PROVIDER_FAILURE"})
                    self.store.db.execute("UPDATE runs SET phase='failed' WHERE id=?", (run,))
                    self.store.changed.notify_all()
        finally:
            with self.store.changed:
                self.workers.discard(threading.current_thread())

    def command(self, route, run, action, body):
        key = opaque(body.get("requestKey"))
        launch = None
        with self.store.changed, self.store.db:
            prior = self.store.receipt(key, route, body)
            if prior is not None:
                return prior
            if action == "create":
                scope = validate_command(body)
                if self.provider is None:
                    raise GatewayError(503, "PROVIDER_NOT_CONFIGURED")
                run = "run/" + uuid.uuid4().hex + "+opaque"
                self.store.db.execute("INSERT INTO runs(id,binding,client,phase,command,messages) VALUES (?,?,?,'streaming',?,?)",
                    (run, encode(scope), body["clientInstanceID"], encode(body), encode(wire_history(body))))
                launch = (run, 0)
            else:
                if type(body.get("schemaVersion")) is not int or body["schemaVersion"] != 1:
                    raise GatewayError(400, "SCHEMA_VERSION")
                row = self.store.run(run)
                if binding(body.get("binding")) != decode(row["binding"]):
                    raise GatewayError(409, "BINDING_CONFLICT")
                if body.get("runID", run) != run:
                    raise GatewayError(409, "RUN_CONFLICT")
                if action == "cancel":
                    if row["phase"] not in TERMINAL:
                        self.store.append(row, "run_cancelled", {})
                        self.store.db.execute("UPDATE runs SET phase='cancelled', generation=generation+1 WHERE id=?", (run,))
                elif action == "continue":
                    interaction = "interactionID" in body
                    validate_command(body, interaction)
                    if body["clientInstanceID"] != row["client"]:
                        raise GatewayError(409, "CLIENT_CONFLICT")
                    if row["phase"] not in WAITING:
                        raise GatewayError(409, "RUN_NOT_WAITING")
                    if self.provider is None:
                        raise GatewayError(503, "PROVIDER_NOT_CONFIGURED")
                    pending = self.store.db.execute("SELECT COUNT(*) FROM tools WHERE run=? AND result IS NULL", (run,)).fetchone()[0]
                    if pending:
                        raise GatewayError(409, "TOOLS_UNRESOLVED")
                    if interaction:
                        waiting = decode(row["interaction"]) if row["interaction"] else {}
                        if body["interactionID"] != waiting.get("interactionID"):
                            raise GatewayError(409, "INTERACTION_CONFLICT")
                        if time.time() >= waiting.get("expiresAt", 0):
                            raise GatewayError(410, "INTERACTION_EXPIRED")
                        command, messages = decode(row["command"]), decode(row["messages"])
                        messages.append({"role": "user", "content": encode(body["answer"])})
                    else:
                        command, messages = body, wire_history(body)
                    if row["message_id"]:
                        self.store.append(row, "assistant_completed", {"messageID": row["message_id"]})
                    generation = row["generation"] + 1
                    self.store.db.execute("UPDATE runs SET phase='streaming', command=?, messages=?, message_id=NULL, interaction=NULL, generation=? WHERE id=?",
                        (encode(command), encode(messages), generation, run))
                    launch = (run, generation)
                elif action == "tool-results":
                    execution = opaque(body.get("executionID"))
                    if key != "tool-" + execution:
                        raise GatewayError(400, "TOOL_KEY_MISMATCH")
                    tool = self.store.db.execute("SELECT * FROM tools WHERE execution=? AND run=?", (execution, run)).fetchone()
                    if tool is None:
                        raise GatewayError(404, "TOOL_NOT_FOUND")
                    if body.get("callID") != tool["call"]:
                        raise GatewayError(409, "TOOL_CALL_CONFLICT")
                    text(body.get("content"), MAX_BODY, empty=True)
                    if type(body.get("isFailure")) is not bool:
                        raise GatewayError(400, "INVALID_TOOL_RESULT")
                    if row["phase"] in TERMINAL:
                        raise GatewayError(409, "RUN_TERMINAL")
                    self.store.db.execute("UPDATE tools SET result=? WHERE execution=?", (encode(body), execution))
                    messages = decode(row["messages"])
                    messages.append({"role": "tool", "tool_call_id": tool["call"], "content": body["content"]})
                    self.store.db.execute("UPDATE runs SET messages=? WHERE id=?", (encode(messages), run))
                    remaining = self.store.db.execute("SELECT COUNT(*) FROM tools WHERE run=? AND result IS NULL", (run,)).fetchone()[0]
                    if not remaining and row["phase"] == "streaming":
                        self.store.append(row, "assistant_completed", {"messageID": row["message_id"]})
                        generation = row["generation"] + 1
                        self.store.db.execute("UPDATE runs SET message_id=NULL, generation=? WHERE id=?", (generation, run))
                        launch = (run, generation)
                else:
                    raise GatewayError(404, "ROUTE_NOT_FOUND")
            receipt = self.store.descriptor(self.store.run(run), key)
            self.store.save_receipt(key, route, body, receipt)
            self.store.changed.notify_all()
        if launch:
            self.spawn(*launch)
        return receipt


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Never log URL query, request content, keys, upstream URL or errors.
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def reply(self, status, body):
        data = encode(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def route(self):
        if self.server.token and not hmac.compare_digest(
                self.headers.get("Authorization", ""), "Bearer " + self.server.token):
            raise GatewayError(401, "UNAUTHORIZED")
        parts = urllib.parse.urlsplit(self.path)
        if not parts.path.startswith("/v1/") or re.search(r"%(?![0-9a-fA-F]{2})", parts.path):
            raise GatewayError(404, "ROUTE_NOT_FOUND")
        segments = [urllib.parse.unquote(s, errors="strict") for s in parts.path[4:].split("/")]
        for segment in segments:
            opaque(segment)
        return segments, parts.query

    def do_POST(self):
        self.handle_request(True)

    def do_GET(self):
        self.handle_request(False)

    def handle_request(self, post):
        try:
            path, query = self.route()
            service, store = self.server.service, self.server.service.store
            if post:
                if query or self.headers.get("Transfer-Encoding") or len(self.headers.get_all("Content-Length", [])) != 1:
                    raise GatewayError(400, "INVALID_BODY_FRAMING")
                if self.headers.get_content_type() != "application/json":
                    raise GatewayError(415, "JSON_REQUIRED")
                try:
                    size = int(self.headers.get("Content-Length", ""))
                except ValueError:
                    raise GatewayError(400, "INVALID_CONTENT_LENGTH") from None
                if not 0 < size <= MAX_BODY:
                    raise GatewayError(413, "BODY_TOO_LARGE")
                raw = self.rfile.read(size)
                if len(raw) != size:
                    raise GatewayError(400, "INCOMPLETE_BODY")
                body = decode(raw)
                if not isinstance(body, dict):
                    raise GatewayError(400, "OBJECT_REQUIRED")
                key = opaque(body.get("requestKey"))
                if self.headers.get_all("Idempotency-Key") != [key]:
                    raise GatewayError(400, "IDEMPOTENCY_KEY_MISMATCH")
                if path == ["runs"]:
                    run, action = None, "create"
                elif len(path) == 3 and path[0] == "runs" and path[2] in {"continue", "cancel", "tool-results"}:
                    run, action = path[1], path[2]
                else:
                    raise GatewayError(404, "ROUTE_NOT_FOUND")
                receipt = service.command(encode(path), run, action, body)
                self.reply(200, receipt)
            elif len(path) == 3 and path[0] == "runs" and path[2] == "events":
                self.events(path[1], query)
            else:
                if query:
                    raise GatewayError(400, "UNKNOWN_QUERY")
                with store.changed:
                    if path == ["health"]:
                        provider = service.provider
                        body = {"schemaVersion": 1, "status": "ok",
                                "providerConfigured": provider is not None,
                                "synthetic": provider is not None and provider.label.startswith("TEST-ONLY"),
                                "authRequired": bool(self.server.token),
                                "capabilities": ["runs", "sseReplay", "idempotency", "clientTools"]}
                    elif len(path) == 2 and path[0] == "runs":
                        body = store.descriptor(store.run(path[1]))
                    elif len(path) == 2 and path[0] == "requests":
                        body = store.receipt(path[1])
                        if body is None:
                            raise GatewayError(404, "REQUEST_NOT_FOUND")
                    else:
                        raise GatewayError(404, "ROUTE_NOT_FOUND")
                self.reply(200, body)
        except GatewayError as error:
            self.reply(error.status, {"schemaVersion": 1, "error": {"code": error.code}})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True
        except Exception:
            self.reply(500, {"schemaVersion": 1, "error": {"code": "INTERNAL_ERROR"}})

    def events(self, run, query):
        store = self.server.service.store
        params = urllib.parse.parse_qs(query, keep_blank_values=True)
        if set(params) - {"cursor"} or len(params.get("cursor", [])) > 1:
            raise GatewayError(400, "INVALID_CURSOR")
        cursor = params.get("cursor", [None])[0]
        headers = self.headers.get_all("Last-Event-ID", [])
        if len(headers) > 1 or (headers and cursor is not None and cursor != headers[0]):
            raise GatewayError(400, "CURSOR_MISMATCH")
        cursor = cursor if cursor is not None else (headers[0] if headers else None)
        with store.changed:
            store.run(run)
            seq = 0
            if cursor is not None:
                opaque(cursor)
                event = store.db.execute("SELECT seq FROM events WHERE run=? AND id=?", (run, cursor)).fetchone()
                if event is None:
                    raise GatewayError(409, "CURSOR_NOT_FOUND")
                seq = event["seq"]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        self.close_connection = True
        while not self.server.service.stopping:
            with store.changed:
                rows = store.db.execute("SELECT seq,frame FROM events WHERE run=? AND seq>? ORDER BY seq LIMIT 128", (run, seq)).fetchall()
                phase = store.run(run)["phase"]
                if not rows and phase not in TERMINAL | WAITING:
                    store.changed.wait(timeout=1)
            for row in rows:
                self.wfile.write(row["frame"].encode())
                self.wfile.flush()
                seq = row["seq"]
            if not rows:
                if phase in TERMINAL | WAITING:
                    return
                self.wfile.write(b": heartbeat\n\n")
                self.wfile.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", choices=["127.0.0.1"], default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--db", required=True, help="Explicit private SQLite path")
    parser.add_argument("--test-only-provider", action="store_true",
                        help="TEST ONLY: deterministic synthetic model, never production")
    args = parser.parse_args()
    os.umask(0o077)
    provider = None
    if args.test_only_provider:
        from test_provider import TestProvider
        provider = TestProvider()
    else:
        config = [os.environ.get("GATEWAY_PROVIDER_" + name, "") for name in ("BASE_URL", "API_KEY", "MODEL")]
        if any(config) and not all(config):
            parser.error("All three explicit GATEWAY_PROVIDER_* values are required")
        if all(config):
            provider = OpenAIProvider(*config)
    token = os.environ.get("GATEWAY_AUTH_TOKEN", "")
    if "\r" in token or "\n" in token:
        parser.error("Invalid GATEWAY_AUTH_TOKEN")
    store = Store(args.db)
    service = Service(store, provider)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    server.service, server.token = service, token
    print(encode({"listening": f"http://{args.host}:{server.server_port}/v1",
                  "provider": provider.label if provider else "not-configured",
                  "authRequired": bool(token)}), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        service.stopping = True
        with store.changed:
            store.changed.notify_all()
        server.server_close()
        # A blocked provider read is bounded by its network timeout. Process
        # exit leaves in-flight work suspended on next start, never auto-retried.
        with store.changed, contextlib.suppress(Exception):
            store.db.execute("PRAGMA wal_checkpoint(FULL)")
        store.lock_file.close()


if __name__ == "__main__":
    main()
