import SwiftUI
import ClipSlotsKit

/// 闭包只在内容键变化时执行，pan / zoom 不再触发槽位读取与媒体探测。
struct CanvasRenderBoundary: View, Equatable {
    struct Key: Equatable {
        let node: CanvasNode
        let selected: Bool
        let editing: Bool
        let hovered: Bool
        let textVisible: Bool
        var fanTextVisible: Bool = true
        let slotRevision: Int
        let contentRevision: Int
        let currentGroup: String
        let currentContentId: String?
        let path: String
        var connectionAppearance: CanvasConnectionAppearance = .idle
        var referenceNodes: [CanvasNode] = []
        var referenceEdges: [CanvasEdge] = []
        var referenceContentRevisions: [Int] = []
    }
    let key: Key
    private let content: () -> AnyView
    init<Content: View>(key: Key, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = { AnyView(content()) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View {
        #if DEBUG
        let _ = CanvasRenderDiagnostics.record()
        #endif
        content()
    }
}

#if DEBUG
enum CanvasRenderDiagnostics {
    static var count = 0
    static func record() {
        if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1" { count += 1 }
    }
}
#endif
