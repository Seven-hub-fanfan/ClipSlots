import SwiftUI

/// v2.10.87 (perf · 交互状态继续下沉): 导入进度浮层，只观察 `TransientUIStore`。
///
/// 背景：进度状态原挂在巨型主 `SlotStoreObservable` 上，而它是全仓更新最频繁的状态之一——槽位包
/// 导入 / 批量文件导入 / 文件夹导入 / 打包导出每处理一个条目就上报一次。挂在主 store 上意味着每次
/// 百分比前进都令 `store.objectWillChange` 发射，从而让整棵 `ContentView.body`（标题栏 / 搜索区 /
/// 含 10 张卡片的 LazyVGrid / 底栏）重新求值。卡片的 Equatable 能拦住像素级重绘，但视图树 Diff
/// 本身就吃满了导入期间的主线程，表现为「导入大批文件时界面发涩、hover / 滚动不跟手」。
///
/// 拆分后 `ContentView` 不再读取 `store.importProgress`，进度推进只重绘这一条 340pt 宽的浮层。
///
/// 视觉与 v2.10.46 完全一致：
/// - 非模态：底部悬浮轻量进度条，无全屏阻塞遮罩，整体 `allowsHitTesting(false)`，导入期间可继续
///   操作其他槽位（边导入边整理），不打断心流；
/// - `total <= 0` 时显示不确定进度（解压 / 解析阶段），否则显示确定百分比与「x/y」计数；
/// - 进出场沿用 `.move(edge: .bottom) + .opacity` 配 `Anim.status`。
struct ImportProgressOverlayView: View {
    @ObservedObject var ui: TransientUIStore

    var body: some View {
        Group {
            if let progress = ui.importProgress {
                card(progress)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Anim.status, value: ui.importProgress != nil)
    }

    private func card(_ progress: ImportProgress) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text(progress.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                    if !progress.isIndeterminate {
                        Text("\(progress.completed)/\(progress.total)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }

                if progress.isIndeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                }

                if !progress.detail.isEmpty {
                    HStack {
                        Text(progress.detail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if !progress.isIndeterminate {
                            Text("\(Int(progress.fraction * 100))%")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(width: 340)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 14, y: 6)
            )
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 非模态关键点：整体不拦截点击，导入期间主网格照常可交互。
        .allowsHitTesting(false)
    }
}
