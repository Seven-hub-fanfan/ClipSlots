import SwiftUI

struct CanvasSaveProgressView: View {
    @ObservedObject var progress: CanvasStore.SaveProgress
    let retry: () -> Void
    var body: some View {
        switch progress.status {
        case .saved:
            Label("已保存", systemImage: "checkmark")
                .font(.system(size: 10)).foregroundColor(CanvasSkin.chromeInkDim)
        case .saving:
            Text("保存中…").font(.system(size: 10)).foregroundColor(CanvasSkin.chromeInkDim)
        case .failed(let reason):
            Button(action: retry) {
                Label("保存失败 · 重试", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.red).help(reason)
        }
    }
}

struct CanvasSaveIndicator: View {
    @ObservedObject var progress: CanvasStore.SaveProgress
    let save: () -> Void
    private var hint: String {
        switch progress.status {
        case .saved: return "已保存 · 立即保存"
        case .saving: return "正在保存 · 立即保存"
        case .failed(let reason): return "保存失败 · \(reason)"
        }
    }
    private var color: Color {
        switch progress.status { case .saved: return .cyan; case .saving: return .yellow; case .failed: return .orange }
    }
    var body: some View {
        Button(action: save) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14)).frame(width: 40, height: 40)
                Circle().fill(color).frame(width: 5, height: 5).offset(x: -1, y: 1)
            }.background(CanvasSkin.chromeFill, in: Circle())
        }
        .buttonStyle(.plain).help(hint).accessibilityLabel(hint).accessibilityIdentifier("canvas-save-status")
    }
}
