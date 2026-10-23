import Foundation
import ClipSlotsKit

private final class DirectoryEmptyTools: AgentToolExecuting {
    func specs() -> [AgentToolSpec] { [] }
    func execute(call: AgentToolCall) async -> AgentToolResult { .failure("not registered") }
}

private final class DirectoryPolicyFixtureTools: AgentToolExecuting {
    func specs() -> [AgentToolSpec] {
        ["read_slot", "write_slot", "write_attachment", "paste_slot", "run_skill_script"].map {
            .init(name: $0, description: "", parameters: ["type": "object"], originLabel: "fixture")
        }
    }
    func execute(call: AgentToolCall) async -> AgentToolResult { .init(content: "executed", summary: "fixture") }
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
                let base = DirectoryPolicyFixtureTools()
                for mode in AgentAccessMode.allCases {
                    let filtered = AgentAccessTools(base: base, mode: mode)
                    results.append((filtered.permitsCLI("write-attachment") == (mode == .fullAccess)
                        && filtered.permitsCLI("write") == (mode != .allDirectoriesReadOnly)
                        && filtered.permitsCLI("read"), "DIR \(mode.rawValue) applies same policy to Tika XML commands"))
                    for name in ["read_slot", "write_slot", "write_attachment", "paste_slot", "run_skill_script"] {
                        let allowed = name == "read_slot" || mode == .fullAccess
                            || (mode == .selectedDirectories && name == "write_slot")
                        let result = await filtered.execute(call: .init(id: UUID().uuidString, name: name, argumentsJSON: "{}"))
                        results.append((filtered.specs().contains(where: { $0.name == name }) == allowed
                            && result.isFailure != allowed, "DIR \(mode.rawValue) enforces \(name) at publication and dispatch"))
                    }
                }
                let xmlCLI = root.appendingPathComponent("xml-policy-fixture")
                try Data(#"""
                #!/bin/sh
                case "$*" in
                  *ACCESS_MODE_DENIED*) printf '%s\n' '{"type":"text-delta","text":"policy enforced"}' '{"type":"finish"}' ;;
                  *) printf '%s\n' '{"type":"text-delta","text":"<clipslots-call cmd=\"clipslots write 1 --text bypass\"/>"}' '{"type":"finish"}' ;;
                esac
                """#.utf8).write(to: xmlCLI)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xmlCLI.path)
                let scopedTools = AgentAccessTools(base: base, mode: .allDirectoriesReadOnly)
                let journaledTools = AgentJournaledTools(base: scopedTools, journal: AgentExecutionJournal(root: root),
                    scope: .init(sessionID: "fixture", projectID: nil, turnID: "fixture"))
                let xmlBackend = TikaCLIService(config: .init(cliPath: xmlCLI.path, maxToolTurns: 3),
                    localRunner: { _, _ in .init(exitCode: 99, stdout: "BYPASS_EXECUTED", stderr: "", timedOut: false) })
                let xmlMessages = try await xmlBackend.run(history: [.init(role: .user, content: "test policy")],
                    config: AgentConfig(), tools: journaledTools, onEvent: { _ in })
                results.append((xmlMessages.last?.content == "policy enforced"
                    && xmlMessages.contains(where: { $0.role == .tool && $0.content.contains("ACCESS_MODE_DENIED") })
                    && !xmlMessages.contains(where: { $0.content.contains("BYPASS_EXECUTED") }),
                    "DIR actual Tika subprocess XML cannot bypass read-only policy through journal wrapper"))
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
                let allRead = AgentDirectoryTools(base: DirectoryEmptyTools(),
                    access: try AgentDirectoryAccess(url: URL(fileURLWithPath: "/")),
                    readOnly: true, absolutePaths: true) { _ in }
                let globalRead = await allRead.execute(call: try call("local_read_file", ["path": .string(outside.appendingPathComponent("secret.md").resolvingSymlinksInPath().path)]))
                results.append((!globalRead.isFailure && globalRead.content.contains("external"), "DIR all-directory mode reads absolute path outside selected folder"))
                let globalWrite = await allRead.execute(call: try call("local_write_file", [
                    "path": .string(outside.appendingPathComponent("blocked.md").path),
                    "content": "blocked", "expected_sha256": ""]))
                results.append((globalWrite.isFailure && !FileManager.default.fileExists(atPath: outside.appendingPathComponent("blocked.md").path), "DIR all-directory read-only rejects direct write dispatch"))
                let automatic = AgentDirectoryTools(base: DirectoryEmptyTools(),
                    access: try AgentDirectoryAccess(url: URL(fileURLWithPath: "/")),
                    absolutePaths: true, automaticWrites: true) { request in
                        _ = try? await request.respond(["decision": "decline"])
                    }
                let autoTarget = outside.appendingPathComponent("automatic.md").resolvingSymlinksInPath()
                let autoResult = await automatic.execute(call: try call("local_write_file", [
                    "path": .string(autoTarget.path), "content": "full access", "expected_sha256": ""]))
                let autoContent = try String(contentsOf: autoTarget)
                results.append((!autoResult.isFailure && autoContent == "full access", "DIR Full Access performs actual authorized write without approval"))
                let restrictedAuto = automatic.restrictedForPreview()
                let restrictedResult = await restrictedAuto.execute(call: try call("local_write_file", [
                    "path": .string(autoTarget.path), "content": "blocked", "expected_sha256": ""]))
                results.append((restrictedResult.isFailure, "DIR preview restriction strips Full Access writes"))
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
