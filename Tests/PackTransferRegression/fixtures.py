import copy
import json
from pathlib import Path
import stat
import sys
import zipfile

root = Path(sys.argv[1])
with zipfile.ZipFile(root / "source.clipslotspack") as archive:
    # macOS zip writes UTF-8 names without bit 11. Python otherwise interprets
    # those bytes as CP437; preserve the original filename when repacking.
    def original_name(entry):
        if entry.flag_bits & 0x800:
            return entry.filename
        try:
            return entry.filename.encode("cp437").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return entry.filename
    entries = {original_name(i): archive.read(i) for i in archive.infolist()}
manifest = json.loads(entries["manifest.json"])
slot_key = next(k for k in entries if k.endswith("/slots/1/slot.json"))
group_key = slot_key.split("/slots/")[0] + "/group.json"
attachment_key = next(k for k in entries if "/attachments/" in k and entries[k])

def variant(name, edit):
    value = copy.deepcopy(entries)
    edit(value)
    with zipfile.ZipFile(root / (name + ".bin"), "w", zipfile.ZIP_DEFLATED) as archive:
        for key, data in value.items():
            archive.writestr(key, data)

def json_edit(value, key, change):
    obj = json.loads(value[key])
    change(obj)
    value[key] = json.dumps(obj).encode()

variant("corrupt-slot", lambda v: v.update({slot_key: b"{bad"}))
variant("missing-attachment", lambda v: v.pop(attachment_key))
variant("unsupported-version", lambda v: json_edit(v, "manifest.json", lambda m: m.update(version="99.0")))
variant("bad-count", lambda v: json_edit(v, "manifest.json", lambda m: m["pages"][0].update(slotCount=900)))
variant("duplicate-page", lambda v: json_edit(v, "manifest.json", lambda m: m["pages"].append(m["pages"][0])))
variant("duplicate-slot", lambda v: json_edit(v, group_key, lambda g: g.update(slots=[1, 1])))
variant("bad-slot-number", lambda v: json_edit(v, slot_key, lambda s: s.update(slot=9)))
variant("missing-thumbnail", lambda v: json_edit(v, slot_key, lambda s: s.update(manualThumbnail="absent.bin")))
variant("parent-path", lambda v: v.update({"../outside.txt": b"escape"}))
variant("absolute-path", lambda v: v.update({"/tmp/pack-outside.txt": b"escape"}))
variant("newline-path", lambda v: v.update({"folder\n../outside.txt": b"escape"}))
variant("case-collision", lambda v: v.update({"MANIFEST.JSON": v["manifest.json"]}))
variant("file-directory-collision", lambda v: v.update({"collision": b"file", "collision/child": b"child"}))
variant("oversize-json", lambda v: v.update({"extra.json": b" " * (10 * 1024 * 1024 + 1)}))
variant("legacy-slot-scan", lambda v: json_edit(v, group_key, lambda g: g.update(slots=[])))
variant("legacy-page-fallback", lambda v: v.pop(next(k for k in v if k.endswith("/page.json"))))
variant("legacy-no-thumbnail", lambda v: json_edit(v, slot_key, lambda s: s.pop("manualThumbnail", None)))
with zipfile.ZipFile(root / "zip64.bin", "w") as archive:
    for key, data in entries.items():
        with archive.open(key, "w", force_zip64=True) as handle:
            handle.write(data)
with zipfile.ZipFile(root / "crc-mismatch.bin", "w", zipfile.ZIP_STORED) as archive:
    for key, data in entries.items():
        archive.writestr(key, data)
corrupt = (root / "crc-mismatch.bin").read_bytes()
payload = entries[attachment_key]
position = corrupt.find(payload) if payload else -1
if position >= 0:
    corrupt = corrupt[:position] + bytes([corrupt[position] ^ 1]) + corrupt[position + 1:]
(root / "crc-mismatch.bin").write_bytes(corrupt)
with zipfile.ZipFile(root / "symlink.bin", "w") as archive:
    for key, data in entries.items():
        archive.writestr(key, data)
    entry = zipfile.ZipInfo("linked")
    entry.create_system = 3
    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(entry, "/etc/passwd")
with zipfile.ZipFile(root / "ordinary.zip", "w") as archive:
    archive.writestr("notes.txt", b"ordinary file")
with zipfile.ZipFile(root / "ordinary-manifest.zip", "w") as archive:
    archive.writestr("manifest.json", json.dumps({"manifest_version": 3, "name": "Browser extension"}))
    archive.writestr("pages/options.html", b"<title>Options</title>")
(root / "truncated.bin").write_bytes((root / "source.clipslotspack").read_bytes()[:80])
(root / "ordinary.txt").write_text("ordinary")
(root / "fake.clipslotspack").write_text("not a pack")
(root / "folder").mkdir()
