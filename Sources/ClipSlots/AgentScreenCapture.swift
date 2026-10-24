import AppKit
import ImageIO
import Combine
import ClipSlotsKit

/// Images use the local selection/annotation editor and copy PNG pixels.
/// Recording keeps macOS's silent recording picker and bounded importer.
@MainActor
final class AgentScreenCapture: ObservableObject {
    enum Kind { case image, video }
    @Published private(set) var isCapturing = false
    @Published private(set) var needsPermission = false
    private var task: Task<Void, Never>?
    private var panels: [AgentCapturePanel] = []
    private var captureTicket: UUID?
    private var conversationObservation: AnyCancellable?
    private weak var previousWindow: NSWindow?
    #if DEBUG
    static var debugArguments: [String] = []
    static weak var debugEditor: AgentCaptureView?
    #endif

    static func recordingArguments(destination: URL) -> [String] {
        ["-i", "-v", "-x", "-U", "-Jvideo", "-V120", destination.path]
    }

    func start(_ kind: Kind, model: AgentChatModel) {
        guard !isCapturing, !model.isImportingAttachments else { return }
        if kind == .image { startImage(model: model); return }
        let conversation = model.selectedConversationID
        isCapturing = true
        task = Task { [weak self, weak model] in
            guard let self else { return }
            defer { self.isCapturing = false; self.task = nil }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-capture-\(UUID())")
            let destination = folder.appendingPathComponent("录屏.mov")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let arguments = Self.recordingArguments(destination: destination)
                #if DEBUG
                Self.debugArguments = arguments
                if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1",
                   let fixture = ProcessInfo.processInfo.environment["CLIPSLOTS_CAPTURE_FIXTURE"] {
                    let source = URL(fileURLWithPath: fixture).appendingPathComponent("fixture.mp4")
                    try FileManager.default.copyItem(at: source, to: destination)
                } else {
                    let result = await AgentProcessRunner.run(executable: "/usr/sbin/screencapture",
                        arguments: arguments, timeout: 150)
                    if result.exitCode != 0, !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw AgentOperationError("截取未完成，请检查系统屏幕录制权限。")
                    }
                }
                #else
                let result = await AgentProcessRunner.run(executable: "/usr/sbin/screencapture",
                    arguments: arguments, timeout: 150)
                if result.exitCode != 0, !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw AgentOperationError("截取未完成，请检查系统屏幕录制权限。")
                }
                #endif
                try Task.checkCancellation()
                guard let model, model.selectedConversationID == conversation,
                      FileManager.default.fileExists(atPath: destination.path) else { return }
                await model.importAttachments([destination], conversation: conversation)
            } catch is CancellationError {
                return
            } catch {
                if let model, model.selectedConversationID == conversation { model.errorText = error.localizedDescription }
            }
        }
    }

    func cancel() {
        task?.cancel()
        if !panels.isEmpty { finishImage(nil, ticket: captureTicket) }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func startImage(model: AgentChatModel) {
        let ticket = UUID()
        captureTicket = ticket
        previousWindow = NSApp.keyWindow
        needsPermission = false
        var frames: [(CGRect, CGImage)] = []
        #if DEBUG
        if Bundle.main.bundleIdentifier == "com.clipslots.app.canvas-v2174-test",
           ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1",
           let fixture = ProcessInfo.processInfo.environment["CLIPSLOTS_CAPTURE_FIXTURE"],
           let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: fixture).appendingPathComponent("fixture.png") as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let screen = NSScreen.main {
            frames = [(screen.frame, image)]
        }
        #endif
        if frames.isEmpty {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                needsPermission = true
                model.errorText = "需要屏幕录制权限。请在系统设置中允许 ClipSlots，然后重新打开应用再截图。"
                captureTicket = nil
                return
            }
            // Acquire all screens before creating any overlay window.
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let image = CGDisplayCreateImage(number.uint32Value) else { continue }
                frames.append((screen.frame, image))
            }
        }
        guard !frames.isEmpty else {
            model.errorText = "无法读取屏幕，请检查屏幕录制权限并重试。"
            captureTicket = nil
            return
        }
        isCapturing = true
        let conversation = model.selectedConversationID
        conversationObservation = model.objectWillChange.sink { [weak self, weak model] in
            DispatchQueue.main.async {
                if model?.selectedConversationID != conversation { self?.finishImage(nil, ticket: ticket) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        for (frame, image) in frames {
            let document = AgentCaptureDocument(image: image, size: frame.size)
            let panel = AgentCapturePanel(frame: frame, document: document) { [weak self, weak model] data in
                self?.finishImage(model?.selectedConversationID == conversation ? data : nil, ticket: ticket)
            }
            panels.append(panel)
            #if DEBUG
            Self.debugEditor = panel.contentView as? AgentCaptureView
            #endif
        }
        if let active = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            active.makeKeyAndOrderFront(nil); active.makeFirstResponder(active.contentView)
        }
    }

    private func finishImage(_ data: Data?, ticket: UUID?) {
        guard let ticket, captureTicket == ticket else { return }
        captureTicket = nil
        conversationObservation = nil
        let closing = panels
        panels = []
        for panel in closing { panel.orderOut(nil); panel.close() }
        isCapturing = false
        previousWindow?.makeKeyAndOrderFront(nil)
        previousWindow = nil
        NSCursor.arrow.set()
        guard let data else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

}
