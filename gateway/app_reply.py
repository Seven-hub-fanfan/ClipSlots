"""ClipSlots App reply v1. Authority and execution are supplied by the gateway.

This is a local versioned contract, not an inferred TapNow cloud implementation.
No HTML hash or numeric artifact revision is converted into a manifest revision.
"""
import hashlib
import json
import re
import time
import unicodedata
import uuid

VERSION = 1
MAX_REPLY_BYTES = 32768
MAX_RUN_REPLIES = 128


class AppReplyError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status, self.code = status, code


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)


def digest(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) is not None


def reply_id(value):
    if not isinstance(value, str) or re.fullmatch(
            r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", value) is None:
        raise AppReplyError(400, "INVALID_REPLY_ID")
    return str(uuid.UUID(value))


def schema(db):
    db.executescript("""
        CREATE TABLE IF NOT EXISTS app_artifacts (
            binding TEXT NOT NULL, path TEXT NOT NULL, artifact TEXT NOT NULL,
            revision INTEGER NOT NULL, origin TEXT NOT NULL, manifest TEXT,
            PRIMARY KEY(binding, path), UNIQUE(binding, artifact));
        CREATE TABLE IF NOT EXISTS app_replies (
            id TEXT PRIMARY KEY, origin TEXT NOT NULL, artifact TEXT NOT NULL,
            digest TEXT NOT NULL, body TEXT NOT NULL, run TEXT NOT NULL UNIQUE,
            accepted_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS app_reply_origin ON app_replies(origin);
    """)


def register_artifact(db, row, payload):
    """Called only inside the artifact event's SQLite transaction."""
    if "appReplyAuthority" in payload:
        raise AppReplyError(400, "CLIENT_SELECTED_APP_AUTHORITY")
    manifest = payload.get("appReplyManifest")
    path = payload.get("path")
    if manifest is None and path is None:
        return payload  # Legacy events cannot create App reply authority.
    if not isinstance(path, str) or not path or len(path.encode("utf-8")) > 1024 \
            or path.startswith(("/", "~")) or "\\" in path or ":" in path \
            or unicodedata.normalize("NFC", path) != path \
            or any(part in {"", ".", ".."} for part in path.split("/")) \
            or len(path.split("/")) > 32 or any(unicodedata.category(c) == "Cc" for c in path):
        raise AppReplyError(400, "INVALID_APP_ARTIFACT_PATH")
    if manifest is not None and (
            not isinstance(manifest, dict)
            or set(manifest) != {"schemaVersion", "manifestRevision", "actions"}
            or type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != VERSION
            or not digest(manifest["manifestRevision"]) or manifest["actions"] != ["previs_reply"]):
        raise AppReplyError(400, "INVALID_APP_MANIFEST")
    artifact, revision = payload["artifactID"], payload["revision"]
    prior = db.execute("SELECT * FROM app_artifacts WHERE binding=? AND path=?",
                       (row["binding"], path)).fetchone()
    encoded_manifest = encode(manifest) if manifest is not None else None
    if prior is not None:
        if revision < prior["revision"]:
            return payload  # Stale events have no newly issued authority.
        if revision == prior["revision"]:
            if (artifact, row["id"], encoded_manifest) != (
                    prior["artifact"], prior["origin"], prior["manifest"]):
                raise AppReplyError(409, "APP_ARTIFACT_REVISION_CONFLICT")
        else:
            other = db.execute("SELECT path FROM app_artifacts WHERE binding=? AND artifact=?",
                               (row["binding"], artifact)).fetchone()
            if other is not None and other["path"] != path:
                raise AppReplyError(409, "APP_ARTIFACT_ID_CONFLICT")
            db.execute("UPDATE app_artifacts SET artifact=?,revision=?,origin=?,manifest=? "
                       "WHERE binding=? AND path=?",
                       (artifact, revision, row["id"], encoded_manifest, row["binding"], path))
    else:
        if db.execute("SELECT 1 FROM app_artifacts WHERE binding=? AND artifact=?",
                      (row["binding"], artifact)).fetchone() is not None:
            raise AppReplyError(409, "APP_ARTIFACT_ID_CONFLICT")
        db.execute("INSERT INTO app_artifacts VALUES (?,?,?,?,?,?)",
                   (row["binding"], path, artifact, revision, row["id"], encoded_manifest))
    if manifest is None:
        return payload  # A new revision without a manifest revokes previous authority.
    return dict(payload, appReplyAuthority=authority(db, row, artifact))


def authority(db, origin, artifact):
    record = db.execute("SELECT * FROM app_artifacts WHERE binding=? AND artifact=? AND origin=?",
                        (origin["binding"], artifact, origin["id"])).fetchone()
    if record is None or record["manifest"] is None:
        raise AppReplyError(404, "APP_MANIFEST_NOT_AVAILABLE")
    manifest = json.loads(record["manifest"])
    return {"schemaVersion": VERSION, "binding": json.loads(origin["binding"]),
            "originRunID": origin["id"], "artifactID": artifact, "path": record["path"],
            "artifactRevision": record["revision"], "manifestRevision": manifest["manifestRevision"],
            "actions": manifest["actions"]}


def parse_reply(raw, manifest_revision):
    if not isinstance(raw, str):
        raise AppReplyError(400, "INVALID_APP_REPLY")
    try:
        data = raw.encode("utf-8")
    except UnicodeEncodeError:
        raise AppReplyError(400, "INVALID_APP_REPLY") from None
    if len(data) > MAX_REPLY_BYTES:
        raise AppReplyError(413, "APP_REPLY_TOO_LARGE")

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate field")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("nonfinite value")

    try:
        reply = json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)
        # Also reject lone escaped surrogates, including those in nested payloads.
        json.dumps(reply, ensure_ascii=False).encode("utf-8")
    except (ValueError, UnicodeError, RecursionError):
        raise AppReplyError(400, "INVALID_APP_REPLY") from None
    if not isinstance(reply, dict) or set(reply) - {
            "reply_id", "action", "payload", "expected_manifest_revision"} \
            or reply.get("action") != "previs_reply" or not isinstance(reply.get("payload"), dict):
        raise AppReplyError(400, "INVALID_APP_REPLY")
    identity = reply_id(reply.get("reply_id"))
    if "expected_manifest_revision" in reply and reply["expected_manifest_revision"] != manifest_revision:
        raise AppReplyError(409, "APP_MANIFEST_CONFLICT")
    return identity, reply


def validate_body(body, row):
    fields = {"schemaVersion", "appReplySchemaVersion", "requestKey", "binding", "originRunID",
              "artifactID", "artifactRevision", "manifestRevision", "replyJSON"}
    if set(body) != fields or type(body["schemaVersion"]) is not int or body["schemaVersion"] != 1 \
            or type(body["appReplySchemaVersion"]) is not int or body["appReplySchemaVersion"] != VERSION:
        raise AppReplyError(400, "APP_REPLY_SCHEMA_VERSION")
    if body["binding"] != json.loads(row["binding"]) or body["originRunID"] != row["id"]:
        raise AppReplyError(409, "APP_REPLY_BINDING_CONFLICT")
    if not digest(body["manifestRevision"]) or type(body["artifactRevision"]) is not int \
            or not 0 <= body["artifactRevision"] < 9_007_199_254_740_992 \
            or not isinstance(body["artifactID"], str):
        raise AppReplyError(400, "INVALID_APP_REPLY_AUTHORITY")
    identity, reply = parse_reply(body["replyJSON"], body["manifestRevision"])
    if body["requestKey"] != identity:
        raise AppReplyError(400, "APP_REPLY_KEY_MISMATCH")
    return identity, reply


def receipt(record, body, deduped=False):
    return {"schemaVersion": 1, "appReplySchemaVersion": VERSION,
            "binding": body["binding"], "originRunID": record["origin"],
            "artifactID": record["artifact"], "artifactRevision": body["artifactRevision"],
            "manifestRevision": body["manifestRevision"], "replyID": record["id"],
            "replySHA256": hashlib.sha256(body["replyJSON"].encode()).hexdigest(),
            "requestKey": record["id"], "runID": record["run"],
            "acceptedAt": record["accepted_at"], "deduped": deduped}


def submit(service, route, origin_id, body):
    """Durable acceptance, new run and receipt commit together, before execution."""
    store = service.store
    with store.changed, store.db:
        origin = store.run(origin_id)
        identity, reply = validate_body(body, origin)
        signature = hashlib.sha256(encode(body).encode()).hexdigest()
        prior = store.db.execute("SELECT * FROM app_replies WHERE id=?", (identity,)).fetchone()
        if prior is not None:
            if prior["digest"] != signature or prior["origin"] != origin_id:
                raise AppReplyError(409, "APP_REPLY_ID_CONFLICT")
            # Deduplication must precede current-manifest preflight. Accepted replies
            # remain readable after an artifact is replaced, deleted or revoked.
            store.receipt(identity, route, body)
            return receipt(prior, body, deduped=True)
        if store.receipt(identity) is not None:
            raise AppReplyError(409, "IDEMPOTENCY_CONFLICT")
        current = authority(store.db, origin, body["artifactID"])
        if current["artifactRevision"] != body["artifactRevision"] \
                or current["manifestRevision"] != body["manifestRevision"]:
            raise AppReplyError(409, "APP_MANIFEST_CONFLICT")
        if service.provider is None:
            raise AppReplyError(503, "APP_REPLY_PROVIDER_NOT_CONFIGURED")
        if not callable(getattr(service.provider, "generate_app_reply", None)):
            raise AppReplyError(422, "APP_REPLY_PROVIDER_UNSUPPORTED")
        if origin["phase"] != "completed":
            raise AppReplyError(409, "APP_REPLY_ORIGIN_BUSY")
        count = store.db.execute("SELECT COUNT(*) FROM app_replies WHERE origin=?", (origin_id,)).fetchone()[0]
        if count >= MAX_RUN_REPLIES:
            raise AppReplyError(429, "APP_REPLY_LIMIT")
        run = "run/" + uuid.uuid4().hex + "+opaque"
        command = json.loads(origin["command"])
        command["requestKey"] = identity
        command["appReply"] = {"authority": current, "reply": reply}
        store.db.execute("INSERT INTO runs(id,binding,client,phase,command,messages) "
                         "VALUES (?,?,?,'streaming',?,?)",
                         (run, origin["binding"], origin["client"], encode(command), origin["messages"]))
        store.db.execute("INSERT INTO app_replies VALUES (?,?,?,?,?,?,?)",
                         (identity, origin_id, body["artifactID"], signature, encode(body), run, time.time()))
        record = store.db.execute("SELECT * FROM app_replies WHERE id=?", (identity,)).fetchone()
        accepted = receipt(record, body)
        store.append(store.run(run), "app_reply_accepted", accepted)
        store.save_receipt(identity, route, body, accepted)
        store.changed.notify_all()
    service.spawn(run, 0)
    return accepted


def readback(store, origin_id, identity):
    store.run(origin_id)
    identity = reply_id(identity)
    record = store.db.execute("SELECT * FROM app_replies WHERE origin=? AND id=?",
                              (origin_id, identity)).fetchone()
    if record is None:
        raise AppReplyError(404, "APP_REPLY_NOT_FOUND")
    result = receipt(record, json.loads(record["body"]))
    phase = store.run(record["run"])["phase"]
    result["phase"] = phase
    result["state"] = ("unknown" if phase == "waiting_suspended" else
                       "terminal" if phase in {"completed", "failed", "cancelled"} else "running")
    return result


def continue_run(service, route, run, body):
    """Explicit recovery of an accepted execution, never reapply the first action."""
    if set(body) != {"schemaVersion", "requestKey", "binding", "clientInstanceID"} \
            or type(body["schemaVersion"]) is not int or body["schemaVersion"] != 1:
        raise AppReplyError(400, "INVALID_APP_REPLY_CONTINUATION")
    key = reply_id(body["requestKey"])
    store = service.store
    with store.changed, store.db:
        row = store.run(run)
        command = json.loads(row["command"])
        if "appReply" not in command or encode(body["binding"]) != row["binding"] \
                or body["clientInstanceID"] != row["client"]:
            raise AppReplyError(409, "APP_REPLY_RUN_CONFLICT")
        prior = store.receipt(key, route, body)
        if prior is not None:
            return prior
        if row["phase"] != "waiting_suspended":
            raise AppReplyError(409, "APP_REPLY_RUN_NOT_SUSPENDED")
        if not callable(getattr(service.provider, "continue_app_reply", None)):
            raise AppReplyError(422, "APP_REPLY_CONTINUATION_UNSUPPORTED")
        pending = store.db.execute("SELECT COUNT(*) FROM tools WHERE run=? AND result IS NULL", (run,)).fetchone()[0]
        if pending:
            raise AppReplyError(409, "TOOLS_UNRESOLVED")
        if row["message_id"]:
            store.append(row, "assistant_completed", {"messageID": row["message_id"]})
        generation = row["generation"] + 1
        command["requestKey"] = key
        store.db.execute("UPDATE runs SET phase='streaming',command=?,message_id=NULL,"
                         "interaction=NULL,generation=? WHERE id=?", (encode(command), generation, run))
        result = store.descriptor(store.run(run), key)
        store.save_receipt(key, route, body, result)
        store.changed.notify_all()
    service.spawn(run, generation)
    return result
