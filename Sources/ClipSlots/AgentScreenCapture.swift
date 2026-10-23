import AppKit
import ImageIO
import ClipSlotsKit

/// macOS owns the region/window picker and recording toolbar. Captures are
/// silent and enter the same bounded attachment importer as uploaded files.
@MainActor
final class AgentScreenCapture: ObservableObject {
    enum Kind { case image, video }
    @Published private(set) var isCapturing = false
    private var task: Task<Void, Never>?
    #if DEBUG
    static var debugArguments: [String] = []
    #endif

    static func arguments(kind: Kind, destination: URL) -> [String] {
        switch kind {
        case .image: return ["-i", "-x", "-U", "-Jselection", "-t", "png", destination.path]
        case .video: return ["-i", "-v", "-x", "-U", "-Jvideo", "-V120", destination.path]
        }
    }

    func start(_ kind: Kind, model: AgentChatModel) {
        guard !isCapturing, !model.isImportingAttachments else { return }
        let conversation = model.selectedConversationID
        isCapturing = true
        task = Task { [weak self, weak model] in
            guard let self else { return }
            defer { self.isCapturing = false; self.task = nil }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-capture-\(UUID())")
            let destination = folder.appendingPathComponent(kind == .image ? "截图.png" : "录屏.mov")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let arguments = Self.arguments(kind: kind, destination: destination)
                #if DEBUG
                Self.debugArguments = arguments
                if ProcessInfo.processInfo.environment["CLIPSLOTS_CANVAS_REGRESSION"] == "1",
                   let fixture = ProcessInfo.processInfo.environment["CLIPSLOTS_CAPTURE_FIXTURE"] {
                    let source = URL(fileURLWithPath: fixture).appendingPathComponent(
                        kind == .image ? "fixture.png" : "fixture.mp4")
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
                let attachment: URL
                if kind == .image {
                    attachment = try await Task.detached(priority: .userInitiated) {
                        try Self.optimizedScreenshot(destination)
                    }.value
                } else { attachment = destination }
                try Task.checkCancellation()
                await model.importAttachments([attachment], conversation: conversation)
            } catch is CancellationError {
                return
            } catch {
                if let model, model.selectedConversationID == conversation { model.errorText = error.localizedDescription }
            }
        }
    }

    func cancel() { task?.cancel() }

    nonisolated private static func optimizedScreenshot(_ sourceURL: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw AgentAttachmentImport.ImportError.unsupported }
        let bitmap = NSBitmapImageRep(cgImage: image)
        for quality in [0.8, 0.6, 0.4, 0.2] {
            guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                  data.count <= AgentAttachmentImport.maxImageBytes else { continue }
            let output = sourceURL.deletingPathExtension().appendingPathExtension("jpg")
            try data.write(to: output, options: .atomic)
            return output
        }
        throw AgentAttachmentImport.ImportError.tooLarge
    }
}
