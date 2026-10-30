#!/usr/bin/env python3
"""Reproducible M05 service matrix plus optional current Swift compatibility."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import unittest

import test_decision
import test_live
import test_manage
import test_steer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-bin", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    paths = sorted(set((root / "Sources").rglob("*.swift")) |
                   set((root / "gateway").glob("*.py")) |
                   {root / "scripts/gateway-fixtures/GatewayLiveMain.swift"})
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    sources = {str(p.relative_to(root)): digest(p) for p in paths}
    print(json.dumps({"evidence": str(test_live.EVIDENCE), "remoteProviderRequests": 0}), flush=True)
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case)
                               for case in (test_live.LiveTests, test_manage.SetupTests,
                                            test_steer.SteerTests, test_decision.DecisionTests))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    swift_status, reports = test_live.run_swift(str(args.swift_bin.resolve(strict=True))) \
        if args.swift_bin and result.wasSuccessful() else (None, [])
    summary = {"pythonTests": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
               "swiftExit": swift_status, "swiftCases": sum(r["swiftCases"] for r in reports),
               "swiftAssertions": sum(r["assertions"] for r in reports),
               "sources": sources, "sourceUnchanged": all(digest(root / p) == h for p, h in sources.items()),
               "swiftBinarySHA256": digest(args.swift_bin) if args.swift_bin else None,
               "evidence": str(test_live.EVIDENCE), "remoteProviderRequests": 0,
               "scope": "self-owned service v1; existing Swift interface compatibility, not new M05 App recovery",
               "M05Accepted": False, "goalComplete": False}
    (test_live.EVIDENCE / "decision-compatibility-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "sources"}), flush=True)
    return 0 if result.wasSuccessful() and swift_status in (None, 0) and summary["sourceUnchanged"] else 1


if __name__ == "__main__":
    sys.exit(main())
