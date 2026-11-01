#!/usr/bin/env python3
"""Exercise output protection, source integrity and signed manifest checks in synthetic directories."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from package_inventory import inventory, logical_bytes, write_new_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-dir", required=True, type=Path)
    parser.add_argument("--candidate-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists() or not args.output.parent.is_dir():
        raise ValueError("Report must be a new file in an existing directory.")
    repo = Path(__file__).resolve().parents[1]
    root = Path(tempfile.mkdtemp(prefix="clipslots-package-contract-", dir="/private/tmp"))
    candidate = args.candidate_dir.resolve(strict=True)
    before = inventory(candidate)
    rows = []
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("SIGN_", "ALLOW_ADHOC", "CLIPSLOTS_", "CANVAS_", "GATEWAY_"))}

    def reject(name, script, arguments, expected):
        run = subprocess.run(["python3", str(repo / "scripts" / script), *map(str, arguments)],
                             capture_output=True, text=True, env=env, timeout=30)
        passed = run.returncode != 0 and expected in run.stderr
        rows.append({"name": name, "passed": passed, "exitCode": run.returncode,
                     "stdout": run.stdout, "stderr": run.stderr})

    products = args.products_dir.resolve(strict=True)
    package = ["--products-dir", products, "--output", root / "new", "--allow-adhoc"]
    reject("existing output preserved", "package_agent_lite.py",
           ["--products-dir", products, "--output", candidate, "--allow-adhoc"], "already exists")
    sentinel = root / "sentinel"
    sentinel.mkdir()
    (sentinel / "keep.txt").write_text("keep")
    link = root / "output-link"
    link.symlink_to(sentinel, target_is_directory=True)
    reject("symlink output rejected", "package_agent_lite.py",
           ["--products-dir", products, "--output", link, "--allow-adhoc"], "already exists")
    reject("installation output rejected", "package_agent_lite.py",
           ["--products-dir", products, "--output", "/Applications/ClipSlots-S43-never-create", "--allow-adhoc"],
           "installation directory")
    reject("missing output parent rejected", "package_agent_lite.py",
           ["--products-dir", products, "--output", root / "missing/new", "--allow-adhoc"],
           "parent must already exist")
    reject("explicit signing choice required", "package_agent_lite.py",
           package[:-1], "explicitly pass --allow-adhoc")
    fake = root / "fake-products"
    fake.mkdir()
    for name in ["ClipSlots", "ClipSlotsCLI", "ClipSlotsMCP"]:
        shutil.copy2(products / name, fake / name)
    reject("missing Kit bundle rejected before output", "package_agent_lite.py",
           ["--products-dir", fake, "--output", root / "missing-resource-output", "--allow-adhoc"],
           "Missing regular resource")
    shutil.copytree(products / "ClipSlots_ClipSlotsKit.bundle", fake / "ClipSlots_ClipSlotsKit.bundle")
    css = fake / "ClipSlots_ClipSlotsKit.bundle/Resources/TapNowMotion/node-loading.css"
    original = css.read_bytes()
    css.write_bytes(b"tampered")
    reject("stale/tampered build resource rejected", "package_agent_lite.py",
           ["--products-dir", fake, "--output", root / "tampered-output", "--allow-adhoc"],
           "do not match")
    css.write_bytes(original)
    (fake / "ClipSlotsMCP").unlink()
    (fake / "ClipSlotsMCP").symlink_to(products / "ClipSlotsMCP")
    reject("product symlink rejected", "package_agent_lite.py",
           ["--products-dir", fake, "--output", root / "symlink-product-output", "--allow-adhoc"],
           "Missing regular executable")
    audit = ["--app", candidate / "ClipSlots.app", "--manifest", candidate / "manifest.json",
             "--output", root / "audit.json"]
    reject("unidentified baseline rejected", "audit_agent_lite.py",
           audit + ["--baseline-app", candidate / "ClipSlots.app"], "supplied together")
    existing = root / "existing.json"
    existing.write_text("preserve")
    reject("audit output preserved", "audit_agent_lite.py",
           audit[:-1] + [existing], "already exists")
    altered = root / "altered-manifest.json"
    manifest = json.loads((candidate / "manifest.json").read_text())
    manifest["inventory"]["Contents/Info.plist"]["sha256"] = "0" * 64
    altered.write_text(json.dumps(manifest))
    reject("manifest inventory mismatch rejected", "audit_agent_lite.py",
           ["--app", candidate / "ClipSlots.app", "--manifest", altered,
            "--output", root / "mismatch-audit.json"], "inventory differs")
    manifest["schema"] = "unknown"
    altered.write_text(json.dumps(manifest))
    reject("unknown manifest schema rejected", "audit_agent_lite.py",
           ["--app", candidate / "ClipSlots.app", "--manifest", altered,
            "--output", root / "schema-audit.json"], "Unsupported")
    tree = root / "inventory"
    tree.mkdir()
    (tree / "data").write_bytes(b"abc")
    (tree / "file-link").symlink_to("data")
    (tree / "directory-link").symlink_to(sentinel, target_is_directory=True)
    entries = inventory(tree)
    rows.append({"name": "logical inventory records links without following targets",
                 "passed": logical_bytes(entries) == 3 and len(entries) == 3
                 and entries["directory-link"]["kind"] == "symlink"})
    expected_absent = ["new", "missing-resource-output", "tampered-output",
                       "symlink-product-output", "audit.json", "mismatch-audit.json", "schema-audit.json"]
    rows.append({"name": "rejected actions create no output",
                 "passed": all(not (root / name).exists() for name in expected_absent)})
    rows.append({"name": "existing candidates and sentinel bytes unchanged",
                 "passed": before == inventory(candidate) and existing.read_text() == "preserve"
                 and (sentinel / "keep.txt").read_text() == "keep"})
    report = {"root": str(root), "checks": rows, "passed": sum(row["passed"] for row in rows),
              "failures": [row["name"] for row in rows if not row["passed"]]}
    write_new_json(args.output, report)
    print(json.dumps({k: v for k, v in report.items() if k != "checks"}, ensure_ascii=False, indent=2))
    return bool(report["failures"])


if __name__ == "__main__":
    raise SystemExit(main())
