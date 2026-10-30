#!/usr/bin/env python3
"""Self-owned Gateway v1. Local HTTP transport; no bundled model credentials."""
import argparse
import base64
import binascii
import contextlib
import fcntl
import hashlib
import hmac
import json
import math
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
import app_reply

MAX_BODY = 8 * 1024 * 1024
MAX_IMAGE_BYTES = 1_048_576
MAX_MESSAGE_IMAGE_BYTES = 2_097_152
MAX_MESSAGE_IMAGES = 6
TERMINAL = {"completed", "failed", "cancelled"}
WAITING = {"waiting_question", "waiting_confirmation", "waiting_suspended"}
STEER_VERSION = 1
STEER_SAFE_POINTS = {"model_boundary", "tools_resolved"}
MAX_PENDING_STEERS = 32
MAX_RUN_STEERS = 64
MAX_STEER_TEXT_BYTES = 262_144
DECISION_VERSION = 1
MAX_RUN_INTERACTIONS = 128


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
    if not isinstance(value, str) or (not empty and not value):
        raise GatewayError(400, "INVALID_STRING")
    try:
        if len(value.encode("utf-8")) > limit:
            raise GatewayError(400, "INVALID_STRING")
    except UnicodeEncodeError:
        raise GatewayError(400, "INVALID_STRING") from None
    return value


def image_size(value):
    """Validate a bounded captured image envelope; never fetch a remote URL.

    ImageIO validates complete image data before the native client captures it.
    The gateway validates MIME magic and transport shape, not full decoding.
    """
    if not isinstance(value, dict) or set(value) - {"url", "detail"}:
        raise GatewayError(400, "INVALID_IMAGE")
    if "detail" in value and value["detail"] not in ("auto", "low", "high"):
        raise GatewayError(400, "INVALID_IMAGE")
    url = value.get("url")
    if not isinstance(url, str):
        raise GatewayError(400, "INVALID_IMAGE")
    match = re.fullmatch(r"data:(image/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/]*={0,2})", url)
    if not match:
        raise GatewayError(400, "INVALID_IMAGE")
    mime, encoded = match.groups()
    if len(encoded) > 4 * ((MAX_IMAGE_BYTES + 2) // 3):
        raise GatewayError(400, "IMAGE_LIMIT")
    try:
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise GatewayError(400, "INVALID_IMAGE") from None
    if not data or base64.b64encode(data).decode("ascii") != encoded:
        raise GatewayError(400, "INVALID_IMAGE")
    if len(data) > MAX_IMAGE_BYTES:
        raise GatewayError(400, "IMAGE_LIMIT")
    signatures = {
        "image/png": data.startswith(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg": data.startswith(b"\xff\xd8\xff"),
        "image/gif": data.startswith((b"GIF87a", b"GIF89a")),
        "image/webp": len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP",
    }
    if not signatures[mime]:
        raise GatewayError(400, "INVALID_IMAGE")
    return len(data)


def validate_content(value, role, message_version, supports_images):
    if isinstance(value, str):
        text(value, MAX_BODY, empty=True)
        return
    if message_version != 1:
        raise GatewayError(400, "MESSAGE_SCHEMA_VERSION")
    if role != "user" or not isinstance(value, list) or not value:
        raise GatewayError(400, "INVALID_MESSAGE_CONTENT")
    # One textual snapshot plus at most six captured images, as in the native
    # client. Bound text-only lists too; do not allow arbitrary model parts.
    if len(value) > MAX_MESSAGE_IMAGES + 1:
        raise GatewayError(400, "IMAGE_LIMIT")
    count, total, texts = 0, 0, 0
    for part in value:
        if not isinstance(part, dict):
            raise GatewayError(400, "INVALID_MESSAGE_CONTENT")
        if part.get("type") == "text" and set(part) == {"type", "text"}:
            texts += 1
            if texts > 1:
                raise GatewayError(400, "INVALID_MESSAGE_CONTENT")
            text(part["text"], MAX_BODY, empty=True)
        elif part.get("type") == "image_url" and set(part) == {"type", "image_url"}:
            if not supports_images:
                raise GatewayError(400, "IMAGE_INPUT_UNSUPPORTED")
            count += 1
            total += image_size(part["image_url"])
            if count > MAX_MESSAGE_IMAGES or total > MAX_MESSAGE_IMAGE_BYTES:
                raise GatewayError(400, "IMAGE_LIMIT")
        else:
            raise GatewayError(400, "INVALID_MESSAGE_CONTENT")


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


def interaction_answer(body):
    """v1 retains the exact answer bytes for a cross-language fingerprint."""
    if "decisionSchemaVersion" not in body:
        if "answer" not in body:
            raise GatewayError(400, "MISSING_ANSWER")
        return body["answer"], hashlib.sha256(encode(body["answer"]).encode()).hexdigest()
    if type(body["decisionSchemaVersion"]) is not int or body["decisionSchemaVersion"] != DECISION_VERSION:
        raise GatewayError(400, "DECISION_SCHEMA_VERSION")
    if "answer" in body:
        raise GatewayError(400, "AMBIGUOUS_ANSWER")
    integer(body.get("requestRevision"))
    fingerprint = text(body.get("requestFingerprint"), 64)
    if re.fullmatch(r"[0-9a-f]{64}", fingerprint) is None:
        raise GatewayError(400, "INVALID_REQUEST_FINGERPRINT")
    raw = text(body.get("answerJSON"), MAX_BODY)
    answer = decode(raw)
    if not isinstance(answer, dict):
        raise GatewayError(400, "INVALID_ANSWER")
    return answer, hashlib.sha256(raw.encode()).hexdigest()


def available_decisions(params):
    decisions = params.get("availableDecisions", ["accept", "decline"])
    if not isinstance(decisions, list) or not decisions \
            or any(type(d) is not str or d not in {"accept", "decline"} for d in decisions) \
            or len(set(decisions)) != len(decisions):
        raise GatewayError(400, "INVALID_AVAILABLE_DECISIONS")
    return decisions


def validate_decision_request(kind, params):
    if kind == "waiting_question":
        questions = params.get("questions")
        if not isinstance(questions, list) or not 1 <= len(questions) <= 32:
            raise GatewayError(400, "INVALID_QUESTIONS")
        identities = set()
        for question in questions:
            if not isinstance(question, dict):
                raise GatewayError(400, "INVALID_QUESTIONS")
            identity = opaque(question.get("id"))
            if identity in identities:
                raise GatewayError(400, "INVALID_QUESTIONS")
            identities.add(identity)
            text(question.get("question"), MAX_BODY)
            options = question.get("options", [])
            if not isinstance(options, list) or len(options) > 64:
                raise GatewayError(400, "INVALID_QUESTIONS")
            labels = []
            for option in options:
                if not isinstance(option, dict):
                    raise GatewayError(400, "INVALID_QUESTIONS")
                labels.append(text(option.get("label"), MAX_BODY))
            if len(set(labels)) != len(labels):
                raise GatewayError(400, "INVALID_QUESTIONS")
            for flag in ("isSecret", "isOther"):
                if flag in question and type(question[flag]) is not bool:
                    raise GatewayError(400, "INVALID_QUESTIONS")
    else:
        available_decisions(params)
        if "items" in params:
            items = params["items"]
            if not isinstance(items, list) or not 1 <= len(items) <= 64:
                raise GatewayError(400, "INVALID_BATCH_DECISION")
            indices = set()
            for item in items:
                if not isinstance(item, dict):
                    raise GatewayError(400, "INVALID_BATCH_DECISION")
                index = integer(item.get("index"))
                if index in indices:
                    raise GatewayError(400, "INVALID_BATCH_DECISION")
                indices.add(index)
                opaque(item.get("action"))
                available_decisions(item)
                allowed = item.get("allowedModifications", [])
                if not isinstance(allowed, list) or len(allowed) > 64 \
                        or any(not isinstance(key, str) or not key for key in allowed) \
                        or len(set(allowed)) != len(allowed):
                    raise GatewayError(400, "INVALID_BATCH_DECISION")
    if "cost" in params:
        cost = params["cost"]
        if not isinstance(cost, dict):
            raise GatewayError(400, "INVALID_COST_DECISION")
        available_decisions(cost)


def validate_decision_answer(kind, params, answer):
    if not isinstance(answer, dict):
        raise GatewayError(400, "INVALID_ANSWER")
    expected = {"costDecision"} if "cost" in params else set()
    if "cost" in params and answer.get("costDecision") not in available_decisions(params["cost"]):
        raise GatewayError(400, "INVALID_COST_DECISION")
    if kind == "waiting_question":
        expected.add("answers")
        answers = answer.get("answers")
        questions = params["questions"]
        if not isinstance(answers, dict) or set(answers) != {q["id"] for q in questions}:
            raise GatewayError(400, "INVALID_ANSWER")
        for question in questions:
            values = answers[question["id"]]
            if not isinstance(values, dict) or set(values) != {"answers"}:
                raise GatewayError(400, "INVALID_ANSWER")
            values = values["answers"]
            if not isinstance(values, list) or len(values) != 1 or type(values[0]) is not str \
                    or not values[0].strip():
                raise GatewayError(400, "INVALID_ANSWER")
            options = [o["label"] for o in question.get("options", [])]
            if options and not question.get("isOther", False) and values[0] not in options:
                raise GatewayError(400, "INVALID_ANSWER")
    elif "items" in params:
        expected.add("items")
        items = answer.get("items")
        if not isinstance(items, list) or len(items) != len(params["items"]):
            raise GatewayError(400, "INVALID_BATCH_DECISION")
        # Order is part of the request. Never zip after sorting or silently
        # replace the original action/index with a generated position.
        for original, item in zip(params["items"], items):
            if not isinstance(item, dict) or set(item) != {"index", "action", "decision", "modifications"} \
                    or type(item["index"]) is not int or item["index"] != original["index"] \
                    or item["action"] != original["action"] \
                    or item["decision"] not in available_decisions(original):
                raise GatewayError(400, "INVALID_BATCH_DECISION")
            modifications = item["modifications"]
            if not isinstance(modifications, dict) or set(modifications) - set(original.get("allowedModifications", [])) \
                    or (item["decision"] == "decline" and modifications):
                raise GatewayError(400, "INVALID_BATCH_MODIFICATIONS")
    else:
        expected.add("decision")
        if answer.get("decision") not in available_decisions(params):
            raise GatewayError(400, "INVALID_ANSWER")
    if set(answer) != expected:
        raise GatewayError(400, "INVALID_ANSWER")


def validate_command(body, interaction=False):
    if not isinstance(body, dict) or type(body.get("schemaVersion")) is not int or body["schemaVersion"] != 1:
        raise GatewayError(400, "SCHEMA_VERSION")
    if "appReply" in body:
        raise GatewayError(400, "APP_REPLY_REQUIRES_DEDICATED_ROUTE")
    opaque(body.get("requestKey"))
    scope = binding(body.get("binding"))
    if interaction:
        opaque(body.get("clientInstanceID"))
        opaque(body.get("interactionID"))
        interaction_answer(body)
        return scope
    message_version = body.get("messageSchemaVersion", 0)
    if type(message_version) is not int or message_version not in (0, 1):
        raise GatewayError(400, "MESSAGE_SCHEMA_VERSION")
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
    supports_images = config.get("supportsImageInput", False)
    if type(supports_images) is not bool:
        raise GatewayError(400, "INVALID_IMAGE_CAPABILITY")
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
        validate_content(message.get("content"), message["role"], message_version, supports_images)
        if message.get("reasoning") is not None:
            if message["role"] != "assistant":
                raise GatewayError(400, "INVALID_REASONING_ROLE")
            text(message["reasoning"], MAX_BODY, empty=True)
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
        if item["role"] == "assistant" and item.get("reasoning") is not None:
            message["reasoning_content"] = item["reasoning"]
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


def validate_steer(body, row):
    """Only a captured user message. It cannot expand a run's frozen tools."""
    allowed = {"schemaVersion", "steerSchemaVersion", "requestKey", "binding",
               "runID", "clientInstanceID", "submissionID", "message"}
    if set(body) != allowed or type(body.get("steerSchemaVersion")) is not int \
            or body["steerSchemaVersion"] != STEER_VERSION:
        raise GatewayError(400, "STEER_SCHEMA_VERSION")
    submission = opaque(body.get("submissionID"))
    try:
        uuid.UUID(submission)
    except ValueError:
        raise GatewayError(400, "INVALID_SUBMISSION_ID") from None
    if body["requestKey"] != "steer-" + submission:
        raise GatewayError(400, "STEER_KEY_MISMATCH")
    if body.get("clientInstanceID") != row["client"]:
        raise GatewayError(409, "CLIENT_CONFLICT")
    command = decode(row["command"])
    if any(message["id"] == submission for message in command["history"]):
        raise GatewayError(409, "MESSAGE_ID_CONFLICT")
    if command["config"]["taskPolicy"] != "chat":
        raise GatewayError(409, "STEER_UNSUPPORTED")
    message = body.get("message")
    if not isinstance(message, dict) or set(message) != {"id", "role", "content"} \
            or message["id"] != submission or message["role"] != "user":
        raise GatewayError(400, "INVALID_STEER_MESSAGE")
    content = message["content"]
    validate_content(content, "user", 1, command["config"].get("supportsImageInput", False))
    if isinstance(content, str):
        text(content, MAX_STEER_TEXT_BYTES)
    else:
        for part in content:
            if part["type"] == "text":
                text(part["text"], MAX_STEER_TEXT_BYTES, empty=True)
    return {"role": "user", "content": content}


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
        if self.db.execute("PRAGMA user_version").fetchone()[0] not in (0, 1, 2, 3, 4):
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
            CREATE TABLE IF NOT EXISTS steers (
                key TEXT PRIMARY KEY, run TEXT NOT NULL, submission TEXT NOT NULL,
                body TEXT NOT NULL, state TEXT NOT NULL,
                sequence INTEGER NOT NULL, accepted_at REAL NOT NULL,
                placement TEXT, return_reason TEXT,
                UNIQUE(run, submission), UNIQUE(run, sequence));
            CREATE TABLE IF NOT EXISTS interactions (
                run TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL,
                request TEXT NOT NULL, fingerprint TEXT NOT NULL,
                revision INTEGER NOT NULL, created_at REAL NOT NULL,
                expires_at REAL NOT NULL, decision TEXT,
                PRIMARY KEY(run, id));
            PRAGMA user_version=3;
        """)
        app_reply.schema(self.db)
        self.db.execute("PRAGMA user_version=4")
        with self.changed, self.db:
            # Old events and receipts stay byte-identical. Only an existing
            # pending request can be migrated without inventing old decisions.
            for row in self.db.execute("SELECT * FROM runs WHERE interaction IS NOT NULL "
                    "AND phase IN ('waiting_question','waiting_confirmation')").fetchall():
                payload = decode(row["interaction"])
                if self.db.execute("SELECT 1 FROM interactions WHERE run=? AND id=?",
                                   (row["id"], payload["interactionID"])).fetchone() is None:
                    self.register_interaction(row, row["phase"], payload, legacy=True)
            for row in self.db.execute("SELECT * FROM runs WHERE id IN "
                    "(SELECT run FROM steers WHERE state='accepted')").fetchall():
                self.return_steers(row, "PROCESS_RESTART")
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
                  "runID": row["id"], "phase": row["phase"], "clientInstanceID": row["client"]}
        result["decisionCapability"] = {"schemaVersion": DECISION_VERSION, "readback": True}
        if key is not None:
            result["requestKey"] = key
        if decode(row["command"])["config"]["taskPolicy"] == "chat":
            result["steerCapability"] = {
                "schemaVersion": STEER_VERSION, "safePoints": sorted(STEER_SAFE_POINTS),
                "accepting": row["phase"] == "streaming",
                "maxPending": MAX_PENDING_STEERS, "maxPerRun": MAX_RUN_STEERS}
        return result

    def register_interaction(self, row, kind, payload, legacy=False):
        identity = opaque(payload.get("interactionID"))
        expiry = payload.get("expiresAt")
        params = payload.get("params")
        if kind not in {"waiting_question", "waiting_confirmation"} \
                or not isinstance(params, dict) or type(expiry) not in (int, float) or not math.isfinite(expiry):
            raise GatewayError(400, "INVALID_INTERACTION")
        if not legacy:
            validate_decision_request(kind, params)
        original = {"interactionID": identity, "kind": kind, "expiresAt": expiry, "params": params}
        fingerprint = hashlib.sha256(encode(original).encode()).hexdigest()
        old = self.db.execute("SELECT * FROM interactions WHERE run=? AND id=?", (row["id"], identity)).fetchone()
        if old is not None:
            if old["fingerprint"] != fingerprint or old["decision"] is not None:
                raise GatewayError(409, "INTERACTION_ID_REUSED")
            created = old["created_at"]
        else:
            count = self.db.execute("SELECT COUNT(*) FROM interactions WHERE run=?", (row["id"],)).fetchone()[0]
            if count >= MAX_RUN_INTERACTIONS:
                raise GatewayError(429, "INTERACTION_LIMIT")
            created = time.time()
            self.db.execute("INSERT INTO interactions VALUES (?,?,?,?,?,1,?,?,NULL)",
                            (row["id"], identity, kind, encode(original), fingerprint, created, expiry))
        # Only the server can assign request revision/fingerprint and time.
        return dict(payload, decisionSchemaVersion=DECISION_VERSION, requestRevision=1,
                    requestFingerprint=fingerprint, serverTime=time.time(), createdAt=created)

    def interaction(self, run, identity):
        row = self.run(run)
        request = self.db.execute("SELECT * FROM interactions WHERE run=? AND id=?", (run, identity)).fetchone()
        if request is None:
            raise GatewayError(404, "INTERACTION_NOT_FOUND")
        now = time.time()
        if request["decision"] is not None:
            state = "resolved"
        elif row["interaction"] is None or decode(row["interaction"]).get("interactionID") != identity \
                or row["phase"] not in {"waiting_question", "waiting_confirmation"}:
            state = "superseded"
        elif now >= request["expires_at"]:
            state = "expired"
        else:
            state = "pending"
        result = {"schemaVersion": 1, "decisionSchemaVersion": DECISION_VERSION,
                  "binding": decode(row["binding"]), "runID": run,
                  "clientInstanceID": row["client"], "interactionID": identity,
                  "requestRevision": request["revision"], "requestFingerprint": request["fingerprint"],
                  "kind": request["kind"], "createdAt": request["created_at"],
                  "expiresAt": request["expires_at"], "serverTime": now, "state": state}
        if request["decision"] is not None:
            result["decision"] = decode(request["decision"])
        return result

    def steer_receipt(self, row, steer):
        receipt = {"schemaVersion": 1, "steerSchemaVersion": STEER_VERSION,
                   "binding": decode(row["binding"]), "runID": row["id"],
                   "clientInstanceID": row["client"], "requestKey": steer["key"],
                   "submissionID": steer["submission"], "messageID": steer["submission"],
                   "state": steer["state"], "revision": 1 if steer["state"] == "accepted" else 2,
                   "sequence": steer["sequence"], "acceptedAt": steer["accepted_at"]}
        if steer["placement"]:
            receipt["placement"] = decode(steer["placement"])
        if steer["return_reason"]:
            receipt["returnReason"] = steer["return_reason"]
        return receipt

    def steer(self, run, submission):
        row = self.run(run)
        steer = self.db.execute("SELECT * FROM steers WHERE run=? AND submission=?",
                                (run, submission)).fetchone()
        if steer is None:
            raise GatewayError(404, "STEER_NOT_FOUND")
        return self.steer_receipt(row, steer)

    def pending_steers(self, run):
        return self.db.execute("SELECT * FROM steers WHERE run=? AND state='accepted' "
                               "ORDER BY sequence", (run,)).fetchall()

    def return_steers(self, row, reason):
        for steer in self.pending_steers(row["id"]):
            self.db.execute("UPDATE steers SET state='returned', return_reason=? WHERE key=?",
                            (reason, steer["key"]))
            self.append(row, "steer_state", self.steer(row["id"], steer["submission"]))

    def place_steers(self, row, messages, point, generation):
        """Call only inside the same transaction that closes the safe point."""
        if point not in STEER_SAFE_POINTS:
            raise GatewayError(500, "INVALID_STEER_SAFE_POINT")
        if self.db.execute("SELECT COUNT(*) FROM tools WHERE run=? AND result IS NULL",
                           (row["id"],)).fetchone()[0]:
            raise GatewayError(409, "TOOLS_UNRESOLVED")
        placed = 0
        for steer in self.pending_steers(row["id"]):
            message = decode(steer["body"])["message"]
            wire = {"role": "user", "content": message["content"]}
            if len(messages) >= 1000 or len(encode(messages + [wire]).encode()) > MAX_BODY:
                self.db.execute("UPDATE steers SET state='returned', return_reason='CONTEXT_LIMIT' WHERE key=?",
                                (steer["key"],))
            else:
                placement = {"point": point, "generation": generation,
                             "messageIndex": len(messages), "placedAt": time.time()}
                messages.append(wire)
                self.db.execute("UPDATE steers SET state='placed', placement=? WHERE key=?",
                                (encode(placement), steer["key"]))
                placed += 1
            self.append(row, "steer_state", self.steer(row["id"], steer["submission"]))
        self.db.execute("UPDATE runs SET messages=? WHERE id=?", (encode(messages), row["id"]))
        return placed

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
            payload = app_reply.register_artifact(self.db, row, payload)
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
        reason_seen = False
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
                        reason_seen = True
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
        result = {"content": content, "calls": [calls[i] for i in sorted(calls)]}
        if reason_seen:
            result["reasoning"] = reason
        return result


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
            if event in {"waiting_question", "waiting_confirmation"}:
                payload = self.store.register_interaction(row, event, payload)
                self.store.return_steers(row, "RUN_WAITING")
                self.store.db.execute("UPDATE runs SET phase=?, interaction=? WHERE id=?", (event, encode(payload), run))
            self.store.append(row, event, payload)
            self.store.changed.notify_all()

    def spawn(self, run, generation):
        worker = threading.Thread(target=self.work, args=(run, generation), daemon=True)
        with self.store.changed:
            self.workers.add(worker)
        worker.start()

    def work(self, run, generation):
        launch = None
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
            if "appReply" in command:
                method = "generate_app_reply" if generation == 0 else "continue_app_reply"
                handler = getattr(self.provider, method, None)
                if not callable(handler):
                    raise GatewayError(422, "APP_REPLY_PROVIDER_UNSUPPORTED")
                result = handler(provider_command, messages, command["appReply"],
                                 emit, lambda: self.alive(run, generation))
            else:
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
                if result.get("reasoning") is not None:
                    assistant["reasoning_content"] = text(result["reasoning"], MAX_BODY, empty=True)
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
                    if self.store.place_steers(row, messages, "model_boundary", generation + 1):
                        self.store.db.execute("UPDATE runs SET message_id=NULL, generation=generation+1 WHERE id=?", (run,))
                        launch = (run, generation + 1)
                    else:
                        self.store.append(row, "run_completed", {"messageID": row["message_id"]})
                        self.store.db.execute("UPDATE runs SET phase='completed', message_id=NULL WHERE id=?", (run,))
                self.store.changed.notify_all()
        except Exception as error:
            # Provider exceptions and HTTP bodies may contain secrets.
            # Fixed local request failures can be actionable without exposing
            # exception text or an upstream-provided error field.
            local_codes = {"INTERACTION_LIMIT", "INTERACTION_ID_REUSED", "INVALID_INTERACTION",
                           "INVALID_AVAILABLE_DECISIONS", "INVALID_QUESTIONS",
                           "INVALID_BATCH_DECISION", "INVALID_COST_DECISION"}
            code = error.code if isinstance(error, GatewayError) and error.code in local_codes else "PROVIDER_FAILURE"
            with self.store.changed, self.store.db:
                if self.alive(run, generation):
                    row = self.store.run(run)
                    self.store.return_steers(row, "TERMINAL_FAILED")
                    self.store.append(row, "run_failed", {"code": code})
                    self.store.db.execute("UPDATE runs SET phase='failed' WHERE id=?", (run,))
                    self.store.changed.notify_all()
        finally:
            with self.store.changed:
                self.workers.discard(threading.current_thread())
        if launch:
            self.spawn(*launch)

    def command(self, route, run, action, body):
        if action == "app-replies":
            return app_reply.submit(self, route, run, body)
        if action == "app-reply-continue":
            return app_reply.continue_run(self, route, run, body)
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
                        self.store.return_steers(row, "TERMINAL_CANCELLED")
                        self.store.append(row, "run_cancelled", {})
                        self.store.db.execute("UPDATE runs SET phase='cancelled', generation=generation+1 WHERE id=?", (run,))
                elif action == "steer":
                    message = validate_steer(body, row)
                    if row["phase"] != "streaming":
                        raise GatewayError(409, "RUN_NOT_STEERABLE")
                    pending = self.store.pending_steers(run)
                    count = self.store.db.execute("SELECT COUNT(*) FROM steers WHERE run=?", (run,)).fetchone()[0]
                    if len(pending) >= MAX_PENDING_STEERS or count >= MAX_RUN_STEERS:
                        raise GatewayError(429, "STEER_QUEUE_LIMIT")
                    messages = decode(row["messages"]) + [
                        {"role": "user", "content": decode(s["body"])["message"]["content"]}
                        for s in pending] + [message]
                    if len(messages) > 1000 or len(encode(messages).encode()) > MAX_BODY:
                        raise GatewayError(413, "STEER_CONTEXT_LIMIT")
                    self.store.db.execute("INSERT INTO steers VALUES (?,?,?,?,'accepted',?,?,NULL,NULL)",
                        (key, run, body["submissionID"], encode(body), count + 1, time.time()))
                    receipt = self.store.steer(run, body["submissionID"])
                    self.store.append(row, "steer_state", receipt)
                    self.store.save_receipt(key, route, body, receipt)
                    self.store.changed.notify_all()
                    return receipt
                elif action == "continue":
                    interaction = "interactionID" in body
                    if not interaction and "appReply" in decode(row["command"]):
                        raise GatewayError(409, "APP_REPLY_REQUIRES_DEDICATED_CONTINUATION")
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
                        accepted_at = time.time()
                        if accepted_at >= waiting.get("expiresAt", 0):
                            raise GatewayError(410, "INTERACTION_EXPIRED")
                        answer, answer_digest = interaction_answer(body)
                        if "decisionSchemaVersion" in body:
                            current = self.store.interaction(run, body["interactionID"])
                            if current["state"] != "pending" or body["requestRevision"] != current["requestRevision"] \
                                    or body["requestFingerprint"] != current["requestFingerprint"]:
                                raise GatewayError(409, "INTERACTION_REVISION_CONFLICT")
                            validate_decision_request(row["phase"], waiting["params"])
                            validate_decision_answer(row["phase"], waiting["params"], answer)
                        command, messages = decode(row["command"]), decode(row["messages"])
                        decision = {"requestKey": key, "answerSHA256": answer_digest,
                                    "acceptedAt": accepted_at, "generation": row["generation"] + 1,
                                    "messageIndex": len(messages)}
                        messages.append({"role": "user", "content": encode(answer)})
                        if len(messages) > 1000 or len(encode(messages).encode()) > MAX_BODY:
                            raise GatewayError(413, "DECISION_CONTEXT_LIMIT")
                        changed = self.store.db.execute("UPDATE interactions SET decision=? "
                            "WHERE run=? AND id=? AND decision IS NULL",
                            (encode(decision), run, body["interactionID"]))
                        if changed.rowcount != 1:
                            raise GatewayError(409, "INTERACTION_DECISION_CONFLICT")
                    else:
                        placed = self.store.db.execute("SELECT body FROM steers WHERE run=? AND state='placed' "
                                                       "ORDER BY sequence", (run,)).fetchall()
                        identities = {m["id"]: (i, m) for i, m in enumerate(body["history"])}
                        if placed and len(identities) != len(body["history"]):
                            raise GatewayError(409, "PLACED_MESSAGE_ORDER")
                        positions = []
                        for item in placed:
                            original = decode(item["body"])["message"]
                            supplied = identities.get(original["id"])
                            if supplied is None or supplied[1]["role"] != "user" \
                                    or encode(supplied[1]["content"]) != encode(original["content"]):
                                raise GatewayError(409, "PLACED_MESSAGE_MISSING")
                            positions.append(supplied[0])
                        if positions != sorted(set(positions)):
                            raise GatewayError(409, "PLACED_MESSAGE_ORDER")
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
                        self.store.place_steers(row, messages, "tools_resolved", generation)
                        self.store.db.execute("UPDATE runs SET message_id=NULL, generation=? WHERE id=?", (generation, run))
                        launch = (run, generation)
                else:
                    raise GatewayError(404, "ROUTE_NOT_FOUND")
            receipt = self.store.descriptor(self.store.run(run), key)
            if action == "continue" and "interactionID" in body:
                receipt["decisionReceipt"] = self.store.interaction(run, body["interactionID"])
                self.store.append(self.store.run(run), "decision_resolved", receipt["decisionReceipt"])
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
                elif len(path) == 3 and path[0] == "runs" and path[2] in {
                        "continue", "cancel", "tool-results", "steer", "app-replies", "app-reply-continue"}:
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
                                "capabilities": ["runs", "sseReplay", "idempotency", "clientTools",
                                                 "messageContentV1", "reasoningHistory", "decisionReadbackV1",
                                                 "appReplyReadbackV1"],
                                "appReplyExecution": callable(getattr(provider, "generate_app_reply", None)),
                                "messageSchemaVersion": 1}
                    elif len(path) == 2 and path[0] == "runs":
                        body = store.descriptor(store.run(path[1]))
                    elif len(path) == 4 and path[0] == "runs" and path[2] == "steers":
                        body = store.steer(path[1], path[3])
                    elif len(path) == 4 and path[0] == "runs" and path[2] == "interactions":
                        body = store.interaction(path[1], path[3])
                    elif len(path) == 5 and path[0] == "runs" and path[2] == "artifacts" \
                            and path[4] == "app-reply-manifest":
                        body = app_reply.authority(store.db, store.run(path[1]), path[3])
                    elif len(path) == 4 and path[0] == "runs" and path[2] == "app-replies":
                        body = app_reply.readback(store, path[1], path[3])
                    elif len(path) == 2 and path[0] == "requests":
                        body = store.receipt(path[1])
                        if body is None:
                            raise GatewayError(404, "REQUEST_NOT_FOUND")
                    else:
                        raise GatewayError(404, "ROUTE_NOT_FOUND")
                self.reply(200, body)
        except (GatewayError, app_reply.AppReplyError) as error:
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
