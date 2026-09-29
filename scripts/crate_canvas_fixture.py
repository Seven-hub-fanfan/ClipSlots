#!/usr/bin/env python3
"""Deterministic CLI boundary fixture; selected only by the DEBUG regression runner."""
import json
import os
import pathlib
import sys
import uuid

root = pathlib.Path(os.environ["CLIPSLOTS_FIXTURE_DIR"])
args = sys.argv[1:]
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["auth", "status"]:
    result = {"username": "canvas-test"}
elif args[:2] == ["model", "list"]:
    result = [
        {"id": ident, "name": name, "generationTypes": [cap], "parameters": [
            {"name": "ratio", "options": [{"value": "16:9"}, {"value": "1:1"}, {"value": "9:16"}]}
        ]}
        for ident, name, cap in [
            ("seedream45", "Seedream 4.5", "text-2-image"),
            ("seedance2-mini", "Seedance 2 Mini", "text-2-video")
        ]
    ]
elif args[:2] == ["model", "describe"]:
    result = {"parameters": []}
elif args[:2] == ["task", "get"]:
    ident = args[2]
    suffix = "mp4" if ident.startswith("video") else "png"
    result = {"taskInfo": {"task_status": 2, "task_id": ident, "results": [
        {"content": f"http://127.0.0.1:{os.environ['CLIPSLOTS_FIXTURE_PORT']}/fixture.{suffix}"}
    ]}}
elif "generate" in args:
    ident = ("video" if "video" in args else "image") + uuid.uuid4().hex[:12]
    result = {"success": True, "taskId": ident}
else:
    print(json.dumps({"error": "Unexpected fixture command", "args": args}))
    sys.exit(1)
print(json.dumps(result))
