import SwiftUI
import ClipSlotsKit

/// Every canvas child already has a fixed frame and a world-space offset.
/// Mounting one must not make the stack measure all the other cards.
struct CanvasAbsoluteLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
        }
    }
}

struct CanvasNodeLayerKey: Equatable {
    let project: String
    let nodes: [CanvasNode]
    let edges: [CanvasEdge]
    let piles: [CanvasPile]
    let groups: [CanvasNodeGroup]
    let selected: Set<String>
    let selectedGroup: String?
    let edited: String?
    let hovered: String?
    let dragID: String?
    let dragged: Set<String>
    let delta: CGSize
    let pan: CGSize
    let zoom: CGFloat
    let layoutZoom: CGFloat
    let size: CGSize
    let source: String?
    let reverse: Bool
    let aimed: String?
    let contentRevisions: [String: Int]
    let currentGroup: String
    let paths: [String]
    let landings: [String: CGRect]
    let groupDrag: String?
    let groupResize: CGRect?
    let pileDrag: String?
    let hoveredPile: String?
    let pileGallery: String?
    let pileEntries: [String: CGRect]
}

/// Menu state and pointer movement do not traverse the whole node layer when
/// its displayed content and geometry are unchanged.
struct CanvasNodeLayerBoundary: View, Equatable {
    let key: CanvasNodeLayerKey
    private let content: () -> AnyView
    init<Content: View>(key: CanvasNodeLayerKey, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = { AnyView(content()) }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View { content() }
}

/// Each fixed slot observes its own admission. Opening a slot does not rebuild
/// the ForEach or invalidate the already mounted cards.
struct CanvasMountingNode: View {
    @ObservedObject var admission: CanvasNodeAdmission
    private let content: () -> AnyView
    init<Content: View>(admission: CanvasNodeAdmission, @ViewBuilder content: @escaping () -> Content) {
        self.admission = admission
        self.content = { AnyView(content()) }
    }
    var body: some View {
        if admission.ready { content() }
    }
}

final class CanvasNodeAdmission: ObservableObject {
    static let immediate = CanvasNodeAdmission(ready: true)
    @Published var ready: Bool
    let label: String
    init(ready: Bool, label: String = "") { self.ready = ready; self.label = label }
}

final class CanvasNodeMountQueue {
    private(set) var pendingIDs = Set<String>()
    private var pending: [String] = []
    private var admissions: [String: CanvasNodeAdmission] = [:]
    private var ticker: UUID?
    func admission(for id: String) -> CanvasNodeAdmission {
        if let value = admissions[id] { return value }
        let value = CanvasNodeAdmission(ready: !pendingIDs.contains(id), label: id)
        admissions[id] = value
        return value
    }
    func enroll(_ ids: [String]) {
        pendingIDs.formUnion(ids)
        for id in ids { admissions[id] = CanvasNodeAdmission(ready: false, label: id) }
    }
    func admitNative(_ ids: [String]) {
        for id in ids {
            pendingIDs.remove(id)
            admissions[id]?.ready = true
        }
        pending.removeAll { ids.contains($0) }
        if pending.isEmpty { cancel() }
    }
    func update(ids: [String]) {
        pendingIDs.formIntersection(ids)
        let retained = Set(ids)
        admissions = admissions.filter { retained.contains($0.key) }
        pending = ids.filter { pendingIDs.contains($0) }
        guard !pending.isEmpty else { cancel(); return }
        guard ticker == nil else { return }
        ticker = CanvasDisplayClock.shared.subscribe { [weak self] in
            guard let self, let id = self.pending.first else { self?.cancel(); return }
            self.pending.removeFirst()
            self.pendingIDs.remove(id)
            WorkspaceMountTrace.mark("admit:\(id)")
            if let admission = self.admissions[id], !admission.ready { admission.ready = true }
            if self.pending.isEmpty { self.cancel() }
        }
    }
    func cancel() {
        if let ticker { CanvasDisplayClock.shared.unsubscribe(ticker) }
        ticker = nil
    }
    /// Tear down each visible section separately before replacing the root.
    /// Cancellation uses pendingIDs to restore the currently displayed page.
    @MainActor
    func retire() async {
        cancel()
        for id in admissions.keys.sorted().reversed() {
            guard !Task.isCancelled else { return }
            guard let admission = admissions[id], admission.ready else { continue }
            pendingIDs.insert(id)
            WorkspaceMountTrace.mark("retire:\(id)")
            admission.ready = false
            await CanvasDisplayClock.shared.nextFrame()
        }
    }
    func reset() {
        cancel()
        pendingIDs = []
        pending = []
        admissions = [:]
    }
    deinit { cancel() }
}
