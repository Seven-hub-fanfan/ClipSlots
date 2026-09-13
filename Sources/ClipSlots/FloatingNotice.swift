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

// MARK: - Toast 表面（v2.11.7 hotfix13，多彩分明暗 hotfix14）
//
// 两种皮肤两套材质，共用一套几何（`NoticeMetrics`）：
//
// **简洁模式**：与主界面画布**同色**的圆角卡片 + 两条长在边界上的描边（左上白亮边 = 受光棱、
// 右下暗边 = 侧面厚度），**没有任何外部投影**。这就是 hotfix8 定下的新拟物约定：凸起感由描边
// 表达，而不是由「离底板有段距离」的外投影表达。原来那张卡片是 `#F7F7FA` 纯白底 + 一圈均匀
// 灰边 + `black 12% blur 8` 外投影，贴在深色内容上就是用户说的「抠图没抠干净」——白块与背景
// 之间既没有材质过渡，也没有光源方向。
//
// **多彩模式**：磨砂玻璃 + 染层 + 细边 + 柔投影，**明暗两档各一套**（见
// `NoticePalette.colorfulSurface(dark:)`）。hotfix13 只做了深色那一档，理由是「深色卡片在
// 明暗两档下都能压住底下的彩色卡片」——浅色档下这句话不成立，近黑卡片贴在浅灰白画布上就是
// 一块和界面无关的黑条（用户 hotfix14 报的正是这个）。
//
// 明暗判据取 SwiftUI 环境值 `colorScheme` 而不是 `AppTheme.isDarkAppearance`：
//   * 环境值是**响应式**的，明暗切换会自然触发重绘，不像读 `NSApp.effectiveAppearance` 那样
//     把结果烘死进视图（NeumorphicKit 的 `dynAlpha` 注释记着这个坑）；
//   * HUD 面板那条通道也拿得到正确值 —— `FloatingNoticeWindowController` 在 host 时已经按
//     `appearanceMode` 显式注入了 `\.colorScheme`。
struct NoticeSurface: View {
    var radius: CGFloat = NoticeMetrics.cornerRadius

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if AppTheme.isMinimalSkin {
            NeuRaisedBackground(radius: radius)
        } else {
            let style = NoticePalette.colorfulSurface(dark: colorScheme == .dark)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(NoticeInk.material(style))
                .overlay(shape.fill(NoticeInk.color(style.tint)))
                .overlay(shape.strokeBorder(NoticeInk.color(style.border), lineWidth: style.borderWidth))
                .shadow(color: Color.black.opacity(style.shadow.opacity),
                        radius: style.shadow.radius,
                        x: 0,
                        y: style.shadow.offsetY)
        }
    }
}

/// Toast 上的文字 / 图标色。简洁模式走中性墨色（本身就是动态色，明暗各一档），
/// 多彩模式按 `colorScheme` 从 `NoticePalette` 取对应那一档。
enum NoticeInk {

    static func color(_ rgba: NoticeSurfaceStyle.RGBA) -> Color {
        Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.opacity)
    }

    /// 材质档位 → SwiftUI `Material`。两档是不同的具体类型，只能用 `AnyShapeStyle` 抹平。
    static func material(_ style: NoticeSurfaceStyle) -> AnyShapeStyle {
        switch style.material {
        case .ultraThin: return AnyShapeStyle(.ultraThinMaterial)
        case .thin:      return AnyShapeStyle(.thinMaterial)
        }
    }

    static func title(_ scheme: ColorScheme) -> Color {
        AppTheme.isMinimalSkin
            ? Neu.ink
            : color(NoticePalette.colorfulSurface(dark: scheme == .dark).titleInk)
    }

    static func subtitle(_ scheme: ColorScheme) -> Color {
        AppTheme.isMinimalSkin
            ? Neu.subtleInk
            : color(NoticePalette.colorfulSurface(dark: scheme == .dark).subtitleInk)
    }

    /// 状态图标色。它是整张卡片上唯一的语义信号（成功 / 警告 / 失败），两种皮肤都保留
    /// —— 简洁模式收掉的是**装饰性**上色（见 `NeuMiniButton`），不是功能性状态色。
    /// 多彩 + 深色卡片上要提亮一档，AppTheme 那组饱和色直接放上去会发暗；多彩 + 浅色卡片
    /// 反过来必须用原本的饱和色，提亮版（浅绿 / 浅黄）在白底上几乎看不见。
    static func icon(_ kind: FloatingNoticeKind, _ scheme: ColorScheme) -> Color {
        if AppTheme.isMinimalSkin { return kind.iconColor }
        guard NoticePalette.colorfulSurface(dark: scheme == .dark).isDarkSurface else {
            return kind.iconColor
        }
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

    /// hotfix14: 多彩皮肤的文字 / 图标色也分明暗两档，取环境值而不是读 `NSApp.effectiveAppearance`。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: NoticeMetrics.iconTextSpacing) {
            Image(systemName: notice.kind.semanticIcon)
                .font(.system(size: NoticeMetrics.iconSize, weight: .semibold))
                .foregroundColor(NoticeInk.icon(notice.kind, colorScheme))

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: NoticeMetrics.titleFontSize, weight: .semibold))
                    .foregroundColor(NoticeInk.title(colorScheme))
                    .lineLimit(1)

                if !notice.subtitle.isEmpty {
                    Text(notice.subtitle)
                        .font(.system(size: NoticeMetrics.subtitleFontSize, weight: .medium))
                        .foregroundColor(NoticeInk.subtitle(colorScheme))
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
