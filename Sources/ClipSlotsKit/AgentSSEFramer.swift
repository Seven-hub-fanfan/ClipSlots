import Foundation

/// SSE frames carry opaque IDs. Only complete UTF-8 lines are decoded, even
/// when URLSession splits inside a Chinese character, emoji, BOM or CRLF.
public struct AgentSSEFrame: Equatable, Sendable {
    public let event: String
    public let id: String?
    public let data: String
}

public struct AgentSSEFramer {
    public enum FramingError: Error, Equatable { case invalidUTF8, capacityExceeded }
    public private(set) var lastEventID: String?
    public private(set) var retryMilliseconds: Int?
    private var line = Data()
    private var dataLines: [String] = []
    private var eventType = ""
    private var eventBytes = 0
    private var firstLine = true
    private var skipLF = false
    private let limit: Int

    public init(maximumEventBytes: Int = 1_048_576) { limit = max(1, maximumEventBytes) }

    public mutating func feed(_ bytes: Data) throws -> [AgentSSEFrame] {
        var frames: [AgentSSEFrame] = []
        for byte in bytes {
            if skipLF { skipLF = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                try consumeLine(into: &frames)
                skipLF = byte == 13
            } else {
                guard line.count < limit else { throw FramingError.capacityExceeded }
                line.append(byte)
            }
        }
        return frames
    }

    /// Standard SSE discards unterminated events. OpenAI compatibility may
    /// explicitly flush the last payload; that never synthesizes a DONE event.
    public mutating func finish(flushUnterminated: Bool = false) throws -> [AgentSSEFrame] {
        var frames: [AgentSSEFrame] = []
        if flushUnterminated {
            if !line.isEmpty { try consumeLine(into: &frames) }
            dispatch(into: &frames)
        }
        line.removeAll(); dataLines.removeAll(); eventBytes = 0; eventType = ""; skipLF = false
        return frames
    }

    private mutating func consumeLine(into frames: inout [AgentSSEFrame]) throws {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        guard let text = String(data: bytes, encoding: .utf8) else { throw FramingError.invalidUTF8 }
        if text.isEmpty { dispatch(into: &frames); return }
        if text.hasPrefix(":") { return }
        let separator = text.firstIndex(of: ":")
        let field = separator.map { String(text[..<$0]) } ?? text
        var value = separator.map { String(text[text.index(after: $0)...]) } ?? ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data":
            eventBytes += bytes.count + 1
            guard eventBytes <= limit else { throw FramingError.capacityExceeded }
            dataLines.append(value)
        case "event": eventType = value
        case "id":
            if !value.utf8.contains(0) { lastEventID = value }
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let retry = Int(value) {
                retryMilliseconds = retry
            }
        default: break
        }
    }

    private mutating func dispatch(into frames: inout [AgentSSEFrame]) {
        if !dataLines.isEmpty {
            frames.append(.init(event: eventType.isEmpty ? "message" : eventType,
                                id: lastEventID, data: dataLines.joined(separator: "\n")))
        }
        dataLines.removeAll(keepingCapacity: true); eventBytes = 0; eventType = ""
    }
}
