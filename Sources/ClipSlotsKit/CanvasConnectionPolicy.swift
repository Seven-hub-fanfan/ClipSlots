import Foundation

/// Session policy is separate from graph topology. A remote collaboration
/// adapter can supply locks; the local application does not manufacture them.
public struct CanvasConnectionPolicy: Equatable {
    public var nodesConnectable: Bool
    public var readOnly: Bool
    public var lockedNodeIDs: Set<String>
    public init(nodesConnectable: Bool = true, readOnly: Bool = false,
                lockedNodeIDs: Set<String> = []) {
        self.nodesConnectable = nodesConnectable
        self.readOnly = readOnly
        self.lockedNodeIDs = lockedNodeIDs
    }
    public func canConnect(nodeID: String) -> Bool {
        nodesConnectable && !readOnly && !lockedNodeIDs.contains(nodeID)
    }
    public func canConnect(from: String, to: String) -> Bool {
        canConnect(nodeID: from) && canConnect(nodeID: to)
    }
}
