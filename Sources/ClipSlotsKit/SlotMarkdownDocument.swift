import Foundation

public extension SlotContent {
    var hasEmptyBody: Bool { items.isEmpty && htmlSource?.isEmpty != false }
    var isMarkdownFile: Bool {
        let files = detectedFileURLs
        return files.count == 1 && files[0].pathExtension.lowercased() == "md"
    }
}

/// Owns the bytes opened by the editor. A save creates a slot-owned .md file;
/// Finder sources are never rewritten. Compare bytes as well as file metadata.
public struct SlotMarkdownDocument {
    public let sourceURL: URL
    public let sourceBytes: Data
    public let text: String
    private let version: String
    private let encoding: String.Encoding
    private let bom: Data
    private let newline: String
    public static let maximumBytes = 8 * 1024 * 1024

    public init(content: SlotContent) throws {
        guard content.isMarkdownFile, let url = content.detectedFileURLs.first else {
            throw AgentOperationError("此槽位不是单个 Markdown 文件。")
        }
        sourceURL = url
        version = GenerationRunContext.fileVersion(url.path)
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true,
              (attributes.fileSize ?? Int.max) <= Self.maximumBytes else {
            throw AgentOperationError("Markdown 文件过大，暂时无法在槽位中编辑。")
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= Self.maximumBytes,
              GenerationRunContext.fileVersion(url.path) == version else { throw AgentCanvasError.conflict }
        sourceBytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = Data([0xEF, 0xBB, 0xBF]); encoding = .utf8
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            bom = Data([0xFF, 0xFE]); encoding = .utf16LittleEndian
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            bom = Data([0xFE, 0xFF]); encoding = .utf16BigEndian
        } else { bom = Data(); encoding = .utf8 }
        let payload = Data(bytes.dropFirst(bom.count))
        guard let decoded = String(data: payload, encoding: encoding),
              !decoded.contains("\0"), decoded.data(using: encoding) == payload else {
            throw AgentOperationError("无法无损读取此 Markdown 文件的编码，请先将文件转换为 UTF-8。")
        }
        newline = decoded.contains("\r\n") ? "\r\n" : decoded.contains("\r") ? "\r" : "\n"
        text = Self.normalized(decoded)
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public func validateSource(in content: SlotContent) throws {
        guard content.isMarkdownFile, content.detectedFileURLs.first == sourceURL,
              GenerationRunContext.fileVersion(sourceURL.path) == version,
              (try? Data(contentsOf: sourceURL)) == sourceBytes,
              GenerationRunContext.fileVersion(sourceURL.path) == version else {
            throw AgentOperationError("Markdown 源文件已更改或不可用。草稿已保留，请重新打开最新文件。")
        }
    }

    public func encoded(_ draft: String) throws -> Data {
        let value = Self.normalized(draft).replacingOccurrences(of: "\n", with: newline)
        guard let payload = value.data(using: encoding), bom.count + payload.count <= Self.maximumBytes else {
            throw AgentOperationError("Markdown 内容过大或无法按原编码保存，草稿已保留。")
        }
        return bom + payload
    }

    public func contentForUndo(_ original: SlotContent) -> SlotContent {
        var value = original
        var file = original.managedBodyFiles?[sourceURL.absoluteString]
            ?? .init(name: sourceURL.lastPathComponent, type: .file, path: sourceURL.path)
        file.data = sourceBytes
        value.managedBodyFiles = [sourceURL.absoluteString: file]
        return value
    }

    func replacingBody(in original: SlotContent, text: String) throws -> SlotContent {
        var value = original
        // New identity avoids reusing materialized-file caches for changed bytes.
        let file = SlotContent.SlotAttachment(name: sourceURL.lastPathComponent, type: .file,
            data: try encoded(text), originalPath: original.managedBodyFiles?[sourceURL.absoluteString]?.originalPath
                ?? sourceURL.path)
        value.items = [[PasteboardItem(type: "public.file-url", data: Data(sourceURL.absoluteString.utf8)),
                        PasteboardItem(type: "public.url", data: Data(sourceURL.absoluteString.utf8))]]
        value.htmlSource = nil
        value.managedBodyFiles = [sourceURL.absoluteString: file]
        return value
    }
}

public struct SlotMarkdownEdit {
    public let document: SlotMarkdownDocument
    public let text: String
    public init(document: SlotMarkdownDocument, text: String) {
        self.document = document; self.text = text
    }
}
