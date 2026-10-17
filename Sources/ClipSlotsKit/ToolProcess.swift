import Foundation
import Darwin

@_silgen_name("proc_listchildpids")
private func toolChildPIDs(_ parent: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

/// Bounded, cancellable subprocess capture. The worker drains both pipes concurrently with
/// nonblocking reads; an inherited pipe in a child cannot keep the caller waiting forever.
public enum ToolProcess {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let stopped: Bool
        public let truncated: Bool
        public init(status: Int32, stdout: String, stderr: String,
                    stopped: Bool = false, truncated: Bool = false) {
            self.status = status; self.stdout = stdout; self.stderr = stderr
            self.stopped = stopped; self.truncated = truncated
        }
    }

    public enum Failure: LocalizedError {
        case timeout
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .timeout: return "操作超时，请检查网络后重试。"
            case .failed(let text): return text
            }
        }
    }

    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    private static func terminateChildren(_ pid: Int32, depth: Int = 0) {
        guard depth < 16 else { return }
        var children = [Int32](repeating: 0, count: 1024)
        let bytes = children.withUnsafeMutableBytes {
            toolChildPIDs(pid, $0.baseAddress, Int32($0.count))
        }
        for child in children.prefix(max(0, min(children.count, Int(bytes) / 4))) where child > 1 {
            terminateChildren(child, depth: depth + 1)
            kill(child, SIGTERM)
        }
    }

    public static func run(_ executable: String, _ arguments: [String],
                           environment: [String: String]? = nil, directory: URL? = nil,
                           timeout: TimeInterval = 30, outputLimit: Int = 1_048_576,
                           captureStoppedOutput: Bool = false,
                           onStandardOutputLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                if cancellation.isCancelled { throw CancellationError() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = directory
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                try process.run()
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                let outFD = out.fileHandleForReading.fileDescriptor
                let errFD = err.fileHandleForReading.fileDescriptor
                _ = fcntl(outFD, F_SETFL, O_NONBLOCK)
                _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
                defer {
                    try? out.fileHandleForReading.close()
                    try? err.fileHandleForReading.close()
                }
                var stdout = Data(), stderr = Data()
                var pendingLine = Data()
                var truncated = false
                var buffer = [UInt8](repeating: 0, count: 16384)
                func drain(_ fd: Int32, into data: inout Data) {
                    // Bound each turn too: a noisy child must not prevent timeout/cancellation.
                    for _ in 0..<64 {
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        guard count > 0 else { break }
                        if data.count + count > outputLimit { truncated = true }
                        if data.count < outputLimit {
                            data.append(contentsOf: buffer.prefix(min(count, outputLimit - data.count)))
                        }
                        if fd == outFD, let onStandardOutputLine {
                            pendingLine.append(contentsOf: buffer.prefix(count))
                            while let end = pendingLine.firstIndex(of: 10) {
                                onStandardOutputLine(String(decoding: pendingLine[..<end], as: UTF8.self))
                                pendingLine.removeSubrange(...end)
                            }
                            if pendingLine.count > outputLimit { pendingLine.removeAll(); truncated = true }
                        }
                    }
                }
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                var stoppedAt: TimeInterval?
                var timedOut = false
                while true {
                    drain(outFD, into: &stdout); drain(errFD, into: &stderr)
                    guard process.isRunning else { break }
                    let now = ProcessInfo.processInfo.systemUptime
                    if stoppedAt == nil, cancellation.isCancelled || now >= deadline {
                        timedOut = !cancellation.isCancelled
                        stoppedAt = now
                        terminateChildren(process.processIdentifier)
                        process.terminate()
                    }
                    if let stoppedAt, now - stoppedAt > 1, process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    // Keep Process.run / waitUntilExit on the same worker thread.
                    // Suspending this detached task can migrate it and leave
                    // Foundation's launch-thread run-loop source undrained.
                    usleep(20_000)
                }
                process.waitUntilExit()
                drain(outFD, into: &stdout); drain(errFD, into: &stderr)
                if !captureStoppedOutput {
                    if cancellation.isCancelled { throw CancellationError() }
                    if timedOut { throw Failure.timeout }
                }
                return Output(status: process.terminationStatus,
                              stdout: String(decoding: stdout, as: UTF8.self),
                              stderr: String(decoding: stderr, as: UTF8.self),
                              stopped: timedOut || cancellation.isCancelled, truncated: truncated)
            }.value
        }, onCancel: { cancellation.cancel() })
    }
}
