#!/usr/bin/env python3
"""Supervise the production App's native directory Store with real OS bookmarks."""
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
    root = pathlib.Path(tempfile.mkdtemp(prefix="clipslots-directory-grant-", dir="/private/tmp"))
    process = subprocess.run([args.binary, str(root)], capture_output=True, text=True, timeout=20)
    (root / "stdout.json").write_text(process.stdout)
    (root / "stderr.log").write_text(process.stderr)
    data = json.loads(process.stdout.strip().splitlines()[-1]) if process.returncode == 0 else {}
    checks = {
        "native_process_complete": process.returncode == 0,
        "native_checks_complete": data.get("failed") == 0,
        "unselected_directory_preserved": (root / "项目 B/input.txt").read_bytes() == b"second-marker",
        "corrupt_catalog_exact": (root / "corrupt/agent-workdirs.json").read_bytes() == b"corrupt-catalog-marker",
    }
    result = {"root": str(root), "exitCode": process.returncode, "checks": checks, "result": data,
              "files": [{"path": str(p.relative_to(root)), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                        for p in root.rglob("*") if p.is_file()]}
    pathlib.Path(args.report).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    failures = [name for name, passed in checks.items() if not passed]
    print(json.dumps({"nativeChecks": len(data.get("checks", [])), "diskChecks": len(checks),
                      "failures": failures, "root": str(root)}, ensure_ascii=False))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
