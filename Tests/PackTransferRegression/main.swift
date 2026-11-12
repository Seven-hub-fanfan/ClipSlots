import Foundation
import ClipSlotsKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let environment = ProcessInfo.processInfo.environment
precondition(environment["CLIPSLOTS_DATA_DIR"] == root.appendingPathComponent("data").path)
precondition(environment["CLIPSLOTS_CONFIG_PATH"] == root.appendingPathComponent("config.toml").path)
let fm = FileManager.default
let storage = SpecialSlotStorage.shared
var checks: [[String: Any]] = []
func record(_ name: String, _ body: () throws -> Bool) {
    do { checks.append(["case": name, "passed": try body()]) }
    catch { checks.append(["case": name, "passed": false, "error": error.localizedDescription]) }
}
func rejects(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}
func importFile(_ url: URL, limit: Int = 10, append: Bool = false) throws -> PackImportResult {
    try PackImporter(maxChildSlots: limit).importPack(from: url,
        resolvePageConflict: { _ in append ? .append : .overwrite },
        resolveGroupConflict: { _, _ in .overwrite })
}
func contents(_ group: String) -> Bool {
    let content = storage.get(1, in: group)
    return content.items.first?.first?.data == Data("正文 100% %@ 中文".utf8) &&
        storage.getLabel(1, in: group) == "用户标题" &&
        content.attachments.count == 2 &&
        content.attachments[0].resolveData() == Data("附件完整性".utf8) &&
        content.attachments[1].resolveData() == Data()
}

let page = try storage.createPage(name: "Transfer", withDefaultGroup: false).page
let group = try storage.createSpecialSlot(name: "Media", pageId: page.id)
try storage.updateGroupAppearances([(group.id, "star.fill", "#6B8A77")])
let empty = root.appendingPathComponent("empty.txt")
try Data().write(to: empty)
var content = SlotContent()
content.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data("正文 100% %@ 中文".utf8))]]
content.attachments = [.init(name: "资料.txt", type: .file, data: Data("附件完整性".utf8)),
                       .init(name: "empty.txt", type: .file, path: empty.path)]
precondition(storage.set(1, content: content, in: group.id))
precondition(storage.setLabel(1, label: "用户标题", in: group.id))
precondition(storage.setLabel(10, label: "Only label", in: group.id))
let freshGroup = storage.loadIndex().specialSlots.first { $0.id == group.id }!
let selection = PackExportSelection(pages: [.init(page: page, groups: [freshGroup])])
let exporter = PackExporter(maxChildSlots: 10, appVersion: "2.17.108")
let source = root.appendingPathComponent("source.clipslotspack")
var progress: [(Int, Int)] = []
let exported = try exporter.export(selection, to: source) { done, total, _ in progress.append((done, total)) }
record("zero-byte attachment exported") { exported.failedAttachments.isEmpty }
record("export progress counts label-only slot") { progress.contains { $0 == 2 && $1 == 2 } }
record("empty selection rejected") {
    rejects { try exporter.export(PackExportSelection(pages: []), to: source) }
}
record("existing destination remains valid after overwrite") {
    try exporter.export(selection, to: source)
    return try PackImporter(maxChildSlots: 10).readManifest(from: source).pages[0].slotCount == 2
}
let directory = root.appendingPathComponent("destination-directory.clipslotspack")
try fm.createDirectory(at: directory, withIntermediateDirectories: false)
try Data("preserve".utf8).write(to: directory.appendingPathComponent("sentinel"))
record("failed destination replacement preserves original") {
    let failed = rejects { try exporter.export(selection, to: directory) }
    return failed && fm.fileExists(atPath: directory.appendingPathComponent("sentinel").path)
}
let fixture = Process()
fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
fixture.arguments = ["python3", CommandLine.arguments[2], root.path]
try fixture.run()
fixture.waitUntilExit()
precondition(fixture.terminationStatus == 0)

var renamed: [URL] = []
for name in ["renamed.clipslotspack", "UPPER.CLIPSLOTSPACK", "中文 空格.clipslotspack",
             "no-extension", "renamed.zip", "scene [final].bin", "scene *.bin", "scene ?.bin",
             "-leading.bin", "emoji 🎨.bin", "percent%20 #.bin", "multi.part.final.dat",
             "改名\n换行.bin"] {
    let url = root.appendingPathComponent(name)
    try fm.copyItem(at: source, to: url)
    renamed.append(url)
    record("renamed roundtrip: \(name)") {
        let result = try importFile(url)
        return result.importedSlots == 2 && result.errors.isEmpty && contents(group.id)
    }
}
record("relative path roundtrip") {
    let url = URL(fileURLWithPath: "source.clipslotspack", relativeTo: root)
    return try importFile(url).importedSlots == 2 && contents(group.id)
}
record("moved nested directory roundtrip") {
    let destination = root.appendingPathComponent("folder/moved package.bin")
    try fm.copyItem(at: source, to: destination)
    return try importFile(destination).importedSlots == 2 && contents(group.id)
}
record("new group retains icon and color") {
    let before = Set(storage.loadIndex().specialSlots.map(\.id))
    _ = try importFile(source, append: true)
    let imported = storage.loadIndex().specialSlots.first { !before.contains($0.id) && $0.name == "Media" }
    return imported?.icon == "star.fill" && imported?.colorHex == "#6B8A77"
}
for name in ["legacy-slot-scan", "legacy-page-fallback", "legacy-no-thumbnail", "zip64"] {
    record(name) { try importFile(root.appendingPathComponent(name + ".bin")).importedSlots == 2 }
}
for name in ["corrupt-slot", "missing-attachment", "unsupported-version", "bad-count",
             "duplicate-page", "duplicate-slot", "bad-slot-number", "missing-thumbnail",
             "parent-path", "absolute-path", "newline-path", "case-collision",
             "file-directory-collision", "oversize-json", "symlink", "truncated", "crc-mismatch"] {
    record("reject and preserve: \(name)") {
        let ids = Set(storage.loadIndex().specialSlots.map(\.id))
        let original = storage.get(1, in: group.id).contentId
        let failed = rejects { _ = try importFile(root.appendingPathComponent(name + ".bin")) }
        return failed && ids == Set(storage.loadIndex().specialSlots.map(\.id)) &&
            original == storage.get(1, in: group.id).contentId
    }
}
record("smaller slot configuration rejects instead of truncating") {
    rejects { _ = try importFile(source, limit: 5) }
}
record("larger slot configuration compatible") { try importFile(source, limit: 20).importedSlots == 2 }
record("page skip preserves data") {
    let result = try PackImporter(maxChildSlots: 10).importPack(from: source,
        resolvePageConflict: { _ in .skip }, resolveGroupConflict: { _, _ in .skip })
    return result.importedSlots == 0 && contents(group.id)
}
record("group skip preserves data") {
    let result = try PackImporter(maxChildSlots: 10).importPack(from: source,
        resolvePageConflict: { _ in .overwrite }, resolveGroupConflict: { _, _ in .skip })
    return result.skippedGroups == 1 && result.importedSlots == 0 && contents(group.id)
}
record("long unicode attachment filename roundtrip") {
    var value = SlotContent()
    let name = String(repeating: "资料", count: 40) + ".txt"
    value.attachments = [.init(name: name, type: .file, data: Data("long filename".utf8))]
    guard storage.set(2, content: value, in: group.id) else { return false }
    let pack = root.appendingPathComponent("long-name.bin")
    try exporter.export(selection, to: pack)
    _ = try importFile(pack)
    let attachment = storage.get(2, in: group.id).attachments.first
    return attachment?.name == name && attachment?.resolveData() == Data("long filename".utf8)
}
#if !BASELINE
record("multi-selection recognizes every renamed pack") {
    PackImportSelection.classify(renamed, maxChildSlots: 10).allSatisfy {
        if case .pack = $0 { return true }; return false
    }
}
record("mixed selection preserves order and ordinary files") {
    let items = PackImportSelection.classify([renamed[0], root.appendingPathComponent("ordinary.txt"),
        renamed[3], root.appendingPathComponent("ordinary.zip"), root.appendingPathComponent("folder"),
        root.appendingPathComponent("fake.clipslotspack"), root.appendingPathComponent("unsupported-version.bin")],
        maxChildSlots: 10)
    return items.map {
        switch $0 { case .pack: return "pack"; case .file: return "file"; case .invalid: return "invalid" }
    } == ["pack", "file", "pack", "file", "file", "invalid", "invalid"]
}
record("unrelated ZIP manifest remains an ordinary attachment") {
    let items = PackImportSelection.classify([root.appendingPathComponent("ordinary-manifest.zip")], maxChildSlots: 10)
    if case .file = items[0] { return true }
    return false
}
record("expansion budget rejects before writing") {
    rejects { try PackArchive.read(source, limits: .init(expandedBytes: 100)) }
}
record("entry budget rejects before writing") {
    rejects { try PackArchive.read(source, limits: .init(entries: 2)) }
}
#endif
// Force a late failure after overwriting the first group, then ensure the old
// bytes and label are restored and independent imported attachments are removed.
let second = try storage.createSpecialSlot(name: "Second", pageId: page.id)
precondition(storage.set(1, content: content, in: second.id))
let two = root.appendingPathComponent("two.clipslotspack")
try exporter.export(.init(pages: [.init(page: page, groups: [freshGroup, second])]), to: two)
try storage.deleteSpecialSlot(id: second.id)
try storage.updateSettings { $0.maxSpecialSlots = 1 }
var sentinel = SlotContent()
sentinel.items = [[PasteboardItem(type: "public.utf8-plain-text", data: Data("original".utf8))]]
precondition(storage.set(1, content: sentinel, in: group.id))
precondition(storage.setLabel(1, label: "original label", in: group.id))
let attachmentRoot = ClipSlotsPaths.dataRoot.appendingPathComponent("imported_attachments")
let filesBefore = Set((try? fm.contentsOfDirectory(atPath: attachmentRoot.path)) ?? [])
record("late overwrite failure rolls back content and attachments") {
    let failed = rejects { _ = try importFile(two) }
    return failed && storage.get(1, in: group.id).items.first?.first?.data == Data("original".utf8) &&
        storage.getLabel(1, in: group.id) == "original label" &&
        filesBefore == Set((try? fm.contentsOfDirectory(atPath: attachmentRoot.path)) ?? [])
}
record("interrupted import preserves original backup") {
    let backup = ClipSlotsPaths.specialSlots.appendingPathComponent(".import_backup_\(group.id)_\(UUID().uuidString)")
    try fm.copyItem(at: ClipSlotsPaths.specialSlots.appendingPathComponent(group.id), to: backup)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: backup.path)
    let failed = rejects { _ = try importFile(source) }
    return failed && fm.fileExists(atPath: backup.path) &&
        storage.get(1, in: group.id).items.first?.first?.data == Data("original".utf8)
}
let data = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("results.json"))
let failed = checks.filter { $0["passed"] as? Bool != true }
print("\(checks.count - failed.count)/\(checks.count) passed")
for item in failed { print(item) }
exit(failed.isEmpty ? 0 : 1)
