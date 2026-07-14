import Foundation

public enum HotkeyTemplateKind: String, Codable, CaseIterable, Identifiable {
    case hybrid = "hybrid"
    case numeric = "numeric"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hybrid: return "12345 + QWERT"
        case .numeric: return "1234567890"
        case .custom: return "自定义"
        }
    }
}

public struct HotkeyTemplate: Codable, Equatable {
    public var kind: HotkeyTemplateKind = .numeric
    public var customKeys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    public init(kind: HotkeyTemplateKind = .numeric,
                customKeys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]) {
        self.kind = kind
        self.customKeys = customKeys
    }

    /// Return the single-character key token for a given slot (1-based).
    public func keyToken(for slot: Int) -> String? {
        guard slot >= 1, slot <= 10 else { return nil }
        let idx = slot - 1

        switch kind {
        case .hybrid:
            let keys = ["1", "2", "3", "4", "5", "q", "w", "e", "r", "t"]
            return idx < keys.count ? keys[idx] : nil
        case .numeric:
            let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
            return idx < keys.count ? keys[idx] : nil
        case .custom:
            guard customKeys.indices.contains(idx) else { return nil }
            return customKeys[idx].lowercased()
        }
    }
}
