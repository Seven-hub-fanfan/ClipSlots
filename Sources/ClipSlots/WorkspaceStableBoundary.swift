import SwiftUI

/// An equality boundary for chrome whose appearance does not depend on pan.
/// Its binding locations and local control state remain owned by SwiftUI.
struct WorkspaceStableBoundary: View, Equatable {
    struct Key: Equatable {
        let zoom: CGFloat
        let map: Bool
        let edges: Bool
        let grid: Bool
        let hovered: String?
        let tooltip: String?
        let helpOpen: Bool
        let saveStatus: String
        let saveSource: ObjectIdentifier?
        let project: String
    }
    let key: Key
    private let content: () -> AnyView
    init<Content: View>(key: Key, @ViewBuilder content: @escaping () -> Content) {
        self.key = key; self.content = { AnyView(content()) }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View { content() }
}
