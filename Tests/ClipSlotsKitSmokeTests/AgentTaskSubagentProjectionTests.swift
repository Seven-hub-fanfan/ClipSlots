import Foundation
import JavaScriptCore
@testable import ClipSlotsKit

// Original gc/Px/Tx/_x/Ix/Ex bodies from the retained shell excerpts. Closure
// dependencies below are explicit fixtures: call-ID tools, terminal statuses
// completed/failed/stopped/ended_unknown. This does not prove missing Go/hc/ym
// implementations or the full shell normalization and remote scheduler.
private let taskSubagentOracle = #"""
const ym=new Set(["completed","failed","stopped","ended_unknown"]);
const hc=new Set(["completed","failed","stopped","ended_unknown"]);
const Go=e=>typeof e.tool_call_id==="string"&&e.tool_call_id?e.tool_call_id:void 0;
const Da=e=>ym.has(e);
const Rx=(e,t)=>!!(t.parent_tool_call_id&&e.parent_tool_call_id&&t.parent_tool_call_id!==e.parent_tool_call_id);
const Nx=new Set(["started","progress","content","tool_started","tool_completed","completed","failed","stopped"]);
const Tx=(e,t)=>
{const
  n=e??[],
  o=n[n.length-1];
  return o?.kind==="text"?[...n.slice(0,-1),{
    kind:"text",
    text:`${o.text}${t}`}]:[...n,{
    kind:"text",
    text:t}]
};
const _x=(e,t)=>
{const
  n=e??[];
  return!t||n.some(o=>o.kind==="tool"&&o.tool_call_id===t)?n:[...n,{
    kind:"tool",
    tool_call_id:t}]
};
const Ix=e=>e.tool_event&&typeof e.tool_event=="object"?e.tool_event:typeof e.tool_call_id=="string"&&e.tool_call_id?{
  schema_version:"tool_event.v1",
  type:"tool_event",
  tool:e.tool_name||"",
  status:e.tool_status||(e.phase==="tool_completed"?"completed":"started"),
  tool_call_id:e.tool_call_id,
  request:{},
  response:null}:null;
const Px=(e,t)=>
{const
  n=Go(t);
  if(!n)
  return[...e,t];const
  o=e.findIndex(p=>Go(p)===n);
  if(o<0)
  return[...e,t];const
  a=e[o],
  r=typeof a.status=="string"?a.status:"",
  s=typeof t.status=="string"?t.status:"";
  if(hc.has(r)&&!hc.has(s))
  return e;const
  l=[...e],
  c=a.request&&typeof a.request=="object"?a.request:void 0,
  d=t.request&&typeof t.request=="object"?t.request:void 0;
  return l[o]={...t,
    request:d&&Object.keys(d).length>0?d:c??d},l
};
const gc=(e,t,n)=>
{
  if(e===null&&!Nx.has(String(t.phase)))
  return null;const
  o=e??{
    subagent_id:String(t.subagent_id),
    status:"running",
    text:"",
    tools:[]},
  a={...o,
    agent_type:t.agent_type||o.agent_type,
    parent_tool_call_id:t.parent_tool_call_id||o.parent_tool_call_id,
    task_description:t.task_description||o.task_description},
  r=Da(a.status);
  switch(t.phase){case"started":
  return(!r||Rx(o,t))&&(a.status="running"),a;case"progress":
  return r||(a.status="running"),a;case"content":
  return r||n!==void 0&&a.last_content_seq!==void 0&&n<=a.last_content_seq||(a.text=`${a.text}${t.text??""}`,t.text&&(a.timeline=Tx(a.timeline,t.text)),n!==void 0&&(a.last_content_seq=n)),a;case"tool_started":case"tool_completed":
  {const
    s=Ix(t);
    return s&&(a.tools=Px(a.tools,s),a.timeline=_x(a.timeline,Go(s))),a
}case"completed":case"failed":case"stopped":
  return r||(a.status=t.phase),a;default:
  return a}
};
const Ex=e=>
{const
  t=e.split("|")[1];
  if(!t)
  return;const
  n=Number(t);
  return Number.isFinite(n)?n:void 0
};
var state=null;
function receive(text,id){state=gc(state,JSON.parse(text),Ex(id));return JSON.stringify(state)}
"""#

private func subagentWire(_ state: AgentSubagentState) -> JSONValue {
    var value: [String: JSONValue] = ["subagent_id": .string(state.subagentID), "status": .string(state.status.rawValue),
                                     "text": .string(state.text), "tools": .array(state.tools)]
    if let parent = state.parentToolCallID { value["parent_tool_call_id"] = .string(parent) }
    if let type = state.agentType { value["agent_type"] = .string(type) }
    if let description = state.taskDescription { value["task_description"] = .string(description) }
    if let sequence = state.lastContentSequence { value["last_content_seq"] = .number(sequence) }
    if !state.timeline.isEmpty {
        value["timeline"] = .array(state.timeline.map { item in
            switch item {
            case .text(let text): return ["kind": "text", "text": .string(text)]
            case .tool(let id): return ["kind": "tool", "tool_call_id": .string(id)]
            }
        })
    }
    return .object(value)
}

func runTaskSubagentProjectionTests(_ t: TestRunner) {
    func child(_ projection: AgentTaskSubagentProjection, last: Bool = true) -> AgentSubagentState? {
        let states = projection.entries.compactMap { entry -> AgentSubagentState? in
            if case .subagent(let state) = entry.content { return state }; return nil
        }
        return last ? states.last : states.first
    }
    func event(_ phase: String, parent: String = "parent-one", text: String? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["schema_version": "subagent_event.v1", "phase": .string(phase),
            "subagent_id": "child", "parent_tool_call_id": .string(parent)]
        if let text { value["text"] = .string(text) }
        return .object(value)
    }
    do {
        let plan: JSONValue = ["schema_version": "agent_task_snapshot.v1", "plan_ready": false,
            "tasks": [["task_id": "one", "subject": "读图", "status": "pending"]]]
        let accepted = try AgentTaskPlanSnapshot(validating: plan)
        t.equal(accepted.wireValue, plan, "TASK preserve original received plan")
        for invalid: JSONValue in [
            .null, ["schema_version": "task_snapshot.v1", "plan_ready": false, "tasks": []],
            ["schema_version": "agent_task_snapshot.v1", "plan_ready": "false", "tasks": []],
            ["schema_version": "agent_task_snapshot.v1", "plan_ready": true, "tasks": [[]]],
            ["schema_version": "agent_task_snapshot.v1", "plan_ready": true,
             "tasks": [["task_id": "", "subject": "one", "status": "pending"]]],
            ["schema_version": "agent_task_snapshot.v1", "plan_ready": true,
             "tasks": [["task_id": "one", "subject": "one", "status": "stopped"]]]
        ] {
            t.check((try? AgentTaskPlanSnapshot(validating: invalid)) == nil, "TASK malformed plan is not accepted")
        }
        var projection = AgentTaskSubagentProjection()
        let message = UUID(), previous = UUID()
        let anchor = AgentContextCompactionAnchor(messageID: message, afterMessageID: previous,
            content: "中🙂", reasoning: "思", displayOrder: 3)
        _ = try projection.receiveTasks(accepted, eventID: "plan|1", runID: "run", anchor: anchor)
        var ready = plan.objectValue!
        ready["plan_ready"] = true
        let nextAnchor = AgentContextCompactionAnchor(messageID: message, afterMessageID: previous,
            content: "中🙂继续", reasoning: "思考", displayOrder: 5)
        _ = try projection.receiveTasks(.init(validating: .object(ready)), eventID: "plan|2", runID: "run", anchor: nextAnchor)
        t.equal(projection.entries.count, 1, "TASK one snapshot block per assistant")
        t.equal(projection.entries[0].anchor, anchor, "TASK plan replacement preserves original position")
        let changed = try projection.receiveTasks(.init(validating: .object(ready)), eventID: "plan|2", runID: "run", anchor: nextAnchor)
        t.check(!changed, "TASK repeated receipt is ignored")
        let beforeConflict = projection
        t.check((try? projection.receiveTasks(accepted, eventID: "plan|2", runID: "run", anchor: anchor)) == nil,
                "TASK conflicting repeated receipt rejected")
        t.equal(projection, beforeConflict, "TASK receipt rejection is atomic")

        for (id, expected): (String, Double?) in [
            ("e|2", 2), ("e|1.5|extra", 1.5), ("e|-3", -3), ("e|   ", 0),
            ("e|0x10", 16), ("e|0b11", 3), ("e|0o10", 8),
            ("e|9007199254740994", 9007199254740994), ("e|", nil), ("e|Infinity", nil), ("e|bad", nil)
        ] {
            t.equal(AgentTaskSubagentProjection.contentSequence(eventID: id), expected, "CHILD Ex sequence \(id)")
        }

        let vm = JSContext()!
        vm.evaluateScript(taskSubagentOracle)
        var oracleProjection = AgentTaskSubagentProjection()
        var seed: UInt64 = 217104
        // Each group resets the VM so content ordering, terminal behavior and
        // tools all run through reachable pre- and post-terminal states.
        for group in 0..<40 {
            vm.evaluateScript("state=null")
            let run = "oracle-\(group)"
            for operation in 0..<30 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let phases = ["started", "progress", "content", "content", "tool_started", "tool_completed"]
                let phase = operation == 22 ? ["completed", "failed", "stopped"][group % 3]
                    : phases[Int(seed >> 32) % phases.count]
                var payload = event(phase).objectValue!
                if phase == "content" { payload["text"] = .string(operation % 2 == 0 ? "中🙂" : "e\u{301}") }
                if phase.hasPrefix("tool_") {
                    let id = "tool-\(operation % 4)"
                    payload["tool_event"] = ["schema_version": "tool_event.v1", "type": "tool_event",
                        "tool_call_id": .string(id), "tool": "Read", "status": .string(phase == "tool_started" ? "started" : "completed"),
                        "request": phase == "tool_started" ? ["path": "fixture"] : .object([:]),
                        "response": phase == "tool_started" ? .null : "synthetic result"]
                }
                let id = "g\(group)-op\(operation)|\(operation % 7)"
                let value = JSONValue.object(payload)
                _ = try oracleProjection.receiveSubagent(value, eventID: id, runID: run, anchor: anchor)
                let expected = vm.objectForKeyedSubscript("receive")!.call(withArguments: [try value.encodedText(), id])!.toString()!
                t.equal(subagentWire(child(oracleProjection)!), try JSONValue.decode(jsonText: expected),
                        "CHILD original gc local reducer \(group)/\(operation)")
            }
        }

        var children = AgentTaskSubagentProjection()
        _ = try children.receiveSubagent(event("started"), eventID: "e|1", runID: "run", anchor: anchor)
        _ = try children.receiveSubagent(event("content", text: "完整🙂"), eventID: "e|3", runID: "run", anchor: anchor)
        _ = try children.receiveSubagent(event("content", text: "重复"), eventID: "duplicate|3", runID: "run", anchor: anchor)
        _ = try children.receiveSubagent(event("content", text: "旧"), eventID: "old|2", runID: "run", anchor: anchor)
        t.equal(child(children)?.text, "完整🙂", "CHILD same and old sequence never append")
        _ = try children.receiveSubagent(event("stopped"), eventID: "e|4", runID: "run", anchor: anchor)
        _ = try children.receiveSubagent(event("progress"), eventID: "e|5", runID: "run", anchor: anchor)
        _ = try children.receiveSubagent(event("started"), eventID: "e|6", runID: "run", anchor: anchor)
        _ = try children.receiveSubagent(event("content", text: "迟到"), eventID: "e|7", runID: "run", anchor: anchor)
        t.equal(child(children)?.status, .stopped, "CHILD same parent never reopens terminal")
        t.equal(child(children)?.text, "完整🙂", "CHILD terminal content remains original")
        _ = try children.receiveSubagent(event("started", parent: "parent-two"), eventID: "e|8", runID: "run", anchor: nextAnchor)
        t.equal(children.entries.count, 2, "CHILD successor preserves predecessor")
        t.equal(child(children)?.status, .running, "CHILD distinct explicit parent starts new instance")
        t.equal(child(children)?.text, "", "CHILD successor does not inherit old text")
        _ = try children.receiveSubagent(event("content", parent: "parent-one", text: "旧实例"), eventID: "e|9", runID: "run", anchor: anchor)
        _ = try children.receiveSubagent(event("started", parent: "parent-one"), eventID: "e|10", runID: "run", anchor: anchor)
        t.equal(child(children)?.parentToolCallID, "parent-two", "CHILD retired parent cannot replace successor")
        t.equal(child(children, last: false)?.status, .stopped, "CHILD historical stop remains stop")
        let restored = try JSONDecoder().decode(AgentTaskSubagentProjection.self, from: JSONEncoder().encode(children))
        t.equal(restored, children, "CHILD full identities text tools timeline receipts persist")
        children.finish(runID: "run")
        t.equal(child(children)?.status, .endedUnknown, "CHILD parent completion does not invent child completion")
        let legacy = try AgentSubagentState(legacy: ["subagent_id": "old", "status": "unrecognized", "text": "保留",
            "tools": [["tool_call_id": "t", "status": "completed"]]])
        t.equal(legacy.status, .endedUnknown, "CHILD old unknown status stays unknown")
        t.equal(legacy.tools[0]["schema_version"], "tool_event.v1", "CHILD legacy tool fields normalized")

        let parts = AgentContextCompactionLifecycle.project(content: "中🙂尾", reasoning: "思考",
            cards: [], identity: "body", taskSubagents: projection.entries)
        let bytes = parts.compactMap { part -> String? in
            if case .assistant(let text, _) = part.kind { return text }; return nil
        }.joined()
        t.equal(Data(bytes.utf8), Data("中🙂尾".utf8), "TASK display segmentation keeps every body byte")
        t.check(parts.contains { if case .taskSubagent = $0.kind { return true }; return false },
                "TASK display includes actual snapshot at anchor")
    } catch { t.check(false, "TASK/CHILD unexpected error \(error)") }
}
