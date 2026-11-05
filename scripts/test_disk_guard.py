#!/usr/bin/env python3
"""Small disk guard regressions; fixtures stay below a few KiB."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import disk_guard as guard


class DiskGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipslots-disk-guard-test-")
        self.root = Path(self.temporary.name)
        self.registry = patch.object(guard, "REGISTRY_ROOT", self.root / "registry")
        self.registry.start()
        self.free = patch.object(guard, "shutil_free", return_value=100 * guard.GIB)
        self.free.start()

    def tearDown(self):
        self.free.stop()
        self.registry.stop()
        self.temporary.cleanup()

    def test_low_projected_space_blocks(self):
        with patch.object(guard, "shutil_free", return_value=43 * guard.GIB):
            with self.assertRaises(guard.DiskLimitError):
                guard.check_space("build", reserve_gib=4, volume=self.root)

    def test_removed_staging_directory_during_sample_is_tolerated(self):
        (self.root / "kept.bin").write_bytes(b"kept")
        def walker(root, followlinks, onerror):
            onerror(FileNotFoundError("staging directory was atomically removed"))
            yield str(root), [], ["kept.bin"]
        with patch.object(guard.os, "walk", side_effect=walker):
            self.assertEqual(guard.bytes_used(self.root), 4)

    def test_unreadable_directory_still_blocks_sampling(self):
        def walker(root, followlinks, onerror):
            onerror(PermissionError("directory cannot be inspected"))
            yield str(root), [], []
        with patch.object(guard.os, "walk", side_effect=walker):
            with self.assertRaises(PermissionError):
                guard.bytes_used(self.root)

    def test_free_floor_passes_at_boundary(self):
        with patch.object(guard, "shutil_free", return_value=44 * guard.GIB):
            self.assertEqual(guard.check_space("build", reserve_gib=4, volume=self.root), 44)

    def test_nan_reserve_is_rejected(self):
        with self.assertRaises(guard.DiskLimitError):
            guard.check_space("build", reserve_gib=float("nan"), volume=self.root)

    def test_backup_count_blocks_third_and_keeps_both(self):
        backups = self.root / "backups"
        (backups / "one").mkdir(parents=True)
        (backups / "two").mkdir()
        with self.assertRaises(guard.DiskLimitError):
            guard.BackupLease(backups, "install", 1)
        self.assertTrue((backups / "one").exists())
        self.assertTrue((backups / "two").exists())

    def test_backup_budget_blocks_without_copying(self):
        with self.assertRaises(guard.DiskLimitError):
            guard.BackupLease(self.root / "backups", "install", 31)
        self.assertEqual(list((self.root / "backups").glob("data*")), [])

    def test_existing_backup_can_receive_budgeted_delta_without_third_copy(self):
        backups = self.root / "backups"
        (backups / "one").mkdir(parents=True)
        (backups / "two").mkdir()
        lease = guard.BackupLease(backups, "install", 1, reuse_backup=backups / "two")
        try:
            lease.reserve_additional(1024)
            with self.assertRaises(guard.DiskLimitError):
                lease.reserve_additional(30 * guard.GIB)
            self.assertEqual(sorted(p.name for p in backups.iterdir() if p.is_dir()), ["one", "two"])
        finally:
            lease.release()

    def test_explicit_install_allowance_keeps_default_and_delta_checks(self):
        backups = self.root / "backups"
        (backups / "one").mkdir(parents=True)
        with patch.object(guard, "bytes_used", return_value=29 * guard.GIB):
            with self.assertRaises(guard.DiskLimitError):
                guard.BackupLease(backups, "default", 1.1, reuse_backup=backups / "one")
            lease = guard.BackupLease(backups, "authorized", 1.1,
                                     reuse_backup=backups / "one", max_backup_gib=31)
            try:
                lease.reserve_additional(int(0.2 * guard.GIB))
                with self.assertRaises(guard.DiskLimitError):
                    lease.reserve_additional(guard.GIB)
            finally:
                lease.release()
        self.assertEqual(guard.MAX_BACKUP_GIB, 30)
        self.assertTrue((backups / "one").exists())

    def test_install_allowance_cannot_disable_floor_or_count(self):
        for value in [float("inf"), float("nan"), 32, 0]:
            with self.assertRaises(guard.DiskLimitError):
                guard.BackupLease(self.root / "backups", "install", 1, max_backup_gib=value)
        with patch.object(guard, "shutil_free", return_value=40 * guard.GIB):
            with self.assertRaises(guard.DiskLimitError):
                guard.BackupLease(self.root / "backups", "install", 1, max_backup_gib=31)

    def test_reuse_rejects_symlink_or_outside_directory(self):
        backups = self.root / "backups"
        (backups / "one").mkdir(parents=True)
        (backups / "link").symlink_to(backups / "one", target_is_directory=True)
        for path in [backups / "link", self.root, backups / "missing"]:
            with self.assertRaises(guard.DiskLimitError):
                guard.BackupLease(backups, "install", 1, reuse_backup=path)

    def test_backup_lease_serializes_installers(self):
        backups = self.root / "backups"
        first = guard.BackupLease(backups, "install", 1)
        try:
            with self.assertRaises(BlockingIOError):
                guard.BackupLease(backups, "second install", 1)
        finally:
            first.release()
        second = guard.BackupLease(backups, "install", 1)
        second.release()

    def test_same_output_concurrency_is_rejected(self):
        first = guard.JobLease([self.root / "build"], 4)
        try:
            with self.assertRaises(guard.DiskLimitError):
                guard.JobLease([self.root / "build"], 4)
        finally:
            first.release()

    def test_registered_outputs_stop_accumulation(self):
        build = self.root / "prior-build"
        build.mkdir()
        (build / "payload").write_bytes(b"prior-output")
        registry = self.root / "registry"
        registry.mkdir()
        (registry / "outputs.json").write_text(json.dumps([str(build)]))
        with patch.object(guard, "MAX_BUILD_GIB", 4):
            with self.assertRaises(guard.DiskLimitError):
                guard.JobLease([self.root / "next-build"], 4)
        self.assertEqual((build / "payload").read_bytes(), b"prior-output")

    def test_current_output_is_reused(self):
        build = self.root / "build"
        build.mkdir()
        (build / "payload").write_bytes(b"reusable")
        first = guard.JobLease([build], 4)
        first.release()
        second = guard.JobLease([build], 4)
        second.release()
        self.assertEqual((build / "payload").read_bytes(), b"reusable")

    def test_budget_excess_retains_short_lived_job_output(self):
        build = self.root / "build"
        build.mkdir()
        file = build / "payload"
        command = [sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'abc')", str(file)]
        with self.assertRaises(guard.DiskLimitError):
            guard.guarded_run(command, [build], 1 / guard.GIB)
        self.assertEqual(file.read_bytes(), b"abc")
        self.assertEqual(json.loads((self.root / "registry/active.json").read_text()), [])

    def test_existing_over_budget_never_launches(self):
        build = self.root / "build"
        build.mkdir()
        (build / "payload").write_bytes(b"abc")
        with patch.object(guard.subprocess, "Popen") as popen:
            with self.assertRaises(guard.DiskLimitError):
                guard.guarded_run([sys.executable, "-c", "pass"], [build], 1 / guard.GIB)
            popen.assert_not_called()

    def test_symlink_root_is_rejected(self):
        target = self.root / "target"
        target.mkdir()
        link = self.root / "build"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises(guard.DiskLimitError):
            guard.guarded_run([sys.executable, "-c", "pass"], [link], 4)
        self.assertTrue(target.exists())

    def test_child_failure_is_preserved(self):
        self.assertEqual(guard.guarded_run(
            [sys.executable, "-c", "raise SystemExit(7)"], [self.root / "output"], 4), 7)

    def test_running_job_stops_when_free_space_falls(self):
        output = self.root / "output"
        output.mkdir()
        pidfile = output / "child.pid"
        command = [sys.executable, "-c",
                   "import os,sys,threading; from pathlib import Path; "
                   "Path(sys.argv[1]).write_text(str(os.getpid())); threading.Event().wait()",
                   str(pidfile)]
        with patch.object(guard, "shutil_free", side_effect=[100 * guard.GIB, 39 * guard.GIB]):
            with self.assertRaises(guard.DiskLimitError):
                guard.guarded_run(command, [output], 4)
        self.assertTrue(pidfile.exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)
        self.assertEqual(json.loads((self.root / "registry/active.json").read_text()), [])


if __name__ == "__main__":
    unittest.main()
