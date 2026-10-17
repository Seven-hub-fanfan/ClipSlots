import Foundation
import ImageIO
import CryptoKit

/// Saves the original task bytes, never a rendered canvas or thumbnail.
/// A serial actor and atomic rename isolate simultaneous completions.
actor CanvasImageDownloads {
    static let shared = CanvasImageDownloads()

    func save(file: URL, taskID: String) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String? else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let ext: String
        switch type {
        case "public.jpeg": ext = "jpg"
        case "public.png": ext = "png"
        case "org.webmproject.webp": ext = "webp"
        case "com.compuserve.gif": ext = "gif"
        case "public.tiff": ext = "tiff"
        case "public.heic": ext = "heic"
        default: ext = file.pathExtension.isEmpty || file.pathExtension == "bin" ? "img" : file.pathExtension
        }
        let root: URL
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["CLIPSLOTS_TEST_DOWNLOAD_DIR"] {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
        #else
        root = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        #endif
        let directory = root.appendingPathComponent("ClipSlots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = taskID.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        let digest = SHA256.hash(data: Data(taskID.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = "ClipSlots-\(identity.prefix(60))-\(digest)"
        var destination = directory.appendingPathComponent(name + "." + ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            if FileManager.default.contentsEqual(atPath: file.path, andPath: destination.path) { return destination }
            // Preserve a file the user edited instead of overwriting it on recovery.
            destination = directory.appendingPathComponent(name + "-" + UUID().uuidString + "." + ext)
        }
        let staged = directory.appendingPathComponent("." + UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: file, to: staged)
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }
}
