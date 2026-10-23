import SwiftUI

/// Preserve every measurement for native hit testing, while coalescing the
/// workspace notification during a passive batch entrance. Any input ends the
/// batch immediately, so moving ports retain their normal geometry updates.
final class CanvasControlRegionBuffer {
    var latest: [String: CGRect]?
    private var finish: DispatchWorkItem?
    private var publish: (([String: CGRect]) -> Void)?

    func begin(duration: Double, publish: @escaping ([String: CGRect]) -> Void) {
        end()
        self.publish = publish
        let work = DispatchWorkItem { [weak self] in self?.end() }
        finish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func receive(_ regions: [String: CGRect], publish: ([String: CGRect]) -> Void) {
        latest = regions
        if finish == nil { publish(regions) }
    }

    func end() {
        finish?.cancel()
        finish = nil
        let action = publish
        publish = nil
        if let latest { action?(latest) }
    }

    deinit { finish?.cancel() }
}
