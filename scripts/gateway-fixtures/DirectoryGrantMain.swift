import Foundation
import Darwin
import ClipSlotsKit

@main enum DirectoryGrantMain {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.hasPrefix("/private/tmp/clipslots-directory-grant-") else { exit(2) }
        var checks: [JSONValue] = []
        func check(_ passed: Bool, _ name: String) { checks.append(["name": .string(name), "passed": .bool(passed)]) }
        let first = root.appendingPathComponent("项目 A"), second = root.appendingPathComponent("项目 B")
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("first-marker".utf8).write(to: first.appendingPathComponent("input.txt"))
        try Data("second-marker".utf8).write(to: second.appendingPathComponent("input.txt"))
        let catalogRoot = root.appendingPathComponent("catalog")
        let store = AgentWorkingDirectoryStore(root: catalogRoot)
        let id = try await store.add(first)
        let grant = try store.access(id)
        check(try grant.read("input.txt") == Data("first-marker".utf8), "native Store grants actual selected directory")
        let duplicate = try await store.add(first)
        check(duplicate == id && store.directories.count == 1 && !grant.isActive,
              "native Store reauthorization revokes previously retained invocation grant")
        let renewed = try store.access(id)
        let replacement = try await store.add(second, replacing: id)
        check(replacement == id && !renewed.isActive && store.entry(id)?.path == canonical(second),
              "native Store replacing authorization revokes old root before next invocation")
        let newGrant = try store.access(id)
        try store.remove(id)
        check(!newGrant.isActive && store.directories.isEmpty, "native Store remove expires live grant")
        do { _ = try store.access(id); check(false, "removed grant cannot resolve to Home or another root") }
        catch { check(true, "removed grant cannot resolve to Home or another root") }
        check(try Data(contentsOf: second.appendingPathComponent("input.txt")) == Data("second-marker".utf8),
              "native Store remove leaves directory bytes")
        let movedID = try await store.add(first)
        let moved = root.appendingPathComponent("项目 A moved")
        try FileManager.default.moveItem(at: first, to: moved)
        let relocated = try store.access(movedID)
        let relocatedBytes = try relocated.read("input.txt")
        check(relocated.url.path == canonical(moved) && store.entry(movedID)?.path == canonical(moved)
              && relocatedBytes == Data("first-marker".utf8),
              "actual OS stale/moved bookmark refresh persists relocated directory with same identity")
        let reopened = AgentWorkingDirectoryStore(root: catalogRoot)
        let reopenedBytes = try reopened.access(movedID).read("input.txt")
        check(reopened.entry(movedID)?.path == canonical(moved)
              && reopenedBytes == Data("first-marker".utf8),
              "native Store reopen restores refreshed OS bookmark")
        try FileManager.default.removeItem(at: moved)
        do { _ = try reopened.access(movedID); check(false, "deleted bookmarked root has no fallback") }
        catch { check(true, "deleted bookmarked root has no fallback") }
        var invalid = try AgentWorkingDirectory.authorize(second)
        invalid.bookmark = Data("invalid-bookmark".utf8)
        do { _ = try invalid.resolve(); check(false, "invalid OS bookmark cannot fall back to stored text path") }
        catch { check(true, "invalid OS bookmark cannot fall back to stored text path") }
        let corruptRoot = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptFile = corruptRoot.appendingPathComponent("agent-workdirs.json")
        try Data("corrupt-catalog-marker".utf8).write(to: corruptFile)
        let corrupt = AgentWorkingDirectoryStore(root: corruptRoot)
        check(corrupt.error != nil && corrupt.directories.isEmpty, "native Store exposes corrupt catalog without reset")
        do { _ = try await corrupt.add(second); check(false, "native Store does not overwrite corrupt catalog") }
        catch { check(try Data(contentsOf: corruptFile) == Data("corrupt-catalog-marker".utf8),
                      "native Store does not overwrite corrupt catalog") }
        print(try JSONValue.object(["checks": .array(checks),
              "failed": .number(Double(checks.filter { $0["passed"] != true }.count))]).encodedText())
    }
}
