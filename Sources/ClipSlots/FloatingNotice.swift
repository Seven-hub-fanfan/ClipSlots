import Foundation
import SwiftUI

// MARK: - Floating Notice Kind (v2.6.3)

enum FloatingNoticeKind {
    case success
    case info
    case warning
    case error

    var iconColor: Color {
        switch self {
        case .success: return .green
        case .info:    return .accentColor
        case .warning: return .orange
        case .error:   return .red
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

// MARK: - Floating Notice View (v2.6.3)

/// Standalone view used by both the ContentView overlay and the global HUD window.
struct FloatingNoticeView: View {
    let notice: FloatingNotice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: notice.iconName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(notice.kind.iconColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                if !notice.subtitle.isEmpty {
                    Text(notice.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 18, y: 8)
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
