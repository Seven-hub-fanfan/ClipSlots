import Foundation

public struct AgentCanvasReadbackSnapshot: Codable, @unchecked Sendable {
    public let projectID: String
    public let nodes: [CanvasNode]
    public let edges: [CanvasEdge]
    public init(projectID: String, nodes: [CanvasNode] = [], edges: [CanvasEdge] = []) {
        self.projectID = projectID; self.nodes = nodes; self.edges = edges
    }
}

/// The source must be explicitly configured. No guessed cloud endpoints,
/// rendered-content cache or missing-file-as-empty fallback is permitted.
public protocol AgentCanvasSnapshotReading: Sendable {
    func nodes(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot
    func edges(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot
    func fullSnapshot(projectID: String) async throws -> AgentCanvasReadbackSnapshot
    func snapshot(projectID: String, nodeIDs: [String], edgeIDs: [String]) async throws -> AgentCanvasReadbackSnapshot
}

public enum AgentCanvasSaveOutcome: Equatable, Sendable { case saved, deferred }
public protocol AgentCanvasSavingSnapshotReading: AgentCanvasSnapshotReading {
    /// Flush the explicitly configured authority. A deferred or failed save
    /// never permits the full snapshot query.
    func saveBeforeSnapshot(projectID: String) async throws -> AgentCanvasSaveOutcome
}

public extension AgentCanvasSnapshotReading {
    func snapshot(projectID: String, nodeIDs: [String], edgeIDs: [String]) async throws -> AgentCanvasReadbackSnapshot {
        async let nodeRead = nodes(projectID: projectID, ids: nodeIDs)
        async let edgeRead = edges(projectID: projectID, ids: edgeIDs)
        let (nodes, edges) = try await (nodeRead, edgeRead)
        guard nodes.projectID == projectID, edges.projectID == projectID else {
            throw AgentGatewayError.originMismatch
        }
        return .init(projectID: projectID, nodes: nodes.nodes, edges: edges.edges)
    }
}

/// Shared by a host across source/session replacement. Cancellation of the
/// caller is not proof that a reader's save or query has actually exited.
public actor AgentCanvasReadbackSerialGate {
    public static let shared = AgentCanvasReadbackSerialGate()
    private var owners: [String: UUID] = [:]
    private var waiting: [String: [(UUID, CheckedContinuation<Void, Error>)]] = [:]
    public init() {}
    public var waitingCount: Int { waiting.values.reduce(0) { $0 + $1.count } }
    func acquire(_ project: String) async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if owners[project] == nil {
                    owners[project] = id
                    continuation.resume()
                } else if waitingCount < 128 {
                    waiting[project, default: []].append((id, continuation))
                } else {
                    continuation.resume(throwing: AgentGatewayError.busy)
                }
            }
        } onCancel: { Task { await self.cancel(project, id: id) } }
        return id
    }
    private func cancel(_ project: String, id: UUID) {
        guard let index = waiting[project]?.firstIndex(where: { $0.0 == id }) else { return }
        let pending = waiting[project]!.remove(at: index)
        if waiting[project]?.isEmpty == true { waiting.removeValue(forKey: project) }
        pending.1.resume(throwing: CancellationError())
    }
    func release(_ project: String, id: UUID) {
        guard owners[project] == id else { return }
        owners.removeValue(forKey: project)
        guard var queue = waiting[project], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        if queue.isEmpty { waiting.removeValue(forKey: project) } else { waiting[project] = queue }
        owners[project] = next.0
        next.1.resume()
    }
}

public actor AgentCanvasReadbackBatcher {
    private struct Pending {
        let request: AgentCanvasReadbackRequest
        let continuation: CheckedContinuation<AgentCanvasReadbackSnapshot, Error>
        let order: UInt64
        let beforeRead: @Sendable () async throws -> Void
    }
    private let reader: any AgentCanvasSnapshotReading
    private let serialGate: AgentCanvasReadbackSerialGate
    private let sleep: @Sendable () async throws -> Void
    private var queued: [UUID: Pending] = [:]
    private var active: [UUID: Pending] = [:]
    private var timer: Task<Void, Never>?
    private var timerID: UUID?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var workerRequests: [UUID: Set<UUID>] = [:]
    private var projectWorkers: [String: UUID] = [:]
    private var ready: [String: [[UUID]]] = [:]
    private var order: UInt64 = 0

    public init(reader: any AgentCanvasSnapshotReading,
                serialGate: AgentCanvasReadbackSerialGate = AgentCanvasReadbackSerialGate(),
                sleep: @escaping @Sendable () async throws -> Void = {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }) {
        self.reader = reader; self.serialGate = serialGate; self.sleep = sleep
    }
    public var pendingCount: Int { queued.count + active.count }

    public func read(_ request: AgentCanvasReadbackRequest,
                     beforeRead: @escaping @Sendable () async throws -> Void = {}) async throws -> AgentCanvasReadbackSnapshot {
        try request.validate()
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, queued.count + active.count < 128 else {
                    continuation.resume(throwing: Task.isCancelled ? CancellationError() : AgentGatewayError.busy)
                    return
                }
                order += 1
                let pending = Pending(request: request, continuation: continuation, order: order, beforeRead: beforeRead)
                if request.isFullSnapshot {
                    // Earlier ID notices must reach the reader before a full
                    // save/query. Later cohorts remain behind this operation.
                    if let generation = timerID { timer?.cancel(); flush(generation) }
                    active[id] = pending
                    ready[request.projectID, default: []].append([id])
                    startNext(request.projectID)
                    return
                }
                queued[id] = pending
                if timer == nil {
                    let generation = UUID()
                    timerID = generation
                    timer = Task { [weak self, sleep] in
                        do { try await sleep(); try Task.checkCancellation(); await self?.flush(generation) }
                        catch { await self?.cancelQueued(generation) }
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        (queued.removeValue(forKey: id) ?? active.removeValue(forKey: id))?.continuation.resume(throwing: CancellationError())
        for (workerID, ids) in workerRequests where ids.contains(id) && ids.allSatisfy({ active[$0] == nil }) {
            workers[workerID]?.cancel()
        }
    }
    private func cancelQueued(_ generation: UUID? = nil) {
        if let generation, timerID != generation { return }
        timer = nil; timerID = nil
        let pending = queued; queued.removeAll()
        pending.values.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }
    public func cancelAll() {
        timer?.cancel(); cancelQueued()
        let pending = active; active.removeAll()
        pending.values.forEach { $0.continuation.resume(throwing: CancellationError()) }
        ready.removeAll()
        // Keep the project lease until the reader actually exits, including a
        // reader which is slow to observe cancellation.
        workers.values.forEach { $0.cancel() }
    }
    private func flush(_ generation: UUID) {
        guard timerID == generation else { return }
        timer = nil; timerID = nil
        let batch = queued; queued.removeAll()
        for (project, entries) in Dictionary(grouping: batch, by: { $0.value.request.projectID }) {
            for (id, pending) in entries { active[id] = pending }
            var ids: [UUID] = [], nodes = Set<String>(), edges = Set<String>()
            for (id, pending) in entries.sorted(by: { $0.value.order < $1.value.order }) {
                let nextNodes = nodes.union(pending.request.nodeIDs), nextEdges = edges.union(pending.request.edgeIDs)
                if !ids.isEmpty && (nextNodes.count > 1000 || nextEdges.count > 2000) {
                    ready[project, default: []].append(ids)
                    ids = []; nodes = []; edges = []
                }
                ids.append(id); nodes.formUnion(pending.request.nodeIDs); edges.formUnion(pending.request.edgeIDs)
            }
            if !ids.isEmpty { ready[project, default: []].append(ids) }
            startNext(project)
        }
    }
    private func startNext(_ project: String) {
        guard projectWorkers[project] == nil else { return }
        while var batches = ready[project], !batches.isEmpty {
            let ids = batches.removeFirst().filter { active[$0] != nil }
            if batches.isEmpty { ready.removeValue(forKey: project) } else { ready[project] = batches }
            guard !ids.isEmpty else { continue }
            let requests = ids.compactMap { active[$0]?.request }
            let beforeRead = ids.compactMap { active[$0]?.beforeRead }
            let workerID = UUID()
            projectWorkers[project] = workerID
            let reader = self.reader, serialGate = self.serialGate
            workerRequests[workerID] = Set(ids)
            workers[workerID] = Task { [weak self] in
                let result: Result<AgentCanvasReadbackSnapshot, Error>
                var lease: UUID?
                do {
                    lease = try await serialGate.acquire(project)
                    if requests.contains(where: \.isFullSnapshot) {
                        guard requests.count == 1, let saveReader = reader as? any AgentCanvasSavingSnapshotReading else {
                            throw AgentCanvasError.unavailable
                        }
                        try Task.checkCancellation()
                        try await beforeRead[0]()
                        try Task.checkCancellation()
                        guard try await saveReader.saveBeforeSnapshot(projectID: project) == .saved else {
                            throw AgentCanvasError.unavailable
                        }
                        try Task.checkCancellation()
                        let snapshot = try await saveReader.fullSnapshot(projectID: project)
                        try Task.checkCancellation()
                        guard snapshot.projectID == project else { throw AgentGatewayError.originMismatch }
                        result = .success(snapshot)
                    } else {
                    let nodes = Set(requests.flatMap(\.nodeIDs)), edges = Set(requests.flatMap(\.edgeIDs))
                    guard nodes.count <= 1000, edges.count <= 2000 else { throw AgentGatewayError.requestTooLarge }
                    try Task.checkCancellation()
                    let snapshot = try await reader.snapshot(projectID: project,
                        nodeIDs: nodes.sorted(), edgeIDs: edges.sorted())
                    try Task.checkCancellation()
                    guard snapshot.projectID == project else {
                        throw AgentGatewayError.originMismatch
                    }
                    var returnedNodes = snapshot.nodes.filter { nodes.contains($0.id) }
                    var returnedEdges = snapshot.edges.filter { edges.contains($0.id) }
                    let missingNodes = nodes.subtracting(returnedNodes.map(\.id))
                    let missingEdges = edges.subtracting(returnedEdges.map(\.id))
                    if (!missingNodes.isEmpty || !missingEdges.isEmpty) && requests.contains(where: \.allowsFallback) {
                        let full = try await reader.fullSnapshot(projectID: project)
                        try Task.checkCancellation()
                        guard full.projectID == project else { throw AgentGatewayError.originMismatch }
                        returnedNodes += full.nodes.filter { missingNodes.contains($0.id) }
                        returnedEdges += full.edges.filter { missingEdges.contains($0.id) }
                    }
                    guard Set(returnedNodes.map(\.id)).count == returnedNodes.count,
                          Set(returnedEdges.map(\.id)).count == returnedEdges.count else {
                        throw AgentGatewayError.malformedPayload
                    }
                    result = .success(.init(projectID: project, nodes: returnedNodes, edges: returnedEdges))
                    }
                } catch { result = .failure(error) }
                if let lease { await serialGate.release(project, id: lease) }
                await self?.complete(project: project, workerID: workerID, ids: ids, result: result)
            }
            return
        }
    }
    private func complete(project: String, workerID: UUID, ids: [UUID], result: Result<AgentCanvasReadbackSnapshot, Error>) {
        workers.removeValue(forKey: workerID)
        workerRequests.removeValue(forKey: workerID)
        for id in ids {
            guard let pending = active.removeValue(forKey: id) else { continue }
            pending.continuation.resume(with: result.flatMap { snapshot in
                if pending.request.isFullSnapshot { return .success(snapshot) }
                let nodes = Set(pending.request.nodeIDs), edges = Set(pending.request.edgeIDs)
                let clipped = AgentCanvasReadbackSnapshot(projectID: snapshot.projectID,
                    nodes: snapshot.nodes.filter { nodes.contains($0.id) },
                    edges: snapshot.edges.filter { edges.contains($0.id) })
                guard Set(clipped.nodes.map(\.id)) == nodes, Set(clipped.edges.map(\.id)) == edges else {
                    return .failure(AgentGatewayError.malformedPayload)
                }
                return .success(clipped)
            })
        }
        if projectWorkers[project] == workerID { projectWorkers.removeValue(forKey: project) }
        startNext(project)
    }
}

/// Explicit native source for hosts whose authority is a separate canvas
/// storage. It reads disk without populating or trusting a display cache.
public struct CanvasStorageReadbackSource: AgentCanvasSnapshotReading, @unchecked Sendable {
    private let storage: CanvasStorage
    public init(storage: CanvasStorage) { self.storage = storage }
    public func fullSnapshot(projectID: String) async throws -> AgentCanvasReadbackSnapshot {
        let task = Task.detached { try storage.readbackSnapshot(projectId: projectID) }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { task.cancel() }
    }
    public func nodes(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        let full = try await fullSnapshot(projectID: projectID), selected = Set(ids)
        return .init(projectID: projectID, nodes: full.nodes.filter { selected.contains($0.id) })
    }
    public func edges(projectID: String, ids: [String]) async throws -> AgentCanvasReadbackSnapshot {
        let full = try await fullSnapshot(projectID: projectID), selected = Set(ids)
        return .init(projectID: projectID, edges: full.edges.filter { selected.contains($0.id) })
    }
    public func snapshot(projectID: String, nodeIDs: [String], edgeIDs: [String]) async throws -> AgentCanvasReadbackSnapshot {
        let full = try await fullSnapshot(projectID: projectID)
        let nodes = Set(nodeIDs), edges = Set(edgeIDs)
        return .init(projectID: projectID, nodes: full.nodes.filter { nodes.contains($0.id) },
                     edges: full.edges.filter { edges.contains($0.id) })
    }
}

public enum AgentCanvasReadbackSync {
    public struct Plan {
        public let document: CanvasDocument
        public let preservedNodeIDs: [String]
        public let deletedNodeIDs: [String]
        public let preservedEdgeIDs: [String]
        public let changedNodeIDs: [String]
        public let changedEdgeIDs: [String]
    }

    public static func plan(request: AgentCanvasReadbackRequest, snapshot: AgentCanvasReadbackSnapshot,
                            before: CanvasDocument, current: CanvasDocument,
                            activeProject: String, conversation: String, run: String,
                            locallyChangedNodeIDs: Set<String> = [], locallyChangedEdgeIDs: Set<String> = [],
                            locallyDeletedNodeIDs: Set<String> = []) throws -> Plan {
        try request.validate()
        guard request.projectID == activeProject, snapshot.projectID == activeProject,
              request.conversationID == conversation, request.runID == run else {
            throw AgentGatewayError.originMismatch
        }
        let expectedNodes = Set(request.nodeIDs), expectedEdges = Set(request.edgeIDs)
        guard request.isFullSnapshot || (Set(snapshot.nodes.map(\.id)) == expectedNodes
              && Set(snapshot.edges.map(\.id)) == expectedEdges
              && snapshot.nodes.count == expectedNodes.count && snapshot.edges.count == expectedEdges.count),
              Set(snapshot.nodes.map(\.id)).count == snapshot.nodes.count,
              Set(snapshot.edges.map(\.id)).count == snapshot.edges.count,
              Set(before.nodes.map(\.id)).count == before.nodes.count,
              Set(current.nodes.map(\.id)).count == current.nodes.count,
              Set(before.edges.map(\.id)).count == before.edges.count,
              Set(current.edges.map(\.id)).count == current.edges.count else {
            throw AgentGatewayError.malformedPayload
        }
        let baseNodes = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
        let baseEdges = Dictionary(uniqueKeysWithValues: before.edges.map { ($0.id, $0) })
        var liveNodes = Dictionary(uniqueKeysWithValues: current.nodes.map { ($0.id, $0) })
        var liveEdges = Dictionary(uniqueKeysWithValues: current.edges.map { ($0.id, $0) })
        var preserved: [String] = [], deleted: [String] = [], preservedEdges: [String] = []
        var changed: [String] = [], changedEdges: [String] = []
        for node in snapshot.nodes {
            guard CanvasGroupHierarchy.validWorldFrame(node.frame), !node.groupId.isEmpty,
                  !node.pageId.isEmpty, node.slot >= 1,
                  node.slot <= (SpecialSlotStorage.isReservedGroupId(node.groupId) ? SpecialSlotStorage.unfiledCapacity : 10),
                  node.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw AgentGatewayError.malformedPayload
            }
            if locallyChangedNodeIDs.contains(node.id) || locallyDeletedNodeIDs.contains(node.id) {
                if liveNodes[node.id] == nil { deleted.append(node.id) } else { preserved.append(node.id) }
                continue
            }
            if let base = baseNodes[node.id] {
                guard let live = liveNodes[node.id] else { deleted.append(node.id); continue }
                guard live == base, node.createdAt == base.createdAt,
                      node.groupId == base.groupId, node.slot == base.slot, node.pageId == base.pageId else {
                    preserved.append(node.id); continue
                }
            } else if let live = liveNodes[node.id], live != node {
                preserved.append(node.id); continue
            }
            if liveNodes[node.id] != node { changed.append(node.id); liveNodes[node.id] = node }
        }
        let deletedSet = Set(before.nodes.map(\.id)).subtracting(current.nodes.map(\.id)).union(locallyDeletedNodeIDs)
        for edge in snapshot.edges {
            if locallyChangedEdgeIDs.contains(edge.id) {
                preservedEdges.append(edge.id); continue
            }
            if let base = baseEdges[edge.id] {
                guard let live = liveEdges[edge.id] else { preservedEdges.append(edge.id); continue }
                guard live == base else { preservedEdges.append(edge.id); continue }
            } else if let live = liveEdges[edge.id], live != edge {
                preservedEdges.append(edge.id); continue
            }
            if deletedSet.contains(edge.fromNodeId) || deletedSet.contains(edge.toNodeId) {
                preservedEdges.append(edge.id); continue
            }
            guard liveNodes[edge.fromNodeId] != nil, liveNodes[edge.toNodeId] != nil else {
                if request.isFullSnapshot { preservedEdges.append(edge.id); continue }
                throw AgentGatewayError.malformedPayload
            }
            if liveEdges[edge.id] != edge { changedEdges.append(edge.id); liveEdges[edge.id] = edge }
        }
        var next = current
        // Retain stable order and append new entities in deterministic ID order.
        next.nodes = current.nodes.compactMap { liveNodes.removeValue(forKey: $0.id) }
            + liveNodes.values.sorted { $0.id < $1.id }
        next.edges = current.edges.compactMap { liveEdges.removeValue(forKey: $0.id) }
            + liveEdges.values.sorted { $0.id < $1.id }
        let alive = Set(next.nodes.map(\.id))
        guard CanvasEdgeGraph.normalized(next.edges, nodeIds: alive, preservingImageCycles: next.nodes) == next.edges else {
            throw AgentGatewayError.malformedPayload
        }
        try CanvasGroupHierarchy.validate(next.groups, nodeIDs: alive)
        return .init(document: next, preservedNodeIDs: preserved.sorted(), deletedNodeIDs: deleted.sorted(),
                     preservedEdgeIDs: preservedEdges.sorted(), changedNodeIDs: changed.sorted(),
                     changedEdgeIDs: changedEdges.sorted())
    }
}
