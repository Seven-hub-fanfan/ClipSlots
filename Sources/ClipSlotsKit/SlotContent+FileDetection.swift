import Foundation

extension SlotContent {
    /// Canonical list of file extensions treated as images across the whole app
    /// (GUI thumbnailing + CLI attachment typing/classification). This lives in
    /// the shared ClipSlotsKit layer so both the GUI (`ClipSlots`) and the CLI
    /// (`ClipSlotsCLI`) reference ONE source of truth and can no longer drift.
    /// (v2.9.7 R2: previously duplicated in ClipSlotsCLI/main.swift `IMAGE_EXTS`
    /// and ClipSlots/SlotContent+Thumbnail.swift `imageExtensions`.)
    public static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp",
        "heic", "heif", "tiff", "tif", "ico", "icns", "avif"
    ]

    public var detectedFileURLs: [URL] {
        var urls: [URL] = []
        for itemGroup in items {
            for item in itemGroup {
                if item.type == "public.file-url",
                   let string = String(data: item.data, encoding: .utf8),
                   let url = URL(string: string) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    public var detectedFolderURLs: [URL] {
        detectedFileURLs.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public var detectedRegularFileURLs: [URL] {
        detectedFileURLs.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    public var containsFolder: Bool {
        !detectedFolderURLs.isEmpty
    }

    // MARK: - File URL Detection (moved from SlotContent+Thumbnail so the shared
    // data layer can resolve file URLs without importing AppKit/UI code).

    /// First file URL found in pasteboard content.
    public var primaryFileURL: URL? {
        for itemList in items {
            for item in itemList where item.type == "public.file-url" {
                if let urlString = String(data: item.data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   let url = URL(string: urlString) {
                    return url
                }
            }
        }
        return nil
    }

    /// File name from file URL, if available.
    public var fileDisplayName: String? {
        primaryFileURL?.lastPathComponent
    }
}
