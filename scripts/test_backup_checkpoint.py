#!/usr/bin/env python3
"""Exercise rollback reconstruction including edits, deletions and symlink changes."""
import json
import os
from pathlib import Path
import tempfile
import unittest
import backup_checkpoint as checkpoint


def snapshot(root):
    return {str(p.relative_to(root)): {"link": os.readlink(p)} if p.is_symlink()
            else {"sha256": checkpoint.sha(p), "bytes": p.stat().st_size}
            for p in root.rglob("*") if p.is_symlink() or p.is_file()}


class CheckpointTests(unittest.TestCase):
    def test_reconstruct_latest_exactly_and_preserve_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base, live = root / "base", root / "live"
            for parent in [base, live]:
                for kind in ["data", "config"]:
                    folder = parent / kind
                    folder.mkdir(parents=True)
                    (folder / "same").write_text("unchanged")
                    (folder / "edit").write_text("old")
                    (folder / "remove").write_text("removed later")
                    (folder / "link").symlink_to("/old/target")
            original = {k: snapshot(base / k) for k in ["data", "config"]}
            (base / "protected-before.json").write_text(json.dumps(original))
            for kind in original:
                (live / kind / "edit").write_text("new content")
                (live / kind / "new").write_text("newly created")
                (live / kind / "remove").unlink()
                (live / kind / "link").unlink()
                (live / kind / "link").symlink_to("/new/target")
            current = {k: snapshot(live / k) for k in original}
            destination = base / "checkpoint"
            copied = checkpoint.create(base, current, {k: live / k for k in original}, destination)
            self.assertEqual(copied, 48)
            restored = root / "restored"
            checkpoint.materialize(base, destination, restored)
            self.assertEqual({k: snapshot(restored / k) for k in original}, current)
            self.assertEqual({k: snapshot(base / k) for k in original}, original)
            with self.assertRaises(FileExistsError):
                checkpoint.materialize(base, destination, restored)
            next((destination / "objects").iterdir()).write_text("corrupt")
            with self.assertRaises(AssertionError):
                checkpoint.verify(base, destination)


if __name__ == "__main__":
    unittest.main()
