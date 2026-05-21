import Foundation

struct AppConfig: Codable {
    var slots: Int = 5
    var saveKey: String = "ctrl+option+{n}"
    var pasteKey: String = "ctrl+{n}"

    static func load() -> AppConfig {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/clipslots-app/config.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        var c = config
        c.slots = max(1, min(10, c.slots))
        return c
    }

    func save() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/clipslots-app")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configURL = configDir.appendingPathComponent("config.json")
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: configURL, options: .atomic)
        }
    }
}
