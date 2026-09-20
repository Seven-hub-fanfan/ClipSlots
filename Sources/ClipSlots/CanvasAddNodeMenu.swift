import SwiftUI
import ClipSlotsKit

/// 「ADD NODE」菜单（v2.11.8 · 对齐 Crate 画布）。
///
/// 两个入口共用这一个视图：**双击画布空白处**、**选中节点下方的 + 号**。共用不是为了省代码，
/// 是为了让两条路径的选项集合与文案永远一致 —— 两份菜单的实际后果是"双击能建文本节点、+ 号
/// 不能"这类无人察觉的行为分叉。
///
/// 样式刻意写死深色（不跟随浅色模式）：用户明确要求 Crate 风格的深色浮层，而 Crate 的菜单在
/// 亮色画布上也是深色的 —— 它是"悬在画布之上的工具"，与画布内容形成对比才立得住。
struct CanvasAddNodeMenu: View {

    /// 可创建的节点类型。
    ///
    /// **四项**（v2.11.19 加入视频），与项目的数据模型对齐：画布上的节点就是槽位，所以"新建节点"
    /// 要么新占一个空槽位（文本 / 图像 / 视频），要么把已有槽位摆上来（槽位）。
    /// 批量模版节点仍然不放进来——它自身不出图，建了也没有意义。
    enum Choice: String, Identifiable, CaseIterable {
        case text
        case image
        case video
        case slot

        var id: String { rawValue }

        var title: String {
            switch self {
            case .text: return "文本节点"
            case .image: return "图像节点"
            case .video: return "视频节点"
            case .slot: return "槽位节点"
            }
        }

        var subtitle: String {
            switch self {
            case .text: return "纯文本 / Prompt，占用一个空槽位"
            case .image: return "图像生成，入参文件挂在同一槽位"
            case .video: return "视频生成，挂图即首帧 / 尾帧"
            case .slot: return "从左侧槽位库把已有槽位摆上画布"
            }
        }

        var symbol: String {
            switch self {
            case .text: return "text.alignleft"
            case .image: return "photo"
            case .video: return "film"
            case .slot: return "square.grid.2x2"
            }
        }
    }

    let onPick: (Choice) -> Void
    let onDismiss: () -> Void

    @State private var hovered: Choice? = nil

    /// 菜单宽度。够放两行文字（标题 + 说明）而不换行，再宽就会盖住半张画布。
    static let width: CGFloat = 236

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ADD NODE")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.2)
                .foregroundColor(Color.white.opacity(0.45))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(Choice.allCases) { choice in
                row(choice)
            }
        }
        .padding(.bottom, 6)
        .frame(width: CanvasAddNodeMenu.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.42), radius: 22, x: 0, y: 12)
        // Esc 关闭。菜单是浮层，没有它就只能靠点空白关掉 —— 而"点空白"在这里恰好又是
        // 再次触发双击建节点的手势区，容易连环误触。
        .background(CanvasMenuEscapeCatcher(onEscape: onDismiss))
    }

    private func row(_ choice: Choice) -> some View {
        Button {
            onPick(choice)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: choice.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(hovered == choice ? 0.18 : 0.09))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                    Text(choice.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(hovered == choice ? 0.10 : 0))
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? choice : (hovered == choice ? nil : hovered) }
    }
}

/// 给浮层补一个 Esc 键监听。
///
/// SwiftUI 在 macOS 13 上没有对普通浮层生效的 `.onExitCommand`（它只对 focus 链上的响应者有效，
/// 而这个菜单是画布 ZStack 里的一层，从不抢焦点）。所以挂一个零尺寸 NSView 做本地事件监听，
/// 生命周期跟随视图挂载 —— 与 `CanvasInputAnchor` 同一套手法。
private struct CanvasMenuEscapeCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(onEscape: onEscape)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onEscape: onEscape)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var handler: (() -> Void)?

        func install(onEscape: @escaping () -> Void) {
            handler = onEscape
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // 53 = Esc。只吞 Esc，其它键一律原样放行（吞掉别的键会让画布快捷键在菜单开着时失效）。
                guard event.keyCode == 53 else { return event }
                self?.handler?()
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            handler = nil
        }

        deinit { uninstall() }
    }
}
