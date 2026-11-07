#!/usr/bin/env python3
"""Bound new development output; never deletes business data, backups or caches."""
import argparse
import atexit
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

GIB = 1024**3
MIN_FREE_GIB = 40
WARN_FREE_GIB = 60
MAX_BACKUPS = 2
MAX_BACKUP_GIB = 30
MAX_ACTIVE_JOBS = 3
MAX_BUILD_GIB = 12
REGISTRY_ROOT = Path("/private/tmp") / ("clipslots-disk-guard-" + str(os.getuid()))


class DiskLimitError(RuntimeError):
    pass


def bytes_used(root):
    """Conservative logical size; APFS shared extents are intentionally not deducted."""
    root = Path(root)
    if not root.exists():
        return 0
    if root.is_symlink():
        raise DiskLimitError("Output root cannot be a symlink: " + str(root))
    total = 0
    seen = set()
    def walk_error(error):
        if isinstance(error, FileNotFoundError):
            return  # Atomic staging-directory cleanup can race a size sample.
        raise error
    for current, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        dirs[:] = [n for n in dirs if not Path(current, n).is_symlink()]
        for name in files:
            path = Path(current, name)
            try:
                st = path.lstat()
            except FileNotFoundError:
                continue  # Compiler may replace a temporary file during measurement.
            if path.is_symlink():
                continue
            key = (st.st_dev, st.st_ino)
            if key not in seen:
                seen.add(key)
                total += st.st_size
    return total


def check_space(operation, reserve_gib=0, volume=None):
    """Preflight projected free space; does not initialize ClipSlots storage."""
    if not math.isfinite(reserve_gib) or reserve_gib < 0:
        raise DiskLimitError("Reserve must be non-negative")
    volume = Path(volume or Path(__file__).resolve().parent.parent)
    while not volume.exists():
        volume = volume.parent
    free_gib = shutil_free(volume) / GIB
    required = MIN_FREE_GIB + reserve_gib
    if free_gib < required:
        raise DiskLimitError(
            "{} stopped: {:.1f} GiB free; requires {:.1f} GiB "
            "(40 GiB floor + {:.1f} GiB planned output).".format(
                operation, free_gib, required, reserve_gib))
    if free_gib < WARN_FREE_GIB + reserve_gib:
        print("[disk-guard] {:.1f} GiB free; review output before adding more.".format(free_gib),
              file=sys.stderr)
    return free_gib


def shutil_free(volume):
    volume = Path(volume)
    while not volume.exists():
        volume = volume.parent
    stat = os.statvfs(volume)
    return stat.f_bavail * stat.f_frsize


def _live(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _locked_directory(root):
    root.mkdir(parents=True, exist_ok=True)
    if root.is_symlink() or root.stat().st_uid != os.getuid():
        raise DiskLimitError("Guard directory must belong to current user: " + str(root))
    fd = os.open(root / ".guard.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    return os.fdopen(fd, "a+")


class BackupLease:
    """Serialize installers and stop before a third full backup is created."""
    def __init__(self, root, operation, planned_gib, reuse_backup=None, max_backup_gib=MAX_BACKUP_GIB):
        if not math.isfinite(max_backup_gib) or not MAX_BACKUP_GIB <= max_backup_gib <= 31:
            raise DiskLimitError("Explicit backup allowance must be between 30 and 31 GiB.")
        self.max_backup_gib = max_backup_gib
        self.root = Path(root)
        self.operation = operation
        self.planned_gib = planned_gib
        self.handle = _locked_directory(self.root)
        try:
            fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            backups = [p for p in self.root.iterdir() if p.is_dir() and not p.name.startswith(".")]
            if reuse_backup is not None:
                reuse = Path(reuse_backup)
                if (reuse.is_symlink() or reuse.parent.resolve() != self.root.resolve()
                        or reuse.name.startswith(".") or not reuse.is_dir()):
                    raise DiskLimitError("Reuse must name an existing direct backup directory.")
            if len(backups) > MAX_BACKUPS or (reuse_backup is None and len(backups) >= MAX_BACKUPS):
                raise DiskLimitError(
                    "Backup limit reached (2). Keep verified rollback copies and consolidate "
                    "older backups before retrying: " + str(self.root))
            used_gib = bytes_used(self.root) / GIB
            if used_gib + planned_gib > self.max_backup_gib:
                raise DiskLimitError(f"Backup budget would exceed {self.max_backup_gib:g} GiB; no backup created.")
            check_space(operation, reserve_gib=planned_gib, volume=self.root)
        except Exception:
            self.release()
            raise
        atexit.register(self.release)

    def reserve_additional(self, additional_bytes):
        """Budget an immutable checkpoint delta under the existing installer lock."""
        if self.handle is None or additional_bytes < 0:
            raise DiskLimitError("Additional backup reservation requires a live lease.")
        planned = self.planned_gib + additional_bytes / GIB
        if bytes_used(self.root) / GIB + planned > self.max_backup_gib:
            raise DiskLimitError(f"Backup checkpoint would exceed {self.max_backup_gib:g} GiB.")
        check_space(self.operation, reserve_gib=planned, volume=self.root)
        self.planned_gib = planned

    def release(self):
        if self.handle is not None:
            self.handle.close()
            self.handle = None


def reserve_backup(operation, source_roots, reuse_backup=None, max_backup_gib=MAX_BACKUP_GIB):
    root = Path.home() / ".local/share/clipslots-install-backups"
    estimate = sum(bytes_used(p) for p in source_roots) / GIB
    # A reused backup reserves its changed objects and serialized checkpoint
    # metadata separately, once the protected snapshot is known. Full copies
    # retain the general metadata allowance.
    if reuse_backup is None:
        estimate += 0.5
    return BackupLease(root, operation, estimate, reuse_backup=reuse_backup, max_backup_gib=max_backup_gib)


class JobLease:
    def __init__(self, roots, budget_gib):
        self.root = REGISTRY_ROOT
        self.roots = [str(p.resolve()) for p in roots]
        self.pid = os.getpid()
        self.active = False
        with _locked_directory(self.root) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            records = self._read()
            if len(records) >= MAX_ACTIVE_JOBS:
                raise DiskLimitError("At most 3 guarded build/test jobs may run concurrently.")
            for job in records:
                for one in self.roots:
                    for other in job["outputs"]:
                        a, b = Path(one), Path(other)
                        if a == b or a in b.parents or b in a.parents:
                            raise DiskLimitError("Another guarded job is writing this output: " + one)
            saved = self.root / "outputs.json"
            known = json.loads(saved.read_text()) if saved.exists() else []
            known = [p for p in known if Path(p).exists()]
            for one in self.roots:
                for other in known:
                    a, b = Path(one), Path(other)
                    if a != b and (a in b.parents or b in a.parents):
                        raise DiskLimitError("A registered output overlaps this path: " + one)
            active_roots = {p for r in records for p in r["outputs"]}
            inactive = [p for p in known if p not in active_roots and p not in self.roots]
            projected = sum(bytes_used(p) for p in inactive) / GIB
            projected += sum(r["budget_gib"] for r in records) + budget_gib
            if projected > MAX_BUILD_GIB:
                raise DiskLimitError(
                    "Registered build/test output would exceed 12 GiB. "
                    "Review old output before starting another job; nothing was deleted.")
            temporary = self.root / ("outputs-" + str(self.pid) + ".tmp")
            temporary.write_text(json.dumps(sorted(set(known) | set(self.roots))) + "\n")
            os.replace(temporary, saved)
            records.append({"pid": self.pid, "outputs": self.roots, "budget_gib": budget_gib})
            self._write(records)
            self.active = True
        atexit.register(self.release)

    def _read(self):
        path = self.root / "active.json"
        if not path.exists():
            return []
        records = json.loads(path.read_text())
        return [r for r in records if _live(r["pid"])]

    def _write(self, records):
        path = self.root / "active.json"
        temporary = self.root / ("active-" + str(self.pid) + ".tmp")
        temporary.write_text(json.dumps(records) + "\n")
        os.replace(temporary, path)

    def release(self):
        if not self.active:
            return
        with _locked_directory(self.root) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self._write([r for r in self._read() if r["pid"] != self.pid])
        self.active = False


def guarded_run(command, roots, budget_gib):
    if not 0 < budget_gib <= 4:
        raise DiskLimitError("A guarded build/test job has a maximum total output budget of 4 GiB.")
    if not roots or not command:
        raise DiskLimitError("Specify measured output roots and a build/test command.")
    roots = [Path(p).absolute() for p in roots]
    # Reject nested roots rather than double-counting them.
    for i, p in enumerate(roots):
        if p.is_symlink() or any(p == q or p in q.parents or q in p.parents for q in roots[:i]):
            raise DiskLimitError("Output roots must be distinct, nonoverlapping real directories.")
    check_space("Build/test", reserve_gib=budget_gib, volume=roots[0])
    lease = JobLease(roots, budget_gib)
    process = None
    reason = None
    previous_signals = {}
    try:
        used = sum(bytes_used(p) for p in roots)
        if used > budget_gib * GIB:
            raise DiskLimitError("Existing output already exceeds budget; command was not started.")
        process = subprocess.Popen(command, start_new_session=True)
        def interrupted(signum, frame):
            raise SystemExit(128 + signum)
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous_signals[signum] = signal.signal(signum, interrupted)
        while True:
            try:
                code = process.wait(timeout=2)
                break
            except subprocess.TimeoutExpired:
                pass
            if shutil_free(roots[0] if roots[0].exists() else roots[0].parent) < MIN_FREE_GIB * GIB:
                reason = "Free space fell below 40 GiB."
                break
            if sum(bytes_used(p) for p in roots) > budget_gib * GIB:
                reason = "Build/test output exceeded {:.1f} GiB.".format(budget_gib)
                break
        # Capture short-lived commands that exceeded the budget before the first sample.
        if reason is None and sum(bytes_used(p) for p in roots) > budget_gib * GIB:
            reason = "Build/test completed above its output budget."
        if reason:
            raise DiskLimitError(reason + " Output retained for review; no automatic deletion.")
        return code
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        for signum, handler in previous_signals.items():
            signal.signal(signum, handler)
        lease.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    check = sub.add_parser("check")
    check.add_argument("--reserve-gib", type=float, default=0)
    check.add_argument("--operation", default="Development task")
    run = sub.add_parser("run", help="Monitor only build/test jobs; do not wrap an installation")
    run.add_argument("--output", type=Path, action="append", required=True)
    run.add_argument("--budget-gib", type=float, default=4)
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.action == "check":
            free = check_space(args.operation, args.reserve_gib)
            print("[disk-guard] {:.1f} GiB free; preflight passed.".format(free))
            return 0
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        return guarded_run(command, args.output, args.budget_gib)
    except (DiskLimitError, OSError, ValueError) as error:
        print("[disk-guard] " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
