import AppKit
import SwiftUI

// v2.10.19: 一个以 NSPopover(.semitransient) 呈现 SwiftUI 内容的锚点视图。
//
// 背景：SwiftUI 自带的 `.popover` 底层是 `.transient` 行为的 NSPopover，
// 当 App 失焦（例如切到 Finder 去选文件）时会自动关闭。附件面板需要用户切到
// Finder 把文件拖回「拖拽文件到这里」区域，transient 行为会让面板消失、无法拖入。
//
// `.semitransient` 的 NSPopover 只在「用户与承载它的窗口交互」或「主动关闭 / Esc」
// 时才关闭；切换到其他 App 时保持打开，因此可以从 Finder 把文件拖进来。
//
// 用法：`.background(SemiTransientPopoverAnchor(isPresented: $flag) { Content() })`
struct SemiTransientPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var preferredEdge: NSRectEdge = .minY
    @ViewBuilder let content: () -> PopoverContent

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        // 每次刷新都更新内容构造器，保证弹窗内容随外部状态重建。
        context.coordinator.contentBuilder = content
        // 在下一 runloop 执行显示 / 关闭，避免在 SwiftUI 布局阶段直接改动 AppKit 层级。
        DispatchQueue.main.async {
            if isPresented {
                context.coordinator.showIfNeeded(from: nsView, preferredEdge: preferredEdge)
            } else {
                context.coordinator.closeIfNeeded()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: SemiTransientPopoverAnchor
        var contentBuilder: (() -> PopoverContent)?
        private var popover: NSPopover?

        init(_ parent: SemiTransientPopoverAnchor) {
            self.parent = parent
        }

        func showIfNeeded(from view: NSView, preferredEdge: NSRectEdge) {
            guard popover == nil else { return }
            guard view.window != nil else { return }
            guard let contentBuilder else { return }

            let popover = NSPopover()
            popover.behavior = .semitransient   // 关键：失焦不自动关闭
            popover.animates = true
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: contentBuilder())
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
            self.popover = popover
        }

        func closeIfNeeded() {
            guard let popover else { return }
            popover.performClose(nil)
            self.popover = nil
        }

        // 用户主动关闭 / Esc / 与窗口交互导致关闭时，同步回 SwiftUI 状态。
        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if parent.isPresented {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.isPresented = false
                }
            }
        }
    }
}
