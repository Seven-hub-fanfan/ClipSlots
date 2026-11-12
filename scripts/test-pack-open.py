#!/usr/bin/env python3
"""Exercise real macOS cold/warm multi-file delivery into an isolated candidate.

Run under disk_guard.py. The supplied app must use a separate bundle identifier
and ClipSlotsIsolatedCandidate=true. Never launches the production application.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bundle", type=Path, required=True)
parser.add_argument("--fixture", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
app = args.bundle.resolve(strict=True)
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info.get("ClipSlotsIsolatedCandidate") is True
assert info["CFBundleIdentifier"] != "com.clipslots.app"
binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
root = args.output.absolute()
assert not root.exists(), "Use an absent isolated output directory."
assert not subprocess.run(["pgrep", "-f", "^" + str(binary) + "$"], capture_output=True).stdout.strip(), \
    "Quit the isolated candidate before testing cold launch."
root.mkdir(parents=True)
data = root / "data"
config = root / "config.toml"
with zipfile.ZipFile(args.fixture) as archive:
    payload = {
        (n.filename if n.flag_bits & 0x800 else n.filename.encode("cp437").decode("utf-8")): archive.read(n)
        for n in archive.infolist()
    }
manifest = json.loads(payload["manifest.json"])
assert len(manifest["pages"]) == 1, "Supply the single-page pack transfer fixture."
page_id = manifest["pages"][0]["id"]
checks = {}


def verify_page(name):
    index = json.loads((data / "special_slots/index.json").read_text())
    pages = [p for p in index["pages"] if p["name"] == name]
    assert len(pages) == 1, f"{name}: absent or duplicated"
    groups = [g for g in index["specialSlots"] if g["pageId"] == pages[0]["id"]]
    expected_groups = [(path, json.loads(value)) for path, value in payload.items()
                       if path.startswith(f"pages/{page_id}/groups/") and path.endswith("/group.json")]
    assert len(groups) == len(expected_groups)
    for group_path, expected in expected_groups:
        actual = [g for g in groups if g["name"] == expected["name"]]
        assert len(actual) == 1
        actual = actual[0]
        assert actual["icon"] == expected["icon"] and actual.get("colorHex") == expected.get("colorHex")
        prefix = group_path.removesuffix("group.json") + "slots/"
        slots = [(p, json.loads(v)) for p, v in payload.items()
                 if p.startswith(prefix) and p.endswith("/slot.json")]
        for slot_path, slot in slots:
            number = slot_path.removeprefix(prefix).split("/")[0]
            folder = data / "special_slots" / actual["id"] / number
            assert (folder / "label.txt").read_text() == slot.get("label", "")
            for i, item in enumerate(slot.get("items", [])):
                for representation in item:
                    stored = folder / f"item_{i}" / (representation["type"] + ".bin")
                    assert stored.read_bytes() == base64.b64decode(representation["data"])
            expected_attachments = {
                a["name"]: payload[slot_path.removesuffix("slot.json") + "attachments/" + a["file"]]
                for a in slot.get("attachments", [])
            }
            attachment_file = folder / "attachments.json"
            attachments = json.loads(attachment_file.read_text()) if attachment_file.exists() else []
            actual_attachments = {}
            for attachment in attachments:
                stored = Path(attachment["storagePath"])
                assert stored.resolve().is_relative_to(data.resolve())
                actual_attachments[attachment["name"]] = stored.read_bytes()
            assert actual_attachments == expected_attachments
    return True


for phase in ("cold", "warm"):
    names = [f"{phase} import 1", f"{phase} import 2"]
    paths = []
    for n, name in enumerate(names):
        values = dict(payload)
        metadata = json.loads(values["manifest.json"])
        metadata["pages"][0]["name"] = name
        values["manifest.json"] = json.dumps(metadata, ensure_ascii=False).encode()
        page_path = f"pages/{page_id}/page.json"
        page = json.loads(values[page_path])
        page["name"] = name
        values[page_path] = json.dumps(page, ensure_ascii=False).encode()
        path = root / (f"{phase} 改名 [一].bin" if n == 0 else f"{phase} 改名 二")
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            for entry, content in values.items():
                archive.writestr(entry, content)
        paths.append(path)
    command = ["open", "-a", str(app)]
    if phase == "cold":
        command += ["--env", f"CLIPSLOTS_DATA_DIR={data}", "--env", f"CLIPSLOTS_CONFIG_PATH={config}"]
    subprocess.run(command + [str(p) for p in paths], check=True)
    deadline = time.monotonic() + 30
    while True:
        try:
            for name in names:
                verify_page(name)
            break
        except (AssertionError, FileNotFoundError, json.JSONDecodeError) as error:
            if time.monotonic() >= deadline:
                raise AssertionError(f"{phase} failed: {error}") from error
            time.sleep(0.1)
    for name in names:
        checks[name + ": exactly once, labels, body, appearance, attachment bytes"] = True
    print(f"{phase}: two renamed packages imported completely", flush=True)

result = {
    "passed": True, "checks": checks, "route": "macOS open-document events",
    "cold_launch": True, "warm_launch": True, "multiple_files": True,
    "fixture_sha256": hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
    "probe_gui_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "isolated": True,
}
(root / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
print(json.dumps(result, ensure_ascii=False, indent=2))
