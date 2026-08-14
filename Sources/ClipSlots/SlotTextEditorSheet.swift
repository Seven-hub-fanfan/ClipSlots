import SwiftUI

/// v2.10.90 (perf · ★槽位编辑逐字延迟根因): 槽位文本 / HTML 编辑 Sheet 的独立承载视图。
///
/// 背景：编辑器原先直接写在 `SlotCardView` 的 `textEditorSheet` / `htmlEditorSheet` 里，
/// `TextEditor` 绑的是 `SlotCardView` 自己的 `@State private var editingText`。
///
/// 后果是**每敲一个字符都会让整张卡片的 body 重新求值**——而 `SlotCardView.body` 是全仓最重的 body
/// 之一：headerRow、缩略图区（`SlotThumbnailView`，内含 `currentKey` 四段字符串拼接 + provider 查表）、
/// 元数据行、actionRow（其中 `canEditContent` / `editActionTitle` 会触发 `isHTMLContent` 的全文
/// `lowercased()`）、6 层 overlay（描边 / 顶部色条 / 角标 / 拖放提示…）、阴影、`scaleEffect`，
/// 以及两个 `.sheet` 闭包本身。卡片虽被 Sheet 遮住，却仍在视图树里，照样要全部重算。
/// 这就是「每个字都像有延迟输入、不丝滑」的来源：延迟量随卡片复杂度而不是随文本长度增长。
///
/// 拆出来后，`TextEditor` 绑的是**本视图自己的** `@State draft`，逐字输入只重算这一个轻量 Sheet，
/// 与卡片彻底解耦。
///
/// 语义保持完全一致：
/// - 初值由调用方在点「编辑」时快照好传入（`initialText`），与原先 `beginEditing()` 里赋值 `editingText`
///   的时机一致；
/// - 「保存」回调传出当前草稿，「取消」直接关闭且不回调，均与原实现相同；
/// - ⌘↩ 保存快捷键、等宽字体、圆角描边、以及纯文本 / HTML 两种尺寸（520×320 / 620×360）原样保留。
struct SlotTextEditorSheet: View {
    enum Mode {
        case plainText
        case html

        var minWidth: CGFloat {
            switch self {
            case .plainText: return 520
            case .html: return 620
            }
        }

        var minHeight: CGFloat {
            switch self {
            case .plainText: return 320
            case .html: return 360
            }
        }
    }

    let slot: Int
    let mode: Mode
    let initialText: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    /// 逐字输入只影响这个 @State，作用域被限制在本 Sheet 内。
    @State private var draft: String

    /// 初值在 `init` 里就灌进 @State，**不用 onAppear**。
    ///
    /// 这样做是为了同时避免两个方向的坑：
    /// - 用 `onAppear { draft = initialText }`：若该视图在仍处于展示状态时再次触发 onAppear
    ///   （父视图重建、窗口重新出现等），会把用户已经输入的内容覆盖回初值；
    /// - 只在 init 里播种、不做任何兜底：万一 SwiftUI 复用了同一视图身份（`.sheet` 正常会在关闭时销毁内容，
    ///   但不应把正确性押在这上面），@State 会残留上一次的草稿，重开编辑器就会看到**上一次的旧文本**。
    ///
    /// 因此：init 负责新实例的正确初值，下面的 `onChange(of: initialText)` 负责「身份被复用」时纠偏。
    /// `initialText` 只在卡片的 `beginEditing()` 里被写一次，编辑过程中不会变，所以这个 onChange
    /// 不会在打字时误触发、也不会与用户输入打架。
    init(
        slot: Int,
        mode: Mode,
        initialText: String,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.slot = slot
        self.mode = mode
        self.initialText = initialText
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialText)
    }

    private var heading: String {
        switch mode {
        case .plainText: return "编辑槽位 \(slot) 文本"
        case .html: return "编辑槽位 \(slot) HTML"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.headline)

            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .frame(minWidth: mode.minWidth, minHeight: mode.minHeight)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .onChange(of: initialText) { newValue in
            // 身份复用兜底：换了要编辑的内容就重新播种，避免残留上一次的草稿。
            draft = newValue
        }
    }
}
