#!/usr/bin/env python3
"""Real App Store/tool chain, separate process restarts and supervised SIGKILL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    checks, cases, failures = [], [], []

    def check(value, name):
        checks.append({"name": name, "passed": bool(value)})
        if not value:
            failures.append(name)

    def setup(label):
        root = Path(tempfile.mkdtemp(prefix="clipslots-directory-journal-", dir="/private/tmp"))
        cases.append({"label": label, "root": str(root), "calls": []})
        run(root, "setup")
        return root

    def run(root, operation, *extra):
        started = time.monotonic()
        result = subprocess.run([args.binary, str(root), operation, *extra],
                                capture_output=True, text=True, timeout=90)
        call = {"operation": operation, "exitCode": result.returncode, "seconds": time.monotonic() - started,
                "stdout": result.stdout, "stderr": result.stderr}
        next(c for c in cases if c["root"] == str(root))["calls"].append(call)
        if result.returncode:
            raise RuntimeError(f"{operation}: native exit {result.returncode}: {result.stderr[:1200]}")
        return json.loads(result.stdout.strip().splitlines()[-1])

    def kill(root, operation, checkpoint, *extra):
        result = subprocess.Popen([args.binary, str(root), "crash-" + operation, checkpoint, *extra],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        selector.register(result.stdout, selectors.EVENT_READ)
        try:
            if not selector.select(15):
                raise RuntimeError(f"checkpoint timeout {operation}/{checkpoint}")
            marker = result.stdout.readline().decode()
            if json.loads(marker).get("checkpoint") != checkpoint:
                raise RuntimeError(f"wrong checkpoint {marker}")
            os.kill(result.pid, signal.SIGKILL)
            out, err = result.communicate(timeout=10)
        finally:
            selector.close()
            if result.poll() is None:
                result.kill()
                result.communicate(timeout=10)
        next(c for c in cases if c["root"] == str(root))["calls"].append({
            "operation": "crash-" + operation, "checkpoint": checkpoint, "exitCode": result.returncode,
            "stdout": marker + out.decode(), "stderr": err.decode()})
        check(result.returncode == -signal.SIGKILL, f"actual SIGKILL {operation}/{checkpoint}")

    def selected(root, name):
        return root / "selected" / name

    def records(root):
        return run(root, "history").get("records", [])

    try:
        root = setup("single write and restart")
        value = run(root, "write")
        undo = value["undo_id"]
        check(value.get("persistent") is True and selected(root, "original.txt").read_text() == "WRITTEN🙂",
              "actual local_write_file returns durable identity")
        check(records(root)[0]["undo_id"] == undo, "separate process Store reopen discovers written undo")
        check(not run(root, "other-session")["records"], "other session cannot discover journal")
        check(not run(root, "other-project")["records"], "other project cannot discover journal")
        check(run(root, "other-session-undo", undo).get("tool_failed") is True
              and run(root, "other-project-undo", undo).get("tool_failed") is True
              and selected(root, "original.txt").read_text() == "WRITTEN🙂",
              "known undo id cannot cross conversation or project owner")
        for operation in ["other-session", "other-project"]:
            check(run(root, operation).get("persistent") is True, "owner-specific history " + operation)
        restored = run(root, "undo", undo)
        check(restored["complete"] and selected(root, "original.txt").read_text() == "ORIGINAL🙂"
              and selected(root, "original.txt").stat().st_mode & 0o777 == 0o755,
              "separate process approved undo restores exact bytes and executable mode")
        check(run(root, "undo", undo).get("tool_failed") is True, "consumed original id fails after restart")
        check(not records(root), "completed undo leaves bounded empty active log")
        check(run(root, "roundtrip")["complete"] and not selected(root, "same-call.txt").exists(),
              "new invocation object in same process resolves durable undo")

        root = setup("partial conflict")
        value = run(root, "new")
        selected(root, "created.txt").write_text("USER-LATER")
        before = selected(root, "created.txt").stat().st_ino
        check(records(root)[0]["execution_unknown"] is True, "later user edit becomes execution unknown")
        undo = run(root, "undo", value["undo_id"])
        check(not undo["complete"] and undo["undo_id"] != value["undo_id"]
              and selected(root, "created.txt").read_text() == "USER-LATER"
              and selected(root, "created.txt").stat().st_ino == before
              and not selected(root, "independent.txt").exists(),
              "reverse undo preserves later edit and reverts independent item")
        check(run(root, "undo", value["undo_id"]).get("tool_failed") is True,
              "partial conflict consumes old id across process restart")
        root = setup("permission conflict")
        value = run(root, "write")
        selected(root, "original.txt").chmod(0o640)
        check(not run(root, "undo", value["undo_id"])["complete"]
              and selected(root, "original.txt").read_text() == "WRITTEN🙂"
              and selected(root, "original.txt").stat().st_mode & 0o777 == 0o640,
              "later user permission change is preserved as inverse conflict")
        root = setup("cancelled inverse")
        value = run(root, "new")
        outcome = run(root, "cancel-undo", value["undo_id"])
        check(not outcome["complete"] and selected(root, "created.txt").exists()
              and not selected(root, "independent.txt").exists(),
              "inverse cancellation stops between real items and retains successor")
        check(run(root, "undo", outcome["undo_id"])["complete"] and not selected(root, "created.txt").exists(),
              "cancelled inverse can be explicitly completed after restart")

        for operation in ["organize", "chain"]:
            root = setup(operation)
            value = run(root, operation)
            check(value["complete"], "actual durable move " + operation)
            check(run(root, "undo", value["undo_id"])["complete"]
                  and selected(root, "move.txt").read_bytes() == b"MOVE"
                  and not selected(root, "organized").exists() and not selected(root, "final.txt").exists(),
                  "reverse ordering across process restart " + operation)

        root = setup("moved bookmark")
        value = run(root, "write")
        (root / "selected").rename(root / "relocated")
        history = records(root)
        restored = run(root, "undo", value["undo_id"])
        check(history[0]["undo_id"] == value["undo_id"] and restored["complete"]
              and (root / "relocated/original.txt").read_text() == "ORIGINAL🙂",
              "actual OS moved bookmark retains root identity and owner across restart")

        root = setup("explicit reauthorization")
        value = run(root, "write")
        check(not run(root, "reauthorize")["records"], "explicit authorization rotates journal owner")
        check(run(root, "undo", value["undo_id"]).get("tool_failed") is True
              and selected(root, "original.txt").read_text() == "WRITTEN🙂",
              "replaced authorization cannot consume previous owner undo")
        root = setup("sequential write lineage")
        first = run(root, "write")["undo_id"]
        second = run(root, "write-again")["undo_id"]
        check(run(root, "undo", second)["complete"] and selected(root, "original.txt").read_text() == "WRITTEN🙂",
              "second write inverse restores first write bytes")
        check(run(root, "undo", first)["complete"] and selected(root, "original.txt").read_text() == "ORIGINAL🙂",
              "new restored inode propagates only proven committed undo lineage")

        crash_matrix = [
            ("write", s) for s in ["write-recorded", "write-intent", "write-ready", "write-filesystem", "write-applied"]
        ] + [
            ("organize", s) for s in ["mkdir-intent", "mkdir-ready", "mkdir-filesystem", "mkdir-applied",
                                      "move-intent", "move-filesystem", "move-applied"]
        ] + [
            ("undo", s) for s in ["undo-claimed", "undo-intent", "undo-ready", "undo-filesystem", "undo-applied"]
        ]
        for operation, stage in crash_matrix:
            root = setup(f"SIGKILL {operation} {stage}")
            extra = []
            original_id = None
            if operation == "undo":
                original_id = run(root, "write")["undo_id"]
                extra = [original_id]
            kill(root, operation, stage, *extra)
            snapshot = {p.name: p.read_bytes() for p in (root / "selected").iterdir() if p.is_file()}
            history = records(root)
            check(snapshot == {p.name: p.read_bytes() for p in (root / "selected").iterdir() if p.is_file()},
                  f"recovery never replays filesystem {operation}/{stage}")
            if operation == "undo":
                check(run(root, "undo", original_id).get("tool_failed") is True,
                      f"interrupted inverse original id consumed {stage}")
            complete = True
            for record in history:
                complete = complete and run(root, "undo", record["undo_id"])["complete"]
            check(complete and selected(root, "original.txt").read_text() == "ORIGINAL🙂"
                  and selected(root, "move.txt").read_bytes() == b"MOVE"
                  and not selected(root, "organized").exists()
                  and not list((root / "selected").glob(".clipslots-*")) and not records(root),
                  f"explicit inverse restores exact disk after {operation}/{stage}")

        root = setup("edited crash artifact")
        kill(root, "write", "write-filesystem")
        artifacts = list((root / "selected").glob(".clipslots-write-*"))
        check(len(artifacts) == 1, "interrupted exchange preserves displaced entry")
        artifacts[0].write_text("USER-EDITED-ARTIFACT")
        history = records(root)
        undone = run(root, "undo", history[0]["undo_id"])
        check(not undone["complete"] and selected(root, "original.txt").read_text() == "ORIGINAL🙂"
              and artifacts[0].read_text() == "USER-EDITED-ARTIFACT" and records(root),
              "explicit inverse retains edited displaced artifact with discoverable successor")
        root = setup("early mkdir unknown")
        kill(root, "organize", "mkdir-created")
        history = records(root)
        artifacts = list((root / "selected").glob(".clipslots-mkdir-*"))
        check(history[0]["execution_unknown"] and len(artifacts) == 1,
              "crash before staged directory identity persists as unknown")
        check(not run(root, "undo", history[0]["undo_id"])["complete"] and artifacts[0].exists()
              and selected(root, "move.txt").read_bytes() == b"MOVE",
              "unproven staged identity is preserved without blind deletion")

        root = setup("new-file inverse crash")
        value = run(root, "new")
        kill(root, "undo", "undo-filesystem", value["undo_id"])
        history = records(root)
        check(run(root, "undo", history[0]["undo_id"])["complete"]
              and not selected(root, "created.txt").exists() and not selected(root, "independent.txt").exists()
              and not list((root / "selected").glob(".clipslots-*")),
              "interrupted new-file quarantine is reconciled and explicitly cleaned")

        root = setup("occupied inverse directory")
        value = run(root, "organize")
        selected(root, "organized/user.txt").write_text("USER-FILE")
        result = run(root, "undo", value["undo_id"])
        check(not result["complete"] and selected(root, "organized/user.txt").read_text() == "USER-FILE"
              and selected(root, "move.txt").read_bytes() == b"MOVE",
              "occupied created directory is retained while independent reverse move completes")

        root = setup("journal symlink")
        run(root, "history")
        private = root / "app-private/agent-directory-journal"
        private.rename(root / "retained-journal")
        os.symlink(root / "retained-journal", private)
        check(run(root, "new").get("tool_failed") is True
              and not selected(root, "created.txt").exists(),
              "App-private journal directory symlink fails closed")

        root = setup("corrupt journal")
        run(root, "write")
        journal = next((root / "app-private/agent-directory-journal").glob("*.json"))
        journal.write_bytes(b"CORRUPT-UNDO-BYTES")
        before = selected(root, "original.txt").read_bytes()
        check(run(root, "history").get("tool_failed") is True
              and run(root, "new").get("tool_failed") is True
              and journal.read_bytes() == b"CORRUPT-UNDO-BYTES"
              and selected(root, "original.txt").read_bytes() == before
              and not selected(root, "created.txt").exists(),
              "corrupt journal fails closed and preserves original log bytes")

        root = setup("durable pressure")
        result = run(root, "stress")
        check(result["complete"] and result["writes"] == 400
              and not list((root / "selected").glob("pressure-*")) and not records(root),
              "400 real writes and inverses across recreated production Store objects")
        checks.append({"name": "pressure timing", "passed": True, "seconds": result["seconds"],
                       "scope": "one 32GiB ARM64 local disk sample; not GUI/low-memory evidence"})
        root = setup("persistent record budget")
        result = run(root, "record-limit")
        check(result["successful"] == 32 and result["rejected"] and len(result["history"]["records"]) == 32
              and not selected(root, "overflow.txt").exists(),
              "durable 32-record limit survives invocation recreation without evicting pending undo")
        root = setup("persistent byte budget")
        result = run(root, "byte-limit")
        check(result["successful"] == 4 and result["overflow"]["items"][0]["error_code"] == "TOO_LARGE"
              and selected(root, "original.txt").read_text() == "ORIGINAL🙂"
              and len(result["history"]["records"]) == 4,
              "durable 4MiB original-byte budget rejects before mutation and retains all previous records")
        for case in cases:
            journal_root = Path(case["root"]) / "app-private/agent-directory-journal"
            if journal_root.exists():
                check(journal_root.stat().st_mode & 0o777 == 0o700, "private journal directory mode " + case["label"])
                check(all(p.stat().st_mode & 0o777 == 0o600 for p in journal_root.iterdir()),
                      "owner-only journal files " + case["label"])
    except Exception as error:
        failures.append(str(error))
    files = []
    for case in cases:
        for path in Path(case["root"]).rglob("*"):
            if path.is_file():
                files.append({"root": case["root"], "path": str(path.relative_to(case["root"])),
                              "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    report = {"binary": args.binary, "binarySHA256": hashlib.sha256(Path(args.binary).read_bytes()).hexdigest(),
              "checks": checks, "failures": failures, "cases": cases, "files": files}
    Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"checks": len(checks), "cases": len(cases), "failures": failures}, ensure_ascii=False))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
