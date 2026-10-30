#!/usr/bin/env python3
"""Run real directory fixtures and independently verify the final disk bytes."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    root = pathlib.Path(tempfile.mkdtemp(prefix="clipslots-directory-batch-", dir="/private/tmp"))
    process = subprocess.run([args.binary, str(root)], capture_output=True, text=True, timeout=40)
    (root / "stdout.json").write_text(process.stdout)
    (root / "stderr.log").write_text(process.stderr)
    data = json.loads(process.stdout.strip().splitlines()[-1]) if process.returncode == 0 else {}
    original = root / "original-root"
    replacement = root / "项目 with spaces"

    def content(path):
        return path.read_bytes() if path.is_file() else None

    checks = {
        "swift_returned": process.returncode == 0,
        "all_swift_checks_passed": data.get("failed") == 0,
        "original_restored": content(original / "input.txt") == "original🙂".encode(),
        "outside_hardlink_preserved": content(root / "outside/secret.txt") == b"outside-secret",
        "large_binary_exact": content(original / "large.bin") == bytes([0xab]) * 1_048_577,
        "moved_directory_restored": content(original / "nested/deep/file.txt") == b"nested-original",
        "rollback_created_directory_removed": not (original / "sorted").exists(),
        "original_collision_preserved": content(original / "collision.txt") == b"COLLISION",
        "approved_items_exact": content(original / "approved-0.txt") == b"approved0"
            and content(original / "approved-2.txt") == b"approved2",
        "declined_item_absent": not (original / "approved-1.txt").exists(),
        "shell_executed_once": content(original / "once.txt") == "shell-once🙂".encode()
            and content(original / "concurrent-once.txt") == b"concurrent",
        "declined_cancelled_revoked_effects_absent": not any((original / name).exists()
            for name in ("denied-shell.txt", "cancelled-shell.txt", "revocation-write.txt")),
        "approval_concurrent_user_bytes": content(original / "approval-race.txt") == b"user-during-approval",
        "organize_rollback_conflict_bytes": content(original / "conflict-dir/user.txt") == b"ROLLBACK-USER-LATER"
            and not (original / "rollback-user.txt").exists(),
        "pressure_files_absent": not list(original.glob("pressure-*.txt")),
        "wide_fixture_not_deleted": len(list((original / "wide").glob("f-*.txt"))) == 2500,
        "replacement_root_preserved": content(replacement / "input.txt") == b"replacement-root"
            and not (replacement / "revoked.txt").exists(),
        "no_temporary_write_files": not list(original.rglob(".clipslots-write-*")),
    }
    result = {"root": str(root), "exitCode": process.returncode, "checks": checks, "result": data,
              "stdoutFile": str(root / "stdout.json"), "stderrFile": str(root / "stderr.log"),
              "files": [{"path": str(p.relative_to(root)), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                        for p in root.rglob("*") if p.is_file() and not p.is_symlink()]}
    pathlib.Path(args.report).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    failed = [name for name, passed in checks.items() if not passed]
    print(json.dumps({"swiftChecks": len(data.get("checks", [])), "diskChecks": len(checks),
                      "failures": failed, "root": str(root)}, ensure_ascii=False))
    return bool(failed)


if __name__ == "__main__":
    raise SystemExit(main())
