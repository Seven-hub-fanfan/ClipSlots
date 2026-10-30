"""Create deterministic 10-slot groups under a new isolated directory."""
import argparse
import json
from pathlib import Path
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument("--root", type=Path, required=True)
p.add_argument("--count", type=int, choices=[20000, 50000], required=True)
a = p.parse_args()
if not str(a.root).startswith("/private/tmp/clipslots-search-") or a.root.exists():
    raise SystemExit("A new /private/tmp/clipslots-search-* root is required")
a.root.mkdir()
start = time.monotonic()
for number in range(a.count):
    slot = number % 10 + 1
    directory = a.root / f"g{number // 10:05d}" / str(slot)
    item = directory / "item_0"
    item.mkdir(parents=True)
    body = f"ALL_中文 {number:05d} cafe\u0301 👩🏽‍💻 before\0AFTER_NULL\n"
    body += "完整正文包含骑马摄影和尾部检索，保留全部内容。\n" * 24
    if number < 10:
        body += "TEN_HITS"
    (item / "public.utf8-plain-text.bin").write_bytes(body.encode())
    (directory / "content.json").write_text(json.dumps({
        "contentId": str(uuid.UUID(int=number + 1)), "updatedAt": 1.0,
        "itemTypeOrder": [["public.utf8-plain-text"]]
    }))
    (directory / "label.txt").write_text(f"标签 {number:05d}")
print(json.dumps({"root": str(a.root), "slots": a.count,
                  "creationSeconds": time.monotonic() - start}))
