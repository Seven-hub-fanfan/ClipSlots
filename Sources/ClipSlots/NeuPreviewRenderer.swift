import SwiftUI
import AppKit
import ClipSlotsKit

// MARK: - 顶部 chrome 离屏预览渲染器（v2.11.7 hotfix9）
//
// 为什么需要它：这一轮改的全是**观感**，唯一的验收手段是肉眼看截图。而 `screencapture` 依赖
// 「窗口此刻正在屏幕上」——本机已经两次（hotfix6、hotfix9）在改完之后遇到屏幕锁定 / 窗口不可见，
// 截出来只有一张壁纸，只能把「看起来对不对」这一步推到下次开机。
//
// `ImageRenderer`（macOS 13+）走的是 CoreGraphics 位图，**不需要窗口上屏**，所以锁屏时照样能出图。
// 于是把顶部 chrome 的那几个控件按真实布局拼一遍、离屏渲染成 PNG，皮肤 / 明暗各来一张。
//
// 触发方式刻意做成环境变量而不是命令行参数：命令行参数会被 SwiftUI 的 App 生命周期看见，
// 而 `open -a` 又不方便传参；环境变量对正常启动零影响——没设就直接 return false，一行都不跑。
//
//   CLIPSLOTS_RENDER_PREVIEW=/tmp/neu open -a ClipSlots     # 出 /tmp/neu_{minimal,colorful}_{light,dark}.png
//
// 注意这里渲染的是**控件本身**，不是真实窗口：数据是写死的假数据，布局按 ContentView 的顺序摆。
// 它能验证材质 / 光影 / 尺寸关系，验证不了真实数据下的换行与截断——那仍然要靠真机截图。
enum NeuPreviewRenderer {

    /// 若设置了 `CLIPSLOTS_RENDER_PREVIEW`，渲染预览图并返回 true（调用方应随即退出进程）。
    @MainActor
    static func runIfRequested() -> Bool {
        guard let prefix = ProcessInfo.processInfo.environment["CLIPSLOTS_RENDER_PREVIEW"],
              !prefix.isEmpty else { return false }

        for skin in [AppSkin.minimal, AppSkin.colorful] {
            for dark in [false, true] {
                AppSkinCenter.apply(skin)
                let path = "\(prefix)_\(skin.rawValue)_\(dark ? "dark" : "light").png"
                render(to: path, dark: dark)
            }
        }
        return true
    }

    @MainActor
    private static func render(to path: String, dark: Bool) {
        // 明暗两档都要真的生效，需要**两处**同时设置：
        //   • SwiftUI 侧的 `colorScheme` 环境值（决定 SwiftUI 自己解析的动态色）
        //   • AppKit 侧的「当前绘制外观」（决定 Neu 里 `dynAlpha` 那些 NSColor 动态回调走哪一档）
        // 只设 NSApp.appearance 是不够的——离屏渲染不经过窗口，取不到 App 的 effectiveAppearance，
        // 第一版就是这么写的，结果 light / dark 两张图逐字节相同。
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let renderer = ImageRenderer(content: PreviewStrip()
            .environment(\.colorScheme, dark ? .dark : .light))
        // 2x：与 Retina 截图同密度，1pt 的描边才有 2px 可看，否则「暗边比亮边宽」这种关系会被抹平。
        renderer.scale = 2
        var rendered: NSImage?
        appearance?.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let image = rendered ?? renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("[NeuPreview] render failed: \(path)\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("[NeuPreview] wrote \(path)")
    }
}

/// 顶部 chrome 的三行控件，按 ContentView 里的真实顺序与间距拼装。
private struct PreviewStrip: View {
    @State private var autoStore = true
    @State private var autoPaste = false
    @State private var scope = 0
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ① Header：开关簇（hotfix9 从竖滑道换成胶囊）
            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 6) {
                    NeuPillToggle(isOn: $autoStore, statusColor: .green, label: "自动存储")
                    HStack(spacing: 5) {
                        NeuMiniButton(title: "回退", icon: "arrow.uturn.backward") {}
                        NeuMiniButton(title: "重置", icon: "arrow.counterclockwise") {}
                    }
                }
                Rectangle().fill(Neu.hairlineStrong).frame(width: 1, height: 58)
                VStack(spacing: 6) {
                    NeuPillToggle(isOn: $autoPaste, statusColor: .blue, label: "自动粘贴")
                    HStack(spacing: 5) {
                        NeuMiniButton(title: "回退", icon: "arrow.uturn.backward") {}
                        NeuMiniButton(title: "重置", icon: "arrow.counterclockwise") {}
                    }
                }
            }

            // ② 搜索行：内凹搜索框 + 分段范围 + 图标方块
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Neu.subtleInk)
                    Text("搜索槽位内容")
                        .font(.system(size: 12))
                        .foregroundColor(Neu.subtleInk)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(width: 240, height: NeumorphicMetrics.searchHeight)
                .neuWell(radius: NeumorphicMetrics.searchRadius)

                NeuSegmentedControl(options: [NeuSegment(value: 0, title: "组内"),
                                              NeuSegment(value: 1, title: "全局")],
                                    selection: $scope)
                    .frame(width: 110)

                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Neu.ink)
                    .neuIconTile()
            }

            // ③ 组标签行（hotfix9 并入新拟物）
            HStack(spacing: 6) {
                GroupTabButton(name: "prompt", isCurrent: true) {}
                GroupTabButton(name: "1", isCurrent: false) {}
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Neu.ink)
                    .frame(width: NeumorphicMetrics.actionHeight, height: NeumorphicMetrics.actionHeight)
                    .neuRaised(radius: NeumorphicMetrics.actionRadius)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Neu.subtleInk)
                    .frame(width: NeumorphicMetrics.actionHeight, height: NeumorphicMetrics.actionHeight)
                    .neuRaised(radius: NeumorphicMetrics.actionRadius)
            }
        }
        .padding(24)
        .background(Neu.ground)
    }
}
