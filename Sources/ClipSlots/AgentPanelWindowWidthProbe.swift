import SwiftUI
import AppKit

/// Observe the host, not the panel's own proposal, so resizing has no layout
/// feedback loop. The probe publishes only actual window width changes.
struct AgentPanelWindowWidthProbe: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    func makeNSView(context: Context) -> Probe { Probe(onChange: onChange) }
    func updateNSView(_ view: Probe, context: Context) { view.onChange = onChange }
    final class Probe: NSView {
        var onChange: (CGFloat) -> Void
        private var observer: NSObjectProtocol?
        private var lastWidth: CGFloat?
        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                               object: window, queue: .main) { [weak self] _ in
                self?.publish()
            }
            publish()
        }
        private func publish() {
            guard let width = window?.contentView?.bounds.width, width != lastWidth else { return }
            lastWidth = width
            DispatchQueue.main.async { [weak self] in self?.onChange(width) }
        }
    }
}
