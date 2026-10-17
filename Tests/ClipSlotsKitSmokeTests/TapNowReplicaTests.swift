import Foundation
import CoreGraphics
import ClipSlotsKit

func runTapNowReplicaTests(_ t: TestRunner) {
    let data = Data("\u{FEFF}: heartbeat\r\nid: opaque/z9\r\nevent: content\r\nretry: 5000\r\ndata: 你好🙂\r\ndata: 第二行\r\n\r\nid:\r\n\r\ndata: 尾帧\r\r".utf8)
    let expected = ["你好🙂\n第二行", "尾帧"]
    var allSplits = true
    for split in 0...data.count {
        do {
            var f = AgentSSEFramer()
            let frames = try f.feed(Data(data.prefix(split))) + f.feed(Data(data.dropFirst(split))) + f.finish()
            allSplits = allSplits && frames.map(\.data) == expected && frames.first?.event == "content"
                && frames.first?.id == "opaque/z9" && frames.last?.id == "" && f.retryMilliseconds == 5000
        } catch { allSplits = false }
    }
    t.check(allSplits, "REA SSE: every byte split preserves Unicode, BOM, CRLF, multiline data and opaque IDs")
    do {
        var f = AgentSSEFramer()
        var frames: [AgentSSEFrame] = []
        for byte in data { frames += try f.feed(Data([byte])) }
        frames += try f.finish()
        t.equal(frames.map(\.data), expected, "REA SSE: single-byte delivery matches complete delivery")
        var incomplete = AgentSSEFramer()
        let pending = try incomplete.feed(Data("data: unfinished".utf8)) + incomplete.finish()
        t.check(pending.isEmpty, "REA SSE: EOF never commits an unterminated gateway event")
        var invalidID = AgentSSEFramer()
        let output = try invalidID.feed(Data("id: valid\n\nid: bad\0id\ndata: ok\n\n".utf8))
        t.equal(output.first?.id, "valid", "REA SSE: NUL-containing IDs do not replace the resume cursor")
        var invalid = AgentSSEFramer()
        t.expectThrows("REA SSE: invalid UTF-8 reports a framing error") { _ = try invalid.feed(Data([0xff, 10])) }
        var bounded = AgentSSEFramer(maximumEventBytes: 20)
        t.expectThrows("REA SSE: unclosed large events are bounded") {
            _ = try bounded.feed(Data("data: 123456789\ndata: 123456789\n".utf8))
        }
    } catch { t.check(false, "REA SSE exception: \(error)") }

    let sse = Data("data: {\"choices\":[{\"delta\":{\"content\":\"中文🙂组合👨‍👩‍👧‍👦\"}}]}\n\ndata: [DONE]\n\n".utf8)
    var unicodeSplits = true
    for split in 0...sse.count {
        var d = AgentSSEDecoder(), a = AgentStreamAccumulator()
        for event in d.feed(Data(sse.prefix(split))) + d.feed(Data(sse.dropFirst(split))) + d.finish() { a.ingest(event) }
        unicodeSplits = unicodeSplits && a.content == "中文🙂组合👨‍👩‍👧‍👦" && a.receivedDone
    }
    t.check(unicodeSplits, "REA OpenAI adapter: every raw-byte split preserves complete text")

    let origin = CGPoint(x: 100, y: 200), forward = CGPoint(x: 900, y: 360)
    let c = CanvasEdgeGeometry.controlPoints(start: origin, end: forward, outSide: .right, inSide: .left)
    t.equal(c.0, CGPoint(x: 500, y: 200), "REA Cf: forward source offset is half the axis distance")
    t.equal(c.1, CGPoint(x: 500, y: 360), "REA Cf: target uses its own outward axis")
    let reverse = CanvasEdgeGeometry.controlPoints(start: CGPoint(x: 400, y: 200),
        end: CGPoint(x: 0, y: 360), outSide: .right, inSide: .left)
    t.equal(reverse.0.x, 525, "REA ko: reverse source uses 0.25 * 25 * sqrt(400)")
    t.equal(reverse.1.x, -125, "REA ko: reverse target has matching outward curvature")
    var scaleInvariant = true
    for zoom in [CGFloat(0.25), 0.65, 1, 2, 4] {
        let controls = CanvasEdgeGeometry.controlPoints(start: CGPoint(x: 400 * zoom, y: 200 * zoom),
            end: CGPoint(x: 0, y: 360 * zoom), outSide: .right, inSide: .left, coordinateScale: zoom)
        scaleInvariant = scaleInvariant && abs(controls.0.x / zoom - 525) < 0.001
            && abs(controls.1.x / zoom + 125) < 0.001
    }
    t.check(scaleInvariant, "REA geometry: zoom preserves reverse curve world coordinates")
    let vertical = CanvasEdgeGeometry.controlPoints(start: origin, end: forward, outSide: .bottom, inSide: .top)
    t.equal(vertical.0, CGPoint(x: 100, y: 280), "REA geometry: bottom handle uses vertical distance")
    let zero = CanvasEdgeGeometry.controlPoints(start: .zero, end: .zero, outSide: .right, inSide: .left)
    t.check(zero.0 == .zero && zero.1 == .zero, "REA geometry: coincident endpoints remain finite")
    t.equal(WindowLayoutMetrics.agentPanelWidth(requested: 440, windowWidth: 1440), 440, "REA Agent panel: default 440")
    t.equal(WindowLayoutMetrics.agentPanelWidth(requested: 100, windowWidth: 1440), 360, "REA Agent panel: minimum 360")
    t.check(abs(WindowLayoutMetrics.agentPanelWidth(requested: 2000, windowWidth: 1440) - 691.2) < 0.001,
            "REA Agent panel: maximum 48%")
    t.equal(WindowLayoutMetrics.agentPanelWidth(requested: .nan, windowWidth: 1060), 440, "REA Agent panel: invalid saved width recovers")
    t.equal(WindowLayoutMetrics.agentPanelWidth(requested: 440, windowWidth: 300), 300, "REA Agent panel: narrow host does not overflow")
    let animated = CanvasEdge(fromNodeId: "source", toNodeId: "target", animated: true)
    let restored = try? JSONDecoder().decode(CanvasEdge.self, from: JSONEncoder().encode(animated))
    t.check(restored?.animated == true && restored?.id == animated.id,
            "REA edge animation persists without changing endpoint identity")

    let tools = SmokeToolExecutor()
    let partial = """
    data: {"choices":[{"delta":{"content":"收到部分文字"}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"unfinished","function":{"name":"list_slots","arguments":"{\\"slot\\":"}}]}}]}

    """
    let partialService = AgentService(transport: AgentScriptedTransport(steps: [.sse(partial)]),
                                     secretStore: AgentInMemorySecretStore(key: "test-fixture"))
    let failure: AgentError? = smokeAwait {
        do {
            _ = try await partialService.run(history: [.init(role: .user, content: "fixture")],
                config: AgentConfig(), tools: tools, onEvent: { _ in })
            return nil
        } catch { return error as? AgentError }
    }
    if case .interrupted? = failure { t.check(true, "REA transport: EOF without completion is unknown, never success") }
    else { t.check(false, "REA transport: incomplete response returns interrupted") }
    t.check(tools.calls.isEmpty, "REA tools: partial tool arguments never execute")
}
