import Foundation
import ClipSlotsKit

func runAgentArtifactGatewayPayloadTests(_ t: TestRunner) {
    do {
        let scope = try AgentArtifactScope(projectID: "project", canvasID: "canvas")
        let value: JSONValue = ["artifactID": "artifact", "path": "preview.html",
                                "revision": 1, "content": "完整🙂", "mimeType": "text/html"]
        let update = try AgentArtifactGatewayPayload.update(value, scope: scope)
        t.equal(update.content, Data("完整🙂".utf8), "ARTIFACT gateway Unicode content stays complete")
        t.equal(update.key.scope, scope, "ARTIFACT namespace comes from the host binding")
        var invalid = value.objectValue ?? [:]
        invalid["projectID"] = "foreign"
        t.expectThrows("ARTIFACT foreign claimed project is rejected") {
            _ = try AgentArtifactGatewayPayload.update(.object(invalid), scope: scope)
        }
        invalid["projectID"] = 3
        t.expectThrows("ARTIFACT malformed project field cannot become absent") {
            _ = try AgentArtifactGatewayPayload.update(.object(invalid), scope: scope)
        }
        invalid.removeValue(forKey: "projectID")
        invalid["content"] = [:]
        t.expectThrows("ARTIFACT malformed content cannot appear as a missing download") {
            _ = try AgentArtifactGatewayPayload.update(.object(invalid), scope: scope)
        }
        invalid["content"] = "complete"
        invalid["contentBase64"] = .string(Data("binary".utf8).base64EncodedString())
        t.expectThrows("ARTIFACT two content formats are rejected") {
            _ = try AgentArtifactGatewayPayload.update(.object(invalid), scope: scope)
        }
    } catch { t.check(false, "ARTIFACT gateway payload setup: \(error)") }
}
