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


def changed_objects(original, current):
    result = {}
    for kind, entries in current.items():
        for name, entry in entries.items():
            if entry != original[kind].get(name) and "sha256" in entry:
                digest = entry["sha256"]
                assert len(digest) == 64 and all(c in "0123456789abcdef" for c in digest)
                assert digest not in result or result[digest] == entry["bytes"]
                result[digest] = entry["bytes"]
    return result


def reusable_objects(base, checkpoint, current):
    """Reuse only verified immutable objects from a checkpoint in this backup."""
    base, checkpoint = Path(base), Path(checkpoint)
    assert not checkpoint.is_symlink() and checkpoint.parent == base
    assert checkpoint.name.startswith("checkpoint-") and checkpoint.is_dir()
    objects = checkpoint / "objects"
    assert not objects.is_symlink() and objects.is_dir()
    manifest = json.loads((checkpoint / "manifest.json").read_text())
    assert manifest["base_manifest_sha256"] == sha(base / "protected-before.json")
    original = json.loads((base / "protected-before.json").read_text())
    referenced = {entry["sha256"] for entries in manifest["snapshot"].values()
                  for entry in entries.values() if "sha256" in entry}
    result = {}
    for digest, size in changed_objects(original, current).items():
        source = objects / digest
        if digest not in referenced or not source.exists():
            continue
        assert not source.is_symlink() and source.is_file()
        assert source.stat().st_dev == base.stat().st_dev
        assert source.stat().st_size == size and sha(source) == digest
        result[digest] = source
    return result


def new_object_bytes(original, current, reusable=None):
    reusable = reusable or {}
    return sum(size for digest, size in changed_objects(original, current).items()
               if digest not in reusable)


def create(base, current, roots, destination, reusable=None):
    """Store changed bytes only; the complete manifest also records removals."""
    reusable = reusable or {}
    original = json.loads((base / "protected-before.json").read_text())
    destination.mkdir()
    objects = destination / "objects"
    objects.mkdir()
    for kind, entries in current.items():
        for name, entry in entries.items():
            if entry != original[kind].get(name) and "sha256" in entry:
                target = objects / entry["sha256"]
                if not target.exists():
                    if source := reusable.get(entry["sha256"]):
                        assert source.parent.name == "objects"
                        assert source.parent.parent.parent == base
                        assert not source.is_symlink() and sha(source) == entry["sha256"]
                        os.link(source, target, follow_symlinks=False)
                    else:
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
