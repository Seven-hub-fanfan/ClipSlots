#!/usr/bin/env python3
"""Real loopback tool requests, temporary file effects, SIGKILL and independent native recovery."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--legacy-binary", type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo / "gateway"))
from test_live import ProcessServer, EVIDENCE

root = Path(tempfile.mkdtemp(prefix="clipslots-app-reply-tools-", dir="/tmp"))
reports = []
hash_file = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
sources = {str(p.relative_to(repo)): hash_file(p) for p in (repo / "Sources").rglob("*.swift")}
try:
    for mode in ["normal", "no-activation", "changed", "crash-receipt", "crash-before-execute"]:
        directory = root / mode
        directory.mkdir()
        server = ProcessServer(token="app-reply-page-auth")
        phases = ([mode, "restore-receipt"] if mode == "crash-receipt" else
                  [mode, "restore-unknown"] if mode == "crash-before-execute" else [mode])
        try:
            original_owner = None
            for phase in phases:
                if phase.startswith("restore"):
                    server.restart(crash=True)
                with (directory / (phase + ".log")).open("w") as output:
                    result = subprocess.run([str(args.binary.resolve()), str(directory), server.root, phase],
                                            stdout=output, stderr=output, timeout=45)
                if phase.startswith("crash-"):
                    assert result.returncode == -signal.SIGKILL, (phase, result.returncode, directory)
                    database = next((directory / "reply-run").rglob("*.sqlite3"))
                    with sqlite3.connect(database) as db:
                        snapshots = json.loads(db.execute("SELECT payload FROM state WHERE key='snapshots'").fetchone()[0])
                        original_owner = next(iter(snapshots.values()))["instanceID"]
                    continue
                assert result.returncode == 0, (phase, directory)
                report = json.loads((directory / (phase + ".log")).read_text().splitlines()[-1])
                assert report["originalUnchanged"], report
                assert report["schema"] == 7, report
                assistants = {m["id"]: m for m in report["messages"] if m["role"] == "assistant"}
                tool_calls = [m for m in assistants.values() if m["toolCalls"]]
                assert len(tool_calls) == 1 and tool_calls[0]["toolCalls"][0]["id"] == "same-call-id", report
                for execution, reservation in report["reservations"].items():
                    origin = reservation["messageOrigin"]
                    assert origin["executionID"] == execution
                    if phase == "no-activation":
                        assert origin.get("scope") is None
                    else:
                        assert origin["scope"]["turnID"] == report["scope"]
                    assistant = assistants[origin["assistantID"]]
                    assert origin["runID"] == assistant["runID"]
                    assert origin.get("scope") == assistant.get("executionScope")
                    assert assistant["toolCalls"][0]["id"] == reservation["request"]["callID"]
                    if reservation["phase"] in {"completed", "reported"}:
                        message = next(m for m in report["messages"] if m["id"] == reservation["resultMessageID"])
                        assert message["toolOrigin"] == origin and message["content"] == reservation["content"]
                if phase in {"normal", "restore-receipt"}:
                    assert report["phase"] == "completed" and report["error"] is None, report
                    assert report["file"] == "reply-file🙂" and report["hostReceipts"] == 1, report
                    assert len(report["tools"]) == 1 and "written_bytes" in report["tools"][0], report
                elif phase == "restore-unknown":
                    assert report["file"] is None and report["hostReceipts"] == 0, report
                    assert report["error"] == "toolOutcomeUnknown", report
                else:
                    assert report["file"] is None and report["hostReceipts"] == 0, report
                    assert len(report["tools"]) == 1 and "NOT_AUTHORIZED" in report["tools"][0], report
                if phase.startswith("restore"):
                    assert report["activated"] is False and report["owner"] == original_owner, report
                    if phase == "restore-receipt":
                        assert report["reconciledPhase"] == "waiting_suspended", report
                else:
                    assert report["activated"] == (phase != "no-activation"), report
                if report["owner"]:
                    assert report["owner"] != report["sourceOwner"], report
                if phase == "normal" and args.legacy_binary:
                    legacy = directory / "legacy-reader-copy"
                    shutil.copytree(directory, legacy, ignore=shutil.ignore_patterns("legacy-reader-copy"))
                    database = next((legacy / "reply-run").rglob("*.sqlite3"))
                    with sqlite3.connect(database) as db:
                        before = {table: db.execute("SELECT * FROM " + table).fetchall()
                                  for table in ["state", "messages", "tools", "events", "chunks"]}
                    with (directory / "legacy-reader.log").open("w") as output:
                        old = subprocess.run([str(args.legacy_binary.resolve()), str(legacy), server.root, "restore-unknown"],
                                             stdout=output, stderr=output, timeout=45)
                    assert old.returncode != 0 and "journalUnavailable" in (directory / "legacy-reader.log").read_text()
                    with sqlite3.connect(database) as db:
                        after = {table: db.execute("SELECT * FROM " + table).fetchall() for table in before}
                    assert after == before
                    report["actualSchema6ReaderRejected"] = True
                with sqlite3.connect(server.db) as db:
                    assert db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                    assert db.execute("SELECT COUNT(*) FROM app_replies").fetchone()[0] == 1
                    reply_run = db.execute("SELECT run FROM app_replies").fetchone()[0]
                    assert db.execute("SELECT COUNT(*) FROM tools WHERE run=?", (reply_run,)).fetchone()[0] == 1
                    command = json.loads(db.execute("SELECT command FROM runs WHERE id=?", (reply_run,)).fetchone()[0])
                    assert len(command["tools"]) == 3
                reports.append(report)
        finally:
            server.stop()
            with sqlite3.connect(server.db) as db, sqlite3.connect(directory / "server.sqlite") as target:
                db.backup(target)
finally:
    subject = {"root": str(root), "serverEvidence": str(EVIDENCE), "reports": reports,
               "binarySHA256": hash_file(args.binary), "sources": sources,
               "sourceUnchanged": all(hash_file(repo / p) == h for p, h in sources.items()),
               "remoteProviderRequests": 0, "actualHTTP": True, "actualTemporaryFileEffects": True,
               "actualSIGKILL": True, "M06Accepted": False, "goalComplete": False}
    (root / "subject.json").write_text(json.dumps(subject, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"root": str(root), "reports": len(reports), "modes": [r["mode"] for r in reports]}))
