#!/usr/bin/env python3
"""Deterministic CLI boundary fixture; selected only by the DEBUG regression runner."""
import json
import os
import pathlib
import sys
import time
import uuid
import atexit
import hashlib
import fcntl

root = pathlib.Path(os.environ["CLIPSLOTS_FIXTURE_DIR"])
def count_attempt(key):
    path = root / ("counter-" + hashlib.sha256(key.encode()).hexdigest())
    with path.open("a+") as counter:
        fcntl.flock(counter, fcntl.LOCK_EX)
        counter.seek(0)
        attempt = int(counter.read() or "0") + 1
        counter.seek(0)
        counter.truncate()
        counter.write(str(attempt))
        counter.flush()
    return attempt

args = sys.argv[1:]
if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1":
    def record_process(event):
        with (root / "process-events.jsonl").open("a") as log:
            log.write(json.dumps({"event": event, "pid": os.getpid(), "at": time.time()}) + "\n")
    record_process("start")
    atexit.register(record_process, "end")
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["auth", "status"]:
    result = {"username": "canvas-test"}
elif args[:2] in (["model", "list"], ["model", "describe"]):
    if os.environ.get("CLIPSLOTS_GENERATION_CHAIN_PROBE") == "1":
        result = json.loads(pathlib.Path(os.environ["CLIPSLOTS_CHAIN_MODEL_CATALOG"]).read_text())
        if args[1] == "describe":
            result = next(item for item in result if item["id"] == args[2])
        print(json.dumps(result))
        sys.exit(0)
    result = [
        {"id": ident, "name": name, "generationTypes": [cap], "parameters": [
            {"name": "ratio", "options": [{"value": "16:9"}, {"value": "1:1"}, {"value": "9:16"}]}
        ]}
        for ident, name, cap in [
            ("seedream45", "Seedream 4.5", "text-2-image"),
            ("seedance2-mini", "Seedance 2 Mini", "text-2-video")
        ]
    ]
    if os.environ.get("CLIPSLOTS_REPLICA_PROBE") == "1" or os.environ.get("CLIPSLOTS_NODE_DESIGN_PROBE") == "1":
        result.append({
            "id": "seedream5", "name": "Seedream 5.0", "enabled": True,
            "generationTypes": ["text-2-image", "image-2-image"],
            "parameters": [
                {"name": "ratio", "options": [{"value": ratio} for ratio in
                    ["1:1", "4:3", "3:4", "16:9", "9:16", "3:2", "2:3", "21:9"]]},
                {"name": "width", "min": 16, "max": 16384},
                {"name": "height", "min": 16, "max": 16384},
            ],
        })
    if os.environ.get("CLIPSLOTS_NODE_DESIGN_PROBE") == "1":
        # Published Seedance 2 Mini catalog captured on 2026-10-11.
        result[1]["parameters"] = [
            {"name": "ratio", "options": [{"value": ratio} for ratio in
                ["adaptive", "16:9", "4:3", "1:1", "3:4", "9:16", "21:9"]]},
            {"name": "resolution", "defaultValue": "720p",
             "options": [{"value": "480p"}, {"value": "720p"}]},
            {"name": "generate_audio", "type": "boolean", "defaultValue": True},
            {"name": "duration", "type": "number", "min": 4, "max": 15, "step": 1},
        ]
    if os.environ.get("CLIPSLOTS_INPUT_UPLOAD_PROBE") == "1":
        result[1]["generationTypes"].append("image-to-video")
        result[1]["references"] = {"roles": [
            {"role": "first_frame", "maxCount": 1},
            {"role": "last_frame", "maxCount": 1},
            {"role": "reference_image", "maxCount": 4},
        ]}
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1":
        result[0]["generationTypes"].append("image-2-image")
    if args[1] == "describe":
        result = next(item for item in result if item["id"] == args[2])
elif args[:2] == ["task", "get"]:
    ident = args[2]
    if "batch-query" in ident and count_attempt("query-" + ident) == 1:
        print("fixture: temporary query failure", file=sys.stderr)
        sys.exit(1)
    if os.environ.get("CLIPSLOTS_CANVAS_AGENT_GENERATION_PROBE") == "1":
        with (root / "attempt-events.jsonl").open("a") as log:
            log.write(json.dumps({"event": "query", "task": ident, "at": time.time()}) + "\n")
    suffix = "mp4" if ident.startswith("video") else "png"
    result = {"taskInfo": {"task_status": 2, "task_id": ident, "results": [
        {"content": f"http://127.0.0.1:{os.environ['CLIPSLOTS_FIXTURE_PORT']}/fixture.{suffix}"}
    ]}}
    if os.environ.get("CLIPSLOTS_GENERATION_CHAIN_PROBE") == "1":
        task = json.loads((root / (ident + ".json")).read_text())
        result["taskInfo"]["results"][0]["content"] = (
            f"http://127.0.0.1:{os.environ['CLIPSLOTS_FIXTURE_PORT']}/{task['file']}")
    if "batch-fail" in ident:
        result = {"taskInfo": {"task_status": 3, "task_id": ident, "fail_reason": "fixture generation failed"}}
    if (root / (ident + ".png")).exists():
        result["taskInfo"]["results"][0]["content"] = (
            f"http://127.0.0.1:{os.environ['CLIPSLOTS_FIXTURE_PORT']}/{ident}.png")
    marker_file = root / (ident + ".attempt.json")
    if marker_file.exists():
        marker = json.loads(marker_file.read_text())
        if "CANVAS_SELECTION_PARALLEL" in marker["prompt"]:
            simultaneous = [
                item for path in root.glob("*.attempt.json")
                if "CANVAS_SELECTION_PARALLEL" in (item := json.loads(path.read_text()))["prompt"]
            ]
            if len(simultaneous) < 4 and time.time() - marker["at"] < 1:
                result = {"taskInfo": {"task_status": 1, "task_id": ident}}
            else:
                with (root / "attempt-events.jsonl").open("a") as log:
                    log.write(json.dumps({"event": "completed", "task": ident,
                                          "at": time.time(), "submitted": len(simultaneous)}) + "\n")
elif "generate" in args:
    prompt = args[args.index("--prompt") + 1] if "--prompt" in args else ""
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_SLOW" in prompt:
        time.sleep(0.5)
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_UNKNOWN" in prompt:
        print("fixture: response interrupted after submission")
        sys.exit(0)
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_RATE" in prompt:
        import fcntl
        with (root / "rate-attempts").open("a+") as counter:
            fcntl.flock(counter, fcntl.LOCK_EX)
            counter.seek(0)
            attempt = int(counter.read() or "0") + 1
            counter.seek(0)
            counter.truncate()
            counter.write(str(attempt))
        if "BATCH_RATE_ALWAYS" in prompt or attempt < 3:
            print("API error (429): Too many requests", file=sys.stderr)
            sys.exit(1)
    fails = os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_FAIL" in prompt
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_FAIL_ONCE" in prompt:
        fails = count_attempt("submit-" + prompt) == 1
    fails = fails or (os.environ.get("CLIPSLOTS_CANVAS_AGENT_GENERATION_PROBE") == "1"
                      and "CANVAS_AGENT_FAIL" in prompt)
    marker = "batch-fail" if fails else ""
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_QUERY_FAIL_ONCE" in prompt:
        marker = "batch-query"
    ident = ("video" if "video" in args else "image") + marker + uuid.uuid4().hex[:12]
    if os.environ.get("CLIPSLOTS_CANVAS_AGENT_GENERATION_PROBE") == "1":
        attempt = {"event": "submitted", "task": ident, "prompt": prompt, "at": time.time()}
        (root / (ident + ".attempt.json")).write_text(json.dumps(attempt))
        with (root / "attempt-events.jsonl").open("a") as log:
            log.write(json.dumps(attempt) + "\n")
        if "image" in args and not fails:
            import hashlib
            import struct
            import zlib
            def chunk(kind, data):
                return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
            color = hashlib.sha256(prompt.encode()).digest()[:3]
            image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 72, 8, 2, 0, 0, 0))
            image += chunk(b"IDAT", zlib.compress((b"\x00" + color * 128) * 72)) + chunk(b"IEND", b"")
            (root / (ident + ".png")).write_bytes(image)
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_PARALLEL" in prompt:
        import hashlib
        import struct
        import zlib
        time.sleep(0.15)
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        color = hashlib.sha256(prompt.encode()).digest()[:3]
        image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        image += chunk(b"IDAT", zlib.compress(b"\x00" + color)) + chunk(b"IEND", b"")
        (root / (ident + ".png")).write_bytes(image)
    if os.environ.get("CLIPSLOTS_GENERATION_CHAIN_PROBE") == "1":
        import subprocess
        parsed = subprocess.check_output(
            ["node", os.environ["CLIPSLOTS_CHAIN_PARAMETER_DRIVER"], json.dumps(args)], text=True)
        parameters = json.loads(parsed)
        from PIL import Image
        if args[1] == "image":
            width, height = parameters.get("width", 2048), parameters.get("height", 2048)
            filename = ident + ".png"
            # A different deterministic image per task catches wrong-thumbnail
            # reuse and any previous-result leakage in persisted/downloaded bytes.
            color = "#" + ident[-6:]
            if os.environ.get("CLIPSLOTS_CHAIN_MODE") == "independence":
                # Neutral shades avoid display P3/sRGB gamut conversion affecting
                # the screen identity assertion; every attempt has its own value.
                import fcntl
                with (root / "image-sequence").open("a+") as sequence_file:
                    fcntl.flock(sequence_file, fcntl.LOCK_EX)
                    sequence_file.seek(0)
                    sequence = int(sequence_file.read() or "0")
                    sequence_file.seek(0)
                    sequence_file.truncate()
                    sequence_file.write(str(sequence + 1))
                    sequence_file.flush()
                shade = min(232, 24 + sequence * 27)
                color = "#{0:02x}{0:02x}{0:02x}".format(shade)
            image = Image.new("RGB", (width, height), color)
            from PIL import ImageDraw
            draw = ImageDraw.Draw(image)
            draw.ellipse((width//4, height//4, 3*width//4, 3*height//4), fill="#f4f0e6")
            image.save(root / filename)
        else:
            filename = "fixture.mp4"
        task = {"parameters": parameters, "file": filename, "arguments": args}
        (root / (ident + ".json")).write_text(json.dumps(task))
        with (root / "effective-parameters.jsonl").open("a") as log:
            log.write(json.dumps(task) + "\n")
    result = {"success": True, "taskId": ident}
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_ACCEPTED_EXIT" in prompt:
        print(json.dumps(result), flush=True)
        print("PRIVATE_PROCESS_STDERR_TOKEN_BODY", file=sys.stderr, flush=True)
        sys.exit(1)
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_ACCEPTED_TAIL" in prompt:
        print(json.dumps(result), flush=True)
        print("{broken tail", flush=True)
        sys.exit(0)
    if os.environ.get("CLIPSLOTS_BATCH_PROBE") == "1" and "BATCH_CONFLICTING_RECEIPTS" in prompt:
        print(json.dumps(result), flush=True)
        print(json.dumps({"taskId": "other-" + ident}), flush=True)
        sys.exit(0)
else:
    print(json.dumps({"error": "Unexpected fixture command", "args": args}))
    sys.exit(1)
print(json.dumps(result))
