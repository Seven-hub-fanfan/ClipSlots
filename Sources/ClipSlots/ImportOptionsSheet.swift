import SwiftUI
import ClipSlotsKit

// MARK: - Import Options Sheet (v2.6.7)

/// Displays exactly two import mode choices using custom radio-style rows.
/// No Picker / TabView / ScrollView — plain VStack + Button to avoid wheel/4-dot bugs.

struct ImportOptionsSheet: View {
    let selection: PendingImportSelection
    let onCancel: () -> Void
    let onConfirm: (ImportChoiceMode) -> Void

    @State private var selectedChoice: ImportChoiceMode = .all

    private var summary: ImportSelectionSummary { selection.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("批量导入")
                // v2.9.18: 主标题统一到 AppTheme.Fonts.title（18pt），消除 17/18 摇摆。
                .font(AppTheme.Fonts.title)

            Text(summary.displayText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("选择导入方式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                ImportChoiceRow(
                    title: "全部保存",
                    subtitle: allSubtitle,
                    isSelected: selectedChoice == .all
                ) {
                    selectedChoice = .all
                }

                ImportChoiceRow(
                    title: firstTenTitle,
                    subtitle: firstTenSubtitle,
                    isSelected: selectedChoice == .firstTen
                ) {
                    selectedChoice = .firstTen
                }
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("开始导入") {
                    onConfirm(selectedChoice)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Dynamic labels

    private var allSubtitle: String {
        summary.hasFolders
            ? "导入所有可用文件，超过 10 个会自动保存到后续槽位组。"
            : "保存所有选中文件，超过 10 个会自动保存到后续槽位组。"
    }

    private var firstTenTitle: String {
        if summary.folderCount > 1 {
            return "每个文件夹只保存前 10 个"
        }
        return "只保存前 10 个"
    }

    private var firstTenSubtitle: String {
        if summary.folderCount > 0 && summary.fileCount > 0 {
            return "文件会全部保存，每个文件夹最多展开前 10 个文件。"
        }
        if summary.folderCount > 1 {
            return "每个文件夹最多导入前 10 个文件。"
        }
        if summary.folderCount == 1 {
            return "只导入该文件夹排序后的前 10 个文件。"
        }
        return "只保存当前选择中的前 10 个文件。"
    }
}

// MARK: - Import Choice Row (v2.6.7)

struct ImportChoiceRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(subtitle)
                        // v2.9.18: 11pt 说明字上调到 AppTheme.Fonts.caption（12pt），保证可读。
                        .font(AppTheme.Fonts.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
