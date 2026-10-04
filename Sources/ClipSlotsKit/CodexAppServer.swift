import Foundation

public enum CodexPreferences {
    public static let workspaceBackendKey = "agent.workspace.backend"
    public static let cliPathKey = "agent.codex.cliPath"
    public static let modelKey = "agent.codex.model"
    public static let effortKey = "agent.codex.effort"
    public static let sandboxKey = "agent.codex.sandbox"

    public static func executable(customPath: String = "", bundlePath: String = Bundle.main.bundlePath) -> String? {
        let custom = (customPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        if !custom.isEmpty {
            return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil
        }
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            bundlePath + "/Contents/Resources/codex-runtime/bin/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public struct CodexServerConfiguration: Sendable {
    public var executable: String
    public var workingDirectory: String
    /// nil reuses official Codex credentials. Tests supply a temporary empty home.
    public var codexHome: String?
    public var arguments: [String]
    public var fallbackExecutable: String?
    public var followsInstalledRuntime = false
    public var bridgeExecutable: String?
    public var bridgeSkillSlugs: [String] = []
    public var modelProvider: String?
    public var projectID: String?
    public var sandbox = "read-only"
    /// Background tasks keep "never"; interactive chats explicitly opt in.
    public var interactiveRequests = false
    public var interactionTimeout: TimeInterval = 300

    public init(executable: String, workingDirectory: String, codexHome: String? = nil,
                arguments: [String] = ["app-server"]) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.codexHome = codexHome
        self.arguments = arguments
    }
}

public struct CodexServerError: LocalizedError, Sendable {
    public let message: String
    public let code: Int?
    public init(_ message: String, code: Int? = nil) { self.message = message; self.code = code }
    public var isUnsupported: Bool { code == -32601 }
    public var errorDescription: String? { message }
}

/// The stdout reader is independent of requests and tools. A tool can await a local
/// process without blocking JSON-RPC replies, cancellation, or stderr drainage.
public actor CodexAppServer {
    public nonisolated let events: AsyncThrowingStream<JSONValue, Error>
    private let eventContinuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiveBuffer = Data()
    private var closed = false
    private var started = false
    private var activeTurn: (thread: String, turn: String)?
    private var reader: Task<Void, Never>?
    private var errorReader: Task<Void, Never>?

    public init() {
        var continuation: AsyncThrowingStream<JSONValue, Error>.Continuation!
        events = AsyncThrowingStream { continuation = $0 }
        eventContinuation = continuation
    }

    public func start(_ configuration: CodexServerConfiguration) async throws {
        guard !started, !closed else { throw CodexServerError("Codex 连接已关闭，请重试。") }
        started = true
        try FileManager.default.createDirectory(atPath: configuration.workingDirectory, withIntermediateDirectories: true)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: configuration.executable)
        child.arguments = configuration.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)
        var environment = ProcessInfo.processInfo.environment
        if let home = configuration.codexHome { environment["CODEX_HOME"] = home }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" +
            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        child.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        do { try child.run() } catch {
            close(error: CodexServerError("无法启动 Codex，请检查设置中的程序路径。"))
            throw CodexServerError("无法启动 Codex：\(error.localizedDescription)")
        }
        process = child
        input = stdin.fileHandleForWriting
        reader = Task.detached { [weak self] in
            let handle = stdout.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                await self?.receive(data)
            }
            try? handle.close()
            await self?.close(error: CodexServerError("Codex 连接已结束，请重试。"))
        }
        // Do not retain or log stderr: CLI diagnostics can contain account details.
        errorReader = Task.detached {
            let handle = stderr.fileHandleForReading
            while !handle.availableData.isEmpty {}
            try? handle.close()
        }
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "clipslots", "title": "ClipSlots", "version": "2.17.8"],
            "capabilities": ["experimentalApi": true]
        ])
        try notify("initialized", params: [:])
    }

    public func request(_ method: String, params: JSONValue = [:], timeout: TimeInterval = 30) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do { try write(["id": .string(id), "method": .string(method), "params": params]) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.expire(id)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    public func notify(_ method: String, params: JSONValue) throws {
        try write(["method": .string(method), "params": params])
    }

    public func respond(id: JSONValue, result: JSONValue) throws {
        try write(["id": id, "result": result])
    }

    public func reject(id: JSONValue) throws {
        try write(["id": id, "error": ["code": -32601, "message": "ClipSlots does not support this request."]])
    }

    public func trackTurn(thread: String, turn: String) { activeTurn = (thread, turn) }

    public func interrupt() async {
        if let activeTurn {
            _ = try? await request("turn/interrupt",
                params: ["threadId": .string(activeTurn.thread), "turnId": .string(activeTurn.turn)], timeout: 1)
        }
        close()
    }

    private func write(_ value: JSONValue) throws {
        guard !closed, let input else { throw CodexServerError("Codex 尚未连接。") }
        var data = try JSONEncoder().encode(value)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 10) {
            let line = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= 8_000_000, let json = try? JSONDecoder().decode(JSONValue.self, from: line) else {
                close(error: CodexServerError("Codex 返回了无法解析的消息。请检查运行程序版本。"))
                return
            }
            if json["method"] != nil {
                eventContinuation.yield(json)
            } else if let id = json["id"]?.stringValue, let continuation = pending.removeValue(forKey: id) {
                if let error = json["error"] {
                    continuation.resume(throwing: CodexServerError(error["message"]?.stringValue ?? "Codex 请求失败。",
                                                                  code: error["code"]?.intValue))
                } else {
                    continuation.resume(returning: json["result"] ?? .null)
                }
            }
        }
        if receiveBuffer.count > 8_000_000 {
            close(error: CodexServerError("Codex 消息超出大小限制。"))
        }
    }

    private func expire(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: CodexServerError("Codex 请求超时，请检查网络后重试。"))
    }

    private func cancelRequest(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    public func close(error: Error? = nil) {
        guard !closed else { return }
        closed = true
        try? input?.close()
        input = nil
        let child = process
        process = nil
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        for continuation in pending.values {
            continuation.resume(throwing: error ?? CancellationError())
        }
        pending.removeAll()
        if let error { eventContinuation.finish(throwing: error) }
        else { eventContinuation.finish() }
        reader?.cancel()
        reader = nil
        errorReader = nil
    }
}
