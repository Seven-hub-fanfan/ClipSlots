"""Immutable file-level checkpoints backed by an already verified full backup."""
import hashlib
import json
import os
from pathlib import Path
import shutil


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def changed_bytes(original, current):
    return sum(entry.get("bytes", 0) for kind, entries in current.items()
               for name, entry in entries.items() if entry != original[kind].get(name))


def create(base, current, roots, destination):
    """Store changed bytes only; the complete manifest also records removals."""
    original = json.loads((base / "protected-before.json").read_text())
    destination.mkdir()
    objects = destination / "objects"
    objects.mkdir()
    for kind, entries in current.items():
        for name, entry in entries.items():
            if entry != original[kind].get(name) and "sha256" in entry:
                target = objects / entry["sha256"]
                if not target.exists():
                    shutil.copyfile(roots[kind] / name, target)
                assert sha(target) == entry["sha256"]
                assert target.stat().st_size == entry["bytes"]
    manifest = {"base_manifest_sha256": sha(base / "protected-before.json"),
                "snapshot": current}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2))
    verify(base, destination)
    return changed_bytes(original, current)


def sources(base, checkpoint):
    manifest = json.loads((checkpoint / "manifest.json").read_text())
    assert sha(base / "protected-before.json") == manifest["base_manifest_sha256"]
    original = json.loads((base / "protected-before.json").read_text())
    for kind, entries in manifest["snapshot"].items():
        assert kind in ("data", "config")
        for name, entry in entries.items():
            relative = Path(name)
            assert not relative.is_absolute() and ".." not in relative.parts
            source = base / kind / relative
            if entry != original[kind].get(name) and "sha256" in entry:
                assert len(entry["sha256"]) == 64 and all(c in "0123456789abcdef" for c in entry["sha256"])
                source = checkpoint / "objects" / entry["sha256"]
            yield kind, relative, entry, source


def verify(base, checkpoint):
    for _, _, entry, source in sources(base, checkpoint):
        if "sha256" in entry:
            assert not source.is_symlink() and source.stat().st_size == entry["bytes"]
            assert sha(source) == entry["sha256"]


def materialize(base, checkpoint, destination):
    """Reconstruct into a NEW directory; never overwrites live data or backups."""
    verify(base, checkpoint)
    destination.mkdir(exist_ok=False)
    for kind, relative, entry, source in sources(base, checkpoint):
        target = destination / kind / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if "link" in entry:
            os.symlink(entry["link"], target)
        else:
            shutil.copy2(source, target)
