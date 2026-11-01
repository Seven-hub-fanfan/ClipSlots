"""Logical file inventory for packaging; links are recorded without following targets."""
import hashlib
import json
import os
from pathlib import Path
import stat


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_tree(root):
    root = Path(root)
    if not root.exists() or root.is_symlink():
        raise ValueError("Missing regular resource path: " + str(root))
    paths = [root] + (list(root.rglob("*")) if root.is_dir() else [])
    for path in paths:
        mode = path.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError("Resource trees must contain regular files/directories: " + str(path))


def inventory(root):
    root = Path(root)
    if not root.is_dir() or root.is_symlink():
        raise ValueError("Inventory root must be a regular directory: " + str(root))
    rows = {}
    for folder, directories, files in os.walk(root, followlinks=False):
        # os.walk reports symlinked directories separately; record the link and
        # prevent traversal even when a target is within this bundle.
        paths = [Path(folder) / name for name in files]
        paths += [Path(folder) / name for name in directories if (Path(folder) / name).is_symlink()]
        directories[:] = [name for name in directories if not (Path(folder) / name).is_symlink()]
        for path in sorted(paths):
            relative = str(path.relative_to(root))
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                rows[relative] = {"kind": "symlink", "target": os.readlink(path)}
            elif stat.S_ISREG(mode):
                rows[relative] = {"kind": "file", "bytes": path.stat().st_size, "sha256": sha(path)}
            else:
                raise ValueError("Unsupported entry in inventory: " + str(path))
    return dict(sorted(rows.items()))


def logical_bytes(rows):
    return sum(row["bytes"] for row in rows.values() if row["kind"] == "file")


def write_new_json(path, value):
    with Path(path).open("x") as stream:
        stream.write(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
