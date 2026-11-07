#!/usr/bin/env python3
"""Exercise rollback reconstruction including edits, deletions and symlink changes."""
import json
import os
from pathlib import Path
import tempfile
import unittest
import shutil
import backup_checkpoint as checkpoint


def snapshot(root):
    return {str(p.relative_to(root)): {"link": os.readlink(p)} if p.is_symlink()
            else {"sha256": checkpoint.sha(p), "bytes": p.stat().st_size}
            for p in root.rglob("*") if p.is_symlink() or p.is_file()}


class CheckpointTests(unittest.TestCase):
    def test_reused_objects_remain_self_contained_and_restore_exactly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base, live = root / "base", root / "live"
            for parent in [base, live]:
                for kind in ["data", "config"]:
                    (parent / kind).mkdir(parents=True)
                    (parent / kind / "same").write_text("base")
            original = {kind: snapshot(base / kind) for kind in ["data", "config"]}
            (base / "protected-before.json").write_text(json.dumps(original))
            media = b"verified-media" * 1024
            (live / "data" / "media").write_bytes(media)
            (live / "data" / "alias").write_bytes(media)
            (live / "config" / "setting").write_text("version-one")
            first_state = {kind: snapshot(live / kind) for kind in original}
            roots = {kind: live / kind for kind in original}
            first = base / "checkpoint-first"
            checkpoint.create(base, first_state, roots, first)

            (live / "config" / "setting").write_text("version-two")
            (live / "data" / "same").unlink()
            (live / "data" / "link").symlink_to("/retained/external/target")
            current = {kind: snapshot(live / kind) for kind in original}
            reusable = checkpoint.reusable_objects(base, first, current)
            self.assertEqual(checkpoint.new_object_bytes(original, current, reusable),
                             len(b"version-two"))
            second = base / "checkpoint-second"
            checkpoint.create(base, current, roots, second, reusable=reusable)
            digest = checkpoint.sha(live / "data" / "media")
            self.assertEqual((first / "objects" / digest).stat().st_ino,
                             (second / "objects" / digest).stat().st_ino)
            self.assertEqual((first / "objects" / digest).stat().st_nlink, 2)
            # New checkpoints own their hard links, so restoring does not depend
            # on the old checkpoint's directory continuing to exist.
            shutil.rmtree(first)
            (live / "data" / "media").write_bytes(b"later live edit")
            restored = root / "restored"
            checkpoint.materialize(base, second, restored)
            self.assertEqual({kind: snapshot(restored / kind) for kind in original}, current)
            self.assertEqual({kind: snapshot(base / kind) for kind in original}, original)

    def test_reuse_rejects_corruption_and_symlinked_checkpoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base = root / "base"
            for kind in ["data", "config"]:
                (base / kind).mkdir(parents=True)
            original = {"data": {}, "config": {}}
            (base / "protected-before.json").write_text(json.dumps(original))
            live = root / "live"
            live.mkdir()
            (live / "file").write_bytes(b"protected")
            current = {"data": snapshot(live), "config": {}}
            first = base / "checkpoint-first"
            checkpoint.create(base, current, {"data": live}, first)
            linked = base / "checkpoint-link"
            linked.symlink_to(first, target_is_directory=True)
            with self.assertRaises(AssertionError):
                checkpoint.reusable_objects(base, linked, current)
            next((first / "objects").iterdir()).write_bytes(b"corrupted")
            with self.assertRaises(AssertionError):
                checkpoint.reusable_objects(base, first, current)

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
