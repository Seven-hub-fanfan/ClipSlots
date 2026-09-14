import Foundation
import Security

// MARK: - API Key 存储
//
// 硬约束（用户明确要求，也是本文件唯一的存在理由）：
//   **API Key 只进 Keychain**。不进代码、不进 UserDefaults/@AppStorage、不进日志、
//   不进任何导出文件（.clipslotspack 也不带）。
//
// 结构上分成三层：
//   - `AgentSecretStore` 协议：让上层（AgentService/UI）只依赖"能取到 key"这件事，
//     smoke 测试可以塞内存实现，不碰系统 Keychain（CI/无头环境下 Keychain 会失败）。
//   - `AgentKeychain`：真实实现，service/account 固定为用户指定的值。
//   - `AgentInMemorySecretStore`：测试与 mock 用。
//
// 关于 ad-hoc 签名的已知行为（不是 bug，别去"修"）：
// 本项目发布走 SKIP_NOTARIZE=1 + adhoc 签名，每次构建的代码签名都不同。
// 传统文件型 Keychain 的 ACL 绑定具体可执行文件，因此**版本更新后首次读取会弹出
// 系统授权框**（"ClipSlots 想要使用你储存在钥匙串中的机密信息"）。
// 用户点"始终允许"即可，这是系统行为，不能靠代码绕过（绕过就等于放弃 ACL 保护）。
// 代码这边要做的只有一件事：把 errSecAuthFailed / errSecInteractionNotAllowed
// 翻译成人能看懂的提示，而不是甩一个 -25293。

public protocol AgentSecretStore: AnyObject {
    func readAPIKey() -> String?
    func writeAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

public final class AgentKeychain: AgentSecretStore {
    /// 用户指定的固定坐标，不做可配置——可配置只会让"key 到底存哪了"变成新的支持问题。
    public static let service = "com.clipslots.agent"
    public static let account = "deepseek_api_key"

    public static let shared = AgentKeychain()

    private let service: String
    private let account: String

    public init(service: String = AgentKeychain.service, account: String = AgentKeychain.account) {
        self.service = service
        self.account = account
    }

    public func readAPIKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                // 只记状态码，绝不记内容。
                NSLog("[ClipSlots][Agent] keychain read failed: \(status)")
            }
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func writeAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try deleteAPIKey(); return }
        guard let data = trimmed.data(using: .utf8) else { throw AgentKeychainError.encodingFailed }

        // 先尝试更新已有项。顺序刻意是"update 再 add"而不是"delete 再 add"：
        // delete+add 会重建 ACL，等于每次保存都让用户重新授权一遍。
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw AgentKeychainError.osStatus(updateStatus)
        }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        // 仅本机、解锁后可访问；不参与 iCloud 同步（key 是本地凭据，没有同步的理由）。
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        insert[kSecAttrSynchronizable as String] = false
        insert[kSecAttrLabel as String] = "ClipSlots Agent · DeepSeek API Key"
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AgentKeychainError.osStatus(addStatus) }
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentKeychainError.osStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum AgentKeychainError: LocalizedError, Equatable {
    case encodingFailed
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "API Key 无法编码为 UTF-8"
        case .osStatus(let status):
            switch status {
            case errSecAuthFailed, errSecInteractionNotAllowed:
                return "钥匙串拒绝访问（\(status)）。ClipSlots 使用 ad-hoc 签名，版本更新后首次读写需要在系统弹窗里点「始终允许」。"
            case errSecUserCanceled:
                return "已取消钥匙串授权，API Key 未保存。"
            case errSecDuplicateItem:
                return "钥匙串中已存在同名条目，请先在「钥匙串访问」里删除 com.clipslots.agent 后重试。"
            default:
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "钥匙串操作失败：\(msg)（\(status)）"
            }
        }
    }
}

/// 测试/mock 用：不触碰系统 Keychain。
public final class AgentInMemorySecretStore: AgentSecretStore {
    private var key: String?
    public init(key: String? = nil) { self.key = key }
    public func readAPIKey() -> String? { key }
    public func writeAPIKey(_ key: String) throws {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = t.isEmpty ? nil : t
    }
    public func deleteAPIKey() throws { key = nil }
}
