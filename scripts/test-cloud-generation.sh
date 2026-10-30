#!/bin/bash
set -euo pipefail
repo="$(dirname "$(dirname "$(realpath "$0")")")"
scratch="${1:?Pass the existing Debug build directory}"
test_root="$(mktemp -d /private/tmp/clipslots-cloud-contracts-kit-XXXXXXXX)"
python3 - "$repo" "$scratch" "$test_root" <<'PY'
import hashlib, json, sys
from pathlib import Path
repo, scratch, root = map(Path, sys.argv[1:])
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
source = sorted((repo / "Sources/ClipSlotsKit").glob("*.swift"))
source += [repo / "scripts/gateway-fixtures/CloudContractsMain.swift"]
objects = sorted((scratch / "debug/ClipSlotsKit.build").glob("*.swift.o"))
assert objects
identity = {"sources": {str(p.relative_to(repo)): sha(p) for p in source},
            "objects": {str(p): sha(p) for p in objects},
            "providerRequests": 0, "configuration": "Actual Debug Kit objects, no staged duplicate types"}
(root / "subject.json").write_text(json.dumps(identity, indent=2) + "\n")
PY
swiftc -D DEBUG -parse-as-library -I "$scratch/debug/Modules" \
    "$repo/scripts/gateway-fixtures/CloudContractsMain.swift" \
    "$scratch"/debug/ClipSlotsKit.build/*.swift.o -o "$test_root/probe" \
    >"$test_root/compile.log" 2>&1
"$test_root/probe" "$test_root" >"$test_root/run.log" 2>&1
python3 - "$repo" "$test_root" <<'PY'
import hashlib, json, sys
from pathlib import Path
repo, root = map(Path, sys.argv[1:])
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
identity = json.loads((root / "subject.json").read_text())
assert all(sha(repo / p) == h for p, h in identity["sources"].items()), "Measured sources changed"
report = json.loads((root / "report.json").read_text())
assert report["failed"] == 0 and not report["failures"] and not report["stagedSource"]
identity["binarySHA256"] = sha(root / "probe")
(root / "subject.json").write_text(json.dumps(identity, indent=2) + "\n")
print(json.dumps({"root": str(root), "report": report}))
PY
