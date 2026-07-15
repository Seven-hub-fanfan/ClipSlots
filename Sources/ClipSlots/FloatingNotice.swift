import Foundation
import ClipSlotsKit
import SwiftUI

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

// MARK: - Floating Notice View (v2.6.3, updated v2.6.7)

/// Standalone view used by both the ContentView overlay and the global HUD window.
/// v2.6.7: Replaced transparent/minimal background with solid opaque card that follows colorScheme.
struct FloatingNoticeView: View {
    @Environment(\.colorScheme) private var colorScheme

    let notice: FloatingNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(titleColor)

                if !notice.subtitle.isEmpty {
                    Text(notice.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(subtitleColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .allowsHitTesting(false)
    }

    // MARK: - Colors (v2.9.18: 收敛到 AppTheme.notice* / 语义色，不再自实现一套 RGB)

    private var cardBackground: Color {
        AppTheme.noticeBackground(colorScheme)
    }

    private var titleColor: Color {
        .primary
    }

    private var subtitleColor: Color {
        AppTheme.noticeSubtitle(colorScheme)
    }

    private var borderColor: Color {
        AppTheme.noticeBorder(colorScheme)
    }

    private var iconColor: Color {
        notice.kind.iconColor
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
            if let nsImage = inlineImage {
                let w = Int(nsImage.size.width)
                let h = Int(nsImage.size.height)
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
