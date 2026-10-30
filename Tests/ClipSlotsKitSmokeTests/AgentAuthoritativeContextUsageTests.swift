import Foundation
import JavaScriptCore
@testable import ClipSlotsKit

/// Original Qn/jx/un/wm bodies from the 2026-10-28 REA code evidence.
/// Used only in this offline test VM; no browser, SDK or cloud is simulated.
private let usageOracle = #"""
function Qn(e)
{
  if(!e||typeof e!="object")
  return!1;const
  t=e,
  n=r=>r===null||typeof r=="number"&&Number.isFinite(r)&&r>=0;
  return typeof t.conversation_id=="string"&&t.conversation_id.length>0&&typeof t.run_id=="string"&&t.run_id.length>0&&(t.runtime_session_id===null||typeof t.runtime_session_id=="string")&&typeof t.revision=="number"&&Number.isSafeInteger(t.revision)&&t.revision>=0&&n(t.used_tokens)&&n(t.max_tokens)&&t.max_tokens!==0&&n(t.percentage)&&(t.percentage===null||t.max_tokens!==null&&t.used_tokens!==null)&&(t.model===null||typeof t.model=="string")&&["sdk","last_request_usage","unavailable"].includes(t.source)&&["ready","stale","unavailable"].includes(t.status)&&(t.status!=="ready"||t.used_tokens!==null&&t.source!=="unavailable")&&(t.status!=="unavailable"||t.used_tokens===null&&t.max_tokens===null&&t.percentage===null)&&typeof t.observed_at=="string"&&Number.isFinite(Date.parse(t.observed_at))&&(t.last_good===void 0||t.last_good===null||typeof t.last_good=="object"&&!("last_good"in t.last_good)&&Qn(t.last_good)&&t.last_good.status==="ready"&&t.last_good.conversation_id===t.conversation_id&&t.last_good.revision<=t.revision)
}
const Vf=Qn;
const wm=()=>({snapshot:null,displaySnapshot:null,localVersion:0,stale:!1,compaction:"idle"});
function un(e) {return{...e,stale:!0,localVersion:e.localVersion+1}}
function jx(e,t,n,o,a=!1,r=e.localVersion)
{
  if(a&&r!==e.localVersion||!Vf(t)||t.conversation_id!==n||!a&&o!==null&&t.run_id!==o||e.snapshot!==null&&t.revision<=e.snapshot.revision)
  return e;const
  s=e.displaySnapshot,
  l=s?.source==="sdk"&&s.percentage!==null&&s.max_tokens!==null,
  c=t.source==="sdk"&&t.percentage!==null&&t.max_tokens!==null,
  p={
    displaySnapshot:(t.status==="ready"||s===null&&t.status==="stale")&&t.source!=="unavailable"&&t.used_tokens!==null&&!(l&&!c)?t:s,
    localVersion:e.localVersion,
    snapshot:t,
    stale:t.status!=="ready"||e.compaction==="started",
    compaction:e.compaction==="finished"&&t.status==="ready"?"idle":e.compaction};
  return t.last_good!==void 0?{...p,
    displaySnapshot:t.last_good??(t.status==="ready"?t:null)}:p
}
var state=wm();
function receive(v,c,r,a,version){state=jx(state,v,c,r,a,version);return JSON.stringify(state)}
function invalid(){state=un(state);return JSON.stringify(state)}
function compact(phase){state={...un(state),compaction:phase};return JSON.stringify(state)}
"""#

func usageTestValue(revision: Double = 1, conversation: String = "session", run: String = "opaque/run+one",
                    source: String = "sdk", status: String = "ready", percentage: JSONValue = 200) -> JSONValue {
    ["conversation_id": .string(conversation), "run_id": .string(run), "runtime_session_id": .null,
     "revision": .number(revision), "used_tokens": 200, "max_tokens": 100, "percentage": percentage,
     "model": "fixture", "source": .string(source), "status": .string(status),
     "observed_at": "2026-10-29T02:00:00.123Z"]
}

func runAuthoritativeContextUsageTests(_ t: TestRunner) {
    let context = JSContext()!
    context.evaluateScript(usageOracle)
    func object(_ value: JSONValue) -> Any { try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    func agrees(_ value: JSONValue, _ name: String) {
        let original = context.objectForKeyedSubscript("Qn")!.call(withArguments: [object(value)])!.toBool()
        t.equal((try? AgentContextUsageSnapshot(validating: value)) != nil, original, "USAGE source Qn " + name)
    }
    let valid = usageTestValue()
    agrees(valid, "percentage over 100 is valid")
    let fields = ["conversation_id", "run_id", "runtime_session_id", "revision", "used_tokens", "max_tokens",
                  "percentage", "model", "source", "status", "observed_at"]
    for field in fields {
        var value = valid.objectValue!
        value.removeValue(forKey: field)
        agrees(.object(value), "missing " + field)
        for replacement: JSONValue in [.null, true, -1, 0, 0.5, 9_007_199_254_740_991,
                                      9_007_199_254_740_992, "", "1", "bad", [], [:]] {
            value = valid.objectValue!; value[field] = replacement
            agrees(.object(value), "\(field)=\(replacement)")
        }
    }
    for date in ["Thu, 01 Jan 1970 00:00:00 GMT", "10/29/2026", "2026-10-29", "2026-02-30", "bad date", "1"] {
        var value = valid.objectValue!; value["observed_at"] = .string(date)
        agrees(.object(value), "Date.parse " + date)
    }
    for source in ["sdk", "last_request_usage", "unavailable"] {
        for status in ["ready", "stale", "unavailable"] {
            for counts: [JSONValue] in [[.null, .null, .null], [0, .null, .null], [200, 100, 200], [200, .null, 200]] {
                var value = usageTestValue(source: source, status: status).objectValue!
                value["used_tokens"] = counts[0]; value["max_tokens"] = counts[1]; value["percentage"] = counts[2]
                agrees(.object(value), "\(source)/\(status)/\(counts)")
            }
        }
    }
    for good in [JSONValue.null, valid, usageTestValue(revision: 2),
                 usageTestValue(conversation: "other"), usageTestValue(status: "stale")] {
        var value = valid.objectValue!; value["last_good"] = good
        agrees(.object(value), "last_good \(good)")
    }
    var nested = valid.objectValue!; nested["last_good"] = .null
    var parent = valid.objectValue!; parent["last_good"] = .object(nested)
    agrees(.object(parent), "last_good nested explicit null is invalid")
    for field in ["used_tokens", "max_tokens", "percentage", "revision"] {
        for number in [Double.nan, Double.infinity, -Double.infinity] {
            var value = valid.objectValue!; value[field] = .number(number)
            t.check((try? AgentContextUsageSnapshot(validating: .object(value))) == nil, "USAGE rejects nonfinite " + field)
        }
    }
    do {
        var state = AgentContextUsageState()
        var seed: UInt64 = 431789
        func random(_ max: UInt64) -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (seed >> 32) % max
        }
        func checkState(_ text: String, _ name: String) throws {
            var oracle = try JSONValue.decode(jsonText: text).objectValue!
            if oracle["snapshot"] == .null { oracle.removeValue(forKey: "snapshot") }
            if oracle["displaySnapshot"] == .null { oracle.removeValue(forKey: "displaySnapshot") }
            var swift = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(state)).objectValue!
            swift.removeValue(forKey: "schemaVersion")
            t.equal(JSONValue.object(swift), .object(oracle), name)
        }
        for index in 0..<1800 {
            let operation = random(12)
            if operation == 0 {
                state.invalidate()
                try checkState(context.objectForKeyedSubscript("invalid")!.call(withArguments: [])!.toString(), "USAGE jx/un \(index)")
            } else if operation == 1 {
                let phase: AgentContextCompactionPhase = random(2) == 0 ? .started : .finished
                state.setCompaction(phase)
                try checkState(context.objectForKeyedSubscript("compact")!.call(withArguments: [phase.rawValue])!.toString(),
                               "USAGE compact \(index)")
            } else {
                let revision = Double(index + 1) - Double(random(5))
                let conversation = random(8) == 0 ? "other" : "session"
                let run = random(8) == 0 ? "old-run" : "opaque/run+one"
                let source = random(2) == 0 ? "sdk" : "last_request_usage"
                let status = random(2) == 0 ? "ready" : "stale"
                var value = usageTestValue(revision: max(0, revision), conversation: conversation, run: run,
                    source: source, status: status, percentage: random(2) == 0 ? 200 : .null).objectValue!
                if random(6) == 0 { value["last_good"] = .null }
                if random(9) == 0 { value["last_good"] = usageTestValue(revision: max(0, revision - 1), conversation: conversation) }
                let snapshotRequest = random(3) == 0
                let requested = state.localVersion - min(state.localVersion, random(2))
                let incoming = try AgentContextUsageSnapshot(validating: .object(value))
                state.receive(incoming, conversationID: "session", runID: "opaque/run+one",
                    requestedAtVersion: snapshotRequest ? requested : nil)
                let text = context.objectForKeyedSubscript("receive")!.call(withArguments: [
                    object(.object(value)), "session", "opaque/run+one", snapshotRequest, requested])!.toString()!
                try checkState(text, "USAGE original reducer parity \(index)")
            }
        }
        let encoded = try JSONEncoder().encode(state)
        t.equal(try JSONDecoder().decode(AgentContextUsageState.self, from: encoded), state, "USAGE durable projection restores exactly")
        var versioned = try JSONDecoder().decode(JSONValue.self, from: encoded).objectValue!
        versioned["schemaVersion"] = 2
        t.check((try? JSONDecoder().decode(AgentContextUsageState.self, from: JSONEncoder().encode(JSONValue.object(versioned)))) == nil,
                "USAGE unknown persisted version is rejected")
        var display = AgentContextUsageState()
        display.receive(try .init(validating: valid), conversationID: "session", runID: "opaque/run+one")
        t.equal(AgentContextUsageDisplay(state: display).percentage, 200, "USAGE display text preserves 200%")
        t.equal(AgentContextUsageDisplay(state: display).fraction, 1, "USAGE display ring clamps 200% only at rendering")
        display.setCompaction(.started)
        t.equal(AgentContextUsageDisplay(state: display).statusLabel, "正在压缩", "USAGE compact start shown stale")
        display.setCompaction(.finished)
        t.equal(AgentContextUsageDisplay(state: display).statusLabel, "等待压缩后用量", "USAGE compact finish waits for ready")
        display.receive(try .init(validating: usageTestValue(revision: 2)), conversationID: "session", runID: "opaque/run+one")
        t.check(!display.stale && display.compaction == .idle, "USAGE new ready closes compact only after server observation")
        let current = display
        display.invalidate()
        t.check(!display.hydrate(current, conversationID: "session", requestedAtVersion: current.localVersion),
                "USAGE late metadata hydration discarded after invalidation")
        t.check(!display.hydrate(current, conversationID: "session", requestedAtVersion: display.localVersion) && display.stale,
                "USAGE equal-revision hydration cannot replace local state")
        t.check(!display.hydrate(current, conversationID: "other", requestedAtVersion: display.localVersion),
                "USAGE hydration cannot cross conversation")
        var fresh = AgentContextUsageState()
        fresh.receive(try .init(validating: usageTestValue(revision: 3)), conversationID: "session", runID: "opaque/run+one")
        t.check(display.hydrate(fresh, conversationID: "session", requestedAtVersion: display.localVersion) && !display.stale,
                "USAGE higher ready metadata with unchanged version restores fresh state")
        display.setCompaction(.started)
        fresh.receive(try .init(validating: usageTestValue(revision: 4)), conversationID: "session", runID: "opaque/run+one")
        t.check(display.hydrate(fresh, conversationID: "session", requestedAtVersion: display.localVersion)
                && display.stale && display.compaction == .started,
                "USAGE higher metadata preserves active local compaction until finish")
        var beforeObservation = AgentContextUsageState()
        beforeObservation.setCompaction(.started)
        var recoveredBeforeObservation = AgentContextUsageState()
        t.check(recoveredBeforeObservation.hydrate(beforeObservation, conversationID: "session", requestedAtVersion: 0)
                && recoveredBeforeObservation.compaction == .started,
                "USAGE restores compact lifecycle before first context observation")
        t.check(!recoveredBeforeObservation.hydrate(.init(), conversationID: "session", requestedAtVersion: 0)
                && recoveredBeforeObservation.compaction == .started,
                "USAGE empty metadata cannot clear a local compact lifecycle")
        var inconsistent = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(current)).objectValue!
        inconsistent["displaySnapshot"] = usageTestValue(revision: 90)
        t.check((try? JSONDecoder().decode(AgentContextUsageState.self,
                from: JSONEncoder().encode(JSONValue.object(inconsistent)))) == nil,
                "USAGE inconsistent persisted display revision rejected")
        var lifecycle = AgentContextCompactionLifecycle()
        lifecycle.receive(.started, eventID: "one")
        lifecycle.receive(.started, eventID: "duplicate")
        lifecycle.receive(.finished, eventID: "finished")
        t.check(lifecycle.entries.count == 1 && lifecycle.entries[0].phase == .finished,
                "USAGE compact updates active lifecycle once")
        lifecycle.receive(.started, eventID: "two")
        lifecycle.interrupt()
        t.equal(lifecycle.entries.count, 1, "USAGE aborted lifecycle removed while finished remains")
    } catch { t.check(false, "USAGE fixture failure \(type(of: error))") }
}
