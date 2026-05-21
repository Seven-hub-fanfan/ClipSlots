import Foundation

final class SlotStorage {
    static let shared = SlotStorage()
    private let baseURL: URL
    private var cache: [Int: SlotContent] = [:]
    private let queue = DispatchQueue(label: "com.clipslots.storage", qos: .utility)

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/clipslots-app/slots")
        baseURL = appSupport
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    func get(_ slot: Int) -> SlotContent {
        queue.sync {
            if let cached = cache[slot] { return cached }
            let fileURL = baseURL.appendingPathComponent("slot_\(slot).json")
            guard let data = try? Data(contentsOf: fileURL),
                  let content = try? JSONDecoder().decode(SlotContent.self, from: data) else {
                return SlotContent()
            }
            cache[slot] = content
            return content
        }
    }

    func set(_ slot: Int, content: SlotContent) {
        queue.async { [self] in
            cache[slot] = content
            let fileURL = baseURL.appendingPathComponent("slot_\(slot).json")
            if let data = try? JSONEncoder().encode(content) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    func clear(_ slot: Int) {
        queue.async { [self] in
            cache[slot] = SlotContent()
            let fileURL = baseURL.appendingPathComponent("slot_\(slot).json")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func clearAll() {
        queue.async { [self] in
            cache.removeAll()
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
    }

    func snapshot() -> [Int: SlotContent] {
        queue.sync { cache }
    }
}
