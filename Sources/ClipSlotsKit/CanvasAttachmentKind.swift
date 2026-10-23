import Foundation

/// 入参文件（附件）在画布卡片上的**呈现类别**（v2.11.8 三轮 hotfix2）。
///
/// ## 为什么需要它
///
/// 三轮之前，节点的堆叠卡片只收**图片类**附件（`CanvasNodeCardView.imageAttachmentIndices`）。
/// 用户截图里的现场是：面板显示「入参文件 5 项」，内容是 `038.png`、`多节日.webp`、
/// `启动 Harness.command`、`图库打标平台兼容 Prompt_中文_v2.md`、`未标题-1.png` —— 但卡片上只叠了
/// 三张图，`.command` 和 `.md` **凭空消失**。用户的判断很直接：「卡片不显示非图像文件」。
///
/// 这不只是少画了两张卡：堆叠卡片的全部意义就是把「这个槽位里装了几件东西」变成视觉信息
/// （见 `CanvasSlotFanStack` 的类型注释）。漏掉非图像文件时，这个数字**是错的**，
/// 用户会以为拖进去的音频 / 文档丢了。
///
/// ## 类别划分按用户给的规格
///
/// `png/jpg/jpeg/webp/gif/heic` → 图片；`mp3/m4a/wav/aac` → 音频（`music.note`）；
/// `mp4/mov` → 视频（`film`）；其余 → 通用文件（`doc`）。这里在用户列表基础上补了几个同族扩展名
/// （heif/bmp/tiff、flac/aiff、m4v/mkv），因为它们与列出的格式在本 App 的导入路径里同源出现，
/// 漏掉只会让同一类文件显示成两种图标。
///
/// 判定放在 Kit 而不是 View 扩展里：它是纯字符串规则、需要被 smoke 钉住（扩展名表最容易在后续
/// 迭代里被"顺手"改掉一两项，而症状是某类文件突然变成通用文件图标，几乎没人会立刻发现）。
public enum CanvasAttachmentKind: String, CaseIterable, Sendable {
    case image
    case audio
    case video
    case file

    /// 各类别的扩展名表（全小写、不含点）。
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "bmp", "tiff", "tif"
    ]
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "aiff", "aif"
    ]
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm"
    ]

    /// 按文件名 / 路径判定类别。传空串或无扩展名一律按通用文件。
    public static func from(fileName: String) -> CanvasAttachmentKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .file }
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        return .file
    }

    /// 卡片上用的 SF Symbol 名。
    public var symbolName: String {
        switch self {
        case .image: return "photo"
        case .audio: return "music.note"
        case .video: return "film"
        case .file: return "doc"
        }
    }

    /// 给用户看的类别名（用于 tooltip / 无障碍标签）。
    public var displayName: String {
        switch self {
        case .image: return "图片"
        case .audio: return "音频"
        case .video: return "视频"
        case .file: return "文件"
        }
    }

    /// 卡片上文件名最多显示几行（用户指定「最多 2 行」）。
    public static let cardNameLineLimit = 2
}
