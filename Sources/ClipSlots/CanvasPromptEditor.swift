import SwiftUI
import AppKit

/// 画布节点卡片里的 inline 提示词编辑器（v2.11.7 hotfix20）。
///
/// ## 为什么要自己裹一个 NSTextView
///
/// 用户的要求是「点编辑可以改提示词，回车就默认是修改保存」。这条键位契约在 SwiftUI 原生控件上
/// **做不出来**：
///   - `TextEditor`：Return 被它自己吞掉插成换行，macOS 13 上没有任何合法钩子能在它之前截住
///     （`.onKeyPress` 要 macOS 14，本项目最低 13；`.onSubmit` 对 `TextEditor` 根本不触发）。
///   - `TextField(axis: .vertical)`：Return 会提交，但 Shift+Return 也一样提交 —— 拿不到换行。
///
/// 而"回车保存 + Shift+回车换行"这两条必须同时成立：提示词是多行文本，只给保存不给换行等于
/// 逼用户去编辑页才能写第二行；只给换行不给保存就是用户现在抱怨的那个状态。
///
/// `NSTextView` 的 `textView(_:doCommandBy:)` 是唯一能按修饰键分流 Return 的位置。
///
/// ## 焦点
///
/// 进编辑态后必须**立刻能打字**，否则用户会以为按钮没反应。这里在 `viewDidMoveToWindow` 之后
/// 异步抢 first responder：卡片位于被 `scaleEffect` 包裹的画布子树里，SwiftUI 的 `@FocusState`
/// 在这种子树里实测抢不稳（会被下一次视图重建丢掉），而 NSTextView 自己抢是确定性的。
struct CanvasPromptEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    /// 回车时调用（文本已经通过 binding 同步）。
    let onCommit: () -> Void
    /// Esc。
    let onCancel: () -> Void
    /// 失焦。与 `onCommit` 分开传是为了让调用方能给两条路径不同语义（当前两者都保存）。
    let onBlur: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = FocusGrabbingTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = font
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        // 全选，符合"点编辑就想整段重写"的常见意图；想追加的话按一下 → 即可。
        textView.selectAll(nil)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.font != font { textView.font = font }
        // ★ 只在**外部**值与视图内容不一致时才回写，且必须跳过"正在输入"的情形。
        // 无条件 `textView.string = text` 会在每次 SwiftUI 重建时把光标弹回开头（打一个字跳一次），
        // 这是 NSViewRepresentable 包文本控件最经典的翻车点。
        if textView.string != text && !context.coordinator.isEditing {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CanvasPromptEditor
        weak var textView: NSTextView?
        /// 用户正在这个控件里打字。用来挡掉 `updateNSView` 的回写（见那边注释）。
        var isEditing = false

        init(parent: CanvasPromptEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = tv.string
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditing = false
            parent.text = tv.string
            // 失焦即落库。不判"改没改"—— 下游（槽位写入）本身在无变化时提前返回，
            // 在这里判反而会漏掉边界（比如 IME 组字刚提交就切走）。
            parent.onBlur()
        }

        /// 键位分流。**这个方法是整个文件存在的理由**。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+回车 → 换行。判定必须看**当前事件**的修饰键：AppKit 对
                // Return 与 Shift+Return 默认发的是同一个 `insertNewline:`，光看 selector 分不开。
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.text = textView.string
                isEditing = false
                parent.onCommit()
                return true

            case #selector(NSResponder.insertLineBreak(_:)):
                // 有些键盘布局 / 输入法把 Shift+Return 映射成这个。语义同上：换行。
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                isEditing = false
                parent.onCancel()
                return true

            default:
                return false
            }
        }
    }
}

/// 挂到窗口上就自己抢焦点的 NSTextView。见 `CanvasPromptEditor` 的「焦点」一节。
private final class FocusGrabbingTextView: NSTextView {
    private var hasGrabbedFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasGrabbedFocus, let window else { return }
        hasGrabbedFocus = true
        // 异步一拍：`viewDidMoveToWindow` 时视图层级还在装配，同步 makeFirstResponder 会被
        // 随后的布局回合抢回去。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// 画布上的卡片经常不在活跃窗口的第一响应链里，用户往往是"一下点进来就开始打字"。
    /// 接受 first mouse 能省掉那次"第一下只是激活"的空点。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
