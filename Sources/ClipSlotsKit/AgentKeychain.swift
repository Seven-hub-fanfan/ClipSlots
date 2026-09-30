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
//
// v2.17.6：在此之上加了**进程内内存缓存**，见 `AgentKeychain.readAPIKey()` 头注释。
// 每次构建首次授权框仍然会弹一次（ACL 语义没变），但同一次进程运行内后续读取
// 全部走内存缓存，不再重复调 `SecItemCopyMatching`——彻底修掉"点了始终允许还
// 反复弹"的问题。

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

    // v2.17.6：进程内内存缓存。
    //
    // 为什么必须缓存 ——
    // 本项目 ad-hoc 签名，每次构建 code signing identity 都变，覆盖安装后钥匙串 ACL
    // 会重新弹授权框（这个绕不掉，属于系统语义）。但**同一次进程运行内**不应该反复
    // 弹：以前每次 `readAPIKey()` 都调 `SecItemCopyMatching`，而 UI（SwiftUI computed
    // property、config 面板刷新、侧栏 onAppear）与每次 API 调用（AgentService.callAPI
    // 里 `secretStore.readAPIKey()`）都会读一次。不同调用栈 / 不同线程下，系统
    // authorization prompt 的缓存并不总能命中——结果是同一 build 里用户仍会被反复
    // 弹「始终允许」。
    //
    // 缓存策略：
    // - 首次成功读取后把明文放到进程内存里（进程退出即消失，磁盘/日志/导出都不落）。
    // - 写 / 删同步更新缓存，避免"写完再回头问一次钥匙串"。
    // - 缓存命中完全不碰 SecItem，从根本上没有二次弹框的机会。
    // - 授权失败 / 被用户拒绝时**不写缓存**——用户可能刚点了"始终允许"，下次调用要能重试。
    //
    // 安全语义没变：Keychain ACL 保护的是"把 secret 从磁盘读出"，一旦进程合法读出，
    // 明文本来就在内存里；这里只是把已经在做的事显式化，不放宽任何权限。
    private let cacheLock = NSLock()
    private var cachedKey: String? = nil
    private var cacheLoaded: Bool = false

    public init(service: String = AgentKeychain.service, account: String = AgentKeychain.account) {
        self.service = service
        self.account = account
    }

    public func readAPIKey() -> String? {
        // 命中内存缓存：直接返回，绝不触发 SecItemCopyMatching → 没有二次弹框。
        cacheLock.lock()
        if cacheLoaded {
            let v = cachedKey
            cacheLock.unlock()
            return v
        }
        cacheLock.unlock()

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        var result: String? = nil
        if status == errSecSuccess,
           let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            result = trimmed.isEmpty ? nil : trimmed
        } else if status != errSecItemNotFound {
            // 只记状态码，绝不记内容。
            NSLog("[ClipSlots][Agent] keychain read failed: \(status)")
            // 授权失败不缓存：用户可能马上会点"始终允许"，下次调用要能重试。
            return nil
        }
        cacheLock.lock()
        cachedKey = result
        cacheLoaded = true
        cacheLock.unlock()
        return result
    }

    /// 供"用户可能刚在钥匙串访问里改过条目"的场景强制清缓存重读。UI 常规路径不需要调。
    public func invalidateCache() {
        cacheLock.lock()
        cachedKey = nil
        cacheLoaded = false
        cacheLock.unlock()
    }

    public func writeAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try deleteAPIKey(); return }
        guard let data = trimmed.data(using: .utf8) else { throw AgentKeychainError.encodingFailed }

        // 先尝试更新已有项。顺序刻意是"update 再 add"而不是"delete 再 add"：
        // delete+add 会重建 ACL，等于每次保存都让用户重新授权一遍。
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            // 写成功 → 同步进内存缓存，后续读走不到 SecItem。
            cacheLock.lock(); cachedKey = trimmed; cacheLoaded = true; cacheLock.unlock()
            return
        }
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
        cacheLock.lock(); cachedKey = trimmed; cacheLoaded = true; cacheLock.unlock()
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentKeychainError.osStatus(status)
        }
        cacheLock.lock(); cachedKey = nil; cacheLoaded = true; cacheLock.unlock()
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// 「钥匙串里有没有 key」的**非阻塞**探测。
///
/// v2.11.8：为什么必须有这么个东西 ——
/// `SecItemCopyMatching` 在弹出系统授权框时会**阻塞调用线程直到用户回答**。而本项目每次
/// adhoc 打包签名都变，覆盖安装后首次读取必然弹框（见文件头注释，这是系统行为，不绕）。
/// 之前 Agent 侧栏在 `onAppear` 里同步问了一次 `hasAPIKey`，而侧栏是首帧就渲染的 ——
/// 结果主线程卡死在钥匙串里，**主窗口在用户点掉授权框之前根本画不出来**，用户看到的是
/// 「更新完点图标没反应／只有一个授权框」。
///
/// 这里不改变任何安全语义（照样走 ACL、照样弹框、照样只读钥匙串），只是把读操作挪到后台
/// 线程：窗口先画出来，授权框浮在窗口上，用户点「始终允许」后 UI 再更新。
///
/// v2.17.6 追加：探测走的是 `AgentKeychain.shared`（走缓存路径），所以本次进程内
/// 后续所有对 `hasAPIKey` / `readAPIKey` 的调用都会命中内存缓存，不再触发 SecItem。
public enum AgentKeychainProbe {
    /// 后台线程读一次钥匙串，返回是否存在可用 key。用户拒绝授权/无 key 都返回 false。
    /// v2.17.6：改用 `AgentKeychain.shared`——原来每次 new 一个 AgentKeychain 实例
    /// 走空缓存，等于每次都真的问一次钥匙串；用 shared 后首次问过就一直命中缓存。
    public static func hasAPIKey(service: String = AgentKeychain.service,
                                 account: String = AgentKeychain.account) async -> Bool {
        // 只有默认 service/account 才复用 shared（保留可注入语义给测试）。
        if service == AgentKeychain.service && account == AgentKeychain.account {
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let exists = AgentKeychain.shared.readAPIKey() != nil
                    continuation.resume(returning: exists)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let exists = AgentKeychain(service: service, account: account).readAPIKey() != nil
                continuation.resume(returning: exists)
            }
        }
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
