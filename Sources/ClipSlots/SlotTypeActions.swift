import AppKit
import ClipSlotsKit
import Foundation

// MARK: - Slot Type Actions (v2.5)

enum SlotTypeActions {

    // MARK: - File Operations

    static func openFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func revealInFinder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyFilePath(_ url: URL) {
        copyString(url.path)
    }

    static func copyFileName(_ url: URL) {
        let name = url.lastPathComponent
        copyString(name.isEmpty ? url.path : name)
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - URL Operations

    static func openWebURL(_ url: URL) {
        guard isWebURL(url) else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyMarkdownLink(_ url: URL) {
        let title = url.host ?? url.absoluteString
        let safeTitle = title.replacingOccurrences(of: "]", with: "\\]")
        let markdown = "[\(safeTitle)](\(url.absoluteString))"
        copyString(markdown)
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Clipboard

    static func copyString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
