import Foundation
import JavaScriptCore
@testable import ClipSlotsKit

// Original uw body, unchanged except whitespace. Sn is an explicit identity
// dependency for compact-only arrays; this does not test shell normalization.
private let compactOracle = #"""
const Sn=e=>e;
const uw=(e,t)=>
{const
  n=Sn(e.contents||[]);
  for(let
  o=n.length-1;o>=0;o--)
  {const
    a=n[o];
    if(a.type!=="compact"||!a.content||typeof a.content!="object")
    continue;const
    r=a.content;
    if(r.phase!=="started")
    continue;
    if(t==="started")
    return e;const
    s=[...n];
    return s[o]={...a,
      content:{...r,
        phase:t}},{...e,
      contents:s}
}
  return{...e,
    contents:[...n,{
      type:"compact",
      content:{
        phase:t}}]}
};
var state={contents:[]};
function receive(phase){state=uw(state,phase);return JSON.stringify(state.contents.map(x=>x.content.phase))}
"""#

func runContextCompactionTranscriptTests(_ t: TestRunner) {
    let vm = JSContext()!
    vm.evaluateScript(compactOracle)
    var lifecycle = AgentContextCompactionLifecycle()
    var seed: UInt64 = 217104
    for index in 0..<1200 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let phase: AgentContextCompactionPhase = seed >> 32 & 3 == 0 ? .finished : .started
        lifecycle.receive(phase, eventID: "event-\(index)")
        let expected = vm.objectForKeyedSubscript("receive")!.call(withArguments: [phase.rawValue])!.toString()!
        t.equal(try? JSONEncoder().encode(lifecycle.entries.map { $0.phase.rawValue }),
                expected.data(using: .utf8), "COMPACT uw distinct event \(index)")
    }
    do {
        let message = UUID(), previous = UUID()
        let before = "中👨‍👩‍👧e", after = "\u{301}后"
        let thought = "思考🙂", laterThought = "下一步"
        let first = AgentContextCompactionAnchor(messageID: message, afterMessageID: previous,
                                                content: before, reasoning: thought)
        var cards = AgentContextCompactionLifecycle()
        t.check(cards.receive(.started, eventID: "start", runID: "one", anchor: first), "COMPACT start accepted")
        t.check(!cards.receive(.started, eventID: "start", runID: "one", anchor: first), "COMPACT same receipt not duplicated")
        t.check(!cards.receive(.started, eventID: "different-start", runID: "one", anchor: first),
                "COMPACT second started remains same card")
        t.check(cards.receive(.finished, eventID: "finish", runID: "one", anchor: nil), "COMPACT finish updates start")
        t.check(!cards.receive(.finished, eventID: "finish", runID: "one"), "COMPACT repeated finish receipt ignored")
        let second = AgentContextCompactionAnchor(messageID: message, afterMessageID: previous,
            content: before + after, reasoning: thought + laterThought)
        cards.receive(.started, eventID: "start-two", runID: "one", anchor: second)
        cards.receive(.finished, eventID: "finish-two", runID: "one")
        let parts = AgentContextCompactionLifecycle.project(content: before + after + "尾",
            reasoning: thought + laterThought + "末", cards: cards.entries, identity: message.uuidString)
        let texts = parts.compactMap { part -> String? in
            if case .assistant(let text, _) = part.kind { return text }; return nil
        }
        let thoughts = parts.compactMap { part -> String? in
            if case .assistant(_, let text) = part.kind { return text }; return nil
        }
        t.equal(texts, [before, after, "尾"], "COMPACT combining character split remains receipt aligned")
        t.equal(thoughts, [thought, laterThought, "末"], "COMPACT thinking separates before and after compression")
        t.equal(Data(texts.joined().utf8), Data((before + after + "尾").utf8), "COMPACT content retains exact bytes")
        t.equal(Data(thoughts.joined().utf8), Data((thought + laterThought + "末").utf8), "COMPACT reasoning retains exact bytes")
        t.equal(Set(parts.map(\.id)).count, parts.count, "COMPACT part identities unique")
        t.equal(parts.filter(\.isTail).count, 1, "COMPACT one streaming tail")
        t.equal(try JSONDecoder().decode(AgentContextCompactionLifecycle.self, from: JSONEncoder().encode(cards)),
                cards, "COMPACT real persisted anchors roundtrip")
        let encoded = try JSONEncoder().encode(first)
        var invalid = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        invalid["contentBytes"] = -1
        t.check((try? JSONDecoder().decode(AgentContextCompactionAnchor.self,
            from: JSONSerialization.data(withJSONObject: invalid))) == nil, "COMPACT rejects negative saved coordinate")
        invalid["contentBytes"] = 1 // middle of Chinese scalar: must neither lose bytes nor emit replacement chars
        let malformed = try JSONDecoder().decode(AgentContextCompactionAnchor.self,
                                                 from: JSONSerialization.data(withJSONObject: invalid))
        var damaged = AgentContextCompactionLifecycle()
        damaged.receive(.finished, eventID: "bad", runID: "one", anchor: malformed)
        let safe = AgentContextCompactionLifecycle.project(content: before, reasoning: thought,
            cards: damaged.entries, identity: "safe").compactMap { part -> String? in
                if case .assistant(let text, _) = part.kind { return text }; return nil
            }.joined()
        t.equal(Data(safe.utf8), Data(before.utf8), "COMPACT malformed UTF8 coordinate cannot corrupt body")

        var stale = AgentContextCompactionLifecycle()
        stale.receive(.started, eventID: "start", runID: "one", anchor: first)
        cards.merge(stale, runID: "one")
        t.equal(cards.entries.first?.phase, .finished, "COMPACT old metadata never reopens completed")
        cards.receive(.started, eventID: "start", runID: "two", anchor: first)
        cards.receive(.finished, eventID: "finish", runID: "two")
        t.equal(cards.entries.count, 3, "COMPACT identical receipts in new run keep separate history")
        t.equal(Set(cards.entries.map(\.displayID)).count, 3, "COMPACT run namespace gives unique card IDs")
        cards.receive(.started, eventID: "interrupted", runID: "two", anchor: second)
        cards.interrupt()
        t.equal(cards.entries.count, 3, "COMPACT interrupt removes unfinished without claiming success")
        var unresolved = AgentContextCompactionLifecycle()
        unresolved.receive(.finished, eventID: "finish", runID: "local",
            anchor: .init(messageID: nil, afterMessageID: previous, content: "", reasoning: ""))
        unresolved.attachPending(to: message, runID: "wrong")
        t.equal(unresolved.entries.first?.anchor?.messageID, nil, "COMPACT other run cannot attach pending card")
        unresolved.attachPending(to: message, runID: "local")
        t.equal(unresolved.entries.first?.anchor?.messageID, message, "COMPACT completion binds exact assistant")
        unresolved.attachPending(to: UUID(), runID: "local")
        t.equal(unresolved.entries.first?.anchor?.messageID, message, "COMPACT later completion cannot relocate card")
        unresolved.receive(.finished, eventID: "between", runID: "local",
            anchor: .init(messageID: nil, afterMessageID: previous, content: "", reasoning: "", awaitingAssistant: false))
        unresolved.attachPending(to: message, runID: "local")
        t.equal(unresolved.entries.last?.anchor?.messageID, nil, "COMPACT between-message card never moves into next assistant")
        unresolved.retain(through: [previous])
        t.equal(unresolved.entries.map(\.id), ["between"], "COMPACT fork before assistant preserves only between-message card")
        let legacy = try JSONDecoder().decode(AgentContextCompactionLifecycle.self,
            from: Data(#"{"entries":[{"id":"legacy","phase":"finished"}]}"#.utf8))
        t.equal(legacy.entries.first?.anchor, nil, "COMPACT old session remains readable without invented anchor")
    } catch { t.check(false, "COMPACT transcript fixture \(type(of: error))") }
}
