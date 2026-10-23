import SwiftUI

/// A selected group introduces its toolbar at the same time as all its nodes.
/// Defer that existing toolbar until the first native node surfaces can mount.
final class CanvasGroupMountAdmission {
    private(set) var pendingIDs = Set<String>()
    private var admissions: [String: CanvasNodeAdmission] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func admission(for id: String?) -> CanvasNodeAdmission {
        guard let id else { return .immediate }
        return admissions["batch"] ?? admissions[id] ?? .immediate
    }

    func prepare(_ id: String) {
        tasks[id]?.cancel()
        admissions[id] = CanvasNodeAdmission(ready: false, label: "group-toolbar:\(id)")
        pendingIDs.insert(id)
    }

    func finish(_ id: String) {
        tasks[id] = Task { @MainActor [weak self] in
            for _ in 0..<3 { await CanvasDisplayClock.shared.nextFrame() }
            guard !Task.isCancelled, let self else { return }
            self.admissions[id]?.ready = true
            self.pendingIDs.remove(id)
            self.tasks[id] = nil
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        admissions[id] = nil
        pendingIDs.remove(id)
    }

    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        admissions = [:]
        pendingIDs = []
    }
    deinit { tasks.values.forEach { $0.cancel() } }
}
