#!/usr/bin/env python3
"""Crash the isolated Swift journal between steer state and cursor commit."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True, type=Path)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix="clipslots-steer-journal-", dir="/tmp"))
for mode in ["seed", "crash", "verify", "corrupt"]:
    with (root / (mode + ".log")).open("w") as log:
        result = subprocess.run([str(binary), mode, str(root / "state")], stdout=log, stderr=log, timeout=40)
    assert result.returncode == (-signal.SIGKILL if mode == "crash" else 0), (mode, root, result.returncode)
    if mode == "crash":
        shutil.copytree(root / "state", root / "after-crash")
    if mode == "verify":
        shutil.copytree(root / "state", root / "after-recovery")
record = {"root": str(root), "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
          "realSIGKILL": True, "quotaAbort": True, "missingBodyFailClosed": True, "remoteProviderRequests": 0}
(root / "verification.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record))
