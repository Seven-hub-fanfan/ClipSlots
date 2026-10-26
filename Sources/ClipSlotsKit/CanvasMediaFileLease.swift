import Foundation

/// AVPlayer uses the extension as part of format detection. Keep the immutable
/// stored bin and expose a temporary APFS clone for the decoder's lifetime.
public final class CanvasMediaFileLease {
    public let url: URL
    private let directory: URL?
    public init(source: URL, name: String) throws {
        guard source.pathExtension.lowercased() == "bin" else { url = source; directory = nil; return }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 10, ext.allSatisfy({$0.isLetter || $0.isNumber}) else {
            throw CanvasToolError.invalid("素材扩展名无效")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipslots-player-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("media.\(ext)")
        do {try FileManager.default.copyItem(at:source,to:target)}
        catch {try? FileManager.default.removeItem(at:folder);throw error}
        directory=folder;url=target
    }
    deinit {if let directory {try? FileManager.default.removeItem(at:directory)}}
}
