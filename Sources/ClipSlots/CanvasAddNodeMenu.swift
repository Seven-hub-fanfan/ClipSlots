import SwiftUI
import ClipSlotsKit

/// 「ADD NODE」菜单（v2.11.8 · 对齐 Crate 画布）。
///
/// 空白处添加素材节点；从节点端口进入时引用上游生成。两种入口有不同文案和分区。
///
/// 表面与细边跟随画布外观，浅色模式避免深色光晕。
struct CanvasAddNodeMenu: View {

    /// 可创建的节点类型。
    ///
    /// **四项**（v2.11.19 加入视频），与项目的数据模型对齐：画布上的节点就是槽位。
    ///
    /// ## ★ v2.15.0：`.slot` 从"打开选择器"变成"真的建一个节点"
    ///
    /// 老语义是"展开左侧槽位库，你自己拖一个上来"—— 菜单里点一下却什么都没出现，只弹了行提示。
    /// 用户这一轮指着这张空槽位卡说"把这个作为槽位节点"，说明他期待的就是**点完就有一张卡**。
    /// 从槽位库拖已有槽位那条路一直都在（而且更适合"我要那一个"），不需要菜单再替它做入口。
    ///
    /// 批量模版节点仍然不放进来——它自身不出图，建了也没有意义。
    enum Choice: String, Identifiable, CaseIterable {
        case text
        case image
        case video
        case slot
        case audio
        case threeD
        case timeline
        case stage
        case upload

        var id: String { rawValue }

        var title: String {
            switch self {
            case .text: return "文本"
            case .image: return "图片"
            case .video: return "视频"
            case .slot: return "槽位节点"
            case .audio: return "音频"
            case .threeD: return "3D"
            case .timeline: return "剪辑时间线"
            case .stage: return "3D 片场"
            case .upload: return "上传"
            }
        }

        func title(referencing: Bool) -> String {
            referencing && [.text, .image, .video].contains(self) ? title + "生成" : title
        }

        var isAvailable: Bool { [.text, .image, .video, .slot, .upload].contains(self) }

        var subtitle: String {
            switch self {
            case .text: return "将画面想法优化为生图 Prompt"
            default: return ""
            }
        }

        var symbol: String {
            switch self {
            case .text: return "text.alignleft"
            case .image: return "photo"
            case .video: return "film"
            case .slot: return "square.grid.2x2"
            case .audio: return "waveform"
            case .threeD: return "cube"
            case .timeline: return "film"
            case .stage: return "globe"
            case .upload: return "square.and.arrow.up"
            }
        }
    }

    var parentCount: Int = 0
    var maxHeight: CGFloat = 560
    let onPick: (Choice) -> Void
    let onDismiss: () -> Void

    @State private var hovered: Choice? = nil

    /// 菜单宽度。够放两行文字（标题 + 说明）而不换行，再宽就会盖住半张画布。
    static let width: CGFloat = 260
    static func height(parentCount: Int) -> CGFloat { parentCount > 0 ? 304 : 596 }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle(parentCount > 1 ? "引用所有选中的节点生成" : (parentCount == 1 ? "引用该节点生成" : "添加节点"))
                ForEach([Choice.text, .image, .video, .audio, .threeD]) { row($0) }
                if parentCount == 0 {
                    sectionTitle("辅助工具")
                    row(.timeline)
                    row(.stage)
                    row(.slot)
                    sectionTitle("添加资源")
                    row(.upload)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(width: CanvasAddNodeMenu.width, alignment: .leading)
        .frame(height: min(maxHeight, Self.height(parentCount: parentCount)))
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                // v2.16.2：TapNow 的 ADD NODE 浮层不是一块死实底，而是黑玻璃。
                // 纯 material 在纯黑画布上层次不够，叠一层低透明深色 tint，既保留毛玻璃高光，
                // 又不让下层节点文字透得影响可读性。
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TapSkin.menuFill)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TapSkin.border, lineWidth: 1)
        )
        // Esc 关闭。菜单是浮层，没有它就只能靠点空白关掉 —— 而"点空白"在这里恰好又是
        // 再次触发双击建节点的手势区，容易连环误触。
        .canvasControlRegion("add-menu")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(TapSkin.secondaryInk)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func row(_ choice: Choice) -> some View {
        Button {
            onPick(choice)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: choice.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(TapSkin.ink)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(TapSkin.subtleFill)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title(referencing: parentCount > 0))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(TapSkin.ink)
                    if !choice.subtitle.isEmpty { Text(choice.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(TapSkin.secondaryInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true) }
                }

                Spacer(minLength: 0)
                if !choice.isAvailable {
                    Text("暂未接入")
                        .font(.system(size: 10))
                        .foregroundColor(TapSkin.secondaryInk)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovered == choice ? TapSkin.menuRowHoverFill : .clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!choice.isAvailable)
        .opacity(choice.isAvailable ? 1 : 0.4)
        .help(choice.isAvailable ? choice.title(referencing: parentCount > 0) : "\(choice.title)暂未接入")
        .canvasControlRegion("add-menu-row-\(choice.rawValue)")
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
