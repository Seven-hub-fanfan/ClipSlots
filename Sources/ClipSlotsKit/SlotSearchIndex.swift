import Foundation

// MARK: - Slot Search Index (v2.11.7 hotfix11)
//
// 「搜索基本搜不到想要的内容」的根因就在这里，而且和最近几轮 hotfix 无关——搜索相关文件自
// v2.11.7 hotfix3 起只被改过外观（搜索框换成内凹、范围选择器移到框外换成 NeuSegmentedControl，
// TextField 的绑定 / onChange 一行没动）。真正的问题是**可搜索文本的构造**从 v2.5 起就只取
// `content.preview`：
//
//   preview = 正文首 30 字 + "…"（见 SlotContent.computedPreview）
//
// 也就是说 GUI 只在**每个槽位正文的前 30 个字符**里做子串匹配。存短句时凑巧还能用，一旦槽位装
// 的是长文（本机实测 prompt 组槽位 1 的正文 2165 字），就出现两种症状，正好对应用户描述的
// 「基本不能搜到想要的内容」：
//
//   1. **搜不到**：关键词只要出现在第 31 个字符之后，一律不匹配。实测 `镜头调度`/`骑马`/`声音`
//      在 CLI 能命中，GUI 一条都搜不出来。
//   2. **搜出一大堆**：同批槽位往往共享同样的开头（那批 prompt 全部以
//      `| **编号** | **时间** | **时长** | *` 起头），于是搜表头里的词会把整组槽位全部命中。
//
// 另外纯附件槽位（模式 C）在 GUI 里搜不到附件名，CLI 从 v2.9.3 就支持。
//
// CLI 的 haystack 一直是 `[preview, plainText, label, attachmentNames]`，所以 CLI 搜得到、
// GUI 搜不到——两条搜索路径长期不同源。本文件把「内容侧可搜索文本」下沉到 Kit 作为唯一实现，
// GUI 与 CLI 从此共用（大小写不敏感的子串匹配），并且下沉后 smoke 才测得到它：搜索逻辑此前躺在
// App target，零测试覆盖，这也是这个 bug 能潜伏这么久的原因之一。
//
// 语义分层，避免动到 CLI 的行为契约：
//   * `contentHaystack` —— 内容侧文本，CLI / GUI 共用。
//   * `slotHaystack`    —— 在前者之上追加槽位号与「槽位 N」，**仅 GUI 使用**。GUI 一直支持按
//     槽位号搜（搜 "3" 能定位到槽位 3），CLI 则不该因为这次重构突然让 `search "1"` 命中所有
//     槽位 1。
//
// 性能：拼接 + lowercased 的结果按 `contentId::updatedAt` 缓存。GUI 每敲一个字符都要对全组
// （全局搜索是跨组）重算匹配，2KB 正文 × 上百槽位若每次都重新拼接 / 折叠大小写会明显吃主线程；
// 缓存后每次按键只剩一次纯子串扫描。缓存键带 `updatedAt`，内容一改立即失效。
public enum SlotSearchIndex {

    // MARK: - 匹配

    /// GUI 用：在槽位可搜索文本（含槽位号）里做大小写不敏感子串匹配。空 query 视为不筛选 → true。
    public static func matches(slot: Int,
                               content: SlotContent,
                               label: String,
                               query: String) -> Bool {
        guard let needle = normalize(query) else { return true }
        return slotHaystack(slot: slot, content: content, label: label).contains(needle)
    }

    /// CLI 用：只在内容侧文本里匹配，不含槽位号。空 query 视为不筛选 → true。
    public static func matchesContent(content: SlotContent,
                                      label: String,
                                      query: String) -> Bool {
        guard let needle = normalize(query) else { return true }
        return contentHaystack(content: content, label: label).contains(needle)
    }

    // MARK: - Haystack

    /// 内容侧可搜索文本（已 lowercased），CLI / GUI 共用。
    ///
    /// 收录：label、**完整正文**、preview（图片 / RTF 等非文本槽位的可读描述如
    /// `[图片 742KB]` 只存在于 preview，plainText 对它们是 nil，所以两者都要收）、附件名、
    /// 主文件的文件名 / 完整路径 / 扩展名、检测到的网址与 host。
    public static func contentHaystack(content: SlotContent, label: String) -> String {
        let key = "content::\(content.contentId)::\(content.updatedAt)::\(label)" as NSString
        if let cached = SlotSearchIndexCache.shared.object(forKey: key) { return cached as String }
        let built = buildContentHaystack(content: content, label: label)
        SlotSearchIndexCache.shared.setObject(built as NSString, forKey: key)
        return built
    }

    /// GUI 用可搜索文本：内容侧文本 + 槽位号 + 「槽位 N」。
    public static func slotHaystack(slot: Int, content: SlotContent, label: String) -> String {
        let key = "slot::\(slot)::\(content.contentId)::\(content.updatedAt)::\(label)" as NSString
        if let cached = SlotSearchIndexCache.shared.object(forKey: key) { return cached as String }
        let built = "\(slot)\n槽位 \(slot)\n" + contentHaystack(content: content, label: label)
        SlotSearchIndexCache.shared.setObject(built as NSString, forKey: key)
        return built
    }

    // MARK: - Private

    /// 归一化查询串；空串返回 nil（= 不筛选）。
    private static func normalize(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func buildContentHaystack(content: SlotContent, label: String) -> String {
        var parts: [String] = []

        if !label.isEmpty { parts.append(label) }

        // 完整正文——本次修复的核心。
        if let text = content.plainText, !text.isEmpty { parts.append(text) }

        let preview = content.preview
        if !preview.isEmpty { parts.append(preview) }

        for attachment in content.attachments where !attachment.name.isEmpty {
            parts.append(attachment.name)
        }

        if let url = content.primaryFileURL {
            parts.append(url.lastPathComponent)
            parts.append(url.path)
            parts.append(url.pathExtension)
        }

        if let url = content.detectedWebURL {
            parts.append(url.absoluteString)
            if let host = url.host { parts.append(host) }
        }

        return parts.joined(separator: "\n").lowercased()
    }
}

private enum SlotSearchIndexCache {
    /// 上限与 SlotContent 的 preview / plainText 缓存一致。key 带 updatedAt，改一次内容旧条目
    /// 自然被挤掉。
    static let shared: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 800
        return cache
    }()
}
