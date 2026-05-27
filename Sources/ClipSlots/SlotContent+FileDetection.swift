import Foundation

extension SlotContent {
    var detectedFileURLs: [URL] {
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

    var detectedFolderURLs: [URL] {
        detectedFileURLs.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    var detectedRegularFileURLs: [URL] {
        detectedFileURLs.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    var containsFolder: Bool {
        !detectedFolderURLs.isEmpty
    }
}
