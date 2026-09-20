import SwiftUI
import ClipSlotsKit

/// 画布左上角的**项目切换器**（v2.13.0）。
///
/// ## 为什么是它，而不是"顶栏加一个下拉"
///
/// 用户要求「支持新建项目」。项目是画布的**文档单位**（一条片子一张画布），所以切换器的位置对齐
/// 所有画布类工具的惯例：贴在画布左上角、紧挨侧栏，既是"当前打开的是哪个文件"的常驻指示，
/// 也是唯一的项目入口。放进 App 顶栏会让它和"页 / 组"这两级槽位维度挤在一起 —— 那是两套完全
/// 不同的东西（页/组是槽位容器，项目是画布文档），并排摆只会让人以为它们有从属关系。
///
/// ## ★ 为什么是 Button + popover，而不是 `Menu`
///
/// 第一版用的是 `Menu { … } label: { 胶囊 }` + `.menuStyle(.borderlessButton)`，装机实测**样式全丢**：
/// 胶囊底、描边、阴影、右侧的 chevron 一个都没渲染，画布左上角只剩一个图标加一行字飘在网格上。
/// 根因是 macOS 的 menu style 会**拿 label 里的 text/image 重新搭一个自己的按钮**，而不是把你给的
/// 视图原样画出来 —— 所有装饰性修饰符（background / overlay / shadow）在这一步被丢掉。
/// 所以这里改成自己持有一个 `Button` + `.popover`：样式完全可控，代价是菜单项要自己排。
///
/// ## 输入输出刻意都收在外面
///
/// 这个视图**不碰任何存储**：切换 / 新建 / 重命名 / 删除都往外抛闭包。原因是"删项目"要连带删它的
/// 私有槽位组（`SlotStoreObservable.deleteCanvasPrivateGroup`），而那是主 store 的事 ——
/// 画布侧的这些小视图一旦开始直接写槽位存储，就再也说不清是谁改了用户的数据。
///
/// 弹窗（改名输入、删除确认）留在内部：它们纯粹是本控件的交互细节，外抛只会让调用方多背两个
/// `@State`。
struct CanvasProjectSwitcher: View {

    @ObservedObject var canvas: CanvasStore

    /// 切到某个项目。
    let onSwitch: (String) -> Void
    /// 新建项目（名字已去空白，非空）。
    let onCreate: (String) -> Void
    /// 重命名当前项目。
    let onRename: (String) -> Void
    /// 删除指定项目（调用方负责连带清理它的私有槽位组）。
    let onDelete: (CanvasProject) -> Void

    @State private var isHovering = false
    @State private var showingList = false
    /// 非 nil = 正在弹名字输入框。
    @State private var naming: NamingMode?
    @State private var draftName: String = ""
    @State private var confirmingDelete = false

    enum NamingMode: Identifiable {
        case create
        case rename
        var id: String { self == .create ? "create" : "rename" }
        var title: String { self == .create ? "新建项目" : "重命名项目" }
        var confirm: String { self == .create ? "创建" : "保存" }
    }

    var body: some View {
        Button {
            showingList = true
        } label: {
            capsuleLabel
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Anim.interactive) { isHovering = hovering }
        }
        .help("画布项目：切换 / 新建 / 重命名 / 删除")
        .popover(isPresented: $showingList, arrowEdge: .bottom) {
            listPopover
        }
        .sheet(item: $naming) { mode in
            namingSheet(mode)
        }
        .confirmationDialog("删除项目「\(canvas.activeProject.name)」？",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("删除项目", role: .destructive) {
                onDelete(canvas.activeProject)
            }
            Button("取消", role: .cancel) {}
        } message: {
            // 把"能恢复"写进文案：这是破坏性操作，用户唯一的安全感来源就是这句话。
            Text("画布上的节点与本项目暂存的内容都会被移入回收站（30 天内可恢复）。已归档到正式槽位的内容不受影响。")
        }
    }

    // MARK: - 胶囊

    private var capsuleLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.chromeAccentInk)
            Text(canvas.activeProject.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeInk)
                .lineLimit(1)
            // 项目数 ≥ 2 才报数。只有一个项目时这个角标是纯噪声。
            if canvas.projects.count > 1 {
                Text("\(canvas.projects.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(AppTheme.chromeAccentSoftFill))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            Capsule(style: .continuous)
                .fill(isHovering ? AppTheme.chromeAccentSoftFill : AppTheme.elevatedBackground)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false), radius: 8, x: 0, y: 3)
    }

    // MARK: - 下拉

    private var listPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("画布项目")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(canvas.projects) { project in
                projectRow(project)
            }

            Divider().padding(.vertical, 4)

            actionRow(title: "新建项目…", icon: "plus") {
                draftName = CanvasProject.nextDefaultName(existing: canvas.projects.map(\.name))
                naming = .create
            }
            actionRow(title: "重命名当前项目…", icon: "pencil") {
                draftName = canvas.activeProject.name
                naming = .rename
            }
            actionRow(title: "删除当前项目…", icon: "trash", destructive: true, enabled: canDeleteActive) {
                confirmingDelete = true
            }
            .padding(.bottom, 8)
        }
        .frame(width: 220)
    }

    private func projectRow(_ project: CanvasProject) -> some View {
        let isActive = project.id == canvas.activeProjectId
        return HoverRow {
            showingList = false
            guard !isActive else { return }
            onSwitch(project.id)
        } content: {
            HStack(spacing: 6) {
                // 勾选当前项：没有选中态的话，用户点开只能靠回忆确认自己在哪个项目里。
                // 未选中时占位而不是给一个空 systemName（空名字是无效符号，会画出一个问号占位框）。
                Group {
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(AppTheme.chromeAccentInk)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10, height: 10)
                Text(project.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundColor(AppTheme.canvasChromeInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func actionRow(title: String,
                           icon: String,
                           destructive: Bool = false,
                           enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        HoverRow(enabled: enabled) {
            showingList = false
            action()
        } content: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text(title)
                    .font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundColor(enabled
                             ? (destructive ? Color.red : AppTheme.canvasChromeInk)
                             : AppTheme.canvasChromeTertiaryInk)
        }
    }

    /// 最后一个项目不给删（`CanvasProjectIndex.canDelete`）：画布 UI 建立在"当前一定有一个项目"
    /// 之上，删空之后没有任何界面能把它建回来。
    private var canDeleteActive: Bool {
        CanvasProjectIndex(projects: canvas.projects,
                           activeProjectId: canvas.activeProjectId).canDelete(canvas.activeProjectId)
    }

    // MARK: - 改名 / 新建

    private func namingSheet(_ mode: NamingMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeInk)
            TextField("项目名称", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commit(mode) }
            Text("最多 \(CanvasProject.maxNameLength) 个字")
                .font(.system(size: 10))
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
            HStack {
                Spacer()
                Button("取消") { naming = nil }
                    .keyboardShortcut(.cancelAction)
                Button(mode.confirm) { commit(mode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    private func commit(_ mode: NamingMode) {
        let trimmed = String(draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(CanvasProject.maxNameLength))
        guard !trimmed.isEmpty else { return }
        naming = nil
        switch mode {
        case .create: onCreate(trimmed)
        case .rename: onRename(trimmed)
        }
    }
}

/// 下拉里的一行：整行可点 + 悬停高亮。
///
/// 抽出来是因为 `Button` 在 popover 里默认只有文字可点、且没有悬停反馈 —— 而"整行可点"是所有
/// 原生菜单的基本手感，缺了它用户会以为这一行是标题。
private struct HoverRow<Content: View>: View {
    var enabled: Bool = true
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: { if enabled { action() } }) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering && enabled ? AppTheme.chromeAccentSoftFill : Color.clear)
                        .padding(.horizontal, 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}
