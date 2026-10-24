#if DEBUG
import AppKit
import ClipSlotsKit

@MainActor
func runAgentScreenCaptureProbe(model: AgentChatModel, host: NSView, directory: URL,
                                check: (Bool, String) -> Void) async {
    guard ProcessInfo.processInfo.environment["CLIPSLOTS_CAPTURE_FIXTURE"] != nil else { return }
    func find(_ root: NSView, _ id: String) -> AnyObject? {
        NativeAccessibilityProbe.elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
    }
    func press(_ root: NSView, _ id: String) -> Bool { find(root, id)?.accessibilityPerformPress?() == true }
    func event(_ type: NSEvent.EventType, at point: CGPoint, view: NSView, key: UInt16 = 0) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func drag(_ view: AgentCaptureView, _ start: CGPoint, _ end: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, at: start, view: view))
        view.mouseDragged(with: event(.leftMouseDragged, at: end, view: view))
        view.mouseUp(with: event(.leftMouseUp, at: end, view: view))
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(180)) }
    let pb = NSPasteboard.general
    let saved = (pb.pasteboardItems ?? []).map { source -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for type in source.types { if let data = source.data(forType: type) { item.setData(data, forType: type) } }
        return item
    }
    defer { pb.clearContents(); pb.writeObjects(saved) }
    model.draftAttachments = []
    model.draft = "截图复制不改变正文"
    let draft = model.draft
    let oldChange = pb.changeCount
    check(press(host, "agent-screen-capture"), "native scissors opens local screenshot editor")
    await settle()
    guard let view = AgentScreenCapture.debugEditor, view.window?.isVisible == true else {
        check(false, "screenshot editor is a visible native window"); return
    }
    let doc = view.document
    let start = CGPoint(x: 100, y: 100), end = CGPoint(x: 500, y: 380)
    drag(view, start, end)
    await settle()
    check(doc.selection == CGRect(x: 100, y: 100, width: 400, height: 280),
          "native mouse drag selects exact screenshot bounds")
    drag(view, CGPoint(x: 500, y: 380), CGPoint(x: 520, y: 390))
    check(doc.selection == CGRect(x: 100, y: 100, width: 420, height: 290),
          "native bottom-right handle adjusts selection without annotations")
    for (index, tool) in AgentCaptureDocument.Tool.allCases.enumerated() {
        check(press(view, "agent-capture-tool-\(tool.rawValue)"), "native toolbar selects \(tool.title)")
        await settle()
        if tool == .text {
            let p = CGPoint(x: 180, y: 240)
            view.mouseDown(with: event(.leftMouseDown, at: p, view: view))
            if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
                field.stringValue = "CAPTURE TEXT"
                // Clicking another annotation location commits the native field.
                view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 185, y: 275), view: view))
            } else { check(false, "text annotation exposes an editable native text field") }
        } else {
            let p = CGPoint(x: 120 + index * 40, y: 120 + index * 18)
            drag(view, p, CGPoint(x: p.x + 85, y: p.y + 55))
        }
    }
    check(doc.marks.count == 6 && Set(doc.marks.map(\.tool)) == Set(AgentCaptureDocument.Tool.allCases),
          "all six actual annotation paths create renderable marks")
    for index in 0..<5 {
        check(press(view, "agent-capture-color-\(index)"), "native color \(index) selectable")
        check(doc.colorIndex == index, "color selection updates actual annotation paint")
    }
    check(press(view, "agent-capture-width-4") && doc.lineWidth == 4, "native coarse stroke is selectable")
    check(press(view, "agent-capture-width-2") && doc.lineWidth == 2, "native fine stroke is selectable")
    let count = doc.marks.count
    await settle()
    check(press(view, "agent-capture-undo") && doc.marks.count == count - 1,
          "native undo removes the last completed annotation")
    // Render the recording's red rectangle through the real toolbar and mouse path.
    _ = press(view, "agent-capture-color-0")
    _ = press(view, "agent-capture-tool-rectangle")
    drag(view, CGPoint(x: 140, y: 310), CGPoint(x: 450, y: 350))
    await settle()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("agent-capture-editor.png"))
    }
    check(press(view, "agent-capture-copy"), "native primary button copies annotated screenshot")
    await settle()
    let copied = pb.data(forType: .png)
    if let copied, let bitmap = NSBitmapImageRep(data: copied) {
        try? copied.write(to: directory.appendingPathComponent("agent-capture-copied.png"))
        let sx = CGFloat(doc.image.width) / doc.size.width, sy = CGFloat(doc.image.height) / doc.size.height
        check(abs(bitmap.pixelsWide - Int(doc.selection.width * sx)) <= 2
              && abs(bitmap.pixelsHigh - Int(doc.selection.height * sy)) <= 2,
              "clipboard PNG preserves selected original display pixel dimensions")
        let x = Int(200 * sx - floor(doc.selection.minX * sx))
        let y = Int(310 * sy - floor(doc.selection.minY * sy))
        let painted = (-2...2).contains { dy in
            guard let color = bitmap.colorAt(x: x, y: min(max(0, y + dy), bitmap.pixelsHigh - 1))?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent > 0.8 && color.greenComponent < 0.35 && color.blueComponent < 0.5
        }
        check(painted, "red rectangle is flattened into copied PNG pixels at the selected position")
        check(NSImage(pasteboard: pb) != nil && pb.data(forType: .tiff) != nil,
              "copied image is readable by native canvas paste and other macOS apps")
    } else { check(false, "copy writes actual decodable PNG bytes") }
    check(pb.changeCount > oldChange && view.window?.isVisible != true
          && model.draft == draft && model.draftAttachments.isEmpty,
          "copy closes overlay changes clipboard and preserves empty Agent attachments and draft")
    try? await Task.sleep(for: .milliseconds(250))
    check(press(host, "agent-capture-menu"), "native capture chevron opens menu")
    await settle()
    if let menu = NSApp.windows.compactMap(\.contentView).first(where: { find($0, "agent-capture-record") != nil }) {
        check(press(menu, "agent-capture-record"), "native menu starts recording attachment")
    } else { check(false, "native recording menu exists") }
    for _ in 0..<100 {
        if model.draftAttachments.count == 1 && !model.isImportingAttachments { break }
        try? await Task.sleep(for: .milliseconds(30))
    }
    check(model.draftAttachments.last?.sampledFrames?.count == 3
          && model.draftAttachments.last?.textSnapshot?.contains("未读取音轨") == true,
          "recording imports actual video frames with explicit scope")
    check(AgentScreenCapture.debugArguments.contains("-v")
          && AgentScreenCapture.debugArguments.contains("-x")
          && !AgentScreenCapture.debugArguments.contains("-g")
          && !AgentScreenCapture.debugArguments.contains(where: { $0.hasPrefix("-G") }),
          "recording has no microphone capture flags")
    model.clearHistory()
    let capture = AgentScreenCapture()
    capture.start(.image, model: model)
    let previousConversation = model.selectedConversationID
    model.draft = "切换对话的捕获隔离验收"
    model.clearHistory()
    await settle()
    check(model.selectedConversationID != previousConversation && !capture.isCapturing
          && model.draftAttachments.isEmpty,
          "conversation switch cancels standalone editor and leaves new draft empty")
    let beforeCancel = pb.changeCount
    capture.start(.image, model: model)
    if let cancelled = AgentScreenCapture.debugEditor {
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: cancelled.window!.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        cancelled.keyDown(with: escape)
    } else { check(false, "cancel probe editor exists") }
    check(!capture.isCapturing && pb.changeCount == beforeCancel && model.draftAttachments.isEmpty,
          "actual Escape cancels capture without changing clipboard or attachments")
}
#endif
