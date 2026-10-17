import SwiftUI
import AppKit
import ClipSlotsKit

@MainActor
struct AgentArtifactNativeShareButton: NSViewRepresentable {
    let content: Data
    let path: String
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "共享副本", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.content = content
        context.coordinator.path = path
        context.coordinator.onStatus = onStatus
        button.isEnabled = content.count <= 64 * 1024 * 1024 && context.coordinator.copy == nil
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        // An already selected service keeps its copy until its real completion callback.
        if coordinator.selectedService == nil { coordinator.finish(nil) }
        button.target = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private static var active: [UUID: Coordinator] = [:]
        private let id = UUID()
        var content = Data()
        var path = ""
        var onStatus: (String) -> Void = { _ in }
        var copy: AgentArtifactLocalCopy?
        var selectedService: NSSharingService?
        private var picker: NSSharingServicePicker?
        private var completion: (String) -> Void = { _ in }
        private weak var button: NSButton?

        @objc func share(_ sender: NSButton) {
            guard copy == nil else { return }
            completion = onStatus
            do {
                copy = try AgentArtifactLocalCopy(content: content, path: path)
                guard let copy else { return }
                button = sender; sender.isEnabled = false
                let picker = NSSharingServicePicker(items: [copy.fileURL])
                picker.delegate = self
                self.picker = picker
                Self.active[id] = self
                picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            } catch { completion("共享副本准备失败：\(error.localizedDescription)") }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            selectedService = service
            if service == nil { finish("已取消共享。") }
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                  delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { self }
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish("已通过\(sharingService.title)共享副本。")
        }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            finish("共享失败：\(error.localizedDescription)")
        }
        func finish(_ message: String?) {
            try? copy?.remove()
            copy = nil; picker = nil; selectedService = nil
            button?.isEnabled = true
            Self.active.removeValue(forKey: id)
            if let message { completion(message) }
            completion = { _ in }
        }
    }
}
