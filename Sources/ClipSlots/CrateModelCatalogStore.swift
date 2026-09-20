import Foundation
import SwiftUI
import ClipSlotsKit

/// 模型目录的加载状态持有者（v2.11.18）。
///
/// ## 为什么是单例 ObservableObject，而不是面板里的 `@State`
///
/// 属性面板（`CanvasInspectorPanel`）只在**单选**时出现，而且是随选中节点重建的视图 —— 把加载
/// 状态放进面板的 `@State`，用户每点一个节点就会重新 shell out 一次 `crate model list`（起一个
/// Node 进程、四十来个模型的 JSON）。目录是全 App 共享的、一段时间内不变的东西，所以状态提到
/// 进程级，面板只订阅。
///
/// ## 缓存策略：进程内 + 软过期
///
/// 不落盘：目录是线上状态（模型会下线），落盘缓存的收益只有"冷启动第一次快一点"，代价是要处理
/// "磁盘上的目录已经过期但用户看不出来"。进程内缓存 + `cacheTTL` 软过期够用了，用户还可以手动
/// 刷新（面板上的刷新按钮）。
///
/// ## 失败不是错误弹窗
///
/// 取目录失败的最常见原因是**没登录**或**没装 crate**，而那两种情况下用户本来也生不了图。所以
/// 失败只让选择器退回"只显示当前值 + 一行原因"，不弹窗、不拦路：画布上还有一堆与生图无关的事
/// 可做（改字体、连线、归槽）。
@MainActor
final class CrateModelCatalogStore: ObservableObject {

    static let shared = CrateModelCatalogStore()

    enum State: Equatable {
        case idle
        case loading
        case loaded([CrateModelCatalog.ModelInfo])
        /// 失败原因（已 clip 成一行，可直接显示）。
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// 软过期时间。模型上下线是以天计的事，10 分钟足够让"刚上线的模型"在下次打开面板时出现，
    /// 又不会让连续操作反复起进程。
    private let cacheTTL: TimeInterval = 600
    private var loadedAt: Date?
    private var inFlight: Task<Void, Never>?

    private init() {}

    /// 当前可选的出图模型。未加载 / 失败时为空数组（UI 据此退回只显示当前值）。
    var imageModels: [CrateModelCatalog.ModelInfo] {
        guard case .loaded(let all) = state else { return [] }
        return CrateModelCatalog.imageModels(all)
    }

    /// 当前可选的出视频模型（v2.11.19）。与 `imageModels` 是两份互不相交的清单：
    /// 实测没有任何模型同时声明 `text-2-image` 与 `text-2-video`，所以不必担心一个模型
    /// 在两个 picker 里都出现。
    var videoModels: [CrateModelCatalog.ModelInfo] {
        guard case .loaded(let all) = state else { return [] }
        return CrateModelCatalog.videoModels(all)
    }

    var isLoading: Bool { state == .loading }

    /// 按 id 查模型。**出图与出视频一起查**：调用方（属性面板 / 生成流水线）拿到节点上存的
    /// model 字段时并不总知道它属于哪一类（老画布里可能存着任意值），只查一半会让视频节点
    /// 永远"查不到模型" —— UI 上表现为分辨率/时长选择器凭空消失。
    func model(id: String) -> CrateModelCatalog.ModelInfo? {
        imageModels.first { $0.id == id } ?? videoModels.first { $0.id == id }
    }

    /// 需要时才加载（已加载且未过期 → 直接返回）。面板 `onAppear` 调它。
    func loadIfNeeded() {
        if case .loaded = state, let at = loadedAt, Date().timeIntervalSince(at) < cacheTTL { return }
        if inFlight != nil { return }
        reload()
    }

    /// 强制重取（面板上的刷新按钮 / 用户刚在终端登录完）。
    func reload() {
        inFlight?.cancel()
        state = .loading
        inFlight = Task { [weak self] in
            let result = await Self.fetch()
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let models):
                self.state = .loaded(models)
                self.loadedAt = Date()
            case .failure(let message):
                self.state = .failed(message)
                self.loadedAt = nil
            }
            self.inFlight = nil
        }
    }

    private enum FetchResult {
        case success([CrateModelCatalog.ModelInfo])
        case failure(String)
    }

    private static func fetch() async -> FetchResult {
        do {
            let models = try await CrateGenerationService.shared.fetchModelCatalog()
            // 解析出来但一个出图模型都没有，也算失败：picker 空着不给理由，用户只会以为 UI 坏了。
            guard !CrateModelCatalog.imageModels(models).isEmpty else {
                return .failure("crate 没有返回可用的出图模型")
            }
            return .success(models)
        } catch let err as CrateGenerationService.ServiceError {
            return .failure(err.userMessage)
        } catch {
            return .failure(CrateGeneration.clip(String(describing: error)))
        }
    }
}
