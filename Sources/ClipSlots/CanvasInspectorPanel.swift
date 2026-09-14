import SwiftUI
import AppKit
import ClipSlotsKit

/// 画布右侧属性面板（v2.11.7 hotfix19）。
///
/// ## 为什么现在才有它
///
/// 用户反馈「无法保存字体」。在此之前画布**根本没有字体入口** —— 节点正文写死
/// `.font(.system(size: 10))`。所以这个 bug 的修复是两件事叠在一起：给模型加可持久化的
/// `fontName / fontSize`（`CanvasNode`），再给一个真正写回 store 的面板（本文件）。
///
/// ## 只在单选时出现
///
/// 多选时改字体只有两种可能：只改一个（用户会以为没生效），或者全改（等于偷偷批量改）。
/// 两种都比「面板不出现」更糟，所以由 `CanvasStore.soleSelectedNode` 把关。
///
/// ## 写回路径
///
/// 一律走 `canvas.updateNodeStyle`（内部 `commit`，进撤销栈），**不碰 `updateNode`** ——
/// 后者只落盘不记历史，用它改字体的症状是「改完 Cmd+Z 撤不掉」。
struct CanvasInspectorPanel: View {
    @ObservedObject var canvas: CanvasStore
    let node: CanvasNode

    /// 数据里存着、但本机没装的字体。单独列出来是为了给它一个 tag ——
    /// 否则 Picker 找不到匹配 selection 的 tag 会**显示空白**，看起来正好像「设置没保存」。
    private var missingCurrentFamily: String? {
        guard let current = node.fontName, !current.isEmpty,
              !CanvasFontCatalog.isAvailable(current) else { return nil }
        return current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)

            VStack(alignment: .leading, spacing: 10) {
                fontSection
                Divider().opacity(0.4)
                infoSection
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(width: 208)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.canvasChromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false), radius: 12, x: 0, y: 4)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.chromeAccentInk)
            Text("节点属性")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: 字体

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("正文字体")

            Picker("", selection: fontFamilyBinding) {
                // 「跟随系统」用空串当哨兵值而不是 nil：SwiftUI 的 `Picker` 对 `Optional` 选中值
                // 的 tag 匹配非常容易写错（tag 类型必须与 selection 完全一致，`String?` 与
                // `String` 不匹配时 Picker 会静默显示空白）。空串在 binding 里被归一成 nil。
                Text("跟随系统").tag("")

                if let missing = missingCurrentFamily {
                    Text(CanvasFontCatalog.displayName(missing)).tag(missing)
                }

                // 常用分组只列**本机真的装了的**（`commonFamilies` 已按可用性过滤）——
                // 列一堆装不上的字体、用户选了却没效果，等于把刚修掉的 bug 又造回去。
                Section("常用") {
                    ForEach(CanvasFontCatalog.commonFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Section("全部字体") {
                    ForEach(CanvasFontCatalog.otherFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            if missingCurrentFamily != nil {
                Label("本机未安装，暂以系统字体显示", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                sectionTitle("字号")
                Spacer(minLength: 0)
                Text("\(Int(node.resolvedBodyFontSize))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.canvasChromeInk)
                    .frame(width: 20, alignment: .trailing)
                Stepper("") {
                    canvas.updateNodeStyle(id: node.id, fontSize: .some(node.resolvedBodyFontSize + 1))
                } onDecrement: {
                    canvas.updateNodeStyle(id: node.id, fontSize: .some(node.resolvedBodyFontSize - 1))
                }
                .labelsHidden()
                .controlSize(.small)
            }

            // 实时预览。字体解析失败会静默回落系统字体（`Font.custom` 的老坑），有了这一行
            // 用户能立刻看出「到底换了没有」，不必去画布上比对 10pt 的小字。
            Text("永远相信美好的事情即将发生 Aa 123")
                .font(CanvasFontCatalog.font(family: node.fontName,
                                            size: max(11, node.resolvedBodyFontSize)))
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.chipBackground)
                )

            if node.hasCustomFont {
                Button {
                    canvas.updateNodeStyle(id: node.id, fontName: .some(nil), fontSize: .some(nil))
                } label: {
                    Text("恢复默认")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(AppTheme.chromeAccentInk)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Picker 的双向绑定。空串 ⇄ nil 的归一在这里做，store 只接受「已归一」的值。
    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { node.fontName ?? "" },
            set: { canvas.updateNodeStyle(id: node.id, fontName: .some($0.isEmpty ? nil : $0)) }
        )
    }

    // MARK: 只读信息

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            infoRow("类型", node.kind.displayName)
            infoRow("模型", node.model)
            infoRow("比例", node.ratio)
            // ★ hotfix20：节点 = 槽位，「未绑定」这一档在数据结构层面就不存在了
            // （`CanvasNode` 的 groupId/slot 是非可选的）。名字当场问槽位，见 `CanvasStore.nodeTitle`。
            infoRow("槽位", slotDescription)
        }
    }

    private var slotDescription: String {
        let fallback = "槽位 \(node.slot)"
        let name = canvas.nodeTitle(node)
        return name == fallback ? fallback : "\(name)（\(node.slot)）"
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(AppTheme.canvasChromeTertiaryInk)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(AppTheme.canvasChromeTertiaryInk)
    }
}
