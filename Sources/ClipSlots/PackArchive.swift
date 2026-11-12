import Foundation
import CArchive

/// Use the system archive library with literal paths. Command-line ZIP readers
/// interpret wildcard characters in archive names, even without a shell.
enum PackArchive {
    struct Limits {
        var entries = 100_000
        var expandedBytes: Int64 = 8 * 1024 * 1024 * 1024
        var metadataBytes: Int64 = 10 * 1024 * 1024
    }

    static func hasZIPSignature(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let signature = try handle.read(upToCount: 4) ?? Data()
        return [Data([0x50, 0x4b, 3, 4]), Data([0x50, 0x4b, 5, 6]),
                Data([0x50, 0x4b, 7, 8])].contains(signature)
    }

    /// Validate every entry before extraction. A second pass streams bytes into a
    /// private directory; no archive-supplied permissions or links are restored.
    @discardableResult
    static func read(_ url: URL, into destination: URL? = nil,
                     members: Set<String>? = nil, limits: Limits = Limits()) throws -> Set<String> {
        let names = try walk(url, destination: nil, members: nil, limits: limits)
        if let destination {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            _ = try walk(url, destination: destination, members: members, limits: limits)
        }
        return names
    }

    private static func walk(_ url: URL, destination: URL?, members: Set<String>?,
                             limits: Limits) throws -> Set<String> {
        guard let archive = archive_read_new() else {
            throw PackImportError.unzipFailed("无法创建归档读取器")
        }
        defer { archive_read_free(archive) }
        archive_read_support_format_zip(archive)
        func failure(_ fallback: String) -> PackImportError {
            let detail = archive_error_string(archive).map { String(cString: $0) } ?? fallback
            return .unzipFailed(detail)
        }
        guard archive_read_open_filename(archive, url.standardizedFileURL.path, 64 * 1024) == ARCHIVE_OK else {
            throw failure("无法打开槽位包")
        }
        var names = Set<String>()
        var canonicalNames = Set<String>()
        var regularFiles = Set<String>()
        var directories = Set<String>()
        var total: Int64 = 0
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry,
                  let rawName = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
                  let name = String(validatingUTF8: rawName) else {
                throw failure("归档条目损坏或文件名编码不受支持")
            }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !parts.contains(".."), !parts.contains("."),
                  parts.dropLast(name.hasSuffix("/") ? 1 : 0).allSatisfy({ !$0.isEmpty }) else {
                throw PackImportError.unzipFailed("包内路径无效：\(name)")
            }
            let key = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .precomposedStringWithCanonicalMapping.lowercased()
            guard !key.isEmpty, canonicalNames.insert(key).inserted else {
                throw PackImportError.unzipFailed("包内路径重复：\(name)")
            }
            guard names.count < limits.entries else {
                throw PackImportError.unzipFailed("包内文件数量超过上限")
            }
            let kind = archive_entry_filetype(entry)
            guard (kind == 0o100000 || kind == 0o040000),
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
                  archive_entry_is_encrypted(entry) == 0 else {
                throw PackImportError.unzipFailed("不支持链接、加密或特殊文件：\(name)")
            }
            // Reject file/directory collisions on case-insensitive APFS as well.
            var parent = (key as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !regularFiles.contains(parent) else {
                    throw PackImportError.unzipFailed("包内文件与目录冲突：\(name)")
                }
                directories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
            if kind == 0o100000 {
                guard !directories.contains(key) else {
                    throw PackImportError.unzipFailed("包内文件与目录冲突：\(name)")
                }
                regularFiles.insert(key)
            }
            let size = archive_entry_size(entry)
            guard size >= 0, size <= limits.expandedBytes - total else {
                throw PackImportError.unzipFailed("包展开后超过 8 GiB 上限")
            }
            if name.hasSuffix(".json") || name.hasSuffix("/thumbnail.bin") {
                guard size <= limits.metadataBytes else {
                    throw PackImportError.unzipFailed("包内元数据或缩略图过大：\(name)")
                }
            }
            total += size
            names.insert(name)
            guard let destination, members == nil || members!.contains(name) else {
                guard archive_read_data_skip(archive) == ARCHIVE_OK else { throw failure("归档读取失败") }
                continue
            }
            let target = destination.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw PackImportError.unzipFailed("包内路径越界：\(name)")
            }
            if kind == 0o040000 {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw PackImportError.writeFailed("无法创建临时文件")
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var written: Int64 = 0
            while true {
                let count = archive_read_data(archive, &buffer, buffer.count)
                guard count >= 0 else { throw failure("归档校验失败") }
                if count == 0 { break }
                written += Int64(count)
                guard written <= size else { throw PackImportError.unzipFailed("文件大小与声明不符：\(name)") }
                try handle.write(contentsOf: Data(buffer.prefix(count)))
            }
            guard written == size else { throw PackImportError.unzipFailed("文件内容不完整：\(name)") }
        }
        return names
    }
}

/// Shared by toolbar multi-selection and Finder open events.
enum PackImportSelection {
    enum Item {
        case pack(URL)
        case file(URL)
        case invalid(URL, String)
    }

    static func classify(_ urls: [URL], maxChildSlots: Int) -> [Item] {
        let importer = PackImporter(maxChildSlots: maxChildSlots)
        return urls.map { url in
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true { return .file(url) }
                if url.pathExtension.lowercased() == "clipslotspack" {
                    _ = try importer.readManifest(from: url)
                    return .pack(url)
                }
                guard try PackArchive.hasZIPSignature(url) else { return .file(url) }
                let names = try PackArchive.read(url)
                // Browser extensions and other ordinary ZIP files can also
                // contain manifest.json. Recognize our group layout as well.
                guard names.contains("manifest.json"), names.contains(where: {
                    $0.hasPrefix("pages/") && $0.contains("/groups/") && $0.hasSuffix("/group.json")
                }) else { return .file(url) }
                _ = try importer.readManifest(from: url)
                return .pack(url)
            } catch {
                return .invalid(url, error.localizedDescription)
            }
        }
    }
}
