import SwiftUI
import AppKit
import AVKit
import ClipSlotsKit

/// 全屏预览的**目标**（v2.15.0）。
///
/// 带 `nodeId` 是为了让信息条能说清"这是哪个节点的产物"，也让「入库」按钮有对象可操作 ——
/// 全屏态下用户手边已经没有那张卡片了，此时最想做的两件事恰恰是"存下来"和"在访达里打开"。
struct CanvasPreviewTarget: Identifiable, Equatable {
    let nodeId: String
    let attachment: SlotContent.SlotAttachment
    /// 节点的路径标识（`页面 - 组 - 槽位`），信息条左侧显示。
    let pathLabel: String
    /// 这个节点此刻能不能入库（已经在正式槽位库里的就不能，也不需要）。
    let canArchive: Bool

    var id: String { "\(nodeId)::\(attachment.id.uuidString)" }

    static func == (lhs: CanvasPreviewTarget, rhs: CanvasPreviewTarget) -> Bool { lhs.id == rhs.id }
}

/// 画布媒体的**全屏预览层**（v2.15.0）。
///
/// ## 为什么是画布内的一层 overlay，而不是新开窗口 / `.sheet`
///
/// 画布本身已经是一块**全屏独立工作区**（v2.11.7 hotfix17 起它不共享槽位界面的任何 chrome）。
/// 在它上面再开一个窗口，用户要管理两个窗口的层级和焦点；`.sheet` 更糟 —— macOS 的 sheet 从标题栏
/// 垂下来、带固定圆角和最大尺寸约束，一张 4K 竖图放进去只能得到一条窄缝。
///
/// 盖一层 overlay 的代价是"预览期间画布还在下面活着"，但这正好是想要的：`Esc` 关掉就立刻回到
/// 原来的视口、原来的选中，没有任何上下文丢失。
///
/// ## 交互约定
///
///   - `Esc` / 点击背景 / 右上角 ✕ → 关闭；
///   - 图片：捏合缩放（0.2×~8×）/ 信息条上的 ＋ − 按钮、拖动平移、双击复位；
///   - 视频：`AVPlayerView` 浮动控件，自动播放一次；
///   - 顶部信息条：路径标识 + `尺寸 · 比例 · 时长 · 体积` + 入库 / 在访达中显示 / 关闭。
///
/// 缩放刻意**不接滚轮**。SwiftUI（macOS 13 起）没有视图级滚轮回调，要接就得垫一层 `NSView`，
/// 而这一层会和图片上的 `DragGesture` / 双击抢 hit-test —— 想让滚轮进来又让拖拽穿过去，只能靠
/// 覆写 `hitTest` 之类的取巧写法，而 `scrollWheel` 的派发恰恰依赖 hitTest 的结果，两个要求互斥。
/// 捏合手势（`MagnificationGesture`）是纯 SwiftUI 的，和拖拽天然共存；画布本体此刻被浮层盖住、
/// 收不到事件，所以不存在"我到底在缩谁"的歧义。没有触控板的用户走信息条上的 ＋ − 按钮。
struct CanvasFullscreenPreview: View {

    let target: CanvasPreviewTarget
    let onClose: () -> Void
    /// 入库（存进正式槽位库）。`target.canArchive == false` 时按钮不出现。
    let onArchive: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    /// 捏合手势开始时的缩放基准。见 `MagnificationGesture` 处的注释。
    @State private var pinchBase: CGFloat = 1
    @State private var player: AVPlayer?
    @State private var fullImage: NSImage?

    private var isVideo: Bool { target.attachment.canvasIsVideoLike }

    var body: some View {
        ZStack {
            // 背景。0.92 而不是纯黑：留一点透明能看出"底下还有画布"，从而读作"这是一层浮层"
            // 而不是"我进了另一个界面"——后者会让人去找返回按钮而不是按 Esc。
            Color.black.opacity(0.92)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            content
                .padding(.top, 52)
                .padding(.bottom, 16)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                infoBar
                Spacer(minLength: 0)
            }
        }
        .background(
            // Esc 的接收者。SwiftUI 在 macOS 13 上没有可靠的"视图级 keyDown"，
            // 把 `.keyboardShortcut(.escape)` 挂在一个隐形按钮上是最稳的写法。
            Button(action: onClose) { EmptyView() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .transition(.opacity)
        .onAppear { prepare() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isVideo {
            videoContent
        } else {
            imageContent
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        if let player {
            SafeCanvasPlayerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .cornerRadius(8)
        } else {
            unavailableNotice("这份视频没有独立文件，无法播放",
                              hint: "内容以内嵌字节保存，先把它拖到磁盘上再预览")
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let fullImage {
            GeometryReader { geo in
                Image(nsImage: fullImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: dragStart.width + value.translation.width,
                                                height: dragStart.height + value.translation.height)
                            }
                            .onEnded { _ in dragStart = offset }
                    )
                    .onTapGesture(count: 2) { resetTransform() }
                    // 单击背景关闭，但单击**图片本身**不关闭：放大后拖动图片时手一抖成了单击，
                    // 浮层直接消失会让人非常恼火。
                    .onTapGesture { }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                // `value` 是**相对手势开始**的倍率，不是增量。乘在手势开始时的
                                // 基准上（`pinchBase`）而不是乘在当前 `zoom` 上 —— 后者会把
                                // 每一帧的倍率复合起来，一次小捏合就冲到上限。
                                zoom = clampZoom(pinchBase * value)
                            }
                            .onEnded { _ in pinchBase = zoom }
                    )
            }
        } else {
            unavailableNotice("这张图读不出来", hint: "文件可能已被移动或删除")
        }
    }

    private func unavailableNotice(_ title: String, hint: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.white.opacity(0.7))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    // MARK: - 信息条

    private var infoBar: some View {
        HStack(spacing: 10) {
            Image(systemName: isVideo ? "film" : "photo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(target.pathLabel)
                        .foregroundColor(.white.opacity(0.55))
                    if !badgeLine.isEmpty {
                        Text("·").foregroundColor(.white.opacity(0.35))
                        Text(badgeLine).foregroundColor(.white.opacity(0.8))
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            if !isVideo, fullImage != nil {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .frame(minWidth: 40, alignment: .trailing)
                barButton("minus.magnifyingglass", help: "缩小") { stepZoom(-1) }
                barButton("plus.magnifyingglass", help: "放大") { stepZoom(1) }
                barButton("arrow.counterclockwise", help: "复位（也可双击图片）") { resetTransform() }
            }
            if target.canArchive {
                barButton("tray.and.arrow.down", help: "入库到槽位库") { onArchive() }
            }
            if target.attachment.canvasLocalURL != nil {
                barButton("folder", help: "在访达中显示") { revealInFinder() }
            }
            barButton("xmark", help: "关闭（Esc）") { onClose() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial.opacity(0.9))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func barButton(_ symbol: String,
                          help: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var displayName: String {
        let att = target.attachment
        if let path = att.path, !path.isEmpty { return (path as NSString).lastPathComponent }
        return att.name
    }

    private var badgeLine: String { CanvasMediaProbe.badgeLine(for: target.attachment) }

    // MARK: - 动作

    /// 图片解码在**主线程同步**做一次。
    ///
    /// 这里刻意不走后台队列：全屏预览是用户显式发起的单次动作，等 30ms 出图好过先闪一个
    /// 空框再补上（那会让人以为"这张图坏了"）。而画布卡片上的缩略图仍然走异步缓存 ——
    /// 那边是一屏十几张、每帧都可能重算，两者的取舍前提完全不同。
    private func prepare() {
        if isVideo {
            if let url = target.attachment.canvasLocalURL {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            return
        }
        if let url = target.attachment.canvasLocalURL,
           let img = NSImage(contentsOf: url) {
            fullImage = img
        } else if let data = target.attachment.resolveData(),
                  let img = NSImage(data: data) {
            fullImage = img
        }
    }

    private func resetTransform() {
        zoom = 1
        pinchBase = 1
        offset = .zero
        dragStart = .zero
    }

    /// 上限 8× 下限 0.2×：再往上只是在看插值像素，再往下图比按钮还小。
    private func clampZoom(_ v: CGFloat) -> CGFloat { min(8, max(0.2, v)) }

    /// 按钮缩放：每次 ×1.25 / ÷1.25。
    ///
    /// 用**乘法**而不是"每次 +25%"：缩放是几何量，等比步进才能保证"放大三次再缩小三次回到原处"。
    private func stepZoom(_ direction: Int) {
        zoom = clampZoom(direction > 0 ? zoom * 1.25 : zoom / 1.25)
        pinchBase = zoom
    }

    private func revealInFinder() {
        guard let url = target.attachment.canvasLocalURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - AppKit 桥

/// `AVPlayerView` 的 SwiftUI 包装（v2.15.0）。
///
/// **不要**改用 `SwiftUI.VideoPlayer`：macOS 15.7.x 上私有的 `_AVKit_SwiftUI` 会在实例化泛型
/// 元数据时 abort（v2.7.22 记录过这次崩溃）。`RadialPreviewPanel` 里已有一份同样的桥，但它是
/// `private` 且绑在那个面板的生命周期上；这里需要一份能在画布层独立 dismantle 的。
private struct SafeCanvasPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
