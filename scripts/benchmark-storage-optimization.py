#!/usr/bin/env python3
"""Compare production folder preview and extracted editor count against their prior implementations.

Run through disk_guard.py. All generated sources, binaries and fixtures belong
to --root; no live ClipSlots data or preferences are opened.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, required=True)
options = parser.parse_args()
root = options.root.resolve()
assert str(root).startswith("/private/tmp/clipslots-editor-20261102/performance-deep-")
root.mkdir(parents=True, exist_ok=True)
repo = Path(__file__).resolve().parent.parent
folder = repo / "Sources/ClipSlots/FolderImportService.swift"
model = repo / "Sources/ClipSlots/SlotEditorModel.swift"
source = folder.read_text()
baseline = source.replace(
    "let importableSet = Set(importable)\n        let skipped = children.filter { !importableSet.contains($0) }",
    "let skipped = children.filter { !importable.contains($0) }")
assert baseline != source
for name in ["FolderImportOptions", "FolderImportPreview", "FolderImportResult",
             "BatchImportExpansionResult", "FolderImportService"]:
    baseline = baseline.replace(name, "Baseline" + name)
(root / "Baseline.swift").write_text(baseline)
model_source = model.read_text()
count_code = model_source[model_source.index("    @Published var draft: String {"):
                          model_source.index("    @Published var attachments:")]
count_code = count_code.replace("@Published ", "")
(root / "Count.swift").write_text(
    "import Foundation\nfinal class ProductionCount {\n" + count_code +
    "    init(_ text: String) { draft = text }\n}\n")
(root / "main.swift").write_text(r'''
import Foundation
import ClipSlotsKit
import Darwin
func measure<T>(_ action: () throws -> T) rethrows -> (T, Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let value = try action()
    return (value, (ProcessInfo.processInfo.systemUptime - start) * 1000)
}
func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let actual = FolderImportService(), baseline = BaselineFolderImportService()
var rows: [[String: Any]] = [], checks: [String: Bool] = [:]
for count in [1000, 5000, 10000] {
    let folder = root.appendingPathComponent("folder-\(count)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<count {
        try Data("fixture-\(i)".utf8).write(to: folder.appendingPathComponent("file-\(i).txt"))
    }
    try fm.createDirectory(at: folder.appendingPathComponent("subfolder"), withIntermediateDirectories: true)
    try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden.txt"))
    var oldMS: [Double] = [], newMS: [Double] = []
    for trial in 0..<3 {
        let a: FolderImportPreview, b: BaselineFolderImportPreview
        let ams: Double, bms: Double
        if trial % 2 == 0 {
            (b, bms) = try measure { try baseline.preview(folderURL: folder, options: .init(maxFiles: 10)) }
            (a, ams) = try measure { try actual.preview(folderURL: folder, options: .init(maxFiles: 10)) }
        } else {
            (a, ams) = try measure { try actual.preview(folderURL: folder, options: .init(maxFiles: 10)) }
            (b, bms) = try measure { try baseline.preview(folderURL: folder, options: .init(maxFiles: 10)) }
        }
        checks["preview-\(count)-\(trial)"] = a.importableFiles == b.importableFiles
            && a.skippedURLs == b.skippedURLs && a.totalImportableCount == b.totalImportableCount
            && a.willImportFiles == b.willImportFiles && a.overflowed == b.overflowed
        oldMS.append(bms); newMS.append(ams)
    }
    rows.append(["kind": "production-folder-preview", "files": count,
                 "before_ms": oldMS, "after_ms": newMS,
                 "before_median_ms": median(oldMS), "after_median_ms": median(newMS)])
}
let text = String(repeating: "中文👨‍👩‍👧‍👦e\u{301}🇨🇳🙂\n", count: 4194304 / 48)
let cached = ProductionCount(text)
let expected = text.count
_ = cached.characterCount
let (before, oldMS) = measure { (0..<100).reduce(0) { value, _ in value + text.count } }
let (after, newMS) = measure { (0..<100).reduce(0) { value, _ in value + cached.characterCount } }
checks["cached-count-sum"] = before == after && after == 100 * expected
cached.draft += "🙂"
checks["cached-count-invalidates"] = cached.characterCount == expected + 1
cached.draft = "👨‍👩‍👧‍👦e\u{301}🇨🇳"
checks["unicode-grapheme-count"] = cached.characterCount == 3
rows.append(["kind": "production-extracted-count", "utf8_bytes": text.utf8.count,
             "reads": 100, "before_ms": oldMS, "after_ms": newMS,
             "note": "exact count-cache code extracted from SlotEditorModel; excludes native layout"])
let report: [String: Any] = ["rows": rows, "checks": checks,
                             "passed": checks.values.allSatisfy { $0 }]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("optimization-micro.json"))
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
exit(checks.values.allSatisfy { $0 } ? 0 : 1)
''')
build = repo / ".build/arm64-apple-macosx/debug"
binary = root / "optimization-micro"
subprocess.run(["swiftc", "-Onone", "-I", str(build / "Modules"),
                str(repo / "Sources/ClipSlots/ImportLimitMode.swift"),
                str(repo / "Sources/ClipSlots/BatchImportService.swift"), str(folder),
                str(root / "Baseline.swift"), str(root / "Count.swift"), str(root / "main.swift"),
                *map(str, sorted((build / "ClipSlotsKit.build").glob("*.swift.o"))),
                "-o", str(binary)], check=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_"))}
env.update(CLIPSLOTS_DATA_DIR=str(root / "data"), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
subprocess.run([str(binary), str(root / "fixtures")], env=env, check=True)
report = root / "fixtures/optimization-micro.json"
result = json.loads(report.read_text())
result["source_sha256"] = {
    str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in [folder, model, Path(__file__)]
}
(root / "optimization-micro.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
