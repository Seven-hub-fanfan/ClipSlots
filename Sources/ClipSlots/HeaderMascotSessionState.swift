import Combine
import Foundation

/// Session preference deliberately has no disk or business-model side effects.
@MainActor
final class HeaderMascotSessionState: ObservableObject {
    static let shared=HeaderMascotSessionState()
    @Published private(set) var paused=false
    func togglePause() { paused.toggle() }
}

struct MascotEarliestWake {
    private(set) var scheduledMS:Double?
    mutating func request(_ time:Double) -> Bool {
        guard time.isFinite else { return false }
        if let previous=scheduledMS, previous<=time { return false }
        scheduledMS=time; return true
    }
    mutating func consume() { scheduledMS=nil }
}
