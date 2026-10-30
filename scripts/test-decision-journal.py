#!/usr/bin/env python3
"""Actual SIGKILL and quota abort of the current decision SQLite writer."""
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
root = Path(tempfile.mkdtemp(prefix="clipslots-decision-journal-", dir="/tmp"))
reports = []
for mode in ["seed", "crash", "verify", "corrupt"]:
    with (root / (mode + ".log")).open("w") as log:
        result = subprocess.run([str(binary), mode, str(root / "state")],
                                stdout=log, stderr=log, timeout=50)
    assert result.returncode == (-signal.SIGKILL if mode == "crash" else 0), (mode, result.returncode, root)
    if mode in ["crash", "verify"]:
        shutil.copytree(root / "state", root / ("after-" + mode))
    if mode != "crash":
        reports.append(json.loads((root / (mode + ".log")).read_text().splitlines()[-1]))
subject = {"root": str(root), "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
           "realSIGKILL": True, "quotaAbort": True, "reports": reports, "remoteProviderRequests": 0}
(root / "summary.json").write_text(json.dumps(subject, indent=2) + "\n")
print(json.dumps(subject), flush=True)
