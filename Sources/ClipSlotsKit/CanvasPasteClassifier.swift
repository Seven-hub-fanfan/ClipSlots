import Foundation

/// 画布 Cmd+V 的「粘贴什么 → 建什么节点」判定（v2.11.8）。
///
/// 判定规则下沉到 Kit 的理由：这是一段**优先级逻辑**，而优先级写在 View 里就没人能测。
/// 剪贴板经常同时携带多种表示（从浏览器复制一张图会同时带 image + HTML + 一个 URL 字符串；
/// 从 Finder 复制文件会带 fileURL + 文件名字符串），所以"有文本就当文本"这种朴素写法的
/// 实际表现是：复制一张图片进来，得到一个内容是 `<img src=...>` 的文本节点。
///
/// 优先级（与项目既有的「存入逻辑」同向：更具体的内容优先）：
///   1. **文件 URL** —— 用户复制的是文件本体，最明确；图片文件 → 图像节点，其余 → 图像节点的入参。
///   2. **位图** —— 截图 / 网页图片，没有文件路径，只能落成附件数据。
///   3. **纯文本** —— 兜底：文本进正文（Prompt）。
public enum CanvasPasteIntent: Equatable {
    /// 建图像节点，把这些文件作为入参文件。
    case imageNodeWithFiles([URL])
    /// 建图像节点，把这段位图数据作为入参文件（附件名由上层生成）。
    case imageNodeWithBitmap
    /// 建文本节点，正文 = 这段文字。
    case textNode(String)

    public var kindIsText: Bool {
        if case .textNode = self { return true }
        return false
    }
}

/// 剪贴板的**只读快照**。
///
/// 刻意不让 Kit 认识 `NSPasteboard`：一是 Kit 要能在无头环境跑 smoke（读系统剪贴板在 CI 上
/// 行为不确定），二是"取数"与"判定"混在一起就没法针对判定写用例。App 层负责把 NSPasteboard
/// 翻译成这个结构，翻译代码只有几行、没有分支。
public struct CanvasPasteSnapshot: Equatable {
    public var fileURLs: [URL]
    public var hasBitmap: Bool
    public var text: String?

    public init(fileURLs: [URL] = [], hasBitmap: Bool = false, text: String? = nil) {
        self.fileURLs = fileURLs
        self.hasBitmap = hasBitmap
        self.text = text
    }
}

public enum CanvasPasteClassifier {

    /// 被视为「图片文件」的扩展名。
    ///
    /// 只列真正能被 `NSImage` 直接解码的常见格式。刻意不含 `pdf` / `svg`：它们能被 NSImage 打开，
    /// 但作为"图像入参"的语义是错的（矢量/多页文档），落进图像节点会得到一张莫名的首页缩略图。
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
    ]

    public static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// 判定粘贴意图。返回 nil = 剪贴板里没有任何可用内容（调用方应给出提示而不是静默）。
    public static func classify(_ snapshot: CanvasPasteSnapshot) -> CanvasPasteIntent? {
        if !snapshot.fileURLs.isEmpty {
            return .imageNodeWithFiles(snapshot.fileURLs)
        }
        if snapshot.hasBitmap {
            return .imageNodeWithBitmap
        }
        if let text = snapshot.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .textNode(text)
        }
        return nil
    }
}
