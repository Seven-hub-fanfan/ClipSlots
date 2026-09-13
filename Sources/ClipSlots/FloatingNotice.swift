import Foundation
import ClipSlotsKit
import SwiftUI
import AppKit

// MARK: - Floating Notice Kind (v2.6.3)

enum FloatingNoticeKind {
    case success
    case info
    case warning
    case error

    var iconColor: Color {
        switch self {
        case .success: return AppTheme.success
        case .info:    return .accentColor
        case .warning: return AppTheme.warning
        case .error:   return AppTheme.danger
        }
    }

    /// v2.9.24: 统一的语义化 SF Symbol 图标，替换掉此前按调用点传入的杂乱图标
    /// （包括看起来像"汉堡菜单/三横线"的 text.alignleft）。
    var semanticIcon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }
}

// MARK: - Floating Notice (v2.6.2, enhanced v2.6.3)

struct FloatingNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    let iconName: String
    let kind: FloatingNoticeKind

    init(title: String,
         subtitle: String = "",
         iconName: String = "checkmark.circle.fill",
         kind: FloatingNoticeKind = .success) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.kind = kind
    }
}

// MARK: - Toast 表面（v2.11.7 hotfix13）
//
// 两种皮肤两套材质，共用一套几何（`NoticeMetrics`）：
//
// **简洁模式**：与主界面画布**同色**的圆角卡片 + 两条长在边界上的描边（左上白亮边 = 受光棱、
// 右下暗边 = 侧面厚度），**没有任何外部投影**。这就是 hotfix8 定下的新拟物约定：凸起感由描边
// 表达，而不是由「离底板有段距离」的外投影表达。原来那张卡片是 `#F7F7FA` 纯白底 + 一圈均匀
// 灰边 + `black 12% blur 8` 外投影，贴在深色内容上就是用户说的「抠图没抠干净」——白块与背景
// 之间既没有材质过渡，也没有光源方向。
//
// **多彩模式**：`ultraThinMaterial` 磨砂玻璃 + `#1C1C1E @ 90%` 深色染层 + 白 15% 细边 +
// 轻微柔阴影（black 30% / blur 12）。多彩模式本来就有品牌色与渐变，深色 HUD 卡片在明暗两档
// 下都能压住底下的彩色卡片，不需要为浅色档再另做一版。
struct NoticeSurface: View {
    var radius: CGFloat = NoticeMetrics.cornerRadius

    var body: some View {
        if AppTheme.isMinimalSkin {
            NeuRaisedBackground(radius: radius)
        } else {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(NoticeInk.colorfulCardTint))
                .overlay(shape.strokeBorder(NoticeInk.colorfulBorder, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 4)
        }
    }
}

/// Toast 上的文字 / 图标色。简洁模式走中性墨色（深色字），多彩模式走白色系（深色卡片上）。
enum NoticeInk {

    /// 多彩模式的深色染层：#1C1C1E @ 90%。压在磨砂玻璃之上，既保留一点背景透色，
    /// 又保证白字对比度足够。
    static let colorfulCardTint = Color(.sRGB, red: 0.110, green: 0.110, blue: 0.118, opacity: 0.90)

    /// 多彩模式的细边：白 15%。深色卡片在深色背景上唯一的轮廓来源。
    static let colorfulBorder = Color.white.opacity(0.15)

    static var title: Color { AppTheme.isMinimalSkin ? Neu.ink : .white }

    static var subtitle: Color {
        AppTheme.isMinimalSkin ? Neu.subtleInk : Color.white.opacity(0.72)
    }

    /// 状态图标色。它是整张卡片上唯一的语义信号（成功 / 警告 / 失败），两种皮肤都保留
    /// —— 简洁模式收掉的是**装饰性**上色（见 `NeuMiniButton`），不是功能性状态色。
    /// 多彩模式在深色卡片上要提亮一档，AppTheme 那组饱和色直接放上去会发暗。
    static func icon(_ kind: FloatingNoticeKind) -> Color {
        if AppTheme.isMinimalSkin { return kind.iconColor }
        switch kind {
        case .success: return Color(red: 0.36, green: 0.86, blue: 0.50)
        case .warning: return Color(red: 1.00, green: 0.76, blue: 0.28)
        case .error:   return Color(red: 1.00, green: 0.45, blue: 0.41)
        case .info:    return Color(red: 0.48, green: 0.74, blue: 1.00)
        }
    }
}

/// 用 AppKit 实测一段文字在指定字号下的宽度，喂给 `NoticeMetrics.cardWidth`。
///
/// 见 `NoticeMetrics.cardWidth` 的注释：SwiftUI 的 `frame(maxWidth:)` 会把卡片撑满 280pt，
/// 想要「贴合内容、封顶 280」只能自己量。
enum NoticeTextMeasure {
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        // +2：抗一点点字距/渲染误差，少 1pt 就会多出一个省略号。
        return ceil(measured) + 2
    }
}

// MARK: - Floating Notice View (v2.6.3, updated v2.6.7, redesigned v2.11.7 hotfix13)

/// Standalone view used by both the ContentView overlay and the global HUD window.
///
/// v2.11.7 hotfix13: 白色矩形底块换成随皮肤的两套材质（见 `NoticeSurface`），整体尺度收一档
/// （图标 20 → 14、标题 14 → 12.5、副标题 12 → 10.5、内边距 16/12 → 12/9），并把宽度封在
/// `NoticeMetrics.maxWidth`（280pt）内：`maxWidth` 而不是固定 `width`，所以短文案的卡片仍然
/// 只有内容那么宽，长副标题则居中截断。
struct FloatingNoticeView: View {
    let notice: FloatingNotice

    var body: some View {
        HStack(spacing: NoticeMetrics.iconTextSpacing) {
            Image(systemName: notice.kind.semanticIcon)
                .font(.system(size: NoticeMetrics.iconSize, weight: .semibold))
                .foregroundColor(NoticeInk.icon(notice.kind))

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: NoticeMetrics.titleFontSize, weight: .semibold))
                    .foregroundColor(NoticeInk.title)
                    .lineLimit(1)

                if !notice.subtitle.isEmpty {
                    Text(notice.subtitle)
                        .font(.system(size: NoticeMetrics.subtitleFontSize, weight: .medium))
                        .foregroundColor(NoticeInk.subtitle)
                        .lineLimit(1)
                        // 中间截断：保存类文案的**尾部**信息量最大（尺寸 / 文件名后缀），
                        // 尾部省略号会把它吃掉。
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, NoticeMetrics.horizontalPadding)
        .padding(.vertical, NoticeMetrics.verticalPadding)
        .frame(width: cardWidth, alignment: .leading)
        .background(NoticeSurface())
        .allowsHitTesting(false)
    }

    /// 贴合内容、封顶 280pt（见 `NoticeMetrics.cardWidth`）。
    private var cardWidth: CGFloat {
        NoticeMetrics.cardWidth(
            titleTextWidth: NoticeTextMeasure.width(notice.title,
                                                    size: NoticeMetrics.titleFontSize,
                                                    weight: .semibold),
            subtitleTextWidth: NoticeTextMeasure.width(notice.subtitle,
                                                       size: NoticeMetrics.subtitleFontSize,
                                                       weight: .medium)
        )
    }
}

// MARK: - SlotContent summary for notices

extension SlotContent {
    struct NoticeSummary {
        let typeTitle: String
        let detail: String
        let iconName: String
    }

    var noticeSummary: NoticeSummary {
        // URL
        if let webURL = detectedWebURL {
            return NoticeSummary(
                typeTitle: "URL",
                detail: webURL.host ?? webURL.absoluteString,
                iconName: "link"
            )
        }

        // Multiple files
        let files = detectedRegularFileURLs
        if files.count > 1 {
            return NoticeSummary(
                typeTitle: "多文件",
                detail: "\(files.count) 个文件",
                iconName: "doc.on.doc"
            )
        }

        // Folder
        if let folderURL = detectedFolderURLs.first {
            return NoticeSummary(
                typeTitle: "文件夹",
                detail: folderURL.lastPathComponent,
                iconName: "folder"
            )
        }

        // Single file
        if let fileURL = primaryFileURL {
            return NoticeSummary(
                typeTitle: "文件",
                detail: fileURL.lastPathComponent,
                iconName: "doc"
            )
        }

        // Image
        if hasImage {
            // UI-1 (v2.10.32): probe the image dimensions from the header instead of
            // decoding via `inlineImage`. This summary is built on the main thread from
            // all three save/copy trigger points (copySlot, 保存/覆盖, 文件夹按普通槽保存),
            // and the content is usually a freshly-written contentId (cold cache), so the
            // old `inlineImage` read fully decoded an 8K image on the main thread and
            // dropped ~200-500ms of frames on every save/copy of a large image.
            // `inlineImagePointSize()` reads only the header and reproduces the same
            // "w×h" value, so the HUD text is unchanged.
            if let size = inlineImagePointSize() {
                let w = Int(size.width)
                let h = Int(size.height)
                return NoticeSummary(
                    typeTitle: "图片",
                    detail: "\(w)×\(h)",
                    iconName: "photo"
                )
            }
            return NoticeSummary(
                typeTitle: "图片",
                detail: "图片内容",
                iconName: "photo"
            )
        }

        // Text
        let text = preview.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if !text.isEmpty && text != "(空)" {
            let truncated = String(text.prefix(30))
            return NoticeSummary(
                typeTitle: "文本",
                detail: truncated,
                iconName: "text.alignleft"
            )
        }

        // Empty
        return NoticeSummary(
            typeTitle: "空",
            detail: "无内容",
            iconName: "tray"
        )
    }
}
