import Foundation

struct SlotManifest: Codable {
    struct Entry: Codable {
        let description: String
        let itemCount: Int
        let slot: Int
        let totalBytes: Int
        let types: [String]
        let updatedAt: String
    }

    var entries: [Entry] = []
    var version: Int = 1
}

final class SlotStorage {
    static let shared = SlotStorage()

    private let baseURL: URL
    private var cache: [Int: SlotContent] = [:]
    private let queue = DispatchQueue(label: "com.clipslots.storage", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(slotsDir: URL? = nil) {
        if let slotsDir {
            baseURL = slotsDir
        } else {
            baseURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/clipslots/slots")
        }
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            NSLog("[ClipSlots] SlotStorage init: failed to create base dir \(baseURL.path): \(error)")
        }
    }

    // MARK: - Slot Content

    func get(_ slot: Int) -> SlotContent {
        queue.sync {
            if let cached = cache[slot] { return cached }

            let slotDir = baseURL.appendingPathComponent(String(slot))
            let content = readSlotContent(from: slotDir)
            cache[slot] = content
            return content
        }
    }

    @discardableResult
    func set(_ slot: Int, content: SlotContent) -> Bool {
        queue.sync {
            do {
                try writeSlotContent(content, to: slot)
                cache[slot] = content
                try updateManifest()
                NSLog("[ClipSlots] SlotStorage.set OK slot=\(slot) preview=\(content.preview)")
                return true
            } catch {
                NSLog("[ClipSlots] SlotStorage.set FAIL slot=\(slot) error=\(error)")
                return false
            }
        }
    }

    func clear(_ slot: Int) {
        queue.sync {
            cache[slot] = SlotContent()
            let slotDir = baseURL.appendingPathComponent(String(slot))
            do {
                try FileManager.default.removeItem(at: slotDir)
            } catch {
                let nsErr = error as NSError
                if nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4 { /* file not found */ }
                else { NSLog("[ClipSlots] SlotStorage.clear FAIL slot=\(slot): \(error)") }
            }
            do { try updateManifest() } catch {
                NSLog("[ClipSlots] SlotStorage.clear manifest FAIL: \(error)")
            }
        }
    }

    func clearAll() {
        queue.sync {
            cache.removeAll()
            do {
                try FileManager.default.removeItem(at: baseURL)
                try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
                try updateManifest()
                NSLog("[ClipSlots] SlotStorage.clearAll OK")
            } catch {
                NSLog("[ClipSlots] SlotStorage.clearAll FAIL: \(error)")
            }
        }
    }

    func snapshot() -> [Int: SlotContent] {
        queue.sync { cache }
    }

    // MARK: - Label

    func getLabel(_ slot: Int) -> String? {
        let labelFile = baseURL.appendingPathComponent(String(slot)).appendingPathComponent("label.txt")
        guard let content = try? String(contentsOf: labelFile, encoding: .utf8) else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setLabel(_ slot: Int, label: String?) {
        queue.sync {
            let slotDir = baseURL.appendingPathComponent(String(slot))
            do {
                try FileManager.default.createDirectory(at: slotDir, withIntermediateDirectories: true)
            } catch {
                NSLog("[ClipSlots] setLabel: create dir FAIL slot=\(slot): \(error)")
                return
            }
            let labelFile = slotDir.appendingPathComponent("label.txt")
            if let label = label, !label.isEmpty {
                do {
                    try label.write(to: labelFile, atomically: true, encoding: .utf8)
                } catch {
                    NSLog("[ClipSlots] setLabel: write FAIL slot=\(slot): \(error)")
                }
            } else {
                do { try FileManager.default.removeItem(at: labelFile) } catch {
                    let nsErr = error as NSError
                    if !(nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4) {
                        NSLog("[ClipSlots] setLabel: remove FAIL: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Internal Read/Write

    private func readSlotContent(from slotDir: URL) -> SlotContent {
        var content = SlotContent()
        let itemDir = slotDir.appendingPathComponent("item_0")

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: itemDir.path, isDirectory: &isDir), isDir.boolValue else {
            return content
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: itemDir.path),
           let modDate = attrs[.modificationDate] as? Date {
            content.timestamp = modDate
        }

        var allItems: [PasteboardItem] = []
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: nil)
        } catch {
            NSLog("[ClipSlots] readSlotContent read dir FAIL: \(error)")
            return content
        }

        for file in files where file.pathExtension == "bin" {
            let encodedType = file.deletingPathExtension().lastPathComponent
            let typeName = decodeSafeFileName(encodedType)
            do {
                let data = try Data(contentsOf: file)
                allItems.append(PasteboardItem(type: typeName, data: data))
            } catch {
                NSLog("[ClipSlots] readSlotContent read file FAIL type=\(typeName): \(error)")
            }
        }

        if !allItems.isEmpty {
            content.items = [allItems]
        }

        return content
    }

    private func writeSlotContent(_ content: SlotContent, to slot: Int) throws {
        let slotDir = baseURL.appendingPathComponent(String(slot))
        let itemDir = slotDir.appendingPathComponent("item_0")

        // Clean old items
        try? FileManager.default.removeItem(at: itemDir)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        guard !content.isEmpty else { return }

        // Write all item groups
        for (groupIdx, items) in content.items.enumerated() {
            let targetDir = groupIdx == 0 ? itemDir : slotDir.appendingPathComponent("item_\(groupIdx)")
            if groupIdx > 0 {
                try? FileManager.default.removeItem(at: targetDir)
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }

            for item in items {
                let safeName = encodeSafeFileName(item.type) + ".bin"
                let typeFile = targetDir.appendingPathComponent(safeName)
                try item.data.write(to: typeFile, options: .atomic)
            }
        }
    }

    // MARK: - Safe Filename Encoding

    private let slashPlaceholder = "$slash$"

    private func encodeSafeFileName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: slashPlaceholder)
    }

    private func decodeSafeFileName(_ encoded: String) -> String {
        encoded.replacingOccurrences(of: slashPlaceholder, with: "/")
    }

    // MARK: - Manifest

    private func manifestURL() -> URL {
        baseURL.appendingPathComponent("manifest.json")
    }

    private func readManifest() throws -> SlotManifest {
        let data = try Data(contentsOf: manifestURL())
        return try decoder.decode(SlotManifest.self, from: data)
    }

    private func updateManifest() throws {
        var entries: [SlotManifest.Entry] = []

        for slot in 1...10 {
            let slotDir = baseURL.appendingPathComponent(String(slot))
            let itemDir = slotDir.appendingPathComponent("item_0")

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            var types: [String] = []
            var totalBytes = 0
            var preview = "(empty)"

            let files = try FileManager.default.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: [.fileSizeKey])
            for file in files where file.pathExtension == "bin" {
                let encodedType = file.deletingPathExtension().lastPathComponent
                let typeName = decodeSafeFileName(encodedType)
                types.append(typeName)

                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                if let size = attrs[.size] as? Int { totalBytes += size }

                if typeName == "public.utf8-plain-text" || typeName == "NSStringPboardType" {
                    if let data = try? Data(contentsOf: file),
                       let str = String(data: data, encoding: .utf8) {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        preview = String(trimmed.prefix(37))
                    }
                } else if typeName == "public.rtf" {
                    preview = "[Rich Text]"
                } else if typeName.contains("image") {
                    preview = "[Image \(totalBytes / 1024)KB]"
                } else if typeName == "public.file-url" {
                    if let data = try? Data(contentsOf: file),
                       let urlStr = String(data: data, encoding: .utf8),
                       let url = URL(string: urlStr) {
                        preview = "[File] \(url.lastPathComponent)"
                    } else {
                        preview = "[File]"
                    }
                }
            }

            if let label = getLabel(slot), !label.isEmpty {
                preview = "[\(label)] \(preview)"
            }

            if preview.hasPrefix("[Rich Text]"),
               let richTextFile = itemDir.appendingPathComponent(encodeSafeFileName("public.utf8-plain-text") + ".bin") as URL?,
               FileManager.default.fileExists(atPath: richTextFile.path),
               let data = try? Data(contentsOf: richTextFile),
               let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let chars = trimmed.count
                let suffix = chars > 0 ? " \(chars) chars: \(String(trimmed.prefix(37)))" : ""
                preview = "[Rich Text]\(suffix)"
            }

            entries.append(SlotManifest.Entry(
                description: preview,
                itemCount: 1,
                slot: slot,
                totalBytes: totalBytes,
                types: types.sorted(),
                updatedAt: ISO8601DateFormatter().string(from: Date())
            ))
        }

        let manifest = SlotManifest(entries: entries, version: 1)
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(), options: .atomic)
    }
}
