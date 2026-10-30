#!/usr/bin/env python3
"""Audit completed K07 runs and archive immutable evidence without running workloads."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text())


def require(condition, message):
    if not condition:
        raise ValueError(message)


def percentile(values):
    require(bool(values), "No committed samples")
    return sorted(values)[math.ceil(len(values) * 0.95) - 1]


def checked_samples(root, report):
    rows = [json.loads(line) for line in
            (root / str(report["requestedEvents"]) / "samples.jsonl").read_text().splitlines()]
    count = report["committedEvents"]
    require(isinstance(count, int) and 0 < count <= report["requestedEvents"], "Invalid committed count")
    require(len(rows) == count, "Report/sample count mismatch")
    sizes = [256, 384, 512, 768, 1024, 2048, 4096, 8192]
    require(report["deltaByteSizes"] == sizes, "Different input sizes")
    previous = {"cumulativeLogicalWriteBytes": 0, "processDiskWriteBytes": 0}
    for index, row in enumerate(rows, 1):
        require(row["event"] == index and row["deltaBytes"] == sizes[(index - 1) % 8],
                "Missing/reordered/different input event")
        require(isinstance(row["latencyMS"], (int, float)) and
                math.isfinite(row["latencyMS"]) and row["latencyMS"] >= 0, "Invalid latency")
        for name in previous:
            require(isinstance(row[name], int) and row[name] >= previous[name], "Invalid write counter")
            previous[name] = row[name]
    require(report["logicalBytesWritten"] == rows[-1]["cumulativeLogicalWriteBytes"], "Payload mismatch")
    require(report["processDiskWriteBytes"] >= rows[-1]["processDiskWriteBytes"], "Disk counter mismatch")
    require(math.isclose(report["persistentCommitP95MS"], percentile([r["latencyMS"] for r in rows]),
                         rel_tol=1e-9, abs_tol=1e-9), "Latency percentile mismatch")
    failed = report["failedAtEvent"]
    require((failed is None and count == report["requestedEvents"] and report["completeRequestedScenario"])
            or (failed == count + 1 and count < report["requestedEvents"]
                and not report["completeRequestedScenario"]), "Failure/count contradiction")
    for name in ["recoveredCursorMatches", "recoveredContentMatches", "recoveredToolsMatch",
                 "recoveredArtifactUpdatesMatch", "unknownReceiptRetained"]:
        require(report[name] is True, "Recovery failed: " + name)
    require(report["unreportedToolCount"] == count // 500 and report["providerRequests"] == 0,
            "Tool recovery or service isolation mismatch")
    require(load(root / str(report["requestedEvents"]) / "report.json") == report,
            "Per-scenario and aggregate reports differ")
    return rows


def normalized_method(text, name):
    text = re.sub(r"//[^\n]*", "", text)
    match = re.search(r"\b(?:init|func\s+" + re.escape(name) + r")\s*\(" if name == "init"
                      else r"\bfunc\s+" + re.escape(name) + r"\s*\(", text)
    require(match is not None, "Missing original method: " + name)
    start = text.index("{", match.end())
    depth, end = 1, start + 1
    while depth:
        require(end < len(text), "Unterminated method")
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
        end += 1
    body = text[start:end].replace("payloadBytesWritten += UInt64(data.count)", "")
    return re.sub(r"\s+", "", body)


def audit_subject(root, label, stage, object_identity):
    subject = load(root / "subject.json")
    require(subject["label"] == label and subject["providerRequests"] == 0, "Invalid workload subject")
    require(subject["binarySHA256"] == sha(root / "journal-probe"), "Binary identity changed")
    sources = {r["path"]: r["sha256"] for r in subject["sources"]}
    require(len(sources) == len(subject["sources"]), "Duplicate subject source")
    expected = {r["path"]: r["sha256"] for r in stage["files"]
                if r["path"].startswith("Sources/ClipSlotsKit/") and r["path"].endswith(".swift")}
    require({p: h for p, h in sources.items() if p.startswith("Sources/ClipSlotsKit/")} == expected,
            "Measured Kit differs from accepted S4 source")
    require(all(sha(root / "source" / p) == h for p, h in sources.items()), "Frozen source changed")
    objects = {r["path"]: r["sha256"] for r in subject["objects"]}
    require(len(objects) == len(subject["objects"]) and bool(objects), "Invalid linked objects")
    if object_identity is not None:
        require(objects == object_identity, "Comparison uses different linked Kit objects")
    reports = load(root / "report.json")
    require([r["requestedEvents"] for r in reports] == [1000, 10000, 50000], "Incomplete run")
    require(all(r["label"] == label for r in reports), "Mixed report labels")
    return subject, [checked_samples(root, r) for r in reports], reports, objects


def compare(baseline, candidate, accepted, original):
    stage = load(accepted)
    require(stage["verification"]["journal"] == 105 and stage["verification"]["kit"] == 38112,
            "Missing final durability/build acceptance")
    bs, br, bp, objects = audit_subject(baseline, "baseline-mixed", stage, None)
    cs, cr, cp, _ = audit_subject(candidate, "candidate-mixed", stage, objects)
    require(bs["sources"] == cs["sources"], "Different measurement sources")
    reference = (baseline / "source/scripts/gateway-fixtures/JournalBaselineReference.swift").read_text()
    original_text = original.read_text()
    for name in ["init", "digest", "load", "save", "acquire", "release"]:
        require(normalized_method(reference, name) == normalized_method(original_text, name),
                "Original journal behavior changed in benchmark: " + name)
    rows = []
    for b_report, c_report, b_samples, c_samples in zip(bp, cp, br, cr):
        common = min(len(b_samples), len(c_samples))
        require([r["deltaBytes"] for r in b_samples[:common]] ==
                [r["deltaBytes"] for r in c_samples[:common]], "Common-prefix input differs")
        metrics = {}
        for name, field in [("encodedPayload", "cumulativeLogicalWriteBytes"),
                            ("processDiskWrites", "processDiskWriteBytes")]:
            b, c = b_samples[common - 1][field], c_samples[common - 1][field]
            require(b > 0, "Zero baseline write counter")
            metrics[name] = {"baselineBytes": b, "candidateBytes": c,
                             "reduction": 1 - c / b, "reductionAtLeast50Percent": c * 2 <= b}
        rows.append({
            "requestedEvents": b_report["requestedEvents"], "commonCommittedEvents": common,
            "baselineCommittedEvents": len(b_samples), "candidateCommittedEvents": len(c_samples),
            "baselineFailedAtEvent": b_report["failedAtEvent"], "metricsAtCommonPrefix": metrics,
            "baselinePrefixCommitP95MS": percentile([r["latencyMS"] for r in b_samples[:common]]),
            "candidatePrefixCommitP95MS": percentile([r["latencyMS"] for r in c_samples[:common]]),
            "candidateFullCommitP95MS": c_report["persistentCommitP95MS"],
            "candidateCompleteRequestedScenario": c_report["completeRequestedScenario"],
            "candidateRecoveredToolCount": c_report["unreportedToolCount"],
            "recoveryMatches": True,
        })
    passed = all(r["candidateCompleteRequestedScenario"] and r["candidateFullCommitP95MS"] <= 50 and
                 all(m["reductionAtLeast50Percent"] for m in r["metricsAtCommonPrefix"].values()) for r in rows)
    return {
        "scope": "K07 journal persistence; Debug Kit with optimized entry; no GUI/device/service acceptance",
        "stageManifestSHA256": sha(accepted), "originalJournalSHA256": sha(original),
        "comparisonScriptSHA256": sha(Path(__file__)), "providerRequests": 0,
        "baselineSubjectSHA256": sha(baseline / "subject.json"),
        "candidateSubjectSHA256": sha(candidate / "subject.json"),
        "rows": rows, "durabilityAssertions": stage["verification"]["journal"], "K07Passed": passed,
        "limitations": [
            "Process disk counters include sample logging and filesystem accounting; they are not database-only bytes",
            "End-of-scenario flush bytes are excluded equally by using the last common committed sample",
            "Other headless resource workloads ran concurrently; journal latency is not GUI latency or hardware FPS",
            "The original 50k run can fail at its existing 32 MB limit; only committed common prefixes are compared",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["baseline", "candidate", "accepted", "original", "output"]:
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    result = compare(args.baseline, args.candidate, args.accepted, args.original)
    require(args.output.parent.is_dir() and not args.output.exists(), "Use a new archive destination")
    for root in [args.baseline, args.candidate]:
        require(all(not p.is_symlink() for p in root.rglob("*")), "Symlink in evidence archive")
    args.output.mkdir(mode=0o700)
    shutil.copytree(args.baseline, args.output / "baseline-mixed")
    shutil.copytree(args.candidate, args.output / "candidate-mixed")
    shutil.copy2(Path(__file__), args.output / Path(__file__).name)
    shutil.copy2(args.original, args.output / "original-journal.swift")
    shutil.copy2(args.accepted, args.output / "accepted-source.json")
    for key, filename in [("baselineSubjectSHA256", "baseline-mixed/subject.json"),
                          ("candidateSubjectSHA256", "candidate-mixed/subject.json"),
                          ("originalJournalSHA256", "original-journal.swift"),
                          ("stageManifestSHA256", "accepted-source.json")]:
        require(sha(args.output / filename) == result[key], "Archive identity mismatch")
    # Repeat the audit on archived bytes; copied DBs, binaries and raw samples remain reproducible.
    archived = compare(args.output / "baseline-mixed", args.output / "candidate-mixed",
                       args.output / "accepted-source.json", args.output / "original-journal.swift")
    require(archived["rows"] == result["rows"] and archived["K07Passed"] == result["K07Passed"],
            "Archived results differ")
    (args.output / "comparison.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    hashes = [{"path": str(p.relative_to(args.output)), "sha256": sha(p)}
              for p in sorted(args.output.rglob("*")) if p.is_file()]
    (args.output / "hashes.json").write_text(json.dumps(hashes, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if not result["K07Passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
