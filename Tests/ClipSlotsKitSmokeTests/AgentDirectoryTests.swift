import Foundation
import ClipSlotsKit

private final class DirectoryEmptyTools: AgentToolExecuting {
    func specs() -> [AgentToolSpec] { [] }
    func execute(call: AgentToolCall) async -> AgentToolResult { .failure("not registered") }
}

func runAgentDirectoryTests(_ t: TestRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory '\(UUID())")
    let working = root.appendingPathComponent("项目 with spaces")
    let outside = root.appendingPathComponent("outside")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        for url in [working, outside] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let file = working.appendingPathComponent("输入.md")
        let bytes = Data("LOCAL_DIRECTORY_MARKER_42\n你好🙂".utf8)
        try bytes.write(to: file)
        let authorization = try AgentWorkingDirectory.authorize(working)
        let catalog = AgentDirectoryCatalog(root: root)
        try catalog.save([authorization])
        t.equal(try catalog.load(), [authorization], "DIR catalog and OS bookmark round trip")
        let resolved = try catalog.load()[0].resolve()
        t.equal(try resolved.read("输入.md"), bytes, "DIR restored grant reads exact UTF8 data")
        t.check(resolved.isWritable, "DIR writable selected folder")
        let data = try resolved.list()
        t.equal(data["entries"]?.arrayValue?.first?["name"], .string("输入.md"), "DIR folder enumeration")
        try resolved.write("结果.md", data: Data("输出".utf8), expectedDigest: nil)
        t.equal(try String(contentsOf: working.appendingPathComponent("结果.md")), "输出", "DIR create file")
        try resolved.write("结果.md", data: bytes, expectedDigest: AgentDirectoryAccess.digest(Data("输出".utf8)))
        t.equal(try resolved.read("结果.md"), bytes, "DIR update with exact original digest")
        t.expectThrows("DIR stale hash rejected") {
            try resolved.write("结果.md", data: Data(), expectedDigest: "stale")
        }
        t.expectThrows("DIR create does not overwrite existing file") {
            try resolved.write("结果.md", data: Data(), expectedDigest: nil)
        }
        for path in ["../outside/a", "/etc/hosts", "a/../../outside", "a\0b", "~/.ssh/id"] {
            t.expectThrows("DIR outside path blocked \(path)") { _ = try resolved.read(path) }
        }
        try Data("external".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(at: working.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: working.appendingPathComponent("leaf.md"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.md"))
        t.expectThrows("DIR parent symlink cannot escape root") { _ = try resolved.read("link/secret.md") }
        t.expectThrows("DIR leaf symlink cannot escape root") { _ = try resolved.read("leaf.md") }
        t.expectThrows("DIR symlink write blocked") { try resolved.write("link/new.md", data: bytes, expectedDigest: nil) }
        t.expectThrows("DIR regular file cannot be selected") { _ = try AgentWorkingDirectory.authorize(file) }
        t.expectThrows("DIR missing folder cannot be selected") { _ = try AgentWorkingDirectory.authorize(root.appendingPathComponent("missing")) }
        t.expectThrows("DIR remote URL cannot be selected") { _ = try AgentWorkingDirectory.authorize(URL(string: "https://example.test")!) }
        try Data(repeating: 0, count: AgentDirectoryAccess.maxFileBytes + 1).write(to: working.appendingPathComponent("large"))
        t.expectThrows("DIR oversized read blocked") { _ = try resolved.read("large") }
        for i in 0..<105 { try Data().write(to: outside.appendingPathComponent("f\(i)")) }
        let pages = try AgentDirectoryAccess(url: outside)
        let first = try pages.list()
        let next = try pages.list(offset: first["next_offset"]?.intValue ?? 0)
        t.equal(first["entries"]?.arrayValue?.count, 100, "DIR list is bounded")
        t.equal(next["entries"]?.arrayValue?.count, 6, "DIR list pagination no dropped entries")
        let asynchronous: [(Bool, String)] = smokeAwait {
            var results: [(Bool, String)] = []
            func call(_ name: String, _ values: JSONValue) throws -> AgentToolCall {
                .init(id: UUID().uuidString, name: name, argumentsJSON: try values.encodedText())
            }
            do {
                let yes = AgentDirectoryTools(base: DirectoryEmptyTools(), access: resolved) { request in
                    _ = try? await request.respond(["decision": "accept"])
                }
                let no = AgentDirectoryTools(base: DirectoryEmptyTools(), access: resolved) { request in
                    _ = try? await request.respond(["decision": "decline"])
                }
                let readOnly = AgentDirectoryTools(base: DirectoryEmptyTools(), access: resolved, readOnly: true) { _ in }
                let read = try call("local_read_file", ["path": "输入.md"])
                let readResult = await yes.execute(call: read)
                results.append((!readResult.isFailure && readResult.content.contains("LOCAL_DIRECTORY_MARKER_42"), "DIR read tool returns actual content"))
                let update = try call("local_write_file", ["path": "输入.md", "content": "allowed", "expected_sha256": .string(AgentDirectoryAccess.digest(bytes))])
                let denied = await no.execute(call: update)
                let afterDeny = try resolved.read("输入.md")
                results.append((denied.isFailure && afterDeny == bytes, "DIR refused edit leaves original bytes"))
                let readonlyResult = await readOnly.execute(call: update)
                results.append((readonlyResult.isFailure && !readOnly.specs().contains(where: { $0.name == "local_write_file" }), "DIR canvas read-only tool cannot write"))
                let approved = await yes.execute(call: update)
                let afterApprove = try resolved.read("输入.md")
                results.append((!approved.isFailure && afterApprove == Data("allowed".utf8), "DIR approved edit writes file"))
                let stale = await yes.execute(call: update)
                results.append((stale.isFailure, "DIR repeated old edit cannot overwrite new content"))
                let target = try call("local_write_file", ["path": "cancelled.md", "content": "no", "expected_sha256": ""])
                let pending = AgentDirectoryTools(base: DirectoryEmptyTools(), access: resolved) { _ in }
                let task = Task { await pending.execute(call: target) }
                try await Task.sleep(for: .milliseconds(160))
                task.cancel()
                let cancelled = await task.value
                results.append((cancelled.isFailure && !FileManager.default.fileExists(atPath: working.appendingPathComponent("cancelled.md").path),
                                "DIR stop cancels pending approval without writing"))
                let traversal = await yes.execute(call: try call("local_read_file", ["path": "../outside/secret.md"]))
                results.append((traversal.isFailure, "DIR tool cannot read outside selected folder"))
                try bytes.write(to: file)
                let fixture = root.appendingPathComponent("tika-fixture")
                try Data(#"""
                #!/bin/sh
                printf '%s' "$PWD" > cwd.txt
                case "$*" in
                  *LOCAL_DIRECTORY_MARKER_42*)
                    printf '%s\n' '{"type":"text-delta","text":"本地读取完成"}' '{"type":"finish"}' ;;
                  *)
                    printf '%s\n' '{"type":"text-delta","text":"<clipslots-workspace-call>{\"name\":\"local_read_file\",\"arguments\":{\"path\":\"输入.md\"}}</clipslots-workspace-call>"}' '{"type":"finish"}' ;;
                esac
                """#.utf8).write(to: fixture)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
                let backend = TikaCLIService(config: .init(cliPath: fixture.path, maxToolTurns: 3))
                var config = AgentConfig()
                config.workingDirectory = resolved.url.path
                let messages = try await backend.run(history: [.init(role: .user, content: "读取输入文件")],
                    config: config, tools: yes, onEvent: { _ in })
                results.append((messages.last?.content == "本地读取完成"
                    && messages.contains(where: { $0.role == .tool && $0.content.contains("LOCAL_DIRECTORY_MARKER_42") }),
                                "DIR Tika subprocess requests and receives real local tool output"))
                let cwd = try String(contentsOf: working.appendingPathComponent("cwd.txt"))
                let actualRoot = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath()
                results.append((actualRoot.path == resolved.url.standardizedFileURL.resolvingSymlinksInPath().path,
                                "DIR Tika subprocess uses selected root with spaces and Unicode"))
            } catch { results.append((false, "DIR async checks \(error)")) }
            return results
        }
        for (passed, name) in asynchronous { t.check(passed, name) }
        let malformed = AgentDirectoryToolBridge.calls(in: "<clipslots-workspace-call>{bad")
        t.equal(malformed.first?.name, "local_invalid", "DIR malformed bridge is rejected explicitly")
        let outsideCommand = AgentDirectoryToolBridge.calls(in: #"<clipslots-workspace-call>{"name":"shell","arguments":{}}</clipslots-workspace-call>"#)
        t.equal(outsideCommand.first?.name, "local_invalid", "DIR bridge cannot invoke arbitrary tools")
        var display = AgentDirectoryDisplayFilter()
        let parts = ["开始<clipslots-work", "space-call>{\"content\":\"秘密正文\"}</clipslots-work", "space-call>结束"]
        let visible = parts.map { display.feed($0) }.joined() + display.finish()
        t.equal(visible, "开始结束", "DIR chunked tool payloads stay out of chat bubbles")
        t.equal(AgentDirectoryDisplayFilter.visible("普通文本 < 3"), "普通文本 < 3", "DIR normal text is unchanged")
        try Data("damaged".utf8).write(to: catalog.url)
        t.expectThrows("DIR corrupt catalog is not overwritten") { try catalog.save([]) }
        t.equal(try String(contentsOf: catalog.url), "damaged", "DIR preserves damaged catalog bytes")
    } catch {
        if ProcessInfo.processInfo.environment["CLIPSLOTS_DIRECTORY_DIAGNOSTIC"] == "1" {
            let copy = URL(fileURLWithPath: "/tmp/clipslots-directory-failure")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: root, to: copy)
        }
        t.check(false, "DIR setup failed \(error)")
    }
}
