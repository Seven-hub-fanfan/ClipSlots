#if DEBUG
import Foundation
import ClipSlotsKit

enum ManagedImagePathRegression {
    @MainActor
    static func run(root: URL, png: Data, check: (Bool, String) -> Void) async throws {
        let directory = root.appendingPathComponent("managed-image-paths")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = directory.appendingPathComponent("stored.bin")
        let legacy = directory.appendingPathComponent("removed-original.png")
        let external = directory.appendingPathComponent("external.png")
        try png.write(to: stored, options: .atomic)
        try png.write(to: external, options: .atomic)
        for kind in [SlotContent.AttachmentType.image, .file] {
            let attachment = SlotContent.SlotAttachment(name: "source.png", type: kind,
                path: legacy.path, storagePath: stored.path)
            let captured = try await SlotEditorAI.captureAttachments([attachment])
            check(captured.count == 1 && captured[0].imageSnapshot == png,
                  "\(kind.rawValue): stored image survives missing original path")
            check(captured[0].imageMIMEType == "image/png" &&
                  captured[0].sha256 == AgentDirectoryAccess.digest(png),
                  "\(kind.rawValue): stored bin keeps original PNG format and digest")
        }
        var authoritative = SlotContent.SlotAttachment(name: "source.png", type: .image,
            path: external.path, storagePath: stored.path)
        try Data("obsolete original".utf8).write(to: external, options: .atomic)
        let storedCapture = try await SlotEditorAI.captureAttachments([authoritative])
        check(storedCapture[0].imageSnapshot == png, "managed image bytes take precedence over obsolete source")
        try png.write(to: external, options: .atomic)
        authoritative.data = png
        authoritative.storagePath = legacy.path
        let inline = try await SlotEditorAI.captureAttachments([authoritative])
        check(inline[0].imageSnapshot == png, "unsaved inline image remains first source")

        let pathOnly = SlotContent.SlotAttachment(name: "source.png", type: .image, path: external.path)
        let pathCapture = try await SlotEditorAI.captureAttachments([pathOnly])
        check(pathCapture[0].imageSnapshot == png, "authorized path-only image remains readable")
        let unavailableStorage = SlotContent.SlotAttachment(name: "source.png", type: .image,
            path: external.path, storagePath: legacy.path)
        let fallback = try await SlotEditorAI.captureAttachments([unavailableStorage])
        check(fallback[0].imageSnapshot == png, "missing stored file falls back to recorded authorized source")

        let malformed = directory.appendingPathComponent("malformed.bin")
        try Data("not an image".utf8).write(to: malformed, options: .atomic)
        do {
            _ = try await SlotEditorAI.captureAttachments([.init(name: "source.png", type: .image,
                path: external.path, storagePath: malformed.path)])
            check(false, "invalid managed image rejected without substituting original")
        } catch AgentAttachmentImport.ImportError.unsupported {
            check(true, "invalid managed image rejected without substituting original")
        }
        let oversized = directory.appendingPathComponent("oversized.bin")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(AgentAttachmentImport.maxImageBytes + 1))
        try handle.close()
        do {
            _ = try await SlotEditorAI.captureAttachments([.init(name: "source.png", type: .image,
                path: external.path, storagePath: oversized.path)])
            check(false, "oversized managed image rejected before reading and without fallback")
        } catch AgentAttachmentImport.ImportError.tooLarge {
            check(true, "oversized managed image rejected before reading and without fallback")
        }
        let symlink = directory.appendingPathComponent("symlink.bin")
        if FileManager.default.fileExists(atPath: symlink.path) {
            try FileManager.default.removeItem(at: symlink)
        }
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: stored)
        do {
            _ = try await SlotEditorAI.captureAttachments([.init(name: "source.png", type: .image,
                storagePath: symlink.path)])
            check(false, "stored symlink remains rejected")
        } catch AgentAttachmentImport.ImportError.unavailable {
            check(true, "stored symlink remains rejected")
        }

        let fixture = root.appendingPathComponent("managed-image-fixture")
        let manifestURL = fixture.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let metadata = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: manifestURL))
            let file = fixture.appendingPathComponent("source.bin")
            let original = try Data(contentsOf: file)
            check(AgentDirectoryAccess.digest(original) == metadata.sha256, "reported failing PNG fixture hash verified")
            let attachment = SlotContent.SlotAttachment(name: metadata.name, type: .image,
                path: fixture.appendingPathComponent("removed-body-files/source.png").path, storagePath: file.path)
            let captured = try await SlotEditorAI.captureAttachments([attachment])
            check(captured.count == 1 && captured[0].imageSnapshot == original &&
                  captured[0].imageMIMEType == "image/png", "reported failing attachment now captures original PNG")
            let profile = try AgentAPIProvider.deepseek.profile(baseURL: AgentAPIProvider.deepseek.baseURL,
                                                              model: "deepseek-reasoner")
            let http = OnboardingWireFixture(contract: profile.contract)
            let service = AgentService(transport: AgentProviderTransport(profile: profile, http: http, streaming: http),
                                       secretStore: AgentInMemorySecretStore(key: "fixture-secret"))
            let rewritten = try await SlotEditorAI.rewrite(text: "", instruction: "反推提示词填入", html: false,
                                                          attachments: [attachment], service: service)
            let requests = await http.requests
            let body = try JSONDecoder().decode(JSONValue.self, from: requests[0].httpBody!)
            let parts = body["messages"]?.arrayValue?.last?["content"]?.arrayValue
            let sent = parts?.last?["image_url"]?["url"]?.stringValue
            check(rewritten == "完成🙂" && requests.count == 1 &&
                  body["model"]?.stringValue == "deepseek-reasoner", "reported editor request reaches model adapter")
            check(sent == "data:image/png;base64," + original.base64EncodedString(),
                  "reported editor request carries entire original PNG without thumbnail substitution")
        }
    }

    private struct Fixture: Decodable {
        let name: String
        let sha256: String
    }
}
#endif
