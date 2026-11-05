import AppKit
import SwiftUI
import ClipSlotsKit

/// One independent window owns the draft and native editor for its entire life.
/// Full-screen transitions never detach, reattach or recreate its content.
@MainActor
final class SlotEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var active: SlotEditorWindowController?
    let model: SlotEditorModel
    private weak var parentWindow: NSWindow?
    private let saveAction: (SlotEditorModel) async throws -> Void
    private var transition = false
    private var closing = false

    static func present(slot: Int, groupID: String, store: SlotStoreObservable) {
        if let active { active.window?.makeKeyAndOrderFront(nil); return }
        do {
            let snapshot = try store.captureSlotEditor(slot: slot, groupID: groupID)
            let model = try SlotEditorModel(snapshot: snapshot)
            let controller = SlotEditorWindowController(model: model, parent: NSApp.keyWindow) { model in
                try await store.saveSlotEditorAsync(model.snapshot, body: model.body, attachments: model.attachments,
                                         markdownEdit: model.markdownEdit)
            }
            active = controller
            controller.present()
        } catch { store.transientUI.showToast(error.localizedDescription, duration: 4) }
    }

    init(model: SlotEditorModel, parent: NSWindow?, save: @escaping (SlotEditorModel) async throws -> Void) {
        self.model = model
        parentWindow = parent
        saveAction = save
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "编辑内容 · 槽位 \(model.snapshot.slot)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 580)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.contentView = NSHostingView(rootView: SlotTextEditorSheet(model: model,
            onFullScreen: { [weak self] in self?.toggleFullScreen() },
            onSave: { [weak self] in self?.save() },
            onCancel: { [weak self] in self?.cancel() })
            .ignoresSafeArea(.container, edges: .top))
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        if let parentWindow, let screen = parentWindow.screen {
            let area = screen.visibleFrame
            let x = min(max(parentWindow.frame.midX - window.frame.width / 2, area.minX),
                        max(area.minX, area.maxX - window.frame.width))
            let y = min(max(parentWindow.frame.midY - window.frame.height / 2, area.minY),
                        max(area.minY, area.maxY - window.frame.height))
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else { window.center() }
        window.makeKeyAndOrderFront(nil)
    }
    func toggleFullScreen() {
        guard !transition, let window else { return }
        model.textBridge.commit()
        AgentDraftEditor.commitFocusedDraft(sourceID: ObjectIdentifier(model))
        transition = true
        window.toggleFullScreen(nil)
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        transition = true
        model.textBridge.commit()
        AgentDraftEditor.commitFocusedDraft(sourceID: ObjectIdentifier(model))
        model.fullScreen = true
    }
    func windowDidEnterFullScreen(_ notification: Notification) { transition = false }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        transition = false; model.fullScreen = false
    }
    func windowWillExitFullScreen(_ notification: Notification) { transition = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        transition = false; model.fullScreen = false
        model.focused = false
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { transition = false }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func save() {
        guard !closing, !model.saving else { return }
        model.textBridge.commit()
        if !model.dirty { cancel(); return }
        model.saving = true
        model.textBridge.editor?.isEditable = false
        Task { @MainActor in
            do {
                try await saveAction(model)
                model.saving = false
                cancel()
            } catch {
                model.error = error as? AgentCanvasError == .conflict
                    ? "正文或附件已被其他操作更新。草稿已保留，请复制草稿后重新打开最新内容。"
                    : error.localizedDescription
                model.saving = false
                model.textBridge.editor?.isEditable = true
            }
        }
    }
    func cancel() {
        guard !closing, !model.saving else { return }
        closing = true
        model.close()
        window?.orderOut(nil)
        window?.close()
        parentWindow?.makeKeyAndOrderFront(nil)
        if Self.active === self { Self.active = nil }
    }
}
