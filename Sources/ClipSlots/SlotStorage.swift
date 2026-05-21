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

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/clipslots/slots")
        baseURL = appSupport
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
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

    func set(_ slot: Int, content: SlotContent) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cache[slot] = content
            self.writeSlotContent(content, to: slot)
            self.updateManifest()
        }
    }

    func clear(_ slot: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cache[slot] = SlotContent()
            let slotDir = self.baseURL.appendingPathComponent(String(slot))
            try? FileManager.default.removeItem(at: slotDir)
            self.updateManifest()
        }
    }

    func clearAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cache.removeAll()
            try? FileManager.default.removeItem(at: self.baseURL)
            try? FileManager.default.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
            self.updateManifest()
        }
    }

    func snapshot() -> [Int: SlotContent] {
        queue.sync { cache }
    }

    // MARK: - Label

    func getLabel(_ slot: Int) -> String? {
        let labelFile = baseURL.appendingPathComponent(String(slot)).appendingPathComponent("label.txt")
        return try? String(contentsOf: labelFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setLabel(_ slot: Int, label: String?) {
        queue.async {
            let slotDir = self.baseURL.appendingPathComponent(String(slot))
            try? FileManager.default.createDirectory(at: slotDir, withIntermediateDirectories: true)
            let labelFile = slotDir.appendingPathComponent("label.txt")
            if let label = label, !label.isEmpty {
                try? label.write(to: labelFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: labelFile)
            }
        }
    }

    // MARK: - Internal Read/Write

    private func readSlotContent(from slotDir: URL) -> SlotContent {
        var content = SlotContent()
        let itemDir = slotDir.appendingPathComponent("item_0")

        guard FileManager.default.fileExists(atPath: itemDir.path) else {
            return content
        }

        // Use item directory modification date as timestamp
        if let attrs = try? FileManager.default.attributesOfItem(atPath: itemDir.path),
           let modDate = attrs[.modificationDate] as? Date {
            content.timestamp = modDate
        }

        var allItems: [PasteboardItem] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "bin" {
                let typeName = file.deletingPathExtension().lastPathComponent
                if let data = try? Data(contentsOf: file) {
                    allItems.append(PasteboardItem(type: typeName, data: data))
                }
            }
        }

        if !allItems.isEmpty {
            content.items = [allItems]
        }

        return content
    }

    private func writeSlotContent(_ content: SlotContent, to slot: Int) {
        let slotDir = baseURL.appendingPathComponent(String(slot))
        let itemDir = slotDir.appendingPathComponent("item_0")

        // Clean old items
        try? FileManager.default.removeItem(at: itemDir)
        try? FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        guard !content.isEmpty, let items = content.items.first else { return }

        for item in items {
            let typeFile = itemDir.appendingPathComponent("\(item.type).bin")
            try? item.data.write(to: typeFile, options: .atomic)
        }
    }

    // MARK: - Manifest

    private func manifestURL() -> URL {
        baseURL.appendingPathComponent("manifest.json")
    }

    private func readManifest() throws -> SlotManifest {
        let data = try Data(contentsOf: manifestURL())
        return try decoder.decode(SlotManifest.self, from: data)
    }

    private func updateManifest() {
        var entries: [SlotManifest.Entry] = []

        for slot in 1...10 {
            let slotDir = baseURL.appendingPathComponent(String(slot))
            let itemDir = slotDir.appendingPathComponent("item_0")

            guard FileManager.default.fileExists(atPath: itemDir.path) else { continue }

            var types: [String] = []
            var totalBytes = 0
            var preview = "(empty)"

            if let files = try? FileManager.default.contentsOfDirectory(at: itemDir, includingPropertiesForKeys: [.fileSizeKey]) {
                for file in files where file.pathExtension == "bin" {
                    let typeName = file.deletingPathExtension().lastPathComponent
                    types.append(typeName)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                       let size = attrs[.size] as? Int {
                        totalBytes += size
                    }
                    // Generate preview from plain text
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
                        preview = "[File]"
                    }
                }
            }

            // Add label to preview if exists
            if let label = getLabel(slot), !label.isEmpty {
                preview = "[\(label)] \(preview)"
            }

            if preview.hasPrefix("[Rich Text]"), let data = try? Data(contentsOf: itemDir.appendingPathComponent("public.utf8-plain-text.bin")),
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
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestURL(), options: .atomic)
        }
    }
}
