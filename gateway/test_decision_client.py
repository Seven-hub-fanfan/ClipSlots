#!/usr/bin/env python3
"""Current Swift client against real synthetic-only HTTP and SQLite."""
import argparse
import hashlib
import json
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
from test_live import ProcessServer, EVIDENCE

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True, type=Path)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
repo = Path(__file__).resolve().parent.parent
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-decision-client-", dir="/tmp"))
sources = {str(p.relative_to(repo)): sha(p) for folder in ["Sources", "gateway", "scripts/gateway-fixtures"]
           for p in (repo / folder).rglob("*") if p.is_file() and p.suffix in [".swift", ".py", ".md"]}
reports = []
try:
    for mode in ["normal", "loss", "unknown", "absent", "conflict", "expire", "malformed",
                 "clockfast", "clockslow", "pendingrestart", "batch", "batchdecline", "secret", "crash",
                 "preflight", "savedcrash", "savedexpire", "initialsave"]:
        # Additional cases retain exact bytes across an unsent-answer crash,
        # exercise real SQLite quota rollback and explicit first dispatch.
        directory = root / mode
        directory.mkdir()
        server = ProcessServer(token="decision-client-auth")
        try:
            with (directory / "run.log").open("w") as log:
                result = subprocess.run([str(binary), mode, server.root, str(directory)],
                                        stdout=log, stderr=log, timeout=40)
            expected = -signal.SIGKILL if mode in ["crash", "savedcrash"] else 0
            assert result.returncode == expected, (mode, result.returncode, directory)
            if mode in ["crash", "savedcrash"]:
                server.restart(crash=True)
                with (directory / "restore.log").open("w") as log:
                    restore = "restoresaved" if mode == "savedcrash" else "restore"
                    result = subprocess.run([str(binary), restore, server.root, str(directory)],
                                            stdout=log, stderr=log, timeout=40)
                assert result.returncode == 0, ("restore", directory)
                reports.append(json.loads((directory / (restore + "-report.json")).read_text()))
            else:
                reports.append(json.loads((directory / (mode + "-report.json")).read_text()))
            with sqlite3.connect(server.db) as db:
                db.backup(sqlite3.connect(directory / "server.sqlite"))
                decisions = db.execute("SELECT decision FROM interactions").fetchall()
                accepted = [json.loads(row[0]) for row in decisions if row[0] is not None]
                assert len(decisions) == 1 and len(accepted) <= 1
                if mode not in ["absent", "unknown", "expire", "savedexpire", "malformed"]:
                    assert len(accepted) == 1
                if accepted and mode != "conflict":
                    messages = json.loads(db.execute("SELECT messages FROM runs").fetchone()[0])
                    answer = messages[accepted[0]["messageIndex"]]["content"]
                    record = directory / ("normal-requests.json" if mode == "normal" else mode + "-requests.json")
                    if mode not in ["crash", "savedcrash"]:
                        posts = [json.loads(r["body"]) for r in json.loads(record.read_text())
                                 if r["method"] == "POST" and r["url"].endswith("/continue")]
                        assert len(posts) == 1 and posts[0]["requestKey"] == accepted[0]["requestKey"]
                        assert hashlib.sha256(posts[0]["answerJSON"].encode()).hexdigest() == accepted[0]["answerSHA256"]
                        assert json.loads(posts[0]["answerJSON"]) == json.loads(answer)
        finally:
            server.stop()
    assert all(r["failures"] == r["remoteProviderRequests"] == 0 for r in reports)
finally:
    summary = {"root": str(root), "serverEvidence": str(EVIDENCE), "reports": reports,
               "source": sources, "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
               "binarySHA256": sha(binary), "remoteProviderRequests": 0, "realClientSIGKILL": True,
               "M05Accepted": False, "goalComplete": False}
    (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"root": str(root), "cases": len(reports),
                      "assertions": sum(r["assertions"] for r in reports)}), flush=True)
