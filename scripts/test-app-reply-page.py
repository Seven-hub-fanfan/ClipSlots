#!/usr/bin/env python3
"""Actual App/WebKit/HTTP/SQLite App reply and independent process recovery."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--mode", action="append", choices=[
    "normal", "failed", "before", "after", "permission", "session", "readonly", "prepare",
    "tools-normal", "tools-second", "tools-second-denied", "tools-changed", "tools-prepare",
    "lifecycle-gated", "lifecycle-close", "lifecycle-reload", "lifecycle-session", "lifecycle-unknown", "lifecycle-pending"])
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo / "gateway"))
from test_live import ProcessServer, EVIDENCE

binary = args.binary.resolve(strict=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-", dir="/tmp"))
contents = root / "App Reply Page Test.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
            CFBundleName="App Reply Page Test", ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
reports = []
try:
    for mode in args.mode or ["normal", "failed", "before", "after", "permission", "session", "readonly", "prepare",
                             "tools-normal", "tools-second", "tools-second-denied", "tools-changed", "tools-prepare",
                             "lifecycle-gated", "lifecycle-close", "lifecycle-reload", "lifecycle-session", "lifecycle-unknown",
                             "lifecycle-pending"]:
        server = ProcessServer(token="app-reply-page-auth")
        directory = root / mode
        directory.mkdir()
        try:
            phases = ([mode, "restore"] if mode == "prepare" else
                      [mode, "tools-restore"] if mode == "tools-prepare" else
                      [mode, "tools-restore-second"] if mode == "tools-second" else
                      [mode, "tools-restore-denied"] if mode == "tools-second-denied" else
                      [mode, "tools-restore-completed"] if mode == "tools-normal" else [mode])
            for phase in phases:
                if phase == "restore" or phase.startswith("tools-restore"):
                    server.restart(crash=True)
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(("CLIPSLOTS_", "CANVAS_", "GATEWAY_", "APP_REPLY_"))}
                env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_APP_REPLY_PAGE_REGRESSION="1",
                           CLIPSLOTS_DATA_DIR=str(directory), CLIPSLOTS_CONFIG_PATH=str(directory / "config.toml"),
                           APP_REPLY_PAGE_MODE=phase, APP_REPLY_PAGE_GATEWAY=server.root)
                with (directory / (phase + ".log")).open("w") as output:
                    result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env,
                                            stdout=output, stderr=output, timeout=60)
                report = json.loads((directory / "report.json").read_text())
                shutil.copy2(directory / "report.json", directory / (phase + "-report.json"))
                reports.append(report)
                assert result.returncode == 0 and not report["failures"], (mode, phase, directory, report)
                shutil.copy2(directory / "wire.json", directory / (phase + "-wire.json"))
                wire = json.loads((directory / (phase + "-wire.json")).read_text())
                replies = [r for r in wire if r["method"] == "POST" and r["url"].endswith("/app-replies")]
                for request in replies:
                    body = json.loads(request["body"])
                    assert request["key"] == body["requestKey"]
                    assert body["binding"]["projectID"] == body["binding"]["canvasID"]
                    assert json.loads(body["replyJSON"])["reply_id"].lower() == request["key"]
                original_bodies = {}
                for request in replies:
                    assert original_bodies.setdefault(request["key"], request["body"]) == request["body"]
                if mode.startswith("tools-second") and not phase.startswith("tools-restore"):
                    assert len(replies) == len(original_bodies) == 2
                if phase == "restore":
                    assert not replies
                    continuations = [r for r in wire if r["method"] == "POST"
                                     and r["url"].endswith("/app-reply-continue")]
                    assert len(continuations) == 1 and "history" not in json.loads(continuations[0]["body"])
                if phase.startswith("tools-restore"):
                    assert not replies
                    assert not [r for r in wire if r["method"] == "POST" and r["url"].endswith("/app-reply-continue")]
                with sqlite3.connect(server.db) as db:
                    assert db.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                    for reply_id, body, run in db.execute("SELECT id,body,run FROM app_replies"):
                        body = json.loads(body)
                        assert json.loads(body["replyJSON"])["reply_id"].lower() == reply_id
                        command, messages = db.execute("SELECT command,messages FROM runs WHERE id=?", (run,)).fetchone()
                        assert json.loads(command)["appReply"]["reply"]["reply_id"].lower() == reply_id
                        assert len([m for m in json.loads(messages) if m["role"] == "user"]) == 1
                        if mode.startswith("tools-"):
                            original = body["originRunID"]
                            original_command = json.loads(db.execute("SELECT command FROM runs WHERE id=?",
                                                                     (original,)).fetchone()[0])
                            assert json.loads(command)["tools"] == original_command["tools"]
                            assert db.execute("SELECT COUNT(*) FROM tools WHERE run=?", (run,)).fetchone()[0] == 1
        finally:
            server.stop()
            with sqlite3.connect(server.db) as db, sqlite3.connect(directory / "server.sqlite") as copy:
                db.backup(copy)
finally:
    subject = {"root": str(root), "serverEvidence": str(EVIDENCE), "binarySHA256": sha(binary),
               "sources": sources, "reports": reports,
               "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
               "productionProtected": protected,
               "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
               "remoteProviderRequests": 0, "actualWebKit": True, "actualHTTP": True,
               "foregroundAccepted": False, "M06Accepted": False, "goalComplete": False}
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({"root": str(root), "cases": len(reports),
                      "passed": sum(r["passed"] for r in reports),
                      "failures": [f for r in reports for f in r["failures"]]}), flush=True)
