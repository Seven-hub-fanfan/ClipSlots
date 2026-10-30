#!/usr/bin/env python3
"""Check ordinary Swift diagnostic calls; protocol responses and gated fixtures are separate."""
import argparse
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
options = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
excluded = ("Regression", "Probe", "Test", "PerfMonitor", "NeuPreviewRenderer")
forbidden = [
    r"\.preview\b", r"\.localizedDescription\b", r"\\\(error\)",
    r"\\\(error\?\.localizedDescription", r"\\\([^)]*\.absoluteString\)",
    r"\\\([^)]*\.path\)", r"\\\((?:err|stdout|stderr|message|body|prompt|groupName|pageName)\)",
    r"\\\([^)]*\.localizedName", r"\\\([^)]*\.name\)",
]
checked, failures = [], []
for path in sorted((repo / "Sources").rglob("*.swift")):
    if any(name in path.name for name in excluded):
        continue
    # CLI print and MCP output are their requested response protocol, not diagnostics.
    lines = path.read_text().splitlines()
    for index, line in enumerate(lines):
        if "NSLog(" not in line:
            continue
        snippet = line
        following = index + 1
        while snippet.rstrip().endswith((' "', '+', '"')) and following < len(lines):
            snippet += "\n" + lines[following]
            following += 1
        record = {"file": str(path.relative_to(repo)), "line": index + 1}
        checked.append(record)
        if any(re.search(pattern, snippet) for pattern in forbidden):
            failures.append(record)
report = {
    "scope": "ordinary NSLog calls in Sources; excludes named fixtures/probes and protocol output",
    "callsChecked": len(checked), "checked": checked, "failures": failures,
    "limits": ["Text audit is a regression guard, not a Swift data-flow proof",
               "Synthetic Error output contract and native logs are verified separately"]
}
options.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"callsChecked": len(checked), "failures": len(failures)}))
raise SystemExit(bool(failures))
