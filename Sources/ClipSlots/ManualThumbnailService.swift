import AppKit
import ClipSlotsKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 槽位缩略图手动上传（v2.11.0）
//
// 本文件是「手动缩略图」的**采集 + 归一化 + 展示缓存**三件套，刻意与存储层解耦：
//
//   ManualThumbnailMaker    ── 采集与归一化：截图（screencapture 子进程）、选图（NSOpenPanel），
//                              统一压成「最长边 1024 / JPEG q=0.85」的字节交给存储层。
//   ManualThumbnailCache    ── 展示侧的纯内存缓存（按 manualThumbnailId 定址）+ 异步解码。
//   ManualThumbnailImage    ── 轮盘扇区等「非 ThumbnailProvider」场景用的小尺寸 SwiftUI 视图。
//
// 卡片主预览区**不走**这里的缓存：它复用 ThumbnailProvider 那套「以 thumbnailKey 为维度的共享
// 可观察缓存」，只是在解码入口处优先读手动缩略图（见 ThumbnailProvider.load）。这样手动图和自动图
// 共享同一套失效/驱逐/重入协议，不会再引入第二条状态机——v2.10.64/65「切组串图」正是多套状态机
// 各自为政的产物。

// MARK: - 采集与归一化

enum ManualThumbnailMaker {

    /// 归一化后的最长边（像素）。1024 足够覆盖 Retina 下的卡片主预览与轮盘扇区，
    /// 又能把一张 4K 截图从数 MB 压到百 KB 级，避免大图撑爆槽位目录。
    ///
    /// v2.11.2：编码参数与实现整体下沉到 `ClipSlotsKit.ManualThumbnailCodec`，GUI 与 CLI 共用
    /// 同一份真理。这里保留同名常量只是为了不动 UI 文案等既有调用点。
    static let maxPixelEdge: CGFloat = ManualThumbnailCodec.maxPixelEdge
    /// JPEG 压缩质量。0.85 是「肉眼几乎无损 / 体积可控」的常用折中。
    static let jpegQuality: CGFloat = ManualThumbnailCodec.jpegQuality

    /// 可作为缩略图来源的图片类型。PNG / JPEG / HEIC 是需求明确要求的三种，
    /// 另外附带常见的 TIFF / GIF / BMP / WebP —— 反正统一转码成 JPEG，多支持几种零成本。
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .image]
        if let webp = UTType("org.webmproject.webp") { types.append(webp) }
        return types
    }

    enum MakeError: LocalizedError {
        case cancelled
        case decodeFailed(String)
        case encodeFailed
        case captureToolFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:                 return "已取消"
            case .decodeFailed(let name):    return "无法读取图片「\(name)」，可能不是受支持的图片格式或文件已损坏"
            case .encodeFailed:              return "图片编码失败"
            case .captureToolFailed(let m):  return "截图失败：\(m)"
            }
        }
    }

    /// 把任意图片文件归一化成「最长边 ≤1024 的 JPEG」字节。
    ///
    /// v2.11.2：实现下沉到 `ClipSlotsKit.ManualThumbnailCodec`（CLI 的 `set-thumbnail` 复用同一份），
    /// 这里只做「Kit 错误 → GUI MakeError」的映射，行为与下沉前等价：
    ///   • 解不出位图 / 文件缺失 / SVG·PDF → `.decodeFailed`（面向用户的文案不变）
    ///   • 位图 OK 但 JPEG 编码失败       → `.encodeFailed`
    ///
    /// 归一化本身仍走 ImageIO 增量降采样（`CGImageSourceCreateThumbnailAtIndex`）而不是先
    /// `NSImage(contentsOf:)` 再缩放：后者会把整张原图的全分辨率位图读进内存，用户随手拖一张
    /// 8000×6000 的照片就是 ~190MB 的瞬时峰值。
    static func normalizedJPEGData(from url: URL) throws -> Data {
        do {
            return try ManualThumbnailCodec.normalizedJPEGData(from: url)
        } catch ManualThumbnailCodec.CodecError.encodeFailed {
            throw MakeError.encodeFailed
        } catch {
            throw MakeError.decodeFailed(url.lastPathComponent)
        }
    }

    /// 把已解码的 NSImage 编码成 JPEG（同样先保证最长边 ≤1024）。
    static func jpegData(from image: NSImage) -> Data? {
        ManualThumbnailCodec.jpegData(from: image)
    }

    // MARK: 入口 1：选图

    /// 弹出文件选择器让用户挑一张图片。**必须在主线程调用**（NSOpenPanel 是 UI，
    /// `runModal()` 在非主线程上是未定义行为）。用户取消返回 nil。
    ///
    /// 这里刻意不加 `@MainActor`：调用方 `SlotStoreObservable` 是非 isolated 的
    /// ObservableObject，加了会逼着调用点变成 async，从而把「弹面板」这个同步交互
    /// 拆成两个 runloop 周期。用运行时断言守住线程约定即可。
    static func pickImageFile(slot: Int) -> URL? {
        assert(Thread.isMainThread, "pickImageFile 必须在主线程调用（NSOpenPanel）")
        let panel = NSOpenPanel()
        panel.title = "选择槽位 \(slot) 的缩略图"
        panel.message = "支持 PNG / JPEG / HEIC 等常见图片格式，将自动压缩为最长边 \(Int(maxPixelEdge))px"
        panel.prompt = "设为缩略图"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedContentTypes
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: 入口 2：截图

    /// 隐藏自身窗口后再截图，窗口消失需要等的时间。
    ///
    /// `orderOut` 只是把窗口从窗口列表里摘掉，窗口服务器还要合成并上屏下一帧；紧接着
    /// spawn `screencapture` 有实测概率把 ClipSlots 自己拍进去。0.3s 是「用户几乎感知不到延迟」
    /// 与「窗口一定已经消失」之间的折中，也和微信/飞书截图的手感一致。
    static let windowHideSettleDelay: TimeInterval = 0.3

    /// 调起系统交互式截图（框选），返回截图文件的临时路径；用户按 Esc 取消返回 nil。
    ///
    /// 为什么用 `/usr/sbin/screencapture -i` 子进程而不是 ScreenCaptureKit / CGWindowListCreateImage：
    /// 前者是系统自带工具，**由它自己持有屏幕录制权限**，本 App 无需申请任何 TCC 权限、无需
    /// entitlement、也不会弹「ClipSlots 想要录制此电脑的屏幕」的系统弹窗。代价只是一次进程 spawn。
    ///
    /// 参数说明：
    ///   -i  交互式框选（用户可拖选区域，或按空格切成窗口捕获，Esc 取消）
    ///   -o  窗口捕获时不带窗口阴影（避免缩略图四周一圈半透明黑边）
    ///   -x  静音（不放快门声）——设缩略图是个高频小操作，每次都「咔嚓」很吵
    ///
    /// - Parameter hidingOwnWindows: v2.11.0 hotfix。为 true 时先隐藏 ClipSlots 自己的所有可见
    ///   窗口、等窗口真正消失后再取景，截完（含 Esc 取消 / 抛错）在 `defer` 里恢复。这是微信/飞书
    ///   截图的标准体验：否则主窗口/轮盘就横在屏幕中间，用户想框的内容正好被自己挡住。
    ///
    /// ⚠️ 必须在主线程之外等待吗？不。`screencapture -i` 会阻塞到用户框选完成，可能长达数十秒；
    /// 因此本函数**不可**在主线程调用，调用方（store）负责派到后台队列。
    static func captureInteractiveScreenshot(hidingOwnWindows: Bool = true) throws -> URL? {
        assert(!Thread.isMainThread, "captureInteractiveScreenshot 会阻塞到用户框选完成，不可在主线程调用")

        // v2.11.0：屏幕录制权限**前置**预检。
        //
        // TCC 归因到发起进程（ClipSlots），未授权时直接跑 screencapture 会由系统弹出
        // 「ClipSlots 想要录制此电脑的屏幕」授权窗——那是个普通层级窗口，实测经常被主窗口压在
        // 后面，用户只看到「点了截图什么都没发生」。所以这里不去触发它，改弹我们自己的置顶
        // 引导面板（level = .screenSaver，盖过 App 全部窗口），把用户直接送到设置页。
        //
        // 注意顺序：预检必须在隐藏窗口**之前**，否则面板会在一片空屏上弹出。
        guard ScreenRecordingPermission.isAuthorized else {
            DispatchQueue.main.async { ScreenRecordingPermissionGuide.present() }
            return nil  // 非错误路径：引导已展示，调用方静默返回即可
        }

        // 隐藏 → 等一帧 → 截图 → 恢复。恢复走 defer，保证 Esc 取消和任何抛错路径都不会
        // 把用户的窗口永久留在隐藏状态（这是本功能最不能出的 bug）。
        var restoreHandle: ScreenshotWindowHider.Handle?
        if hidingOwnWindows {
            restoreHandle = DispatchQueue.main.sync { ScreenshotWindowHider.hideVisibleWindows() }
            if restoreHandle?.isEmpty == false {
                Thread.sleep(forTimeInterval: windowHideSettleDelay)
            }
        }
        defer {
            if let restoreHandle {
                DispatchQueue.main.async { ScreenshotWindowHider.restore(restoreHandle) }
            }
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipslots_shot_\(UUID().uuidString).png")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-o", "-x", tmp.path]
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw MakeError.captureToolFailed(error.localizedDescription)
        }
        // P0：先把 stderr 读干净再 wait。管道缓冲区（64KB）写满时子进程会阻塞在 write 上，
        // 而父进程阻塞在 waitUntilExit —— 经典的死锁配方。screencapture 的 stderr 通常为空，
        // 但「通常」不是不死锁的理由。
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        // 用户按 Esc 取消：screencapture 退出码为 1 且不产出文件。这是**正常流程**，不是错误。
        guard proc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            // 兜底：授权可能在预检之后被撤销（系统设置里现改现生效），此时 screencapture 会
            // 直接失败。别把它当成「用户取消」吞掉，仍然把置顶引导弹出来。
            if presentPermissionGuideIfRevoked() { return nil }
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if msg.isEmpty { return nil }  // 静默失败 = 用户取消
            throw MakeError.captureToolFailed(msg)
        }
        // 退出码 0 但没文件：同样按「用户取消」处理（部分系统版本上 Esc 走这一支）。
        guard FileManager.default.fileExists(atPath: tmp.path),
              let size = try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int,
              size > 0 else {
            try? FileManager.default.removeItem(at: tmp)
            _ = presentPermissionGuideIfRevoked()
            return nil
        }
        return tmp
    }

    /// 截图失败后复检权限：已被撤销就弹置顶引导并返回 true（调用方按「已处理」静默返回）。
    private static func presentPermissionGuideIfRevoked() -> Bool {
        guard !ScreenRecordingPermission.isAuthorized else { return false }
        DispatchQueue.main.async { ScreenRecordingPermissionGuide.present() }
        return true
    }
}

// MARK: - 截图期间隐藏自身窗口（v2.11.0 hotfix）

/// 截图取景期间把 ClipSlots 自己的窗口藏起来，截完再原样恢复。
///
/// 为什么是「逐窗口 orderOut」而不是 `NSApp.hide(nil)`：
///   1. `hide` 是 App 级别的，会连带把 App 置为 hidden 状态并交出激活权，`unhide` 回来时
///      还会强行重新激活 App —— 对一个「贴边浮窗 + 菜单栏常驻」的工具来说副作用太大。
///   2. 逐窗口处理才能**精确恢复**：只把「原本可见」的窗口放回去，并保持原有 z 序与 key 窗口，
///      不会把用户早就关掉的面板一起翻出来。
///
/// 状态栏窗口（`NSStatusBarWindow`）必须排除：它承载菜单栏图标，藏掉会让图标在截图期间
/// 闪一下消失，而且它本来也不会挡住用户要框选的内容。
enum ScreenshotWindowHider {

    /// 恢复所需的最小状态：被藏起来的窗口（按原 z 序，前 → 后）与原 key 窗口。
    struct Handle {
        let hidden: [NSWindow]
        let keyWindow: NSWindow?

        var isEmpty: Bool { hidden.isEmpty }
    }

    /// 隐藏本 App 当前所有可见窗口（状态栏窗口除外）。**必须在主线程调用。**
    static func hideVisibleWindows() -> Handle {
        assert(Thread.isMainThread, "hideVisibleWindows 操作 NSWindow，必须在主线程调用")

        let key = NSApp.keyWindow
        // NSApp.windows 是前 → 后的 z 序，原样记下来，恢复时倒序 orderFront 即可还原层次。
        let targets = NSApp.windows.filter { win in
            guard win.isVisible else { return false }
            // 菜单栏图标所在的窗口不能动。用类名判断：NSStatusBarWindow 是私有类，
            // 没有公开符号可比，但类名在各系统版本上稳定。
            return String(describing: type(of: win)) != "NSStatusBarWindow"
        }

        for win in targets { win.orderOut(nil) }
        return Handle(hidden: targets, keyWindow: key)
    }

    /// 恢复此前隐藏的窗口，尽量还原 z 序与键盘焦点。**必须在主线程调用。**
    static func restore(_ handle: Handle) {
        assert(Thread.isMainThread, "restore 操作 NSWindow，必须在主线程调用")
        guard !handle.isEmpty else { return }

        // 倒序（后 → 前）逐个 orderFront，最终 z 序与隐藏前一致。
        for win in handle.hidden.reversed() {
            win.orderFront(nil)
        }
        // key 窗口单独复位。它可能在截图期间被关掉（比如轮盘），所以要重新确认还在列表里。
        if let key = handle.keyWindow, handle.hidden.contains(where: { $0 === key }), key.canBecomeKey {
            key.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - 展示侧内存缓存

/// 手动缩略图的**纯内存**缓存（与项目既有约定一致：不落任何磁盘缓存目录）。
///
/// 定址方式是 `manualThumbnailId`，而 id 每次「换图」都会重新生成 UUID —— 所以缓存天然
/// 内容寻址、永不脏读：同一 id 的字节永远是同一张图（`.bin` 文件写入后从不原地修改，
/// 编辑一律走「新 id + 新文件」）。这条不变量让我们可以放心地把缓存做成全局共享、不按
/// 槽位/组隔离，也就不存在「切组串图」的可能。
@MainActor
final class ManualThumbnailCache: ObservableObject {
    static let shared = ManualThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    /// 正在解码中的 id，避免同一张图被多个视图重复排队解码。
    private var inFlight: Set<String> = []

    private init() {
        // 手动缩略图最长边 1024 → 解压后约 4MB/张；上限 64MB 够放十几张，
        // 超出后 NSCache 自行按 LRU 驱逐（内存告警时也会自动清空）。
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 64
    }

    func cachedImage(id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    /// 异步加载并缓存。已在缓存中则立即返回（不触发 objectWillChange，避免无谓重绘）。
    func image(id: String, url: URL) -> NSImage? {
        if let hit = cachedImage(id: id) { return hit }
        guard !inFlight.contains(id) else { return nil }
        inFlight.insert(id)

        Task.detached(priority: .userInitiated) {
            // 轮盘扇区最大 56pt（Retina 下 112px），解到 256 已远超所需，
            // 顺带覆盖 hover 放大等场景，仍比原图小一个数量级。
            let image = ClipSlotsImageIO.downsampledImage(url: url, maxPixel: 256)
            await MainActor.run {
                self.inFlight.remove(id)
                guard let image else { return }
                self.cache.setObject(image, forKey: id as NSString,
                                     cost: ClipSlotsImageIO.pixelCost(of: image))
                // 通知观察者重绘：此时 cachedImage(id:) 已能命中。
                self.objectWillChange.send()
            }
        }
        return nil
    }

    /// 清空缓存。清除手动缩略图 / 数据目录切换等场景调用。
    func clear() {
        cache.removeAllObjects()
        objectWillChange.send()
    }
}

// MARK: - 小尺寸展示视图（轮盘扇区等）

/// 圆角方形的手动缩略图（center-crop，不变形）。
/// 图未就绪时渲染 `placeholder`，就绪后淡入 —— 轮盘是瞬时弹出的，不能让它先闪一下空白骨架。
struct ManualThumbnailImage<Placeholder: View>: View {
    let manualThumbnailId: String
    let url: URL
    var side: CGFloat = 56
    var cornerRadius: CGFloat = 10
    @ViewBuilder var placeholder: () -> Placeholder

    @ObservedObject private var cache = ManualThumbnailCache.shared

    var body: some View {
        Group {
            if let image = cache.image(id: manualThumbnailId, url: url) {
                Image(nsImage: image)
                    .resizable()
                    // .fill + clipped = center-crop：保持宽高比铺满方形，超出部分裁掉。
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                    )
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .animation(.easeOut(duration: 0.15), value: cache.cachedImage(id: manualThumbnailId) != nil)
    }
}
