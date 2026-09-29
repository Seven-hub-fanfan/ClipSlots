import Foundation

/// 槽位号可以复用，任务必须同时绑定项目、节点创建身份与本次执行标识。
public struct CanvasGenerationTicket: Equatable {
    public let token: UUID
    public let projectId: String
    public var nodeId: String
    public let createdAt: Date

    public init(projectId: String, node: CanvasNode, token: UUID = UUID()) {
        self.token = token
        self.projectId = projectId
        self.nodeId = node.id
        self.createdAt = node.createdAt
    }

    public func matches(_ node: CanvasNode, projectId: String) -> Bool {
        self.projectId == projectId && nodeId == node.id && createdAt == node.createdAt
    }
}
