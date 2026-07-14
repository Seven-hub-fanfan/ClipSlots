import Foundation

extension SlotContent {
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
